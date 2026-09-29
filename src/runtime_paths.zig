//! Runtime paths shared by the daemon and companion clients.

const std = @import("std");

pub fn socketPathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/bobrwm_{d}.sock",
        .{std.c.getuid()},
        0,
    );
}

pub fn socketPathBuf(buf: []u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(
        buf,
        "/tmp/bobrwm_{d}.sock",
        .{std.c.getuid()},
        0,
    );
}
