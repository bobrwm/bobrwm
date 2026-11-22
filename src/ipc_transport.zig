//! Background IPC socket accept/read transport.
//!
//! A libdispatch read source monitors the listening Unix socket on a serial
//! queue so idle daemons incur zero polling wakeups. The transport owns client
//! sockets until the main thread pops a complete request; parsing and state
//! mutation deliberately remain outside this module.

const std = @import("std");
const posix = std.posix;
const c = @import("c");
const cg_extra = @import("cg_extra");

const ipc = @import("ipc.zig");
const osutil = @import("osutil.zig");
const spsc_queue = @import("spsc_queue.zig");

const log = std.log.scoped(.ipc_transport);

/// Total time a connected IPC client has to finish sending its command.
const read_timeout_ms: i64 = 1000;
/// Poll slice inside `readRequest` so `stop()` interrupts a silent client
/// promptly instead of waiting out the full read timeout.
const read_poll_slice_ms: i32 = 50;
/// Rate-limit level-triggered `accept()` retries when the process is out of
/// file descriptors, avoiding a 100% CPU spin loop.
const accept_backoff_ns: i64 = 50 * std.time.ns_per_ms;

pub const Request = struct {
    fd: posix.socket_t,
    len: u16,
    buf: [512]u8,

    /// Return the trimmed command bytes read from the client.
    pub fn command(self: *const Request) []const u8 {
        return self.buf[0..self.len];
    }
};

const RequestQueue = spsc_queue.Queue(Request, 16);
const WakeFn = *const fn () void;

pub const Transport = struct {
    const Self = @This();

    queue: RequestQueue = .{},
    dispatch_queue: c.dispatch_queue_t = null,
    source: c.dispatch_source_t = null,
    cancel_done: c.dispatch_semaphore_t = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    listener_fd: posix.socket_t = -1,
    wake: ?WakeFn = null,

    /// Start accepting requests from an already-listening Unix socket.
    pub fn start(self: *Self, listener_fd: posix.socket_t, wake: WakeFn) !void {
        std.debug.assert(self.source == null);
        std.debug.assert(self.dispatch_queue == null);
        std.debug.assert(listener_fd >= 0);

        // Nonblocking accept lets the read source drain the listen backlog
        // without blocking if a peer drops between kqueue wakeup and accept.
        if (!setNonBlocking(listener_fd, true)) return error.ListenerConfigureFailed;

        const cancel_done = c.dispatch_semaphore_create(0) orelse return error.DispatchSemaphoreFailed;
        errdefer c.dispatch_release(.{ ._dsema = cancel_done });

        const attr = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_USER_INITIATED, 0);
        const dispatch_queue = c.dispatch_queue_create("com.bobrwm.ipc", attr) orelse
            return error.DispatchQueueFailed;
        errdefer c.dispatch_release(.{ ._dq = dispatch_queue });

        const source = c.dispatch_source_create(
            cg_extra.DISPATCH_SOURCE_TYPE_READ(),
            @intCast(listener_fd),
            0,
            dispatch_queue,
        ) orelse return error.DispatchSourceFailed;

        self.listener_fd = listener_fd;
        self.wake = wake;
        self.stop_requested.store(false, .release);
        self.cancel_done = cancel_done;
        self.dispatch_queue = dispatch_queue;
        self.source = source;

        c.dispatch_set_context(.{ ._ds = source }, self);
        c.dispatch_source_set_event_handler_f(source, acceptReady);
        c.dispatch_source_set_cancel_handler_f(source, sourceCancelled);
        c.dispatch_resume(.{ ._ds = source });
    }

    /// Stop accepting and close any client sockets not yet consumed. Waits
    /// for the read source's cancel handler so the caller can safely close
    /// `listener_fd` immediately afterward.
    pub fn stop(self: *Self) void {
        self.stop_requested.store(true, .release);
        if (self.source) |source| {
            c.dispatch_source_cancel(source);
            _ = c.dispatch_semaphore_wait(self.cancel_done, c.DISPATCH_TIME_FOREVER);
            c.dispatch_release(.{ ._ds = source });
            self.source = null;
        }
        if (self.cancel_done) |sem| {
            c.dispatch_release(.{ ._dsema = sem });
            self.cancel_done = null;
        }
        if (self.dispatch_queue) |dispatch_queue| {
            c.dispatch_release(.{ ._dq = dispatch_queue });
            self.dispatch_queue = null;
        }

        while (self.queue.pop()) |request| {
            _ = std.c.close(request.fd);
        }
        self.listener_fd = -1;
        self.wake = null;
    }

    /// Transfer ownership of the oldest complete request to the caller.
    pub fn pop(self: *Self) ?Request {
        return self.queue.pop();
    }

    fn acceptReady(context: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(context orelse return));
        while (!self.stop_requested.load(.acquire)) {
            const client_fd = std.c.accept(self.listener_fd, null, null);
            if (client_fd < 0) {
                switch (posix.errno(client_fd)) {
                    .INTR => continue,
                    .AGAIN => return,
                    .MFILE, .NFILE, .NOBUFS, .NOMEM => |err| {
                        if (!self.stop_requested.load(.acquire)) {
                            log.warn("IPC accept resource limit: {}", .{err});
                            sleepNs(accept_backoff_ns);
                        }
                        return;
                    },
                    else => |err| {
                        if (!self.stop_requested.load(.acquire)) {
                            log.warn("IPC accept failed: {}", .{err});
                        }
                        return;
                    },
                }
            }
            if (!configureClient(client_fd)) {
                _ = std.c.close(client_fd);
                continue;
            }

            const request = readRequest(client_fd, &self.stop_requested) orelse {
                _ = std.c.close(client_fd);
                continue;
            };
            if (!self.queue.push(request)) {
                ipc.writeResponse(client_fd, "err: IPC queue busy\n");
                _ = std.c.close(client_fd);
                continue;
            }
            self.wake.?();
        }
    }

    fn sourceCancelled(context: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(context orelse return));
        _ = c.dispatch_semaphore_signal(self.cancel_done);
    }
};

fn sleepNs(duration_ns: i64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(@divTrunc(duration_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(duration_ns, std.time.ns_per_s)),
    };
    _ = std.c.nanosleep(&req, null);
}

fn setNonBlocking(fd: posix.socket_t, enabled: bool) bool {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    const updated = if (enabled) flags | c.O_NONBLOCK else flags & ~@as(c_int, c.O_NONBLOCK);
    return c.fcntl(fd, c.F_SETFL, updated) == 0;
}

fn configureClient(fd: posix.socket_t) bool {
    // On macOS, accept() inherits O_NONBLOCK from the listening socket. Clear
    // it so readRequest and ipc.writeResponse keep blocking + SO_SNDTIMEO.
    if (!setNonBlocking(fd, false)) {
        log.warn("IPC client blocking-mode restore failed", .{});
        return false;
    }
    ipc.disableSigpipe(fd);
    const timeout: std.c.timeval = .{ .sec = 0, .usec = 250_000 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        log.warn("IPC send timeout setup failed: {}", .{err});
    };
    return true;
}

fn readRequest(fd: posix.socket_t, stop_requested: *const std.atomic.Value(bool)) ?Request {
    var request: Request = .{ .fd = fd, .len = 0, .buf = undefined };
    var written: usize = 0;
    const deadline_ns = osutil.nanoTimestamp() + read_timeout_ms * std.time.ns_per_ms;

    while (written < request.buf.len) {
        if (stop_requested.load(.acquire)) return null;
        const remaining_ns = deadline_ns - osutil.nanoTimestamp();
        if (remaining_ns <= 0) return null;

        const remaining_ms: i32 = @intCast(@max(@as(i128, 1), @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, @min(remaining_ms, read_poll_slice_ms)) catch return null;
        if (ready == 0) continue;

        const n = posix.read(fd, request.buf[written..]) catch return null;
        if (n == 0) break;
        written += n;
    }

    if (written == request.buf.len) {
        ipc.writeResponse(fd, "err: command too long\n");
        return null;
    }

    const command = std.mem.trimEnd(u8, request.buf[0..written], &.{ '\n', '\r', ' ', 0 });
    if (command.len == 0) return null;
    request.len = @intCast(command.len);
    return request;
}

fn openTestSocket(path: [:0]const u8) !struct { fd: posix.socket_t, addr: posix.sockaddr.un } {
    _ = std.c.unlink(path.ptr);
    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    addr.path[path.len] = 0;
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 32) != 0) return error.ListenFailed;
    return .{ .fd = fd, .addr = addr };
}

test "transport accepts requests via dispatch read source and stops cleanly" {
    const testing = std.testing;
    const Probe = struct {
        var woken: c.dispatch_semaphore_t = null;

        fn wake() void {
            _ = c.dispatch_semaphore_signal(woken);
        }
    };
    Probe.woken = c.dispatch_semaphore_create(0);
    defer c.dispatch_release(.{ ._dsema = Probe.woken });

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/bobrwm-ipc-test-{d}.sock", .{std.c.getpid()}, 0);
    defer _ = std.c.unlink(path.ptr);

    const listener = try openTestSocket(path);
    defer _ = std.c.close(listener.fd);

    var transport: Transport = .{};
    try transport.start(listener.fd, Probe.wake);
    defer transport.stop();

    const client_fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try testing.expect(client_fd >= 0);
    defer _ = std.c.close(client_fd);
    try testing.expectEqual(@as(c_int, 0), std.c.connect(client_fd, @ptrCast(&listener.addr), @sizeOf(posix.sockaddr.un)));

    const msg = "retile\n";
    try testing.expectEqual(@as(isize, msg.len), std.c.write(client_fd, msg.ptr, msg.len));
    try testing.expectEqual(@as(c_int, 0), std.c.shutdown(client_fd, std.c.SHUT.WR));

    const wait_result = c.dispatch_semaphore_wait(Probe.woken, c.dispatch_time(c.DISPATCH_TIME_NOW, 2 * std.time.ns_per_s));
    try testing.expectEqual(@as(c_long, 0), wait_result);

    const req = transport.pop() orelse return error.TestUnexpectedResult;
    defer _ = std.c.close(req.fd);
    try testing.expectEqualStrings("retile", req.command());

    ipc.writeResponse(req.fd, "ok\n");
    var reply: [16]u8 = undefined;
    const read_n = try posix.read(client_fd, &reply);
    try testing.expectEqualStrings("ok\n", reply[0..read_n]);
}

test "transport returns busy when queue is full and stops promptly with a silent client" {
    const testing = std.testing;
    const Probe = struct {
        var woken: c.dispatch_semaphore_t = null;

        fn wake() void {
            _ = c.dispatch_semaphore_signal(woken);
        }
    };
    Probe.woken = c.dispatch_semaphore_create(0);
    defer c.dispatch_release(.{ ._dsema = Probe.woken });

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/bobrwm-ipc-busy-{d}.sock", .{std.c.getpid()}, 0);
    defer _ = std.c.unlink(path.ptr);

    const listener = try openTestSocket(path);
    defer _ = std.c.close(listener.fd);

    var transport: Transport = .{};
    try transport.start(listener.fd, Probe.wake);

    // Fill all 16 queue slots without popping.
    var clients: [16]posix.socket_t = undefined;
    for (&clients) |*client| {
        client.* = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        try testing.expect(client.* >= 0);
        try testing.expectEqual(@as(c_int, 0), std.c.connect(client.*, @ptrCast(&listener.addr), @sizeOf(posix.sockaddr.un)));
        try testing.expectEqual(@as(isize, 7), std.c.write(client.*, "retile\n", 7));
        try testing.expectEqual(@as(c_int, 0), std.c.shutdown(client.*, std.c.SHUT.WR));
    }
    defer for (clients) |client| {
        _ = std.c.close(client);
    };
    for (0..clients.len) |_| {
        try testing.expectEqual(
            @as(c_long, 0),
            c.dispatch_semaphore_wait(Probe.woken, c.dispatch_time(c.DISPATCH_TIME_NOW, 2 * std.time.ns_per_s)),
        );
    }

    // The 17th client must receive the busy error rather than blocking.
    const overflow_fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try testing.expect(overflow_fd >= 0);
    defer _ = std.c.close(overflow_fd);
    try testing.expectEqual(@as(c_int, 0), std.c.connect(overflow_fd, @ptrCast(&listener.addr), @sizeOf(posix.sockaddr.un)));
    try testing.expectEqual(@as(isize, 7), std.c.write(overflow_fd, "retile\n", 7));
    try testing.expectEqual(@as(c_int, 0), std.c.shutdown(overflow_fd, std.c.SHUT.WR));

    var busy_reply: [64]u8 = undefined;
    const busy_n = try posix.read(overflow_fd, &busy_reply);
    try testing.expectEqualStrings("err: IPC queue busy\n", busy_reply[0..busy_n]);

    // Connect a silent client that never sends anything, then ensure stop()
    // interrupts it well before the 1000ms read deadline.
    const silent_fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try testing.expect(silent_fd >= 0);
    defer _ = std.c.close(silent_fd);
    try testing.expectEqual(@as(c_int, 0), std.c.connect(silent_fd, @ptrCast(&listener.addr), @sizeOf(posix.sockaddr.un)));
    sleepNs(20 * std.time.ns_per_ms);

    const stop_start_ns = osutil.nanoTimestamp();
    transport.stop();
    const stop_elapsed_ms = @divTrunc(osutil.nanoTimestamp() - stop_start_ns, std.time.ns_per_ms);
    try testing.expect(stop_elapsed_ms < 500);
}
