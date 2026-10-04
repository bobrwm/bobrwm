//! Debug-only timing and platform-call counts for main-thread work.

const std = @import("std");
const builtin = @import("builtin");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.trace);
const enabled = builtin.mode == .debug;

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

pub inline fn countAx() void {
    if (enabled) global_counters.ax +%= 1;
}

pub inline fn countSkylight() void {
    if (enabled) global_counters.skylight +%= 1;
}

pub inline fn countWindowList() void {
    if (enabled) global_counters.window_list +%= 1;
}

pub const Span = struct {
    name: []const u8,
    pid: i32,
    wid: u32,
    start_ns: i128,
    start_counters: Counters,

    pub fn elapsedUs(self: Span) u64 {
        if (!enabled) return 0;
        const elapsed_ns = osutil.nanoTimestamp() - self.start_ns;
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
        log.debug("{s} pid={d} wid={d} {d}.{d:0>3}ms ax={d} sky={d} cg={d}{s}", .{
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
