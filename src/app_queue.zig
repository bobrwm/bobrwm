//! Per-app serial dispatch queues for AX work that must stay off the main
//! thread.
//!
//! Each app gets two serial lanes: an interactive lane (USER_INTERACTIVE) for
//! geometry writes, focus, and focus queries, and a background lane
//! (USER_INITIATED) for observer setup, window scans, readiness, and tab-bar
//! snapshots. Separating the two keeps slow background scans from head-of-line
//! blocking user-triggered focus and animation writes while keeping per-app
//! writer state single-queue confined.

const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.app_queue);

pub const max_apps = 128;

pub const Job = enum {
    /// ax_writer: apply queued geometry writes.
    write,
    /// ax_writer: raise and activate the newest focus target.
    focus,
    /// focus_query: answer an app activation.
    query_activated,
    /// focus_query: answer a focused-window-changed notification.
    query_focus_changed,
    /// focus_query: answer a focus retry.
    query_retry,
    /// ax_observer: create, register, and prime the app's observer.
    observe,
    /// ax_observer: look for windows the app never announced.
    scan,
    /// window_readiness: answer readiness requests.
    readiness,
    /// app_windows: read the app's window list and tab counts.
    app_windows,
};

const LaneKind = enum(u1) {
    interactive = 0,
    background = 1,
};

fn laneFor(job: Job) LaneKind {
    return switch (job) {
        .write, .focus, .query_activated, .query_focus_changed, .query_retry => .interactive,
        .observe, .scan, .readiness, .app_windows => .background,
    };
}

/// One app process as seen by a job. `index` names the app's slot until the
/// process is forgotten; `generation` changes whenever the slot is reused, so
/// per-app state kept by index can tell a new process from the old one.
pub const App = struct {
    pid: i32,
    index: usize,
    generation: u32,
};

pub const Handler = *const fn (app: App) void;

const Lane = struct {
    pending: std.EnumSet(Job) = .empty,
    is_scheduled: bool = false,
    queue: c.dispatch_queue_t = null,
};

const Slot = struct {
    // Guarded by g_lock. A slot keeps its pid while either lane is scheduled
    // or a caller retains its background queue.
    pid: i32 = 0,
    generation: u32 = 0,
    interactive: Lane = .{},
    background: Lane = .{},
    queue_users: usize = 0,

    fn lane(self: *Slot, kind: LaneKind) *Lane {
        return switch (kind) {
            .interactive => &self.interactive,
            .background => &self.background,
        };
    }

    fn isBusy(self: *const Slot) bool {
        return self.interactive.is_scheduled or self.background.is_scheduled or self.queue_users > 0;
    }
};

var g_lock: c.os_unfair_lock = .{};
var g_slots: [max_apps]Slot = @splat(.{});
var g_handlers: std.EnumArray(Job, ?Handler) = .initFill(null);
var g_accepting: bool = true;
// Tracks every scheduled lane until it goes idle, so shutdown can drain
// in-flight jobs before releasing shared main-thread resources.
var g_inflight: c.dispatch_group_t = null;

/// Set the handler for `job`. Main thread, before the first submit.
pub fn setHandler(job: Job, handler: Handler) void {
    g_handlers.set(job, handler);
}

/// Allow new jobs to be submitted after a prior `stop()`. Main thread.
pub fn start() void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    g_accepting = true;
}

/// Reject new jobs, drop pending work not yet started, and wait for every
/// in-flight job to return. Main thread, during shutdown.
pub fn stop() void {
    const group = blk: {
        c.os_unfair_lock_lock(&g_lock);
        defer c.os_unfair_lock_unlock(&g_lock);
        g_accepting = false;
        for (&g_slots) |*slot| {
            slot.interactive.pending = .empty;
            slot.background.pending = .empty;
        }
        break :blk g_inflight;
    };
    if (group != null) _ = c.dispatch_group_wait(group, c.DISPATCH_TIME_FOREVER);
}

/// Run `job` for `pid` on its app's lane. False when stopped or when every
/// slot is busy with another app, in which case nothing was queued. Safe from
/// any thread.
pub fn submit(pid: i32, job: Job) bool {
    std.debug.assert(pid > 0);
    // A job without a handler would be dropped silently once it runs; startup
    // observing apps before ax_observer registered its handler went unnoticed.
    std.debug.assert(g_handlers.get(job) != null);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    if (!g_accepting) return false;

    const index = slotForPid(pid) orelse {
        log.warn("app table full; dropping {s} pid={d}", .{ @tagName(job), pid });
        return false;
    };
    const kind = laneFor(job);
    const lane = g_slots[index].lane(kind);
    const queue = ensureLaneQueue(lane, kind) orelse return false;
    lane.pending.insert(job);
    if (lane.is_scheduled) return true;

    const group = ensureInflightGroup() orelse return false;
    lane.is_scheduled = true;
    c.dispatch_group_enter(group);
    c.dispatch_async_f(queue, encodeContext(index, kind), drainLane);
    return true;
}

/// Drop jobs not yet started for an ended process and free its slot. A job
/// already running finishes; a later process under the same PID gets a new
/// generation.
pub fn forget(pid: i32) void {
    std.debug.assert(pid > 0);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_slots) |*slot| {
        if (slot.pid != pid) continue;
        slot.interactive.pending = .empty;
        slot.background.pending = .empty;
        slot.pid = 0;
    }
}

/// Get the app's background queue for delayed callbacks. Call releaseQueue
/// when the last callback is done using it. Until then, no other process can
/// take its slot.
pub fn retainQueue(pid: i32) ?c.dispatch_queue_t {
    std.debug.assert(pid > 0);
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    if (!g_accepting) return null;

    const index = slotForPid(pid) orelse return null;
    const slot = &g_slots[index];
    const queue = ensureLaneQueue(&slot.background, .background) orelse return null;
    slot.queue_users += 1;
    return queue;
}

/// Allow the queue's slot to be reused once no callback needs it.
pub fn releaseQueue(queue: c.dispatch_queue_t) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_slots) |*slot| {
        if (slot.background.queue != queue) continue;
        std.debug.assert(slot.queue_users > 0);
        slot.queue_users -= 1;
        return;
    }
    unreachable;
}

/// Caller holds g_lock.
fn ensureInflightGroup() ?c.dispatch_group_t {
    if (g_inflight == null) g_inflight = c.dispatch_group_create();
    return g_inflight;
}

/// Caller holds g_lock. Serial queues intentionally use libdispatch's default
/// overcommit target so blocking AX Mach IPC for one app stays isolated and
/// responsive under system CPU load.
fn ensureLaneQueue(lane: *Lane, kind: LaneKind) ?c.dispatch_queue_t {
    if (lane.queue) |existing| return existing;
    const qos: c.dispatch_qos_class_t = switch (kind) {
        .interactive => c.QOS_CLASS_USER_INTERACTIVE,
        .background => c.QOS_CLASS_USER_INITIATED,
    };
    const label: [*:0]const u8 = switch (kind) {
        .interactive => "com.bobrwm.app.interactive",
        .background => "com.bobrwm.app.background",
    };
    const attr = c.dispatch_queue_attr_make_with_qos_class(null, qos, 0);
    lane.queue = c.dispatch_queue_create(label, attr);
    return lane.queue;
}

/// Caller holds g_lock. Prefers a free slot; an idle one held by another
/// live app is taken only when none is free, at the cost of that app's
/// per-slot state.
fn slotForPid(pid: i32) ?usize {
    var free: ?usize = null;
    var idle: ?usize = null;
    for (&g_slots, 0..) |*slot, index| {
        if (slot.pid == pid) return index;
        if (slot.isBusy()) continue;
        if (free == null and slot.pid == 0) free = index;
        if (idle == null) idle = index;
    }

    const index = free orelse idle orelse return null;
    const slot = &g_slots[index];
    slot.pid = pid;
    slot.generation +%= 1;
    return index;
}

fn encodeContext(index: usize, kind: LaneKind) ?*anyopaque {
    return @ptrFromInt(((index << 1) | @backingInt(kind)) + 1);
}

fn decodeContext(context: ?*anyopaque) struct { index: usize, kind: LaneKind } {
    const raw = @intFromPtr(context.?) - 1;
    return .{
        .index = raw >> 1,
        .kind = @fromBackingInt(@intCast(@as(u1, @truncate(raw & 1)))),
    };
}

/// Run the jobs waiting now on one lane. Let delayed callbacks run before
/// starting any jobs added while these jobs were running.
fn drainLane(context: ?*anyopaque) callconv(.c) void {
    const decoded = decodeContext(context);
    const slot = &g_slots[decoded.index];
    const lane = slot.lane(decoded.kind);

    c.os_unfair_lock_lock(&g_lock);
    const pending = lane.pending;
    lane.pending = .empty;
    if (!g_accepting or pending.count() == 0) {
        lane.is_scheduled = false;
        const group = g_inflight;
        c.os_unfair_lock_unlock(&g_lock);
        if (group != null) c.dispatch_group_leave(group);
        return;
    }
    const app: App = .{ .pid = slot.pid, .index = decoded.index, .generation = slot.generation };
    c.os_unfair_lock_unlock(&g_lock);

    var jobs = pending.iterator();
    while (jobs.next()) |job| {
        g_handlers.get(job).?(app);
    }

    c.os_unfair_lock_lock(&g_lock);
    if (g_accepting and lane.pending.count() > 0) {
        const queue = lane.queue;
        c.os_unfair_lock_unlock(&g_lock);
        c.dispatch_async_f(queue, context, drainLane);
    } else {
        lane.pending = .empty;
        lane.is_scheduled = false;
        const group = g_inflight;
        c.os_unfair_lock_unlock(&g_lock);
        if (group != null) c.dispatch_group_leave(group);
    }
}

test "pending jobs coalesce and a forgotten pid gets a new generation" {
    const testing = std.testing;
    const Probe = struct {
        var started: c.dispatch_semaphore_t = null;
        var gate: c.dispatch_semaphore_t = null;
        var done: c.dispatch_semaphore_t = null;
        var runs: u32 = 0;
        var last: App = undefined;

        fn handler(app: App) void {
            _ = c.dispatch_semaphore_signal(started);
            _ = c.dispatch_semaphore_wait(gate, c.DISPATCH_TIME_FOREVER);
            last = app;
            runs += 1;
            _ = c.dispatch_semaphore_signal(done);
        }

        fn awaitStart() void {
            _ = c.dispatch_semaphore_wait(started, c.DISPATCH_TIME_FOREVER);
        }

        fn finishRun() void {
            _ = c.dispatch_semaphore_signal(gate);
            _ = c.dispatch_semaphore_wait(done, c.DISPATCH_TIME_FOREVER);
        }
    };
    Probe.started = c.dispatch_semaphore_create(0);
    Probe.gate = c.dispatch_semaphore_create(0);
    Probe.done = c.dispatch_semaphore_create(0);
    setHandler(.write, Probe.handler);
    const pid = 4242;

    // Both later submits land while the first run is held, and collapse into
    // one more run.
    try testing.expect(submit(pid, .write));
    Probe.awaitStart();
    try testing.expect(submit(pid, .write));
    try testing.expect(submit(pid, .write));
    Probe.finishRun();
    Probe.awaitStart();
    Probe.finishRun();
    try testing.expectEqual(@as(u32, 2), Probe.runs);
    const first = Probe.last;
    try testing.expectEqual(@as(i32, pid), first.pid);

    // A later process under the same PID must not share the old one's state.
    forget(pid);
    try testing.expect(submit(pid, .write));
    Probe.awaitStart();
    Probe.finishRun();
    try testing.expectEqual(@as(u32, 3), Probe.runs);
    try testing.expect(Probe.last.generation != first.generation);
}

test "callbacks run between jobs and keep their queue until they are done" {
    const Probe = struct {
        var started: c.dispatch_semaphore_t = null;
        var gate: c.dispatch_semaphore_t = null;
        var other_done: c.dispatch_semaphore_t = null;
        var done: c.dispatch_semaphore_t = null;
        var runs: u32 = 0;
        var runs_at_callback: u32 = 0;

        fn handler(app: App) void {
            if (runs == 0) {
                _ = c.dispatch_semaphore_signal(started);
                _ = c.dispatch_semaphore_wait(gate, c.DISPATCH_TIME_FOREVER);
            }
            runs += 1;
            if (runs < 4) {
                _ = submit(app.pid, .scan);
            } else _ = c.dispatch_semaphore_signal(done);
        }

        fn callback(_: ?*anyopaque) callconv(.c) void {
            runs_at_callback = runs;
        }

        fn otherHandler(_: App) void {
            _ = c.dispatch_semaphore_signal(other_done);
        }
    };
    Probe.started = c.dispatch_semaphore_create(0);
    Probe.gate = c.dispatch_semaphore_create(0);
    Probe.other_done = c.dispatch_semaphore_create(0);
    Probe.done = c.dispatch_semaphore_create(0);
    defer for ([_]c.dispatch_semaphore_t{ Probe.started, Probe.gate, Probe.other_done, Probe.done }) |semaphore| {
        c.dispatch_release(.{ ._dsema = semaphore });
    };

    const pid = 5001;
    const queue = retainQueue(pid) orelse return error.TestUnexpectedResult;
    defer releaseQueue(queue);
    setHandler(.scan, Probe.handler);
    setHandler(.query_retry, Probe.otherHandler);
    try std.testing.expect(submit(pid, .scan));
    _ = c.dispatch_semaphore_wait(Probe.started, c.DISPATCH_TIME_FOREVER);
    c.dispatch_async_f(queue, null, Probe.callback);

    // A blocked app must not stop a different app's jobs.
    const other_submitted = submit(5002, .query_retry);
    const other_result = c.dispatch_semaphore_wait(Probe.other_done, c.dispatch_time(c.DISPATCH_TIME_NOW, std.time.ns_per_s));
    _ = c.dispatch_semaphore_signal(Probe.gate);
    _ = c.dispatch_semaphore_wait(Probe.done, c.DISPATCH_TIME_FOREVER);
    try std.testing.expect(other_submitted);
    try std.testing.expectEqual(@as(c_long, 0), other_result);
    try std.testing.expectEqual(@as(u32, 1), Probe.runs_at_callback);

    // Wait until the last job has fully returned. The queue must keep its
    // slot even when no jobs are running, until we call releaseQueue.
    c.dispatch_sync_f(queue, null, Probe.callback);
    forget(pid);
    const replacement = retainQueue(pid) orelse return error.TestUnexpectedResult;
    defer releaseQueue(replacement);
    try std.testing.expect(queue != replacement);
}

test "a blocked background job does not block interactive jobs for the same app" {
    const Probe = struct {
        var bg_started: c.dispatch_semaphore_t = null;
        var bg_gate: c.dispatch_semaphore_t = null;
        var bg_done: c.dispatch_semaphore_t = null;
        var interactive_done: c.dispatch_semaphore_t = null;

        fn bgHandler(_: App) void {
            _ = c.dispatch_semaphore_signal(bg_started);
            _ = c.dispatch_semaphore_wait(bg_gate, c.DISPATCH_TIME_FOREVER);
            _ = c.dispatch_semaphore_signal(bg_done);
        }

        fn interactiveHandler(_: App) void {
            _ = c.dispatch_semaphore_signal(interactive_done);
        }
    };
    Probe.bg_started = c.dispatch_semaphore_create(0);
    Probe.bg_gate = c.dispatch_semaphore_create(0);
    Probe.bg_done = c.dispatch_semaphore_create(0);
    Probe.interactive_done = c.dispatch_semaphore_create(0);
    defer for ([_]c.dispatch_semaphore_t{ Probe.bg_started, Probe.bg_gate, Probe.bg_done, Probe.interactive_done }) |sem| {
        c.dispatch_release(.{ ._dsema = sem });
    };

    const pid = 5010;
    defer forget(pid);
    setHandler(.app_windows, Probe.bgHandler);
    setHandler(.focus, Probe.interactiveHandler);

    try std.testing.expect(submit(pid, .app_windows));
    _ = c.dispatch_semaphore_wait(Probe.bg_started, c.DISPATCH_TIME_FOREVER);

    // Interactive focus for the exact same PID must complete while the
    // background capture is still blocked.
    try std.testing.expect(submit(pid, .focus));
    const interactive_result = c.dispatch_semaphore_wait(
        Probe.interactive_done,
        c.dispatch_time(c.DISPATCH_TIME_NOW, std.time.ns_per_s),
    );
    _ = c.dispatch_semaphore_signal(Probe.bg_gate);
    _ = c.dispatch_semaphore_wait(Probe.bg_done, c.DISPATCH_TIME_FOREVER);
    try std.testing.expectEqual(@as(c_long, 0), interactive_result);
}

test "stop drains in-flight jobs and rejects submits until start" {
    const Probe = struct {
        var started: c.dispatch_semaphore_t = null;
        var gate: c.dispatch_semaphore_t = null;
        var finished: std.atomic.Value(bool) = .init(false);

        fn handler(app: App) void {
            _ = c.dispatch_semaphore_signal(started);
            _ = c.dispatch_semaphore_wait(gate, c.DISPATCH_TIME_FOREVER);
            finished.store(true, .release);
            // Re-submitting during shutdown must be ignored cleanly.
            _ = submit(app.pid, .write);
        }

        fn releaseAfterDelay() void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            _ = c.dispatch_semaphore_signal(gate);
        }
    };
    Probe.started = c.dispatch_semaphore_create(0);
    Probe.gate = c.dispatch_semaphore_create(0);
    Probe.finished.store(false, .release);
    defer {
        start();
        c.dispatch_release(.{ ._dsema = Probe.started });
        c.dispatch_release(.{ ._dsema = Probe.gate });
    }

    const pid = 5020;
    defer forget(pid);
    setHandler(.write, Probe.handler);
    try std.testing.expect(submit(pid, .write));
    _ = c.dispatch_semaphore_wait(Probe.started, c.DISPATCH_TIME_FOREVER);

    const releaser = try std.Thread.spawn(.{}, Probe.releaseAfterDelay, .{});
    defer releaser.join();

    stop();
    try std.testing.expect(Probe.finished.load(.acquire));
    try std.testing.expect(!submit(pid, .write));
    try std.testing.expectEqual(@as(?c.dispatch_queue_t, null), retainQueue(pid));

    start();
    Probe.finished.store(false, .release);
    try std.testing.expect(submit(pid, .write));
    _ = c.dispatch_semaphore_wait(Probe.started, c.DISPATCH_TIME_FOREVER);
    _ = c.dispatch_semaphore_signal(Probe.gate);
    stop();
    try std.testing.expect(Probe.finished.load(.acquire));
}
