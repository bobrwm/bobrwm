//! Debug-log-only timing and platform-call counts for main-thread work.

const std = @import("std");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.trace);

/// Tracing follows the debug log level, not the optimize mode: `-Dlog_level`
/// is independent of `-Doptimize`, and a release build that prints trace lines
/// with a disabled clock would report zero for every measurement.
pub const enabled = std.log.logEnabled(.debug, .trace);

pub const frame_budget_us: u64 = 16_000;

pub const Counters = struct {
    ax: u32 = 0,
    skylight: u32 = 0,
    window_list: u32 = 0,

    pub fn since(self: Counters, earlier: Counters) Counters {
        return .{
            .ax = self.ax -% earlier.ax,
            .skylight = self.skylight -% earlier.skylight,
            .window_list = self.window_list -% earlier.window_list,
        };
    }

    pub fn total(self: Counters) u32 {
        return self.ax +% self.skylight +% self.window_list;
    }
};

var global_counters: Counters = .{};

/// Time spent writing trace lines. Spans subtract it so a drain that reports
/// many events is not flagged slow for the cost of its own reporting.
var global_report_ns: i128 = 0;

pub inline fn countAx() void {
    if (enabled) global_counters.ax +%= 1;
}

pub inline fn countSkylight() void {
    if (enabled) global_counters.skylight +%= 1;
}

pub inline fn countWindowList() void {
    if (enabled) global_counters.window_list +%= 1;
}

/// Write a trace line and exclude its cost from every open span.
pub fn emit(comptime format: []const u8, args: anytype) void {
    if (!enabled) return;
    const started_ns = osutil.nanoTimestamp();
    log.debug(format, args);
    global_report_ns += osutil.nanoTimestamp() - started_ns;
}

/// Monotonic stamp for queue publication; zero keeps disabled builds off the clock.
pub fn enqueueTimestamp() i64 {
    if (!enabled) return 0;
    return @truncate(osutil.nanoTimestamp());
}

/// Time an event waited in the queue before its handler started. Zero when the
/// producer did not stamp it.
pub fn queuedUs(enqueued_ns: i64, started_ns: i128) u64 {
    if (enqueued_ns == 0) return 0;
    const waited_ns = @as(i64, @truncate(started_ns)) - enqueued_ns;
    if (waited_ns <= 0) return 0;
    return @intCast(@divTrunc(waited_ns, std.time.ns_per_us));
}

/// Whether work is too routine to report. AX round trips are the signal:
/// every drain pays for a tab-bar window-list copy and the topology poll pays
/// for a SkyLight snapshot, so counting those would make every tick look busy.
pub fn isQuiet(elapsed_us: u64, spent: Counters) bool {
    return elapsed_us < frame_budget_us and spent.ax == 0;
}

pub const Span = struct {
    name: []const u8,
    pid: i32,
    wid: u32,
    start_ns: i128,
    start_report_ns: i128,
    start_counters: Counters,

    pub fn elapsedUs(self: Span) u64 {
        if (!enabled) return 0;
        const wall_ns = osutil.nanoTimestamp() - self.start_ns;
        const elapsed_ns = wall_ns - (global_report_ns - self.start_report_ns);
        if (elapsed_ns <= 0) return 0;
        return @intCast(@divTrunc(elapsed_ns, std.time.ns_per_us));
    }

    pub fn cost(self: Span) Counters {
        return global_counters.since(self.start_counters);
    }

    pub fn end(self: Span) u64 {
        const elapsed_us = self.elapsedUs();
        self.report(elapsed_us);
        return elapsed_us;
    }

    pub fn endIfSlow(self: Span) u64 {
        const elapsed_us = self.elapsedUs();
        if (elapsed_us >= frame_budget_us) self.report(elapsed_us);
        return elapsed_us;
    }

    fn report(self: Span, elapsed_us: u64) void {
        if (!enabled) return;
        const spent = self.cost();
        emit("{s} pid={d} wid={d} {d}.{d:0>3}ms ax={d} sky={d} cg={d}{s}", .{
            self.name,
            self.pid,
            self.wid,
            elapsed_us / 1000,
            elapsed_us % 1000,
            spent.ax,
            spent.skylight,
            spent.window_list,
            if (elapsed_us >= frame_budget_us) " SLOW" else "",
        });
    }
};

pub fn begin(name: []const u8) Span {
    return beginWindow(name, 0, 0);
}

pub fn beginWindow(name: []const u8, pid: i32, wid: u32) Span {
    return .{
        .name = name,
        .pid = pid,
        .wid = wid,
        .start_ns = if (enabled) osutil.nanoTimestamp() else 0,
        .start_report_ns = global_report_ns,
        .start_counters = if (enabled) global_counters else .{},
    };
}

test "counter snapshots handle wraparound" {
    const earlier: Counters = .{ .ax = std.math.maxInt(u32) - 1, .skylight = 4 };
    const current: Counters = .{ .ax = 2, .skylight = 9 };
    const spent = current.since(earlier);

    try std.testing.expectEqual(@as(u32, 4), spent.ax);
    try std.testing.expectEqual(@as(u32, 5), spent.skylight);
    try std.testing.expectEqual(@as(u32, 9), spent.total());
}

test "queued time ignores unstamped and reordered events" {
    try std.testing.expectEqual(@as(u64, 0), queuedUs(0, 5_000_000));
    try std.testing.expectEqual(@as(u64, 0), queuedUs(6_000_000, 5_000_000));
    try std.testing.expectEqual(@as(u64, 3_000), queuedUs(2_000_000, 5_000_000));
}

test "window-list and SkyLight baseline work stays quiet" {
    try std.testing.expect(isQuiet(1_000, .{ .skylight = 1, .window_list = 1 }));
    try std.testing.expect(!isQuiet(1_000, .{ .ax = 1 }));
    try std.testing.expect(!isQuiet(frame_budget_us, .{}));
}

test "span elapsed excludes trace reporting" {
    if (!enabled) return error.SkipZigTest;
    const span = begin("test");
    const report_ns: i128 = 60 * std.time.ns_per_s;
    global_report_ns += report_ns;
    defer global_report_ns -= report_ns;
    try std.testing.expect(span.elapsedUs() < frame_budget_us);
}
