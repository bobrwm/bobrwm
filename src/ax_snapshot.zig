//! Bounded, coalescing AX reads. Only worker jobs touch AX; delivery and all
//! scheduling bookkeeping belong to the AppKit main thread.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const cg_extra = @import("cg_extra");
const ax = @import("ax.zig");
const osutil = @import("osutil.zig");
const shim = @import("shim_api.zig");

const log = std.log.scoped(.ax_snapshot);

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

pub const Window = struct {
    wid: u32,
    manage_state: u8,
    tab_count: ?usize,
    can_resize: ?bool,
};

pub const Snapshot = struct {
    pid: i32,
    windows: [128]Window = undefined,
    count: usize = 0,
    /// False means missing entries are unknown, never evidence of destruction.
    complete: bool = false,
    focused_window_id: u32 = 0,
    /// True includes a definitive AX no-value result (no focused window).
    focus_complete: bool = false,
    focused_window: ?Window = null,

    pub fn window(self: *const Snapshot, wid: u32) ?Window {
        for (self.windows[0..self.count]) |entry| {
            if (entry.wid == wid) return entry;
        }
        if (self.focused_window) |entry| {
            if (entry.wid == wid) return entry;
        }
        return null;
    }
};

pub const Reasons = struct {
    focus: bool = false,
    cleanup: bool = false,
    offscreen: bool = false,
    candidates: bool = false,

    fn merge(self: *Reasons, other: Reasons) void {
        self.focus = self.focus or other.focus;
        self.cleanup = self.cleanup or other.cleanup;
        self.offscreen = self.offscreen or other.offscreen;
        self.candidates = self.candidates or other.candidates;
    }
};

pub const ReadyFn = *const fn (*const Snapshot, Reasons) void;
// These reads no longer hold the main thread. AppKit opening/closing a window
// routinely exceeds a frame; a 25ms timeout discarded healthy replies and
// delayed adoption through repeated retries. Only the affected app waits here.
const messaging_timeout_seconds: f32 = 0.25;
// Cooperative budget: an already running AX message/classification may overrun
// it, but a slow app must not multiply its timeout across every window/child.
const read_budget_ns = std.time.ns_per_s;
const max_apps = 64;

// Never read by a worker. Busy slots remain reserved even after shutdown/exit
// until their main-queue completion releases them, including across re-init.
const App = struct {
    pid: i32 = 0,
    generation: u64 = 0,
    busy: bool = false,
    delivering: bool = false,
    reasons: Reasons = .{},
    // Process-lifetime queues are reused across PID turnover and core restarts.
    queue: c.dispatch_queue_t = null,
    job: Job = undefined,
};

// Inputs are immutable while dispatched. Only the worker writes the result;
// dispatching completion transfers its ownership back to the main queue.
const Job = struct {
    slot: usize,
    pid: i32,
    generation: u64,
    result: Snapshot,
};

var g_apps: [max_apps]App = @splat(.{});
var g_on_ready: ?ReadyFn = null;
var g_manual_test_jobs = false;

/// Main-thread only. Snapshot pointers are borrowed for the callback duration.
pub fn init(on_ready: ReadyFn) void {
    deinit();
    g_on_ready = on_ready;
}

/// Main-thread only; invalidates delivery without waiting on hung AX servers.
/// Static job storage and independent job strings survive outstanding reads.
pub fn deinit() void {
    g_on_ready = null;
    for (&g_apps) |*app| {
        app.pid = 0;
        app.generation +%= 1;
        app.reasons = .{};
    }
}

/// Main-thread only. Merge reasons into an in-flight read without invalidating
/// it; actual AX changes must call invalidate first. Requests during delivery
/// start one fresh read after the callback returns, keeping its snapshot stable.
/// Returns false if disabled, pid is invalid, or all 64 slots are busy.
pub fn request(pid: i32, reasons: Reasons) bool {
    if (pid <= 0 or g_on_ready == null) return false;
    var idle: ?usize = null;
    for (&g_apps, 0..) |*app, index| {
        if (app.pid == pid) {
            app.reasons.merge(reasons);
            if (!app.busy or app.delivering) app.generation +%= 1;
            if (!app.busy) schedule(index);
            return true;
        }
        if (idle == null and !app.busy) idle = index;
    }
    const index = idle orelse return false;
    const app = &g_apps[index];
    app.pid = pid;
    app.generation +%= 1;
    app.reasons = reasons;
    schedule(index);
    return true;
}

/// Main-thread only. True covers both the active read and its coalesced retry.
pub fn pending(pid: i32) bool {
    for (&g_apps) |*app| {
        if (app.pid == pid and app.busy) return true;
    }
    return false;
}

/// Main-thread only. Invalidate an active read without losing requested work.
/// An idle app has no snapshot to invalidate, so this never starts new work.
pub fn invalidate(pid: i32) void {
    for (&g_apps) |*app| {
        if (app.pid == pid and app.busy) app.generation +%= 1;
    }
}

/// Main-thread only. PID reuse cannot inherit a departed process's result.
pub fn forgetApp(pid: i32) void {
    for (&g_apps) |*app| {
        if (app.pid != pid) continue;
        app.pid = 0;
        app.generation +%= 1;
        app.reasons = .{};
    }
}

fn schedule(index: usize) void {
    const app = &g_apps[index];
    std.debug.assert(!app.busy);
    app.job = .{
        .slot = index,
        .pid = app.pid,
        .generation = app.generation,
        .result = .{ .pid = app.pid },
    };
    app.busy = true;
    if (builtin.is_test and g_manual_test_jobs) return;
    if (app.queue == null) {
        app.queue = c.dispatch_queue_create("com.bobrwm.ax-snapshot", null);
    }
    c.dispatch_async_f(app.queue, &app.job, readJob);
}

fn readJob(context: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(context.?));
    const started_ns = osutil.nanoTimestamp();
    readSnapshot(&job.result);
    log.debug("read pid={d} windows={d} complete={} focus={d} elapsed_us={d}", .{
        job.pid,                                                            job.result.count, job.result.complete, job.result.focused_window_id,
        @divTrunc(osutil.nanoTimestamp() - started_ns, std.time.ns_per_us),
    });
    c.dispatch_async_f(cg_extra.dispatch_get_main_queue(), job, completeJob);
}

fn completeJob(context: ?*anyopaque) callconv(.c) void {
    const job: *const Job = @ptrCast(@alignCast(context.?));
    const app = &g_apps[job.slot];
    std.debug.assert(app.busy);
    if (g_on_ready == null or app.pid != job.pid) {
        app.busy = false;
        return;
    }
    if (app.generation != job.generation) {
        app.busy = false;
        schedule(job.slot);
        return;
    }
    const reasons = app.reasons;
    app.reasons = .{};
    app.delivering = true;
    // Keep busy throughout delivery: reentrant requests only record intent,
    // never overwrite this snapshot or start a worker while it is borrowed.
    g_on_ready.?(&job.result, reasons);
    app.delivering = false;
    app.busy = false;
    if (g_on_ready != null and app.pid == job.pid and app.generation != job.generation) schedule(job.slot);
}

fn readSnapshot(result: *Snapshot) void {
    const deadline_ns = osutil.nanoTimestamp() + read_budget_ns;
    const strings = ax.createStrings() orelse return;
    defer ax.freeStrings(strings);
    const app = c.AXUIElementCreateApplication(result.pid) orelse return;
    defer c.CFRelease(@ptrCast(app));
    _ = c.AXUIElementSetMessagingTimeout(app, messaging_timeout_seconds);
    // Focus must not sit behind metadata traversal for all the app's windows.
    readFocus(result, app, &strings, deadline_ns);
    readWindows(result, app, &strings, deadline_ns);
}

fn readWindows(result: *Snapshot, app: c.AXUIElementRef, strings: *const ax.AxStrings, deadline_ns: i128) void {
    if (osutil.nanoTimestamp() >= deadline_ns) return;
    var windows: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, strings.windows_attr, @ptrCast(&windows));
    defer if (windows) |ref| c.CFRelease(@ptrCast(ref));
    if (err != c.kAXErrorSuccess or windows == null) return;
    if (c.CFGetTypeID(@ptrCast(windows)) != c.CFArrayGetTypeID()) return;
    const count = c.CFArrayGetCount(windows);
    if (count < 0) return;
    result.complete = count <= result.windows.len;
    var index: c.CFIndex = 0;
    while (index < count and index < result.windows.len) : (index += 1) {
        if (osutil.nanoTimestamp() >= deadline_ns) {
            result.complete = false;
            break;
        }
        const element: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows, index) orelse {
            result.complete = false;
            continue;
        });
        _ = c.AXUIElementSetMessagingTimeout(element, messaging_timeout_seconds);
        var wid: u32 = 0;
        if (_AXUIElementGetWindow(element, &wid) != c.kAXErrorSuccess or wid == 0) {
            result.complete = false;
            continue;
        }
        // Reuse focused-window metadata instead of traversing its AX tree twice.
        result.windows[result.count] = result.window(wid) orelse readWindow(element, wid, strings, deadline_ns);
        result.count += 1;
    }
}

fn readFocus(result: *Snapshot, app: c.AXUIElementRef, strings: *const ax.AxStrings, deadline_ns: i128) void {
    var focused: c.AXUIElementRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, strings.focused_window_attr, @ptrCast(&focused));
    defer if (focused) |ref| c.CFRelease(@ptrCast(ref));
    if (err == c.kAXErrorNoValue) {
        result.focus_complete = true;
        return;
    }
    if (err != c.kAXErrorSuccess or focused == null) return;
    _ = c.AXUIElementSetMessagingTimeout(focused, messaging_timeout_seconds);
    var wid: u32 = 0;
    if (_AXUIElementGetWindow(focused, &wid) != c.kAXErrorSuccess or wid == 0) return;
    result.focused_window_id = wid;
    result.focus_complete = true;
    // Remote panels can be focused without appearing in AXWindows.
    result.focused_window = readWindow(focused, wid, strings, deadline_ns);
}

fn readWindow(element: c.AXUIElementRef, wid: u32, strings: *const ax.AxStrings, deadline_ns: i128) Window {
    if (osutil.nanoTimestamp() >= deadline_ns) return .{
        .wid = wid,
        .manage_state = shim.BW_MANAGE_PENDING,
        .tab_count = null,
        .can_resize = null,
    };
    var can_resize: c.Boolean = 0;
    const resize_err = c.AXUIElementIsAttributeSettable(element, strings.size_attr, &can_resize);
    return .{
        .wid = wid,
        .manage_state = if (osutil.nanoTimestamp() < deadline_ns) ax.manageStateForElement(element, strings) else shim.BW_MANAGE_PENDING,
        .tab_count = ax.tabCountForElement(element, strings, messaging_timeout_seconds, deadline_ns),
        .can_resize = if (resize_err == c.kAXErrorSuccess) can_resize != 0 else null,
    };
}

test "requests coalesce, suppress stale delivery, and invalidate on exit and shutdown" {
    const Harness = struct {
        var deliveries: usize = 0;
        var last_reasons: Reasons = .{};
        var reenter = false;
        var stable = true;
        fn ready(result: *const Snapshot, reasons: Reasons) void {
            std.debug.assert(result.pid == 42);
            deliveries += 1;
            last_reasons = reasons;
            if (reenter) {
                reenter = false;
                stable = request(42, .{ .candidates = true }) and pending(42);
                // schedule resets the result: a marker supplied by finish
                // must survive until the borrowed callback returns.
                stable = stable and result.focused_window_id == 123;
            }
        }
        fn finish() void {
            // Simulate the worker's main-queue handoff without live AX access.
            for (&g_apps) |*app| {
                if (app.busy) {
                    app.job.result.focused_window_id = 123;
                    completeJob(&app.job);
                    return;
                }
            }
            unreachable;
        }
    };
    g_manual_test_jobs = true;
    defer g_manual_test_jobs = false;
    init(Harness.ready);
    defer deinit();
    try std.testing.expect(request(42, .{ .focus = true }));
    try std.testing.expect(request(42, .{ .cleanup = true }));
    try std.testing.expect(request(42, .{ .offscreen = true }));
    try std.testing.expect(pending(42));
    Harness.finish();
    try std.testing.expectEqual(@as(usize, 1), Harness.deliveries);
    try std.testing.expectEqualDeep(Reasons{ .focus = true, .cleanup = true, .offscreen = true }, Harness.last_reasons);
    try std.testing.expect(!pending(42));
    try std.testing.expect(request(42, .{ .focus = true }));
    invalidate(42);
    try std.testing.expect(request(42, .{ .cleanup = true }));
    invalidate(42);
    Harness.finish();
    try std.testing.expectEqual(@as(usize, 1), Harness.deliveries);
    Harness.reenter = true;
    Harness.finish();
    try std.testing.expect(Harness.stable);
    try std.testing.expectEqualDeep(Reasons{ .focus = true, .cleanup = true }, Harness.last_reasons);
    try std.testing.expect(pending(42));
    Harness.finish();
    try std.testing.expectEqualDeep(Reasons{ .candidates = true }, Harness.last_reasons);
    try std.testing.expectEqual(@as(usize, 3), Harness.deliveries);
    try std.testing.expect(request(42, .{}));
    forgetApp(42);
    try std.testing.expect(request(42, .{}));
    Harness.finish();
    try std.testing.expectEqual(@as(usize, 3), Harness.deliveries);
    Harness.finish();
    try std.testing.expectEqual(@as(usize, 4), Harness.deliveries);
    try std.testing.expect(request(42, .{}));
    deinit();
    init(Harness.ready);
    Harness.finish();
    try std.testing.expectEqual(@as(usize, 4), Harness.deliveries);
}

test "snapshot lookup includes focused panels omitted from AXWindows" {
    const listed: Window = .{ .wid = 10, .manage_state = 1, .tab_count = 0, .can_resize = true };
    const panel: Window = .{ .wid = 11, .manage_state = 0, .tab_count = null, .can_resize = null };
    var snapshot: Snapshot = .{ .pid = 42, .focused_window = panel, .focused_window_id = 11, .focus_complete = true };
    snapshot.windows[0] = listed;
    snapshot.count = 1;
    try std.testing.expectEqualDeep(listed, snapshot.window(10).?);
    try std.testing.expectEqualDeep(panel, snapshot.window(11).?);
    try std.testing.expect(snapshot.window(12) == null);
    // Incomplete does not suppress positive evidence, only absence inference.
    try std.testing.expect(!snapshot.complete);
}
