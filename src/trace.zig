//! Timing spans and OS round-trip counters for the main-thread event loop.
//!
//! Every AX read is a synchronous Mach round trip into the target
//! application's accessibility server. When that app is slow to answer, the
//! call blocks bobrwm's main thread until it does or until the messaging
//! timeout fires — so "new windows from this app feel slow" is almost never
//! bobrwm computing something expensive, it is bobrwm waiting on somebody
//! else, and the only way to tell the two apart from a log is to record both
//! how long a step took and how many round trips it spent doing it.
//!
//! A 300 ms span that made 4 AX calls is a slow app. The same 300 ms across 90
//! calls is bobrwm asking too often — a duplicated detection pass, an
//! uncached element, a per-window query that belongs outside the loop. The
//! numbers are only comparable because every span reports both.
//!
//! Main thread only. The counters are plain globals with no synchronisation:
//! every instrumented helper runs during event drain, while servicing an IPC
//! request, or on the animator's main-queue timer. Background AX observer
//! threads must not call into this module.

const std = @import("std");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.trace);

/// One frame at 60 Hz. Main-thread work that outruns it costs the user a frame
/// they would otherwise have seen, which is what "feels slow" is made of.
pub const frame_budget_us: u64 = 16_000;

/// Past this, a span is no longer a perf data point: the window manager was
/// unresponsive long enough for a person to notice, and the cause is worth
/// finding. Sits well above a legitimate workspace switch — which retiles
/// every window of two workspaces — so ordinary operation never trips it.
pub const stall_us: u64 = 250_000;

/// Round trips out of this process since start-up, by transport.
///
/// `ax` dominates by orders of magnitude: it is IPC into another application
/// and its cost is that application's responsiveness, not ours. `skylight`
/// and `window_list` go to WindowServer, which is fast but not free —
/// `window_list` copies and parses a dictionary per on-screen window, so it is
/// the one to hoist out of loops.
pub const Counters = struct {
    /// AX round trips into an application: attribute reads/writes, window
    /// list copies, element resolution.
    ax: u32 = 0,
    /// SkyLight queries (window bounds, Space membership, connection state).
    skylight: u32 = 0,
    /// `CGWindowListCopyWindowInfo` calls — whole-list copies, not per-window.
    window_list: u32 = 0,

    /// Round trips this interval spent, i.e. `self` minus the earlier `base`.
    pub fn since(self: Counters, base: Counters) Counters {
        return .{
            .ax = self.ax -% base.ax,
            .skylight = self.skylight -% base.skylight,
            .window_list = self.window_list -% base.window_list,
        };
    }

    pub fn total(self: Counters) u32 {
        return self.ax +% self.skylight +% self.window_list;
    }
};

var g_counters: Counters = .{};

/// Record one AX round trip. Called from the helpers that own an AX query,
/// not from every raw `AXUIElementCopyAttributeValue`: what matters for
/// reading a log is how many times a *decision* reached into another process.
pub fn countAx() void {
    g_counters.ax +%= 1;
}

pub fn countAxN(n: usize) void {
    g_counters.ax +%= @truncate(n);
}

pub fn countSkylight() void {
    g_counters.skylight +%= 1;
}

pub fn countWindowList() void {
    g_counters.window_list +%= 1;
}

pub fn counters() Counters {
    return g_counters;
}

/// An open timing interval. Zero-cost to ignore: a caller that does not want
/// a log line can read `elapsedUs`/`cost` and fold them into its own summary.
pub const Span = struct {
    name: []const u8,
    /// 0 when the span is not about one process.
    pid: i32,
    /// 0 when the span is not about one window.
    wid: u32,
    start_ns: i128,
    start_counters: Counters,

    pub fn elapsedUs(self: Span) u64 {
        const delta = osutil.nanoTimestamp() - self.start_ns;
        if (delta <= 0) return 0;
        return @intCast(@divTrunc(delta, std.time.ns_per_us));
    }

    /// Round trips spent since the span opened.
    pub fn cost(self: Span) Counters {
        return counters().since(self.start_counters);
    }

    /// Close the span and log it. Returns the elapsed microseconds so a caller
    /// can accumulate them without reading the clock a second time.
    pub fn end(self: Span) u64 {
        const elapsed_us = self.elapsedUs();
        self.report(elapsed_us);
        return elapsed_us;
    }

    /// Close the span, logging only if it overran a frame. For spans on paths
    /// that run at poll cadence, where a line per tick would bury the ones
    /// that matter.
    pub fn endIfSlow(self: Span) u64 {
        const elapsed_us = self.elapsedUs();
        if (elapsed_us >= frame_budget_us) self.report(elapsed_us);
        return elapsed_us;
    }

    fn report(self: Span, elapsed_us: u64) void {
        const spent = self.cost();

        // A stall is an invariant worth attention, not a measurement: the main
        // thread owns layout, focus and IPC, so nothing else ran for this long.
        if (elapsed_us >= stall_us) {
            log.warn(
                "{s}{s} stalled the main thread for {d}.{d:0>3}ms ax={d} sky={d} cg={d}",
                .{
                    self.name,
                    self.subject(),
                    elapsed_us / 1000,
                    elapsed_us % 1000,
                    spent.ax,
                    spent.skylight,
                    spent.window_list,
                },
            );
            return;
        }

        log.debug("{s}{s} {d}.{d:0>3}ms ax={d} sky={d} cg={d}{s}", .{
            self.name,
            self.subject(),
            elapsed_us / 1000,
            elapsed_us % 1000,
            spent.ax,
            spent.skylight,
            spent.window_list,
            if (elapsed_us >= frame_budget_us) " SLOW" else "",
        });
    }

    /// `" pid=… wid=…"`, rendered into per-span scratch so the whole span
    /// still leaves the file log in one atomic write.
    fn subject(self: Span) []const u8 {
        const scratch = struct {
            threadlocal var buf: [48]u8 = undefined;
        };
        if (self.pid == 0 and self.wid == 0) return "";
        var writer = std.Io.Writer.fixed(&scratch.buf);
        if (self.pid != 0) writer.print(" pid={d}", .{self.pid}) catch {};
        if (self.wid != 0) writer.print(" wid={d}", .{self.wid}) catch {};
        return writer.buffered();
    }
};

/// Open a span that is not about a particular window.
pub fn begin(name: []const u8) Span {
    return .{
        .name = name,
        .pid = 0,
        .wid = 0,
        .start_ns = osutil.nanoTimestamp(),
        .start_counters = counters(),
    };
}

/// Open a span about one window. Pass 0 for either id that does not apply.
pub fn beginWindow(name: []const u8, pid: i32, wid: u32) Span {
    return .{
        .name = name,
        .pid = pid,
        .wid = wid,
        .start_ns = osutil.nanoTimestamp(),
        .start_counters = counters(),
    };
}

/// Milliseconds with three fractional digits, for callers that assemble their
/// own log line out of an elapsed microsecond count.
pub const Millis = struct {
    whole: u64,
    frac: u64,

    pub fn from(elapsed_us: u64) Millis {
        return .{ .whole = elapsed_us / 1000, .frac = elapsed_us % 1000 };
    }
};

test "counters report the delta over an interval, not the running total" {
    const base: Counters = .{ .ax = 10, .skylight = 4, .window_list = 1 };
    const now: Counters = .{ .ax = 31, .skylight = 9, .window_list = 3 };

    const spent = now.since(base);
    try std.testing.expectEqual(@as(u32, 21), spent.ax);
    try std.testing.expectEqual(@as(u32, 5), spent.skylight);
    try std.testing.expectEqual(@as(u32, 2), spent.window_list);
    try std.testing.expectEqual(@as(u32, 28), spent.total());
}

test "counter deltas survive the counters wrapping around" {
    const base: Counters = .{ .ax = std.math.maxInt(u32) - 1 };
    const now: Counters = .{ .ax = 2 };

    try std.testing.expectEqual(@as(u32, 4), now.since(base).ax);
}

test "a span measures the round trips made while it was open" {
    g_counters = .{};
    defer g_counters = .{};

    const span = begin("test");
    countAx();
    countAx();
    countSkylight();

    const spent = span.cost();
    try std.testing.expectEqual(@as(u32, 2), spent.ax);
    try std.testing.expectEqual(@as(u32, 1), spent.skylight);
    try std.testing.expectEqual(@as(u32, 0), spent.window_list);
}

test "a span renders only the ids it was given" {
    const both = beginWindow("test", 722, 5022);
    try std.testing.expectEqualStrings(" pid=722 wid=5022", both.subject());

    const pid_only = beginWindow("test", 722, 0);
    try std.testing.expectEqualStrings(" pid=722", pid_only.subject());

    const wid_only = beginWindow("test", 0, 5022);
    try std.testing.expectEqualStrings(" wid=5022", wid_only.subject());

    const neither = begin("test");
    try std.testing.expectEqualStrings("", neither.subject());
}

test "elapsed microseconds split into milliseconds and a three-digit remainder" {
    try std.testing.expectEqual(@as(u64, 412), Millis.from(412_345).whole);
    try std.testing.expectEqual(@as(u64, 345), Millis.from(412_345).frac);
    try std.testing.expectEqual(@as(u64, 0), Millis.from(7).whole);
    try std.testing.expectEqual(@as(u64, 7), Millis.from(7).frac);
}
