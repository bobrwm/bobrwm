//! Timing spans and OS round-trip accounting for the main-thread event loop.
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
//! Counts alone still leave a gap: a span can spend 326 ms across 24 calls of
//! which three were slow, and the counts cannot say whether the other 21
//! shared the rest or the time went somewhere never recorded at all. So each
//! round trip is also timed, a span reports the wait per transport next to
//! its count, and what remains after every wait is subtracted is printed as
//! `other`. Ordinarily that is our own work. When it is large, something is
//! reaching out of the process without being recorded here. A stall warning
//! additionally names the individual calls that were slow inside it.
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

/// A single round trip at or past this is the story of whatever span holds
/// it, and is named on its own. An idle app answers an attribute read in
/// about 50 µs; nothing legitimate sits between that and this.
pub const slow_call_us: u64 = 10_000;

/// Where a round trip went.
pub const Transport = enum {
    /// Into an application's accessibility server: attribute reads and
    /// writes, window list copies, element resolution. Its cost is that
    /// application's responsiveness, not ours, and it dominates the others by
    /// orders of magnitude.
    ax,
    /// SkyLight queries (window bounds, Space membership, connection state).
    skylight,
    /// `CGWindowListCopyWindowInfo` — whole-list copies, not per-window. Fast
    /// but not free: WindowServer copies and we parse a dictionary per
    /// on-screen window, so it is the one to hoist out of loops.
    window_list,
    /// `NSRunningApplication` / `NSWorkspace` lookups. XPC into
    /// LaunchServices, paid on the same thread, and easy to miss as IPC at all
    /// because the call reads like a property access.
    launch_services,
};

/// Round trips out of this process since start-up, by transport: how many,
/// and how long the thread waited on them.
pub const Counters = struct {
    ax: u32 = 0,
    skylight: u32 = 0,
    window_list: u32 = 0,
    launch_services: u32 = 0,
    ax_us: u64 = 0,
    skylight_us: u64 = 0,
    window_list_us: u64 = 0,
    launch_services_us: u64 = 0,

    /// Round trips this interval spent, i.e. `self` minus the earlier `base`.
    pub fn since(self: Counters, base: Counters) Counters {
        return .{
            .ax = self.ax -% base.ax,
            .skylight = self.skylight -% base.skylight,
            .window_list = self.window_list -% base.window_list,
            .launch_services = self.launch_services -% base.launch_services,
            .ax_us = self.ax_us -% base.ax_us,
            .skylight_us = self.skylight_us -% base.skylight_us,
            .window_list_us = self.window_list_us -% base.window_list_us,
            .launch_services_us = self.launch_services_us -% base.launch_services_us,
        };
    }

    pub fn total(self: Counters) u32 {
        return self.ax +% self.skylight +% self.window_list +% self.launch_services;
    }

    /// Wall time spent waiting on other processes, all transports together.
    pub fn waitedUs(self: Counters) u64 {
        return self.ax_us +| self.skylight_us +| self.window_list_us +| self.launch_services_us;
    }

    fn add(self: *Counters, transport: Transport, count: u32, elapsed_us: u64) void {
        switch (transport) {
            .ax => {
                self.ax +%= count;
                self.ax_us +%= elapsed_us;
            },
            .skylight => {
                self.skylight +%= count;
                self.skylight_us +%= elapsed_us;
            },
            .window_list => {
                self.window_list +%= count;
                self.window_list_us +%= elapsed_us;
            },
            .launch_services => {
                self.launch_services +%= count;
                self.launch_services_us +%= elapsed_us;
            },
        }
    }
};

var g_counters: Counters = .{};

pub fn counters() Counters {
    return g_counters;
}

/// One round trip in flight. Open it immediately before the call and finish
/// it immediately after, so the interval is the wait and nothing else.
pub const Call = struct {
    transport: Transport,
    started_ns: i128,

    /// Charge one round trip. Returns the microseconds it took.
    pub fn finish(self: Call) u64 {
        return self.finishN(1);
    }

    /// Charge `count` round trips made inside one interval — a loop that asks
    /// the same question of every element in a list.
    pub fn finishN(self: Call, count: u32) u64 {
        const elapsed_us = elapsedSince(self.started_ns);
        g_counters.add(self.transport, count, elapsed_us);
        return elapsed_us;
    }
};

pub fn call(transport: Transport) Call {
    return .{ .transport = transport, .started_ns = osutil.nanoTimestamp() };
}

fn elapsedSince(started_ns: i128) u64 {
    const delta = osutil.nanoTimestamp() - started_ns;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, std.time.ns_per_us));
}

/// Where a span's time went: the wait per transport, and `other` — what is
/// left once every recorded wait is subtracted.
pub const Breakdown = struct {
    spent: Counters,
    elapsed_us: u64,

    pub fn format(self: Breakdown, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try bucket(w, "ax", self.spent.ax, self.spent.ax_us);
        try w.writeByte(' ');
        try bucket(w, "sky", self.spent.skylight, self.spent.skylight_us);
        try w.writeByte(' ');
        try bucket(w, "cg", self.spent.window_list, self.spent.window_list_us);
        try w.writeByte(' ');
        try bucket(w, "ls", self.spent.launch_services, self.spent.launch_services_us);
        const other = Millis.from(self.elapsed_us -| self.spent.waitedUs());
        try w.print(" other={d}.{d:0>3}ms", .{ other.whole, other.frac });
    }

    /// `name=count/wait`, the wait omitted when nothing was called: a zero
    /// count already says it, and most spans touch one transport.
    fn bucket(w: *std.Io.Writer, name: []const u8, count: u32, elapsed_us: u64) std.Io.Writer.Error!void {
        try w.print("{s}={d}", .{ name, count });
        if (count == 0) return;
        const ms = Millis.from(elapsed_us);
        try w.print("/{d}.{d:0>3}ms", .{ ms.whole, ms.frac });
    }
};

pub fn breakdown(spent: Counters, elapsed_us: u64) Breakdown {
    return .{ .spent = spent, .elapsed_us = elapsed_us };
}

const SlowCall = struct {
    /// "read" or "write".
    kind: []const u8,
    /// The attribute as a reader of the log knows it.
    what: []const u8,
    pid: i32,
    wid: u32,
    started_ns: i128,
    elapsed_us: u64,
    err: i32,
};

/// The most recent slow calls. A stall warning names the ones made inside its
/// span: the buckets say which transport waited, this says on what.
const slow_calls_kept = 8;
var g_slow_calls: [slow_calls_kept]?SlowCall = @splat(null);
var g_slow_calls_next: usize = 0;

/// Record a round trip that crossed `slow_call_us`, and say so in the debug
/// log now: the stall report only comes if the enclosing span stalls, and a
/// 60 ms read inside a 200 ms span is still worth a line. `kind` and `what`
/// must be static strings.
pub fn noteSlowCall(kind: []const u8, what: []const u8, pid: i32, wid: u32, started_ns: i128, elapsed_us: u64, err: i32) void {
    g_slow_calls[g_slow_calls_next] = .{
        .kind = kind,
        .what = what,
        .pid = pid,
        .wid = wid,
        .started_ns = started_ns,
        .elapsed_us = elapsed_us,
        .err = err,
    };
    g_slow_calls_next = (g_slow_calls_next + 1) % slow_calls_kept;

    const ms = Millis.from(elapsed_us);
    log.debug("ax {s} {s} pid={d} wid={d} {d}.{d:0>3}ms err={d}", .{
        kind, what, pid, wid, ms.whole, ms.frac, err,
    });
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
        return elapsedSince(self.start_ns);
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
        return self.endIfSlowerThan(frame_budget_us);
    }

    /// `endIfSlow` against a caller's own threshold, for work whose normal
    /// cost is already known and is not one frame.
    pub fn endIfSlowerThan(self: Span, threshold_us: u64) u64 {
        const elapsed_us = self.elapsedUs();
        if (elapsed_us >= threshold_us) self.report(elapsed_us);
        return elapsed_us;
    }

    fn report(self: Span, elapsed_us: u64) void {
        const where = breakdown(self.cost(), elapsed_us);
        const ms = Millis.from(elapsed_us);

        // A stall is an invariant worth attention, not a measurement: the main
        // thread owns layout, focus and IPC, so nothing else ran for this long.
        // It carries its own explanation because stderr shows nothing below
        // warn in a release build.
        if (elapsed_us >= stall_us) {
            var buf: [640]u8 = undefined;
            log.warn("{s}{s} stalled the main thread for {d}.{d:0>3}ms {f}{s}", .{
                self.name,
                self.subject(),
                ms.whole,
                ms.frac,
                where,
                self.slowCalls(&buf),
            });
            return;
        }

        log.debug("{s}{s} {d}.{d:0>3}ms {f}{s}", .{
            self.name,
            self.subject(),
            ms.whole,
            ms.frac,
            where,
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

    /// `" slow: read AXWindows pid=… 457.314ms; …"` for the slow calls made
    /// while this span was open, oldest first, or "" when there were none.
    /// Truncates rather than fails when `buf` fills.
    fn slowCalls(self: Span, buf: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buf);
        var any = false;
        for (0..slow_calls_kept) |i| {
            const entry = g_slow_calls[(g_slow_calls_next + i) % slow_calls_kept] orelse continue;
            if (entry.started_ns < self.start_ns) continue;

            const ms = Millis.from(entry.elapsed_us);
            writer.writeAll(if (any) "; " else " slow: ") catch break;
            writer.print("{s} {s}", .{ entry.kind, entry.what }) catch break;
            if (entry.pid != 0) writer.print(" pid={d}", .{entry.pid}) catch break;
            if (entry.wid != 0) writer.print(" wid={d}", .{entry.wid}) catch break;
            writer.print(" {d}.{d:0>3}ms", .{ ms.whole, ms.frac }) catch break;
            if (entry.err != 0) writer.print(" err={d}", .{entry.err}) catch break;
            any = true;
        }
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
    const base: Counters = .{ .ax = 10, .skylight = 4, .window_list = 1, .ax_us = 5_000 };
    const now: Counters = .{ .ax = 31, .skylight = 9, .window_list = 3, .ax_us = 9_000 };

    const spent = now.since(base);
    try std.testing.expectEqual(@as(u32, 21), spent.ax);
    try std.testing.expectEqual(@as(u32, 5), spent.skylight);
    try std.testing.expectEqual(@as(u32, 2), spent.window_list);
    try std.testing.expectEqual(@as(u32, 28), spent.total());
    try std.testing.expectEqual(@as(u64, 4_000), spent.waitedUs());
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
    _ = call(.ax).finish();
    _ = call(.ax).finishN(3);
    _ = call(.skylight).finish();

    const spent = span.cost();
    try std.testing.expectEqual(@as(u32, 4), spent.ax);
    try std.testing.expectEqual(@as(u32, 1), spent.skylight);
    try std.testing.expectEqual(@as(u32, 0), spent.window_list);
    try std.testing.expectEqual(@as(u32, 0), spent.launch_services);
}

test "a breakdown names each transport's count and wait, then the residual" {
    const spent: Counters = .{ .ax = 2, .ax_us = 1_500, .window_list = 1, .window_list_us = 250 };
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{breakdown(spent, 5_000)});
    try std.testing.expectEqualStrings("ax=2/1.500ms sky=0 cg=1/0.250ms ls=0 other=3.250ms", text);
}

test "a residual never goes negative when waits overlap the span's edges" {
    const spent: Counters = .{ .ax = 1, .ax_us = 7_000 };
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{breakdown(spent, 5_000)});
    try std.testing.expectEqualStrings("ax=1/7.000ms sky=0 cg=0 ls=0 other=0.000ms", text);
}

test "a stall report names the slow calls made inside the span, not before it" {
    g_slow_calls = @splat(null);
    g_slow_calls_next = 0;
    defer {
        g_slow_calls = @splat(null);
        g_slow_calls_next = 0;
    }

    const span = begin("test");
    noteSlowCall("read", "AXWindows", 52048, 0, span.start_ns - 1, 300_000, 0);
    noteSlowCall("write", "AXSize", 52048, 12978, span.start_ns, 457_314, -25204);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        " slow: write AXSize pid=52048 wid=12978 457.314ms err=-25204",
        span.slowCalls(&buf),
    );

    const later = begin("later");
    try std.testing.expectEqualStrings("", later.slowCalls(&buf));
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
