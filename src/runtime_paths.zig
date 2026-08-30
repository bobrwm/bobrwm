//! User-private runtime paths shared by the daemon and companion clients.

const std = @import("std");

const runtime_dir_suffix = "Library/Caches/bobrwm";
const socket_name = "bobrwm.sock";
const log_name = "bobrwm.log";

pub fn socketPathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    const home = getenv("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/{s}",
        .{ home, runtime_dir_suffix, socket_name },
        0,
    );
}

pub fn socketPathBuf(buf: []u8) ![:0]u8 {
    const home = getenv("HOME") orelse return error.MissingHome;
    return std.fmt.bufPrintSentinel(
        buf,
        "{s}/{s}/{s}",
        .{ home, runtime_dir_suffix, socket_name },
        0,
    );
}

pub fn logPathBuf(buf: []u8) ![:0]u8 {
    const home = getenv("HOME") orelse return error.MissingHome;
    return std.fmt.bufPrintSentinel(
        buf,
        "{s}/{s}/{s}",
        .{ home, runtime_dir_suffix, log_name },
        0,
    );
}

/// Create and lock down the directory that contains runtime files.
/// Keeping it below the user's home directory prevents other local users from
/// pre-creating predictable socket or log paths in a world-writable directory.
pub fn ensureRuntimeDir(allocator: std.mem.Allocator) !void {
    const home = getenv("HOME") orelse return error.MissingHome;
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ home, runtime_dir_suffix },
        0,
    );
    defer allocator.free(path);

    if (std.c.mkdir(path, 0o700) != 0 and std.c.access(path, 0) != 0) {
        return error.CreateRuntimeDirFailed;
    }

    const flags: std.c.O = .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
    const fd = std.c.open(path, flags);
    if (fd < 0) return error.InvalidRuntimeDir;
    defer _ = std.c.close(fd);

    if (std.c.fchmod(fd, 0o700) != 0) return error.SecureRuntimeDirFailed;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}
