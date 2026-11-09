//! Debug-only main-thread stall detector.
//!
//! The main thread marks each unit of work it runs (a drain, an event, a
//! timer tick) with `begin`/`end`. A background thread checks the unit in
//! progress and warns once it runs past `stall_threshold_ns`, naming the work
//! and the app involved, so stalls caused by other apps can be ranked and
//! moved off the main thread. It measures the work in progress rather than a
//! heartbeat, so an idle main thread never reads as stalled.
//!
//! Compiled out of every non-debug build: `enabled` is comptime-known, so the
//! checker thread, the shared state, and every call site's body vanish.

const std = @import("std");
const builtin = @import("builtin");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.watchdog);

pub const enabled = builtin.mode == .debug;

/// Past anything a user tolerates, and far above the 16ms frame budget the
/// SLOW drain log already flags.
const stall_threshold_ns: i64 = 500 * std.time.ns_per_ms;
/// A stall is reported at most this late past the threshold.
const check_interval_ns: u64 = 250 * std.time.ns_per_ms;

const Activity = struct {
    label: []const u8 = "",
    pid: i32 = 0,
    wid: u32 = 0,
    started_ns: i64 = 0,
};

/// Returned by `begin`; pass it to `end` to resume the enclosing work.
pub const Scope = struct {
    previous: if (enabled) Activity else void,
    sequence: if (enabled) u32 else void,
};

// The main thread is the only writer. Every field is atomic, and the sequence
// is odd while a write is in flight, so the checker never mixes two
// activities' fields. Each completed write leaves a new even sequence that
// identifies the activity it published.
var g_sequence: std.atomic.Value(u32) = .init(0);
var g_label_ptr: std.atomic.Value(usize) = .init(0);
var g_label_len: std.atomic.Value(usize) = .init(0);
var g_pid: std.atomic.Value(i32) = .init(0);
var g_wid: std.atomic.Value(u32) = .init(0);
var g_started_ns: std.atomic.Value(i64) = .init(0);
// Sequence of the activity the checker last reported as stalled.
var g_reported_sequence: std.atomic.Value(u32) = .init(std.math.maxInt(u32));

// Main thread only: the activity currently published, for nesting.
var g_current: Activity = .{};

var g_stop_requested: std.atomic.Value(bool) = .init(false);
var g_thread: ?std.Thread = null;

/// Start the checker thread. Main thread, once per core start.
pub fn start() void {
    if (!enabled) return;
    std.debug.assert(g_thread == null);

    g_stop_requested.store(false, .seq_cst);
    g_thread = std.Thread.spawn(.{}, checkLoop, .{}) catch |err| {
        log.warn("watchdog thread failed to start: {}", .{err});
        return;
    };
}

/// Stop and join the checker thread. Returns within one check interval.
pub fn stop() void {
    if (!enabled) return;
    const thread = g_thread orelse return;

    g_stop_requested.store(true, .seq_cst);
    thread.join();
    g_thread = null;
}

/// Mark the start of a unit of main-thread work. Nested work replaces the
/// enclosing activity until its `end`.
pub inline fn begin(label: []const u8, pid: i32, wid: u32) Scope {
    if (!enabled) return .{ .previous = {}, .sequence = {} };

    const previous = g_current;
    const sequence = publish(.{
        .label = label,
        .pid = pid,
        .wid = wid,
        .started_ns = nowNs(),
    });
    return .{ .previous = previous, .sequence = sequence };
}

/// Mark the end of the work `scope` began and resume the enclosing activity.
/// The enclosing activity's clock restarts, so a stall already reported for
/// the nested work is not reported again under the outer label.
pub inline fn end(scope: Scope) void {
    if (!enabled) return;

    const ended_ns = nowNs();
    if (g_reported_sequence.load(.seq_cst) == scope.sequence) {
        log.warn("main thread stall ended after {d}ms in {s} pid={d} wid={d}", .{
            @divTrunc(ended_ns - g_current.started_ns, std.time.ns_per_ms),
            g_current.label,
            g_current.pid,
            g_current.wid,
        });
    }

    var resumed = scope.previous;
    if (resumed.label.len > 0) resumed.started_ns = ended_ns;
    _ = publish(resumed);
}

fn publish(activity: Activity) u32 {
    const writing = g_sequence.fetchAdd(1, .seq_cst) + 1;
    std.debug.assert(writing % 2 == 1);

    g_label_ptr.store(@intFromPtr(activity.label.ptr), .seq_cst);
    g_label_len.store(activity.label.len, .seq_cst);
    g_pid.store(activity.pid, .seq_cst);
    g_wid.store(activity.wid, .seq_cst);
    g_started_ns.store(activity.started_ns, .seq_cst);

    g_current = activity;
    return g_sequence.fetchAdd(1, .seq_cst) + 1;
}

const Observation = struct {
    activity: Activity,
    sequence: u32,
};

/// A consistent copy of the published activity, or null if the main thread
/// kept rewriting it; the next check tries again.
fn observe() ?Observation {
    for (0..4) |_| {
        const before = g_sequence.load(.seq_cst);
        if (before % 2 == 1) continue;

        const label_ptr = g_label_ptr.load(.seq_cst);
        const label_len = g_label_len.load(.seq_cst);
        const pid = g_pid.load(.seq_cst);
        const wid = g_wid.load(.seq_cst);
        const started_ns = g_started_ns.load(.seq_cst);
        if (g_sequence.load(.seq_cst) != before) continue;

        // Labels are static strings (event tags, literals), so the pointer
        // stays valid after the main thread moves on.
        const label: []const u8 = if (label_len == 0) "" else @as([*]const u8, @ptrFromInt(label_ptr))[0..label_len];
        return .{
            .activity = .{ .label = label, .pid = pid, .wid = wid, .started_ns = started_ns },
            .sequence = before,
        };
    }
    return null;
}

fn checkLoop() void {
    while (!g_stop_requested.load(.seq_cst)) {
        sleepNs(check_interval_ns);
        const observation = observe() orelse continue;
        const activity = observation.activity;

        if (activity.label.len == 0) continue;
        if (g_reported_sequence.load(.seq_cst) == observation.sequence) continue;

        const stalled_ns = nowNs() - activity.started_ns;
        if (stalled_ns < stall_threshold_ns) continue;

        g_reported_sequence.store(observation.sequence, .seq_cst);
        log.warn("main thread stalled {d}ms in {s} pid={d} wid={d}", .{
            @divTrunc(stalled_ns, std.time.ns_per_ms),
            activity.label,
            activity.pid,
            activity.wid,
        });
    }
}

fn nowNs() i64 {
    return @intCast(osutil.nanoTimestamp());
}

fn sleepNs(duration_ns: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&request, null);
}

test "a stalled unit of work is observed with its label until it ends" {
    if (!enabled) return error.SkipZigTest;

    const outer = begin("drain", 0, 0);
    const inner = begin("window_created", 42, 100);
    const inner_started_ns = g_current.started_ns;

    var observation = observe() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("window_created", observation.activity.label);
    try std.testing.expectEqual(@as(i32, 42), observation.activity.pid);
    try std.testing.expectEqual(inner.sequence, observation.sequence);

    end(inner);
    observation = observe() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("drain", observation.activity.label);
    // The outer clock restarts so a reported inner stall is not repeated.
    try std.testing.expect(observation.activity.started_ns >= inner_started_ns);

    end(outer);
    observation = observe() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), observation.activity.label.len);
}

test "the checker thread reports a stall past the threshold" {
    if (!enabled) return error.SkipZigTest;

    start();
    defer stop();

    const scope = begin("staged stall", 7, 0);
    sleepNs(@as(u64, @intCast(stall_threshold_ns)) + 2 * check_interval_ns);
    try std.testing.expectEqual(scope.sequence, g_reported_sequence.load(.seq_cst));
    end(scope);
}
