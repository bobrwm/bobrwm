const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.ipc);

/// Dispatch callback: receives the trimmed command string and the client fd.
/// Callee writes the response to client_fd before returning.
pub const DispatchFn = *const fn (cmd: []const u8, client_fd: posix.socket_t) void;

/// Module-level dispatch — set by main before calling bw_app_setup.
pub var g_dispatch: ?DispatchFn = null;

pub const Server = struct {
    fd: posix.socket_t,
    path: [:0]const u8,

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
        };
    }

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        posix.close(self.fd);
        std.fs.cwd().deleteFile(self.path) catch {};
        allocator.free(self.path);
    }
};

/// Write a response to the IPC client fd.
pub fn writeResponse(fd: posix.socket_t, data: []const u8) void {
    _ = posix.write(fd, data) catch {};
}
