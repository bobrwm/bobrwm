const std = @import("std");
const posix = std.posix;
const layout_mod = @import("layout.zig");

const log = std.log.scoped(.ipc);

/// Dispatch callback: receives the trimmed command string and the client fd.
/// Callee writes the response to client_fd before returning.
pub const DispatchFn = *const fn (cmd: []const u8, client_fd: posix.socket_t) void;

pub const IpcCommand = union(enum) {
    retile,
    toggle_split,
    focus: FocusDir,
    focus_workspace: u8,
    move_to_workspace: u8,
    move_to_display: u8,
    move_workspace_to_display: DisplayTarget,
    bsp_ratio_rel: f64,
    bsp_ratio_abs: f64,
    bsp_insert_mode: layout_mod.InsertMode,
    bsp_insert_point: layout_mod.InsertionPointPolicy,
    bsp_mirror: layout_mod.Direction,
    bsp_equalize,
    bsp_balance,
    bsp_rotate: i32,
    query_windows,
    query_workspaces,
    query_displays,
    query_apps,

    pub const FocusDir = enum { left, right, up, down };

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
        if (std.mem.eql(u8, cmd, "query windows")) return .query_windows;
        if (std.mem.eql(u8, cmd, "query workspaces")) return .query_workspaces;
        if (std.mem.eql(u8, cmd, "query displays")) return .query_displays;
        if (std.mem.eql(u8, cmd, "query apps")) return .query_apps;

        // Commands with arguments — extract the tail after the prefix
        if (stripPrefix(cmd, "focus ")) |arg|
            return parseEnum(FocusDir, arg, .focus);
        if (stripPrefix(cmd, "focus-workspace ")) |arg|
            return parseU8(arg, .focus_workspace);
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
        if (stripPrefix(cmd, "bsp insert-mode ")) |arg|
            return parseEnum(layout_mod.InsertMode, arg, .bsp_insert_mode);
        if (stripPrefix(cmd, "bsp insert-point ")) |arg|
            return parseEnum(layout_mod.InsertionPointPolicy, arg, .bsp_insert_point);
        if (stripPrefix(cmd, "bsp mirror ")) |arg|
            return parseEnum(layout_mod.Direction, arg, .bsp_mirror);
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

pub const Server = struct {
    fd: posix.socket_t,
    path: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator) !Server {
        const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0);
        errdefer allocator.free(path);

        // Check if another daemon is already running by probing the socket.
        // If a connection succeeds, abort to prevent two instances from
        // racing on the same socket and window state.
        if (std.fs.cwd().access(path, .{})) |_| {
            const probe_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
                log.err("single-instance check: socket() failed: {}", .{err});
                return err;
            };
            defer posix.close(probe_fd);

            var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
            @memcpy(addr.path[0..path.len], path[0..path.len]);
            if (path.len < addr.path.len) addr.path[path.len] = 0;

            if (posix.connect(probe_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) |_| {
                log.err("another bobrwm instance is already running on {s}", .{path});
                return error.AddressInUse;
            } else |_| {
                // Connection refused — stale socket from a crashed instance.
            }
        } else |_| {}

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
