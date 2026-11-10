//! A serial dispatch queue per app process to execute any kind of AX work that
//! needs to be kept off the main thread.
//!
//! For any blocking or synchronous calls, we can queue them as a `Job` for the
//! target app's queue, ensuring that it won't block our own main thread if the
//! target app may have stalled or is slow.

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
};

/// One app process as seen by a job. `index` names the app's slot until the
/// process is forgotten; `generation` changes whenever the slot is reused, so
/// per-app state kept by index can tell a new process from the old one.
pub const App = struct {
    pid: i32,
    index: usize,
    generation: u32,
};

pub const Handler = *const fn (app: App) void;

const Slot = struct {
    // Guarded by g_lock. A slot keeps its pid while scheduled.
    pid: i32 = 0,
    generation: u32 = 0,
    pending: std.EnumSet(Job) = .empty,
    is_scheduled: bool = false,
    queue: c.dispatch_queue_t = null,
};

var g_lock: c.os_unfair_lock = .{};
var g_slots: [max_apps]Slot = @splat(.{});
var g_handlers: std.EnumArray(Job, ?Handler) = .initFill(null);

/// Set the handler for `job`. Main thread, before the first submit.
pub fn setHandler(job: Job, handler: Handler) void {
    g_handlers.set(job, handler);
}

/// Run `job` for `pid` on its app's queue. False when every slot is busy
/// with another app, in which case nothing was queued. Safe from any thread.
pub fn submit(pid: i32, job: Job) bool {
    std.debug.assert(pid > 0);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    const index = slotForPid(pid) orelse {
        log.warn("app table full; dropping {s} pid={d}", .{ @tagName(job), pid });
        return false;
    };
    const slot = &g_slots[index];
    slot.pending.insert(job);
    if (slot.is_scheduled) return true;

    slot.is_scheduled = true;
    c.dispatch_async_f(slot.queue, @ptrFromInt(index + 1), drainSlot);
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
        slot.pending = .empty;
        slot.pid = 0;
    }
}

/// Caller holds g_lock. Prefers a free slot; an idle one held by another
/// live app is taken only when none is free, at the cost of that app's
/// per-slot state.
fn slotForPid(pid: i32) ?usize {
    var free: ?usize = null;
    var idle: ?usize = null;
    for (&g_slots, 0..) |*slot, index| {
        if (slot.pid == pid) return index;
        if (slot.is_scheduled) continue;
        if (free == null and slot.pid == 0) free = index;
        if (idle == null) idle = index;
    }

    const index = free orelse idle orelse return null;
    const slot = &g_slots[index];
    if (slot.queue == null) {
        const attr = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_USER_INTERACTIVE, 0);
        slot.queue = c.dispatch_queue_create("com.bobrwm.app", attr);
    }
    slot.pid = pid;
    slot.generation +%= 1;
    return index;
}

/// Run every job pending for one slot. Runs on that slot's serial queue.
fn drainSlot(context: ?*anyopaque) callconv(.c) void {
    const index = @intFromPtr(context) - 1;
    const slot = &g_slots[index];

    while (true) {
        c.os_unfair_lock_lock(&g_lock);
        const pending = slot.pending;
        slot.pending = .empty;
        if (pending.count() == 0) {
            slot.is_scheduled = false;
            c.os_unfair_lock_unlock(&g_lock);
            return;
        }
        const app: App = .{ .pid = slot.pid, .index = index, .generation = slot.generation };
        c.os_unfair_lock_unlock(&g_lock);

        var jobs = pending.iterator();
        while (jobs.next()) |job| {
            const handler = g_handlers.get(job) orelse continue;
            handler(app);
        }
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
