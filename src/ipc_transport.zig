//! Background IPC socket accept/read transport.
//!
//! The transport owns client sockets until the main thread pops a complete
//! request. Parsing and state mutation deliberately remain outside this module.

const std = @import("std");
const posix = std.posix;

const ipc = @import("ipc.zig");
const spsc_queue = @import("spsc_queue.zig");

const log = std.log.scoped(.ipc_transport);

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
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    listener_fd: posix.socket_t = -1,
    wake: ?WakeFn = null,

    /// Start accepting requests from an already-listening Unix socket.
    pub fn start(self: *Self, listener_fd: posix.socket_t, wake: WakeFn) !void {
        std.debug.assert(self.thread == null);
        std.debug.assert(listener_fd >= 0);

        self.listener_fd = listener_fd;
        self.wake = wake;
        self.stop_requested.store(false, .release);
        self.thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            self.listener_fd = -1;
            self.wake = null;
            return err;
        };
    }

    /// Stop the acceptor and close any client sockets not yet consumed.
    pub fn stop(self: *Self) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;

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

    fn acceptLoop(self: *Self) void {
        while (!self.stop_requested.load(.acquire)) {
            var poll_fds = [_]posix.pollfd{.{
                .fd = self.listener_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = posix.poll(&poll_fds, 250) catch |err| {
                if (!self.stop_requested.load(.acquire)) {
                    log.warn("IPC listener poll failed: {}", .{err});
                }
                continue;
            };
            if (ready == 0) continue;

            const client_fd = std.c.accept(self.listener_fd, null, null);
            if (client_fd < 0) continue;
            configureClient(client_fd);

            const request = readRequest(client_fd) orelse {
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
};

fn configureClient(fd: posix.socket_t) void {
    ipc.disableSigpipe(fd);
    const timeout: std.c.timeval = .{ .sec = 0, .usec = 250_000 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        log.warn("IPC send timeout setup failed: {}", .{err});
    };
}

fn readRequest(fd: posix.socket_t) ?Request {
    var request: Request = .{ .fd = fd, .len = 0, .buf = undefined };
    var written: usize = 0;

    while (written < request.buf.len) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, 1000) catch return null;
        if (ready == 0) return null;

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
