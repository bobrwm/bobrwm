//! Route `std.log` to macOS unified logging and stderr, following Ghostty.
//! `BOBRWM_LOG` toggles the `macos` and `stderr` destinations.

const std = @import("std");
const builtin = @import("builtin");
const os_log = @import("os_log.zig");
const osutil = @import("osutil.zig");

/// The Zig scope remains available as the unified-log category.
const subsystem: [:0]const u8 = "com.bobrwm.bobrwm";

const Destinations = packed struct {
    stderr: bool = true,
    macos: bool = true,
};

var destinations: Destinations = .{};

fn osLogType(level: std.log.Level) os_log.LogType {
    return switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .err,
        .err => .fault,
    };
}

/// Freeze destination policy before observer threads can begin logging.
pub fn init() void {
    if (osutil.getenv("BOBRWM_LOG")) |value| {
        destinations = parseDestinations(value) catch .{};
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    logMacos(level, scope, format, args);
    logStderr(level, scope, format, args);
}

fn logMacos(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!destinations.macos) return;

    const logger = scopeLogger(scope);
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    logger.write(std.heap.c_allocator, osLogType(level), prefix ++ format, args);
}

/// Cache one process-lifetime logger per scope without racing first use.
fn scopeLogger(comptime scope: @EnumLiteral()) *os_log.Log {
    const Slot = LoggerSlot(scope);
    if (Slot.logger.load(.acquire)) |logger| return logger;

    const fresh = os_log.Log.create(subsystem, Slot.category);
    if (Slot.logger.cmpxchgStrong(null, fresh, .acq_rel, .acquire)) |existing| {
        fresh.release();
        return existing.?;
    }
    return fresh;
}

fn LoggerSlot(comptime scope: @EnumLiteral()) type {
    return struct {
        const category: [:0]const u8 = @tagName(scope);
        var logger: std.atomic.Value(?*os_log.Log) = .init(null);
    };
}

fn logStderr(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime builtin.mode != .Debug and level == .debug) return;
    if (!destinations.stderr) return;

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();

    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    nosuspend stderr.file_writer.interface.print(
        level.asText() ++ prefix ++ format ++ "\n",
        args,
    ) catch return;
    nosuspend stderr.file_writer.interface.flush() catch return;
}

fn parseDestinations(value: []const u8) !Destinations {
    if (std.mem.eql(u8, value, "true")) return .{ .stderr = true, .macos = true };
    if (std.mem.eql(u8, value, "false")) return .{ .stderr = false, .macos = false };

    var parsed: Destinations = .{};
    var tokens = std.mem.tokenizeScalar(u8, value, ',');
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " ");
        const enable = !std.mem.startsWith(u8, token, "no-");
        const name = if (enable) token else token["no-".len..];
        var recognized = false;
        inline for (@typeInfo(Destinations).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                @field(parsed, field.name) = enable;
                recognized = true;
            }
        }
        if (!recognized) return error.InvalidDestination;
    }
    return parsed;
}

test "BOBRWM_LOG toggles logging destinations" {
    try std.testing.expectEqual(Destinations{}, try parseDestinations(""));
    try std.testing.expectEqual(Destinations{ .stderr = false }, try parseDestinations("no-stderr"));
    try std.testing.expectEqual(Destinations{ .stderr = false, .macos = false }, try parseDestinations("false"));
    try std.testing.expectEqual(Destinations{ .stderr = true, .macos = true }, try parseDestinations("true"));
    try std.testing.expectEqual(Destinations{ .macos = false }, try parseDestinations("no-macos, stderr"));
}

test "BOBRWM_LOG rejects unknown destination names" {
    try std.testing.expectError(error.InvalidDestination, parseDestinations("verbose,no-file"));
}

test "log levels follow Ghostty's unified logging mapping" {
    try std.testing.expectEqual(os_log.LogType.debug, osLogType(.debug));
    try std.testing.expectEqual(os_log.LogType.info, osLogType(.info));
    try std.testing.expectEqual(os_log.LogType.err, osLogType(.warn));
    try std.testing.expectEqual(os_log.LogType.fault, osLogType(.err));
}

test "concurrent first use publishes one logger per scope" {
    const Worker = struct {
        fn run(result: **os_log.Log) void {
            result.* = scopeLogger(.concurrency_test);
        }
    };

    var results: [8]*os_log.Log = undefined;
    var threads: [results.len]std.Thread = undefined;
    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{result});
    }
    for (&threads) |*thread| thread.join();
    for (results[1..]) |logger| try std.testing.expectEqual(results[0], logger);
}
