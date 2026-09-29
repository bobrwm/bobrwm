//! Minimal macOS unified-logging wrapper.

const std = @import("std");

pub const Log = opaque {
    pub fn create(subsystem: [:0]const u8, category: [:0]const u8) *Log {
        return os_log_create(subsystem.ptr, category.ptr);
    }

    pub fn release(self: *Log) void {
        os_release(self);
    }

    pub fn write(
        self: *Log,
        allocator: std.mem.Allocator,
        kind: LogType,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const message = nosuspend std.fmt.allocPrintSentinel(allocator, format, args, 0) catch return;
        defer allocator.free(message);
        bw_os_log(self, kind, message.ptr);
    }
};

pub const LogType = enum(u8) {
    default = 0x00,
    info = 0x01,
    debug = 0x02,
    err = 0x10,
    fault = 0x11,
};

extern "c" fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) *Log;
extern "c" fn os_release(object: *anyopaque) void;
extern "c" fn bw_os_log(logger: *Log, kind: LogType, message: [*:0]const u8) void;

test "write through macOS unified logging" {
    const logger = Log.create("com.bobrwm.bobrwm", "test");
    defer logger.release();

    logger.write(std.testing.allocator, .info, "test value={d}", .{12});
}
