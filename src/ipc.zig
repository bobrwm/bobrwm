const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const tiling = @import("tiling.zig");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.ipc);

/// Dispatch callback: receives the trimmed command string and the client fd.
/// Callee writes the response to client_fd before returning.
pub const DispatchFn = *const fn (cmd: []const u8, client_fd: posix.socket_t) void;

pub const IpcCommand = union(enum) {
    retile,
    toggle_split,
    focus: FocusDir,
    focus_workspace: WorkspaceTarget,
    move_to_workspace: u8,
    move_to_display: u8,
    move_workspace_to_display: DisplayTarget,
    bsp_ratio_rel: f64,
    bsp_ratio_abs: f64,
    bsp_insert_point: tiling.InsertionPointPolicy,
    bsp_mirror: tiling.Direction,
    bsp_equalize,
    bsp_balance,
    bsp_rotate: i32,
    query_windows: QueryFormat,
    query_workspaces: QueryFormat,
    query_displays: QueryFormat,
    query_apps: QueryFormat,

    pub const FocusDir = enum { left, right, up, down };

    pub const WorkspaceTarget = union(enum) {
        prev,
        next,
        index: u8,
    };

    pub const QueryFormat = enum { text, json };

    pub const DisplayTarget = union(enum) {
        next,
        prev,
        index: u8,
    };

    /// Parse a raw IPC command string into a typed command.
    /// Returns null if the command is unrecognized or has malformed arguments.
    pub fn parse(cmd: []const u8) ?IpcCommand {
        // Exact-match commands (no arguments)
        if (std.mem.eql(u8, cmd, "retile")) return .retile;
        if (std.mem.eql(u8, cmd, "toggle-split")) return .toggle_split;
        if (std.mem.eql(u8, cmd, "bsp equalize")) return .bsp_equalize;
        if (std.mem.eql(u8, cmd, "bsp balance")) return .bsp_balance;
        if (std.mem.eql(u8, cmd, "query windows")) return .{ .query_windows = .text };
        if (std.mem.eql(u8, cmd, "query windows --json")) return .{ .query_windows = .json };
        if (std.mem.eql(u8, cmd, "query workspaces")) return .{ .query_workspaces = .text };
        if (std.mem.eql(u8, cmd, "query workspaces --json")) return .{ .query_workspaces = .json };
        if (std.mem.eql(u8, cmd, "query displays")) return .{ .query_displays = .text };
        if (std.mem.eql(u8, cmd, "query displays --json")) return .{ .query_displays = .json };
        if (std.mem.eql(u8, cmd, "query apps")) return .{ .query_apps = .text };
        if (std.mem.eql(u8, cmd, "query apps --json")) return .{ .query_apps = .json };

        // Commands with arguments — extract the tail after the prefix
        if (stripPrefix(cmd, "focus ")) |arg|
            return parseEnum(FocusDir, arg, .focus);
        if (stripPrefix(cmd, "focus-workspace ")) |arg|
            return parseWorkspaceTarget(arg);
        if (stripPrefix(cmd, "move-to-workspace ")) |arg|
            return parseU8(arg, .move_to_workspace);
        if (stripPrefix(cmd, "move-to-display ")) |arg|
            return parseU8(arg, .move_to_display);
        if (stripPrefix(cmd, "move-workspace-to-display ")) |arg|
            return parseDisplayTarget(arg);
        if (stripPrefix(cmd, "bsp ratio rel ")) |arg|
            return parseFloat(arg, .bsp_ratio_rel);
        if (stripPrefix(cmd, "bsp ratio abs ")) |arg|
            return parseFloat(arg, .bsp_ratio_abs);
        if (stripPrefix(cmd, "bsp insert-point ")) |arg|
            return parseEnum(tiling.InsertionPointPolicy, arg, .bsp_insert_point);
        if (stripPrefix(cmd, "bsp mirror ")) |arg|
            return parseEnum(tiling.Direction, arg, .bsp_mirror);
        if (stripPrefix(cmd, "bsp rotate ")) |arg|
            return parseInt(i32, arg, .bsp_rotate);

        return null;
    }

    fn stripPrefix(cmd: []const u8, prefix: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, cmd, prefix))
            return cmd[prefix.len..];
        return null;
    }

    fn parseEnum(comptime E: type, arg: []const u8, comptime tag: anytype) ?IpcCommand {
        // layout enums use underscores; wire format uses underscores too (min_depth).
        const val = std.meta.stringToEnum(E, arg) orelse return null;
        return @unionInit(IpcCommand, @tagName(tag), val);
    }

    fn parseU8(arg: []const u8, comptime tag: anytype) ?IpcCommand {
        const val = std.fmt.parseInt(u8, arg, 10) catch return null;
        return @unionInit(IpcCommand, @tagName(tag), val);
    }

    fn parseInt(comptime T: type, arg: []const u8, comptime tag: anytype) ?IpcCommand {
        const val = std.fmt.parseInt(T, arg, 10) catch return null;
        return @unionInit(IpcCommand, @tagName(tag), val);
    }

    fn parseFloat(arg: []const u8, comptime tag: anytype) ?IpcCommand {
        const val = std.fmt.parseFloat(f64, arg) catch return null;
        return @unionInit(IpcCommand, @tagName(tag), val);
    }

    fn parseWorkspaceTarget(arg: []const u8) ?IpcCommand {
        if (std.mem.eql(u8, arg, "prev"))
            return .{ .focus_workspace = .prev };
        if (std.mem.eql(u8, arg, "next"))
            return .{ .focus_workspace = .next };
        const n = std.fmt.parseInt(u8, arg, 10) catch return null;
        return .{ .focus_workspace = .{ .index = n } };
    }

    fn parseDisplayTarget(arg: []const u8) ?IpcCommand {
        if (std.mem.eql(u8, arg, "next"))
            return .{ .move_workspace_to_display = .next };
        if (std.mem.eql(u8, arg, "prev"))
            return .{ .move_workspace_to_display = .prev };
        const n = std.fmt.parseInt(u8, arg, 10) catch return null;
        return .{ .move_workspace_to_display = .{ .index = n } };
    }
};

/// Module-level dispatch — set by main before calling bw_app_setup.
pub var g_dispatch: ?DispatchFn = null;

// Zig 0.16 removed the std.posix.{socket,bind,listen,connect,write,close,
// shutdown} wrappers ("posix and os.windows removals" in the release notes).
// std.c re-exports the underlying libc entry points, so we go lower rather
// than threading a std.Io instance through every IPC call.

pub const Server = struct {
    fd: posix.socket_t,
    path: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator) !Server {
        const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0);
        errdefer allocator.free(path);

        // Check if another daemon is already running by probing the socket.
        // If a connection succeeds, abort to prevent two instances from
        // racing on the same socket and window state.
        if (osutil.pathExists(path.ptr)) {
            const probe_fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            if (probe_fd < 0) {
                log.err("single-instance check: socket() failed", .{});
                return error.SocketFailed;
            }
            defer _ = std.c.close(probe_fd);

            var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
            @memcpy(addr.path[0..path.len], path[0..path.len]);
            if (path.len < addr.path.len) addr.path[path.len] = 0;

            if (std.c.connect(probe_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) == 0) {
                log.err("another bobrwm instance is already running on {s}", .{path});
                return error.AddressInUse;
            }
            // Connection refused — stale socket from a crashed instance.
        }

        // Remove stale socket (no-op if missing).
        osutil.deleteFile(path.ptr);

        const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        disableSigpipe(fd);

        var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
        if (path.len > addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path[0..path.len]);
        if (path.len < addr.path.len) {
            addr.path[path.len] = 0;
        }

        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
        if (std.c.listen(fd, 5) != 0) return error.ListenFailed;

        log.info("IPC listening on {s}", .{path});

        return .{
            .fd = fd,
            .path = path,
        };
    }

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        _ = std.c.close(self.fd);
        osutil.deleteFile(self.path.ptr);
        allocator.free(self.path);
    }
};

/// Prevent a disconnected IPC client from killing bobrwm with SIGPIPE.
pub fn disableSigpipe(fd: posix.socket_t) void {
    std.debug.assert(fd >= 0);

    switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd => {
            const enabled: i32 = 1;
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled)) catch |err| {
                log.warn("ipc socket SO_NOSIGPIPE failed: {}", .{err});
            };
        },
        else => {},
    }
}

/// Write a response to the IPC client fd.
pub fn writeResponse(fd: posix.socket_t, data: []const u8) void {
    std.debug.assert(fd >= 0);

    var remaining = data;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written < 0) {
            switch (posix.errno(written)) {
                .PIPE, .CONNRESET => return,
                else => |err| log.warn("ipc response write failed: {}", .{err}),
            }
            return;
        }
        if (written == 0) return;
        remaining = remaining[@intCast(written)..];
    }
}

test "write response tolerates closed IPC peer" {
    switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd => {},
        else => return error.SkipZigTest,
    }

    const t = std.testing;
    var fds: [2]posix.socket_t = undefined;
    try t.expectEqual(0, std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);

    disableSigpipe(fds[0]);
    try t.expectEqual(0, std.c.close(fds[1]));
    writeResponse(fds[0], "ok\n");
}

test "parse query format" {
    const t = std.testing;

    try t.expectEqual(IpcCommand{ .query_windows = .text }, IpcCommand.parse("query windows").?);
    try t.expectEqual(IpcCommand{ .query_windows = .json }, IpcCommand.parse("query windows --json").?);
    try t.expectEqual(IpcCommand{ .query_workspaces = .json }, IpcCommand.parse("query workspaces --json").?);
    try t.expectEqual(IpcCommand{ .query_displays = .json }, IpcCommand.parse("query displays --json").?);
    try t.expectEqual(IpcCommand{ .query_apps = .json }, IpcCommand.parse("query apps --json").?);
    try t.expectEqual(@as(?IpcCommand, null), IpcCommand.parse("query windows --json extra"));
}

test "parse focus workspace target" {
    const t = std.testing;

    try t.expectEqual(IpcCommand{ .focus_workspace = .{ .index = 3 } }, IpcCommand.parse("focus-workspace 3").?);
    try t.expectEqual(IpcCommand{ .focus_workspace = .prev }, IpcCommand.parse("focus-workspace prev").?);
    try t.expectEqual(IpcCommand{ .focus_workspace = .next }, IpcCommand.parse("focus-workspace next").?);
    try t.expectEqual(@as(?IpcCommand, null), IpcCommand.parse("focus-workspace previous"));
}
