//! Per-app AX observers.
//!
//! Callbacks run on a background thread and the setup and application scanning
//! runs on the dedicated queue each app is assigned.

const std = @import("std");
const log = std.log.scoped(.ax_observer);
const objc = @import("objc");
const c = @import("c");
const cg_extra = @import("cg_extra");
const app_queue = @import("app_queue.zig");
const focus_query = @import("focus_query.zig");
const osutil = @import("osutil.zig");
const shim = @import("shim_api.zig");
const watchdog = @import("watchdog.zig");
const window_server = @import("window_server.zig");

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

const max_observed_apps: usize = 128;
// Live windows per app, not lifetime windows: gone entries are pruned before
// the list counts as full.
const max_known_windows_per_app: usize = 256;
const observe_retry_interval_ms: u64 = 100;
const observe_retry_attempts_max: u8 = 50;
const window_scan_interval_ms: u64 = 500;
const window_scan_idle_limit: u32 = 10;
const wid_retry_delay_ms: u64 = 50;
const wid_retry_attempts_max: u8 = 60;
const max_wid_retry_contexts: usize = max_observed_apps * 8;
/// Bounds how long a slow app holds its own queue during setup and scans.
const setup_timeout_seconds: f32 = 1.0;

comptime {
    std.debug.assert(max_known_windows_per_app <= window_server.max_batch);
}

const AppObserverEntry = struct {
    pid: i32 = 0,
    // Start time of the process the observer was created for.
    started_at_us: u64 = 0,
    observer: c.AXObserverRef = null,
    known_window_count: u32 = 0,
    known_windows: [max_known_windows_per_app]u32 = @splat(0),
    has_warned_full: bool = false,
};

const ObserveRetryEntry = struct {
    pid: i32 = 0,
    attempts_remaining: u8 = 0,
};

const WidRetryContext = struct {
    in_use: bool = false,
    observer: c.AXObserverRef = null,
    element: c.AXUIElementRef = null,
    queue: c.dispatch_queue_t = null,
    pid: i32 = 0,
    attempts_remaining: u8 = 0,
};

const AxObserverStrings = struct {
    windows_attr: c.CFStringRef,
    window_created_notification: c.CFStringRef,
    focused_window_changed_notification: c.CFStringRef,
    moved_notification: c.CFStringRef,
    resized_notification: c.CFStringRef,
    destroyed_notification: c.CFStringRef,
    miniaturized_notification: c.CFStringRef,
    deminiaturized_notification: c.CFStringRef,
    menu_opened_notification: c.CFStringRef,
    menu_closed_notification: c.CFStringRef,
};

// g_ax_lock guards the observer table and the window-ID retry pool.

var g_ax_lock: c.os_unfair_lock_s = .{ ._os_unfair_lock_opaque = 0 };

/// Background thread handle and its CFRunLoop for AX observer sources.
var g_ax_thread: c.pthread_t = null;
var g_ax_thread_runloop: c.CFRunLoopRef = null;
/// Synchronisation: background thread signals readiness after capturing its runloop ref.
var g_ax_thread_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var g_observe_retry_source: c.dispatch_source_t = null;
var g_window_scan_source: c.dispatch_source_t = null;
var g_app_observers: [max_observed_apps]AppObserverEntry = @splat(.{});
var g_app_observer_count: u32 = 0;
var g_observe_retry_entries: [max_observed_apps]ObserveRetryEntry = @splat(.{});
var g_observe_retry_count: u32 = 0;
var g_window_scan_idle_ticks: u32 = 0;
var g_window_scan_found_new: std.atomic.Value(bool) = .init(false);
var g_is_running: bool = false;
var g_wid_retry_contexts: [max_wid_retry_contexts]WidRetryContext = @splat(.{});
// Count each retry until it finishes, including time spent waiting to run.
var g_wid_retry_group: c.dispatch_group_t = null;
var g_ax_observer_strings: ?AxObserverStrings = null;

fn createAxObserverString(raw: [*:0]const u8) ?c.CFStringRef {
    return c.CFStringCreateWithCString(null, raw, c.kCFStringEncodingUTF8);
}

fn releaseAxObserverString(value: c.CFStringRef) void {
    c.CFRelease(@ptrCast(value));
}

fn ensureAxObserverStrings() ?*const AxObserverStrings {
    if (g_ax_observer_strings) |*strings| return strings;

    const names = [_][*:0]const u8{
        "AXWindows",
        "AXWindowCreated",
        "AXFocusedWindowChanged",
        "AXMoved",
        "AXResized",
        "AXUIElementDestroyed",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
        "AXMenuOpened",
        "AXMenuClosed",
    };
    var refs: [names.len]c.CFStringRef = undefined;

    for (names, 0..) |name, i| {
        refs[i] = createAxObserverString(name) orelse {
            var created_count: usize = i;
            while (created_count > 0) : (created_count -= 1) {
                releaseAxObserverString(refs[created_count - 1]);
            }
            return null;
        };
    }

    g_ax_observer_strings = .{
        .windows_attr = refs[0],
        .window_created_notification = refs[1],
        .focused_window_changed_notification = refs[2],
        .moved_notification = refs[3],
        .resized_notification = refs[4],
        .destroyed_notification = refs[5],
        .miniaturized_notification = refs[6],
        .deminiaturized_notification = refs[7],
        .menu_opened_notification = refs[8],
        .menu_closed_notification = refs[9],
    };
    return &g_ax_observer_strings.?;
}

// Background observer thread

fn axThreadKeepalivePerform(context: ?*anyopaque) callconv(.c) void {
    _ = context;
}

fn axThreadEntry(context: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = context;
    const run_loop = c.CFRunLoopGetCurrent();
    g_ax_thread_runloop = run_loop;

    // An empty CFRunLoop returns immediately. Keep a source installed for the
    // lifetime of this thread so startup cannot turn into a CPU-burning spin
    // before the first AX observer is registered.
    var source_context: c.CFRunLoopSourceContext = std.mem.zeroes(c.CFRunLoopSourceContext);
    source_context.perform = axThreadKeepalivePerform;
    const keepalive_source = c.CFRunLoopSourceCreate(null, 0, &source_context) orelse {
        log.err("failed to create AX thread keepalive source", .{});
        g_ax_thread_runloop = null;
        g_ax_thread_ready.store(true, .release);
        return null;
    };
    defer c.CFRelease(@ptrCast(keepalive_source));
    c.CFRunLoopAddSource(run_loop, keepalive_source, c.kCFRunLoopDefaultMode);
    defer c.CFRunLoopRemoveSource(run_loop, keepalive_source, c.kCFRunLoopDefaultMode);

    g_ax_thread_ready.store(true, .release);
    c.CFRunLoopRun();

    return null;
}

fn startAxThread() void {
    if (g_ax_thread != null) return;

    var attr: c.pthread_attr_t = undefined;
    _ = c.pthread_attr_init(&attr);
    defer _ = c.pthread_attr_destroy(&attr);

    var thread: c.pthread_t = null;
    if (c.pthread_create(&thread, &attr, axThreadEntry, null) != 0) {
        log.err("failed to create AX observer thread", .{});
        return;
    }
    g_ax_thread = thread;

    // Spin until the thread has captured its CFRunLoop ref.  This is fast
    // (< 1ms) because the thread does nothing before signaling readiness.
    while (!g_ax_thread_ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    if (g_ax_thread_runloop == null) {
        _ = c.pthread_join(thread, null);
        g_ax_thread = null;
        g_ax_thread_ready.store(false, .release);
    }
}

fn stopAxThread() void {
    if (g_ax_thread_runloop) |rl| {
        c.CFRunLoopStop(rl);
    }
    if (g_ax_thread) |thread| {
        _ = c.pthread_join(thread, null);
    }
    g_ax_thread = null;
    g_ax_thread_runloop = null;
    g_ax_thread_ready.store(false, .release);
}

// Public API

pub fn init() void {
    deinit();
    if (g_wid_retry_group == null) g_wid_retry_group = c.dispatch_group_create();
    // Created here, on the main thread, and kept for the process: app queue
    // jobs can still be reading them after a deinit.
    _ = ensureAxObserverStrings();
    startAxThread();
    app_queue.setHandler(.observe, runObserve);
    app_queue.setHandler(.scan, runScan);

    c.os_unfair_lock_lock(&g_ax_lock);
    g_is_running = true;
    c.os_unfair_lock_unlock(&g_ax_lock);
}

pub fn deinit() void {
    cancelRuntimeSources();

    // Stop publishing first, so a setup job still running cannot add an
    // observer after the table is emptied.
    var observers: [max_observed_apps]c.AXObserverRef = undefined;
    var observer_count: usize = 0;
    c.os_unfair_lock_lock(&g_ax_lock);
    g_is_running = false;
    for (g_app_observers[0..g_app_observer_count]) |entry| {
        observers[observer_count] = entry.observer;
        observer_count += 1;
    }
    g_app_observer_count = 0;
    g_app_observers = @splat(.{});
    c.os_unfair_lock_unlock(&g_ax_lock);

    // Detach sources, then join the observer thread before releasing anything
    // a callback can read. CFRunLoopStop alone does not wait for an in-flight
    // callback to return.
    if (g_ax_thread_runloop) |rl| {
        for (observers[0..observer_count]) |observer| {
            c.CFRunLoopRemoveSource(rl, c.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);
        }
    }
    stopAxThread();
    for (observers[0..observer_count]) |observer| c.CFRelease(@ptrCast(observer));

    g_observe_retry_count = 0;
    g_window_scan_idle_ticks = 0;

    // Retries can still be running after the observer thread stops. Wait for
    // them to finish so we don't free an AX object while a retry is using it.
    if (g_wid_retry_group) |group| {
        _ = c.dispatch_group_wait(group, c.DISPATCH_TIME_FOREVER);
    }
}

/// Set up an observer for the app on its queue, retrying until it is
/// observed or the attempts run out.
pub fn observeApp(pid: i32) void {
    std.debug.assert(pid > 0);
    if (hasCurrentObserver(pid)) return;
    _ = app_queue.submit(pid, .observe);
    scheduleObserveRetry(pid, observe_retry_interval_ms);
}

/// Queue observer setup after latency-sensitive workspace landing work.
pub fn observeAppDeferred(pid: i32) void {
    std.debug.assert(pid > 0);
    if (hasCurrentObserver(pid)) return;
    scheduleObserveRetry(pid, window_scan_interval_ms);
}

pub fn unobserveApp(pid: i32) void {
    std.debug.assert(pid > 0);
    cancelObserveRetry(pid);
    removeAppObserver(pid);
    updateWindowScanSource();
}

// Internal — main-thread helpers

fn cancelRuntimeSources() void {
    if (g_observe_retry_source) |source| {
        c.dispatch_source_cancel(source);
        c.dispatch_release(.{ ._ds = source });
        g_observe_retry_source = null;
    }

    if (g_window_scan_source) |source| {
        c.dispatch_source_cancel(source);
        c.dispatch_release(.{ ._ds = source });
        g_window_scan_source = null;
    }
}

/// Caller holds g_ax_lock.
fn appObserverIndex(pid: i32) ?u32 {
    var i: u32 = 0;
    while (i < g_app_observer_count) : (i += 1) {
        if (g_app_observers[i].pid == pid) return i;
    }
    return null;
}

/// The PID's observer belongs to the process running under it now. A PID
/// reused after a lost termination keeps the dead process's observer, which
/// never fires again, so it must not count as observed.
fn hasCurrentObserver(pid: i32) bool {
    const observed_started_at_us = blk: {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse return false;
        break :blk g_app_observers[index].started_at_us;
    };

    // An unanswered query trusts the observer it has.
    const started_at_us = (osutil.processStartTimeUs(pid) catch return true) orelse return false;
    return observed_started_at_us == started_at_us;
}

/// The PID's observer, retained for the caller.
fn retainObserver(pid: i32) ?c.AXObserverRef {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);
    const index = appObserverIndex(pid) orelse return null;
    const observer = g_app_observers[index].observer orelse return null;
    _ = c.CFRetain(@ptrCast(observer));
    return observer;
}

/// Add a set-up observer to the table and attach its source to the AX
/// thread. False when the observer is no longer wanted: stopping, the PID
/// already observed, or the table full. Any thread.
fn publishObserver(pid: i32, started_at_us: u64, observer: c.AXObserverRef) bool {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);

    if (!g_is_running) return false;
    if (appObserverIndex(pid) != null) return false;
    if (g_app_observer_count >= max_observed_apps) return false;
    const rl = g_ax_thread_runloop orelse return false;

    c.CFRunLoopAddSource(rl, c.AXObserverGetRunLoopSource(observer), c.kCFRunLoopDefaultMode);
    c.CFRunLoopWakeUp(rl);
    _ = c.CFRetain(@ptrCast(observer));
    g_app_observers[g_app_observer_count] = .{
        .pid = pid,
        .started_at_us = started_at_us,
        .observer = observer,
    };
    g_app_observer_count += 1;
    return true;
}

/// Remove the PID's observer and detach its source. A callback already in
/// flight fails its table lookup instead of mutating a replaced entry, and
/// holds its own reference to the observer. Any thread.
fn removeAppObserver(pid: i32) void {
    const observer = blk: {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse return;
        const removed = g_app_observers[index].observer;

        g_app_observer_count -= 1;
        g_app_observers[index] = g_app_observers[g_app_observer_count];
        g_app_observers[g_app_observer_count] = .{};
        if (g_is_running) {
            if (g_ax_thread_runloop) |rl| {
                c.CFRunLoopRemoveSource(rl, c.AXObserverGetRunLoopSource(removed), c.kCFRunLoopDefaultMode);
            }
        }
        break :blk removed;
    };
    if (observer) |ref| c.CFRelease(@ptrCast(ref));
}

/// Forget a window the manager removed, once WindowServer confirms it is gone.
/// A minimized or hidden window keeps its slot: its deminiaturize
/// notification is what brings it back.
pub fn forgetWindowIfGone(pid: i32, wid: u32) void {
    std.debug.assert(pid > 0);
    std.debug.assert(wid != 0);

    // Termination and destroy notifications usually dropped it already.
    const is_known = blk: {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse break :blk false;
        const entry = &g_app_observers[index];
        break :blk std.mem.findScalar(u32, entry.known_windows[0..entry.known_window_count], wid) != null;
    };
    if (!is_known) return;
    if (window_server.hasWindow(wid)) return;
    appUntrackWindow(pid, wid);
}

const TrackResult = enum { added, known, full, unobserved };

/// Track a window ID in an app's known-windows set.
/// Returns true if the window was newly added, false if already tracked or at
/// capacity. A full set first drops windows WindowServer no longer has.
///
/// Thread-safety: acquires g_ax_lock internally, never across the prune query.
fn appTrackWindow(pid: i32, wid: u32) bool {
    if (wid == 0) return false;

    var result = appTrackWindowOnce(pid, wid);
    if (result == .full) {
        pruneGoneWindows(pid);
        result = appTrackWindowOnce(pid, wid);
    }
    if (result == .full) warnKnownWindowsFull(pid, wid);
    return result == .added;
}

fn appTrackWindowOnce(pid: i32, wid: u32) TrackResult {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);

    const index = appObserverIndex(pid) orelse return .unobserved;
    var entry = &g_app_observers[index];

    const known_windows = entry.known_windows[0..entry.known_window_count];
    if (std.mem.findScalar(u32, known_windows, wid) != null) return .known;
    if (entry.known_window_count == max_known_windows_per_app) return .full;

    entry.known_windows[entry.known_window_count] = wid;
    entry.known_window_count += 1;
    return .added;
}

/// Drop known windows WindowServer no longer has. Destroy notifications can be
/// missed (close-to-background apps, native-tab ID swaps, ghosts reaped by
/// cleanup), and each one left behind would hold a slot for the app's life.
///
/// Thread-safety: snapshots under g_ax_lock, queries WindowServer without it.
fn pruneGoneWindows(pid: i32) void {
    var window_ids: [max_known_windows_per_app]u32 = undefined;
    var window_count: usize = 0;
    {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse return;
        const entry = &g_app_observers[index];
        window_count = entry.known_window_count;
        @memcpy(window_ids[0..window_count], entry.known_windows[0..window_count]);
    }

    var existing_buffer: [max_known_windows_per_app]u32 = undefined;
    const existing = window_server.existingWindowIds(window_ids[0..window_count], &existing_buffer) orelse return;

    var pruned_count: usize = 0;
    for (window_ids[0..window_count]) |wid| {
        if (std.mem.findScalar(u32, existing, wid) != null) continue;
        appUntrackWindow(pid, wid);
        pruned_count += 1;
    }
    log.debug("known windows pruned pid={d} pruned={d} live={d}", .{ pid, pruned_count, existing.len });
}

/// Warn once per observed app: every later window from it is also untracked,
/// and repeating the line for each would bury the first one.
fn warnKnownWindowsFull(pid: i32, wid: u32) void {
    const should_warn = blk: {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse break :blk false;
        const entry = &g_app_observers[index];
        if (entry.has_warned_full) break :blk false;
        entry.has_warned_full = true;
        break :blk true;
    };
    if (!should_warn) return;
    log.warn("known windows full of live windows pid={d} wid={d} limit={d}; new windows are not observed", .{
        pid, wid, max_known_windows_per_app,
    });
}

/// Remove a window ID from an app's known-windows set.
///
/// Thread-safety: acquires g_ax_lock internally.
fn appUntrackWindow(pid: i32, wid: u32) void {
    if (wid == 0) return;

    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);

    const index = appObserverIndex(pid) orelse return;
    var entry = &g_app_observers[index];

    const known_windows = entry.known_windows[0..entry.known_window_count];
    const window_index = std.mem.findScalar(u32, known_windows, wid) orelse return;
    entry.known_windows[window_index] = entry.known_windows[entry.known_window_count - 1];
    entry.known_window_count -= 1;
}

fn observeRetryIndex(pid: i32) ?u32 {
    var i: u32 = 0;
    while (i < g_observe_retry_count) : (i += 1) {
        if (g_observe_retry_entries[i].pid == pid) return i;
    }
    return null;
}

fn observeRetryRemoveIndex(index: u32) void {
    if (index >= g_observe_retry_count) return;
    g_observe_retry_count -= 1;
    g_observe_retry_entries[index] = g_observe_retry_entries[g_observe_retry_count];
}

fn observeRetryStopIfIdle() void {
    if (g_observe_retry_count != 0) return;
    if (g_observe_retry_source) |source| {
        c.dispatch_source_cancel(source);
        c.dispatch_release(.{ ._ds = source });
        g_observe_retry_source = null;
    }
}

fn isAppRunning(pid: i32) bool {
    std.debug.assert(pid > 0);

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return false;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    return app.value != null;
}

fn shouldDropObserveRetryEntry(pid: i32) bool {
    if (!isAppRunning(pid)) return true;
    return hasCurrentObserver(pid);
}

fn observeRetrySourceTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    const scope = watchdog.begin("ax observe retry", 0, 0);
    defer watchdog.end(scope);
    processObserveRetryTick();
}

fn processObserveRetryTick() void {
    var i: u32 = 0;
    while (i < g_observe_retry_count) {
        var entry = &g_observe_retry_entries[i];

        if (shouldDropObserveRetryEntry(entry.pid)) {
            observeRetryRemoveIndex(i);
            continue;
        }

        _ = app_queue.submit(entry.pid, .observe);
        if (entry.attempts_remaining == 0) {
            observeRetryRemoveIndex(i);
            continue;
        }
        entry.attempts_remaining -= 1;
        i += 1;
    }

    observeRetryStopIfIdle();
}

fn scheduleObserveRetry(pid: i32, initial_delay_ms: u64) void {
    if (hasCurrentObserver(pid)) return;

    if (observeRetryIndex(pid)) |existing| {
        g_observe_retry_entries[existing].attempts_remaining = observe_retry_attempts_max;
    } else {
        if (g_observe_retry_count >= max_observed_apps) {
            log.warn("AX observe retry queue exhausted pid={d} limit={d}", .{ pid, max_observed_apps });
            return;
        }
        g_observe_retry_entries[g_observe_retry_count] = .{
            .pid = pid,
            .attempts_remaining = observe_retry_attempts_max,
        };
        g_observe_retry_count += 1;
    }

    if (g_observe_retry_source != null) return;

    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
    );
    if (source == null) return;

    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(initial_delay_ms)) * c.NSEC_PER_MSEC),
        observe_retry_interval_ms * c.NSEC_PER_MSEC,
        @as(u64, 100) * c.NSEC_PER_MSEC,
    );
    c.dispatch_source_set_event_handler_f(source, observeRetrySourceTick);
    c.dispatch_resume(.{ ._ds = source });
    g_observe_retry_source = source;
}

fn cancelObserveRetry(pid: i32) void {
    const index = observeRetryIndex(pid) orelse return;
    observeRetryRemoveIndex(index);
    observeRetryStopIfIdle();
}

fn windowScanSourceTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    const scope = watchdog.begin("ax window scan", 0, 0);
    defer watchdog.end(scope);
    processWindowScanTick();
}

fn updateWindowScanSource() void {
    c.os_unfair_lock_lock(&g_ax_lock);
    const observer_count = g_app_observer_count;
    c.os_unfair_lock_unlock(&g_ax_lock);

    if (observer_count == 0) {
        if (g_window_scan_source) |source| {
            c.dispatch_source_cancel(source);
            c.dispatch_release(.{ ._ds = source });
            g_window_scan_source = null;
        }
        return;
    }

    if (g_window_scan_source != null) return;

    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
    );
    if (source == null) return;

    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(window_scan_interval_ms)) * c.NSEC_PER_MSEC),
        window_scan_interval_ms * c.NSEC_PER_MSEC,
        @as(u64, 100) * c.NSEC_PER_MSEC,
    );
    c.dispatch_source_set_event_handler_f(source, windowScanSourceTick);
    c.dispatch_resume(.{ ._ds = source });
    g_window_scan_source = source;
}

fn packRefcon(pid: i32, wid: u32) ?*anyopaque {
    std.debug.assert(pid > 0 or wid == 0);
    const packed_refcon: usize = (@as(usize, wid) << 32) | @as(usize, @intCast(pid));
    return @ptrFromInt(packed_refcon);
}

fn refconPid(refcon: ?*anyopaque) i32 {
    const packed_refcon: usize = @intFromPtr(refcon orelse return 0);
    const pid_raw: u32 = @truncate(packed_refcon & 0xFFFF_FFFF);
    return @intCast(pid_raw);
}

fn refconWid(refcon: ?*anyopaque) u32 {
    const packed_refcon: usize = @intFromPtr(refcon orelse return 0);
    return @truncate(packed_refcon >> 32);
}

fn registerWindowAXNotifications(observer: c.AXObserverRef, window: c.AXUIElementRef, pid: i32) void {
    const strings = ensureAxObserverStrings() orelse return;

    var wid: u32 = 0;
    _ = _AXUIElementGetWindow(window, &wid);
    const refcon = packRefcon(pid, wid);

    _ = c.AXObserverAddNotification(observer, window, strings.moved_notification, refcon);
    _ = c.AXObserverAddNotification(observer, window, strings.resized_notification, refcon);
    _ = c.AXObserverAddNotification(observer, window, strings.destroyed_notification, refcon);
    _ = c.AXObserverAddNotification(observer, window, strings.miniaturized_notification, refcon);
    _ = c.AXObserverAddNotification(observer, window, strings.deminiaturized_notification, refcon);
}

fn scanAppWindowsForNewEntries(pid: i32, observer: c.AXObserverRef) bool {
    const strings = ensureAxObserverStrings() orelse return false;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));
    _ = c.AXUIElementSetMessagingTimeout(app, setup_timeout_seconds);

    var windows: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, strings.windows_attr, @ptrCast(&windows));
    if (err != c.kAXErrorSuccess or windows == null) return false;
    const windows_ref = windows orelse return false;
    defer c.CFRelease(@ptrCast(windows_ref));

    var found_new = false;
    const count = c.CFArrayGetCount(windows_ref);

    var wi: c.CFIndex = 0;
    while (wi < count) : (wi += 1) {
        const win_any = c.CFArrayGetValueAtIndex(windows_ref, wi) orelse continue;
        const win: c.AXUIElementRef = @ptrCast(win_any);
        // Elements copied out of the list do not inherit the app's timeout.
        _ = c.AXUIElementSetMessagingTimeout(win, setup_timeout_seconds);

        var wid: u32 = 0;
        _ = _AXUIElementGetWindow(win, &wid);
        if (wid == 0) continue;
        if (!appTrackWindow(pid, wid)) continue;

        found_new = true;
        registerWindowAXNotifications(observer, win, pid);
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_CREATED, pid, wid);
    }

    return found_new;
}

/// Queue a scan of every observed app. A scan finds new windows on the app's
/// queue, so this tick sees what the previous round found.
fn processWindowScanTick() void {
    var pids: [max_observed_apps]i32 = undefined;
    var pid_count: usize = 0;
    c.os_unfair_lock_lock(&g_ax_lock);
    for (g_app_observers[0..g_app_observer_count]) |entry| {
        pids[pid_count] = entry.pid;
        pid_count += 1;
    }
    c.os_unfair_lock_unlock(&g_ax_lock);

    for (pids[0..pid_count]) |pid| _ = app_queue.submit(pid, .scan);

    // Stop the repeating scan after consecutive idle ticks to avoid
    // paying the AX enumeration cost forever at steady state.
    if (g_window_scan_found_new.swap(false, .acq_rel)) {
        g_window_scan_idle_ticks = 0;
        return;
    }

    g_window_scan_idle_ticks += 1;
    if (g_window_scan_idle_ticks >= window_scan_idle_limit) {
        if (g_window_scan_source) |source| {
            c.dispatch_source_cancel(source);
            c.dispatch_release(.{ ._ds = source });
            g_window_scan_source = null;
        }
    }
}

fn runScan(app: app_queue.App) void {
    const observer = retainObserver(app.pid) orelse return;
    defer c.CFRelease(@ptrCast(observer));
    if (scanAppWindowsForNewEntries(app.pid, observer)) g_window_scan_found_new.store(true, .release);
}

/// Acquire a WID retry context from the fixed-size pool.
///
/// Thread-safety: acquires g_ax_lock internally.
fn acquireWidRetryCtx(observer: c.AXObserverRef, element: c.AXUIElementRef, pid: i32) ?*WidRetryContext {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);

    if (!g_is_running) return null;
    for (&g_wid_retry_contexts) |*ctx| {
        if (!ctx.in_use or ctx.observer != observer or ctx.pid != pid) continue;
        // AX can report the same new window more than once before it has an ID.
        // Checking whether these are the same window does not contact the app.
        if (c.CFEqual(@ptrCast(ctx.element), @ptrCast(element)) != 0) return null;
    }
    for (&g_wid_retry_contexts) |*ctx| {
        if (ctx.in_use) continue;
        const queue = app_queue.retainQueue(pid) orelse return null;
        _ = c.CFRetain(@ptrCast(observer));
        _ = c.CFRetain(@ptrCast(element));
        ctx.* = .{
            .in_use = true,
            .observer = observer,
            .element = element,
            .queue = queue,
            .pid = pid,
            .attempts_remaining = wid_retry_attempts_max,
        };
        c.dispatch_group_enter(g_wid_retry_group);
        return ctx;
    }
    log.warn("AX window-id retry pool exhausted pid={d} limit={d}", .{ pid, max_wid_retry_contexts });
    return null;
}

fn releaseWidRetryCtx(ctx: *WidRetryContext) void {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);

    if (!ctx.in_use) return;
    if (ctx.observer != null) {
        c.CFRelease(@ptrCast(ctx.observer));
    }
    if (ctx.element != null) {
        c.CFRelease(@ptrCast(ctx.element));
    }
    app_queue.releaseQueue(ctx.queue);
    ctx.* = .{};
    c.dispatch_group_leave(g_wid_retry_group);
}

fn retryResolveWid(context: ?*anyopaque) callconv(.c) void {
    const ctx = @as(*WidRetryContext, @ptrCast(@alignCast(context orelse return)));
    if (!ctx.in_use) return;

    // Bail out if the app was unobserved, or its observer replaced, while
    // this retry was in flight: it must not emit WINDOW_CREATED for a pid the
    // table no longer tracks under this observer.
    if (!isObserverCurrent(ctx.pid, ctx.observer)) {
        releaseWidRetryCtx(ctx);
        return;
    }

    const element = ctx.element orelse {
        releaseWidRetryCtx(ctx);
        return;
    };

    var wid: u32 = 0;
    _ = _AXUIElementGetWindow(element, &wid);

    if (wid != 0) {
        const is_new_window = appTrackWindow(ctx.pid, wid);
        if (!is_new_window) {
            releaseWidRetryCtx(ctx);
            return;
        }

        const observer = ctx.observer orelse {
            releaseWidRetryCtx(ctx);
            return;
        };
        registerWindowAXNotifications(observer, element, ctx.pid);
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_CREATED, ctx.pid, wid);
        releaseWidRetryCtx(ctx);
        return;
    }

    if (ctx.attempts_remaining == 0) {
        releaseWidRetryCtx(ctx);
        return;
    }

    ctx.attempts_remaining -= 1;
    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(wid_retry_delay_ms)) * c.NSEC_PER_MSEC),
        ctx.queue,
        ctx,
        retryResolveWid,
    );
}

fn isObserverCurrent(pid: i32, observer: c.AXObserverRef) bool {
    c.os_unfair_lock_lock(&g_ax_lock);
    defer c.os_unfair_lock_unlock(&g_ax_lock);
    const index = appObserverIndex(pid) orelse return false;
    return g_app_observers[index].observer == observer;
}

fn scheduleWidResolutionRetry(observer: c.AXObserverRef, element: c.AXUIElementRef, pid: i32) void {
    const ctx = acquireWidRetryCtx(observer, element, pid) orelse return;
    _ = c.AXUIElementSetMessagingTimeout(ctx.element, setup_timeout_seconds);

    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(wid_retry_delay_ms)) * c.NSEC_PER_MSEC),
        ctx.queue,
        ctx,
        retryResolveWid,
    );
}

// AX notification callback — runs on the background observer thread.

fn isNotification(notification: c.CFStringRef, expected: c.CFStringRef) bool {
    return c.CFEqual(@ptrCast(notification), @ptrCast(expected)) != 0;
}

fn axNotificationHandler(
    observer: c.AXObserverRef,
    element: c.AXUIElementRef,
    notification: c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void {
    // Keep the observer alive if the main thread concurrently unobserves the
    // app after this callback has been entered.
    _ = c.CFRetain(@ptrCast(observer));
    defer c.CFRelease(@ptrCast(observer));

    const strings = ensureAxObserverStrings() orelse return;

    const pid = refconPid(refcon);
    var wid = refconWid(refcon);

    // Menu elements need not have a CG window ID. Publish only the observation;
    // the main-thread reducer owns nesting and hover-focus suspension.
    if (isNotification(notification, strings.menu_opened_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_MENU_OPENED, pid, 0);
        return;
    }
    if (isNotification(notification, strings.menu_closed_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_MENU_CLOSED, pid, 0);
        return;
    }

    if (isNotification(notification, strings.window_created_notification)) {
        // App-level: wid is 0 in refcon, resolve from the new element.
        _ = _AXUIElementGetWindow(element, &wid);
        if (wid != 0) {
            if (!appTrackWindow(pid, wid)) return;
            registerWindowAXNotifications(observer, element, pid);
            shim.bw_emit_event(shim.BW_EVENT_WINDOW_CREATED, pid, wid);
            return;
        }
        // CGWindowID not assigned yet — schedule retries.
        scheduleWidResolutionRetry(observer, element, pid);
        return;
    }

    if (isNotification(notification, strings.focused_window_changed_notification)) {
        // App-level (wid=0 in refcon). Resolve the window on the app's own
        // queue: a slow app must not hold this thread, which serves every app.
        focus_query.request(pid, .focus_changed);
        return;
    }

    if (wid == 0) return; // Per-window notification but wid was unknown.

    if (isNotification(notification, strings.destroyed_notification)) {
        appUntrackWindow(pid, wid);
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_DESTROYED, pid, wid);
    } else if (isNotification(notification, strings.moved_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_MOVED, pid, wid);
    } else if (isNotification(notification, strings.resized_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_RESIZED, pid, wid);
    } else if (isNotification(notification, strings.miniaturized_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_MINIMIZED, pid, wid);
    } else if (isNotification(notification, strings.deminiaturized_notification)) {
        shim.bw_emit_event(shim.BW_EVENT_WINDOW_DEMINIMIZED, pid, wid);
    }
}

// Observer registration — on the app's queue

fn registerAppLevelAXNotifications(observer: c.AXObserverRef, app: c.AXUIElementRef, app_refcon: ?*anyopaque) bool {
    const strings = ensureAxObserverStrings() orelse return false;

    // If the critical create notification fails, the app AX interface is not ready.
    const add_err = c.AXObserverAddNotification(observer, app, strings.window_created_notification, app_refcon);
    if (add_err != c.kAXErrorSuccess) return false;

    _ = c.AXObserverAddNotification(observer, app, strings.focused_window_changed_notification, app_refcon);
    _ = c.AXObserverAddNotification(observer, app, strings.menu_opened_notification, app_refcon);
    _ = c.AXObserverAddNotification(observer, app, strings.menu_closed_notification, app_refcon);
    return true;
}

fn primeObservedAppWindows(pid: i32, observer: c.AXObserverRef, app: c.AXUIElementRef) void {
    const strings = ensureAxObserverStrings() orelse return;

    // Emit WINDOW_CREATED for pre-existing windows so Zig can tile immediately.
    var windows: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, strings.windows_attr, @ptrCast(&windows));
    if (err != c.kAXErrorSuccess or windows == null) return;
    const windows_ref = windows orelse return;
    defer c.CFRelease(@ptrCast(windows_ref));

    const count = c.CFArrayGetCount(windows_ref);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win_any = c.CFArrayGetValueAtIndex(windows_ref, i) orelse continue;
        const win: c.AXUIElementRef = @ptrCast(win_any);
        _ = c.AXUIElementSetMessagingTimeout(win, setup_timeout_seconds);

        var wid: u32 = 0;
        _ = _AXUIElementGetWindow(win, &wid);
        if (wid != 0) {
            if (!appTrackWindow(pid, wid)) continue;
            registerWindowAXNotifications(observer, win, pid);
            shim.bw_emit_event(shim.BW_EVENT_WINDOW_CREATED, pid, wid);
            continue;
        }

        // Some apps expose AX windows before WindowServer assigns CGWindowID.
        scheduleWidResolutionRetry(observer, win, pid);
    }
}

/// Create and register an observer for the app, publish it, then report
/// its existing windows.
fn runObserve(app: app_queue.App) void {
    const pid = app.pid;
    // A gone process has nothing to observe; the retry tick drops it.
    const started_at_us = (osutil.processStartTimeUs(pid) catch return) orelse return;
    if (hasObserverFor(pid, started_at_us)) return;

    var observer: c.AXObserverRef = null;
    if (c.AXObserverCreate(pid, axNotificationHandler, &observer) != c.kAXErrorSuccess) return;
    const observer_ref = observer orelse return;
    defer c.CFRelease(@ptrCast(observer_ref));

    const ax_app = c.AXUIElementCreateApplication(pid) orelse return;
    defer c.CFRelease(@ptrCast(ax_app));
    _ = c.AXUIElementSetMessagingTimeout(ax_app, setup_timeout_seconds);

    if (!registerAppLevelAXNotifications(observer_ref, ax_app, packRefcon(pid, 0))) return;
    if (!publishObserver(pid, started_at_us, observer_ref)) return;

    c.dispatch_async_f(cg_extra.dispatch_get_main_queue(), null, observersChanged);
    primeObservedAppWindows(pid, observer_ref, ax_app);
}

/// True when the PID already has an observer for this process. One left by
/// an earlier process under the same PID never fires again, so it is
/// removed.
fn hasObserverFor(pid: i32, started_at_us: u64) bool {
    const observed_started_at_us = blk: {
        c.os_unfair_lock_lock(&g_ax_lock);
        defer c.os_unfair_lock_unlock(&g_ax_lock);
        const index = appObserverIndex(pid) orelse return false;
        break :blk g_app_observers[index].started_at_us;
    };
    if (observed_started_at_us == started_at_us) return true;

    log.info("AX observer replaced pid={d}; the observed process ended unreported", .{pid});
    removeAppObserver(pid);
    return false;
}

/// Main queue: restart the window scan for a newly published observer.
fn observersChanged(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    g_window_scan_idle_ticks = 0;
    updateWindowScanSource();
}
