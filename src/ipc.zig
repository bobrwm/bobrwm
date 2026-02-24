const std = @import("std");
const xev = @import("xev");
const posix = std.posix;

const log = std.log.scoped(.ipc);

/// Dispatch callback: receives the trimmed command string and the client fd.
/// Callee writes the response to client_fd before returning.
pub const DispatchFn = *const fn (cmd: []const u8, client_fd: posix.socket_t) void;

/// Module-level dispatch — set by main before calling startAccept.
pub var g_dispatch: ?DispatchFn = null;

pub const Server = struct {
    fd: posix.socket_t,
    path: [:0]const u8,
    accept_completion: xev.Completion,

    pub fn init(allocator: std.mem.Allocator) !Server {
        const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0);
        errdefer allocator.free(path);

        // Remove stale socket
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
        if (path.len > addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path[0..path.len]);
        if (path.len < addr.path.len) {
            addr.path[path.len] = 0;
        }

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 5);

        log.info("IPC listening on {s}", .{path});

        return .{
            .fd = fd,
            .path = path,
            .accept_completion = .{},
        };
    }

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        posix.close(self.fd);
        std.fs.cwd().deleteFile(self.path) catch {};
        allocator.free(self.path);
    }

    pub fn startAccept(self: *Server, loop: *xev.Loop) void {
        self.accept_completion = .{
            .op = .{
                .accept = .{
                    .socket = self.fd,
                },
            },
            .callback = handleAccept,
        };
        loop.add(&self.accept_completion);
    }
};

fn handleAccept(
    _: ?*anyopaque,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    const client_fd = result.accept catch |err| {
        log.err("accept failed: {}", .{err});
        return .rearm;
    };
    defer posix.close(client_fd);

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| {
        log.err("IPC read: {}", .{err});
        return .rearm;
    };
    if (n == 0) return .rearm;

    const cmd = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ', 0 });
    if (cmd.len == 0) return .rearm;

    if (g_dispatch) |dispatch| {
        dispatch(cmd, client_fd);
    }

    return .rearm;
}

/// Write a response to the IPC client fd.
pub fn writeResponse(fd: posix.socket_t, data: []const u8) void {
    _ = posix.write(fd, data) catch {};
}
