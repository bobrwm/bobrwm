//! Per-application AX observer runtime moved from shim.m to Zig.
//!
//! This module owns retry timers, AX observer registration, and deferred
//! CGWindowID resolution while keeping Objective-C class callbacks in shim.m.

const std = @import("std");
const objc = @import("objc");
const c = @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("dispatch/dispatch.h");
});
const shim = @import("shim_api.zig");

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

const max_observed_apps: usize = 128;
const max_known_windows_per_app: usize = 256;
const observe_retry_interval_ms: u64 = 500;
const observe_retry_attempts_max: u8 = 40;
const window_scan_interval_ms: u64 = 500;
const window_scan_idle_limit: u32 = 10;
const wid_retry_delay_ms: u64 = 50;
const wid_retry_attempts_max: u8 = 60;
const max_wid_retry_contexts: usize = max_observed_apps * 8;

const AppObserverEntry = struct {
    pid: i32 = 0,
    observer: c.AXObserverRef = null,
    known_window_count: u32 = 0,
    known_windows: [max_known_windows_per_app]u32 = [_]u32{0} ** max_known_windows_per_app,
};

const ObserveRetryEntry = struct {
    pid: i32 = 0,
    attempts_remaining: u8 = 0,
};

const WidRetryContext = struct {
    in_use: bool = false,
    observer: c.AXObserverRef = null,
    element: c.AXUIElementRef = null,
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
};

var g_observer_runloop: c.CFRunLoopRef = null;
var g_observe_retry_source: c.dispatch_source_t = null;
var g_window_scan_source: c.dispatch_source_t = null;
var g_app_observers: [max_observed_apps]AppObserverEntry = [_]AppObserverEntry{.{}} ** max_observed_apps;
var g_app_observer_count: u32 = 0;
var g_observe_retry_entries: [max_observed_apps]ObserveRetryEntry = [_]ObserveRetryEntry{.{}} ** max_observed_apps;
var g_observe_retry_count: u32 = 0;
var g_window_scan_idle_ticks: u32 = 0;
var g_wid_retry_contexts: [max_wid_retry_contexts]WidRetryContext = [_]WidRetryContext{.{}} ** max_wid_retry_contexts;
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
    };
    return &g_ax_observer_strings.?;
}

fn deinitAxObserverStrings() void {
    if (g_ax_observer_strings) |strings| {
        const refs = [_]c.CFStringRef{
            strings.deminiaturized_notification,
            strings.miniaturized_notification,
            strings.destroyed_notification,
            strings.resized_notification,
            strings.moved_notification,
            strings.focused_window_changed_notification,
            strings.window_created_notification,
            strings.windows_attr,
        };
        for (refs) |value| {
            releaseAxObserverString(value);
        }
        g_ax_observer_strings = null;
    }
}

pub fn init() void {
    // Re-initialization should be equivalent to a fresh startup.
    deinit();
    g_observer_runloop = c.CFRunLoopGetMain();
}

pub fn deinit() void {
    cancelRuntimeSources();

    var i: u32 = 0;
    while (i < g_app_observer_count) : (i += 1) {
        const observer = g_app_observers[i].observer;
        if (observer == null) continue;
        if (g_observer_runloop != null) {
            c.CFRunLoopRemoveSource(
                g_observer_runloop,
                c.AXObserverGetRunLoopSource(observer),
                c.kCFRunLoopCommonModes,
            );
        }
        c.CFRelease(@ptrCast(observer));
    }
    g_app_observer_count = 0;
    g_observe_retry_count = 0;
    g_window_scan_idle_ticks = 0;

    for (&g_wid_retry_contexts) |*ctx| {
        releaseWidRetryCtx(ctx);
    }

    deinitAxObserverStrings();
}

pub fn observeApp(pid: i32) void {
    std.debug.assert(pid > 0);

    if (tryObserveApp(pid)) {
        cancelObserveRetry(pid);
        return;
    }
    scheduleObserveRetry(pid);
}

pub fn unobserveApp(pid: i32) void {
    std.debug.assert(pid > 0);

    cancelObserveRetry(pid);

    var i: u32 = 0;
    while (i < g_app_observer_count) : (i += 1) {
        if (g_app_observers[i].pid != pid) continue;
        removeAppObserverAtIndex(i);
        return;
    }
}

fn cancelRuntimeSources() void {
    if (g_observe_retry_source) |source| {
        c.dispatch_source_cancel(source);
        g_observe_retry_source = null;
    }

    if (g_window_scan_source) |source| {
        c.dispatch_source_cancel(source);
        g_window_scan_source = null;
    }
}

fn appObserverIndex(pid: i32) ?u32 {
    var i: u32 = 0;
    while (i < g_app_observer_count) : (i += 1) {
        if (g_app_observers[i].pid == pid) return i;
    }
    return null;
}

fn appObserverExists(pid: i32) bool {
    return appObserverIndex(pid) != null;
}

fn appTrackWindow(pid: i32, wid: u32) bool {
    if (wid == 0) return false;

    const index = appObserverIndex(pid) orelse return false;
    var entry = &g_app_observers[index];

    var i: u32 = 0;
    while (i < entry.known_window_count) : (i += 1) {
        if (entry.known_windows[i] == wid) return false;
    }

    if (entry.known_window_count < max_known_windows_per_app) {
        entry.known_windows[entry.known_window_count] = wid;
        entry.known_window_count += 1;
        return true;
    }

    // Preserve progress when an app has unusually many windows.
    entry.known_windows[entry.known_window_count - 1] = wid;
    return true;
}

fn appUntrackWindow(pid: i32, wid: u32) void {
    if (wid == 0) return;

    const index = appObserverIndex(pid) orelse return;
    var entry = &g_app_observers[index];

    var i: u32 = 0;
    while (i < entry.known_window_count) : (i += 1) {
        if (entry.known_windows[i] != wid) continue;
        entry.known_windows[i] = entry.known_windows[entry.known_window_count - 1];
        entry.known_window_count -= 1;
        return;
    }
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
    return appObserverExists(pid);
}

fn observeRetrySourceTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
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

        if (tryObserveApp(entry.pid)) {
            observeRetryRemoveIndex(i);
            continue;
        }

        if (entry.attempts_remaining == 0) {
            observeRetryRemoveIndex(i);
            continue;
        }
        entry.attempts_remaining -= 1;
        i += 1;
    }

    observeRetryStopIfIdle();
}

fn scheduleObserveRetry(pid: i32) void {
    if (appObserverExists(pid)) return;

    if (observeRetryIndex(pid)) |existing| {
        g_observe_retry_entries[existing].attempts_remaining = observe_retry_attempts_max;
    } else {
        if (g_observe_retry_count >= max_observed_apps) return;
        g_observe_retry_entries[g_observe_retry_count] = .{
            .pid = pid,
            .attempts_remaining = observe_retry_attempts_max,
        };
        g_observe_retry_count += 1;
    }

    if (g_observe_retry_source != null) return;

    const source = c.dispatch_source_create(
        c.DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        c.dispatch_get_main_queue(),
    );
    if (source == null) return;

    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(observe_retry_interval_ms)) * c.NSEC_PER_MSEC),
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
    processWindowScanTick();
}

fn updateWindowScanSource() void {
    if (g_app_observer_count == 0) {
        if (g_window_scan_source) |source| {
            c.dispatch_source_cancel(source);
            g_window_scan_source = null;
        }
        return;
    }

    if (g_window_scan_source != null) return;

    const source = c.dispatch_source_create(
        c.DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        c.dispatch_get_main_queue(),
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

fn processWindowScanTick() void {
    var found_new = false;

    var i: u32 = 0;
    while (i < g_app_observer_count) : (i += 1) {
        const pid = g_app_observers[i].pid;
        const observer = g_app_observers[i].observer;
        if (observer == null) continue;
        if (scanAppWindowsForNewEntries(pid, observer)) {
            found_new = true;
        }
    }

    // Stop the repeating scan after consecutive idle ticks to avoid
    // paying the AX enumeration cost forever at steady state.
    if (found_new) {
        g_window_scan_idle_ticks = 0;
        return;
    }

    g_window_scan_idle_ticks += 1;
    if (g_window_scan_idle_ticks >= window_scan_idle_limit) {
        if (g_window_scan_source) |source| {
            c.dispatch_source_cancel(source);
            g_window_scan_source = null;
        }
    }
}

fn acquireWidRetryCtx() ?*WidRetryContext {
    for (&g_wid_retry_contexts) |*ctx| {
        if (ctx.in_use) continue;
        ctx.* = .{ .in_use = true };
        return ctx;
    }
    return null;
}

fn releaseWidRetryCtx(ctx: *WidRetryContext) void {
    if (!ctx.in_use) return;
    if (ctx.observer != null) {
        c.CFRelease(@ptrCast(ctx.observer));
    }
    if (ctx.element != null) {
        c.CFRelease(@ptrCast(ctx.element));
    }
    ctx.* = .{};
}

fn retryResolveWid(context: ?*anyopaque) callconv(.c) void {
    const ctx = @as(*WidRetryContext, @ptrCast(@alignCast(context orelse return)));
    if (!ctx.in_use) return;

    // Bail out if the owning app was unobserved or terminated while this
    // retry was in flight. Without this guard a stale callback can emit
    // WINDOW_CREATED for a pid we no longer track.
    if (!appObserverExists(ctx.pid) or !isAppRunning(ctx.pid)) {
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
        c.dispatch_get_main_queue(),
        ctx,
        retryResolveWid,
    );
}

fn scheduleWidResolutionRetry(observer: c.AXObserverRef, element: c.AXUIElementRef, pid: i32) void {
    const ctx = acquireWidRetryCtx() orelse return;

    const retained_observer = c.CFRetain(@ptrCast(observer)) orelse {
        releaseWidRetryCtx(ctx);
        return;
    };
    ctx.observer = @ptrCast(@constCast(retained_observer));

    const retained_element = c.CFRetain(@ptrCast(element)) orelse {
        releaseWidRetryCtx(ctx);
        return;
    };
    ctx.element = @ptrCast(@constCast(retained_element));
    ctx.pid = pid;
    ctx.attempts_remaining = wid_retry_attempts_max;

    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, @intCast(wid_retry_delay_ms)) * c.NSEC_PER_MSEC),
        c.dispatch_get_main_queue(),
        ctx,
        retryResolveWid,
    );
}

fn isNotification(notification: c.CFStringRef, expected: c.CFStringRef) bool {
    return c.CFEqual(@ptrCast(notification), @ptrCast(expected)) != 0;
}

fn axNotificationHandler(
    observer: c.AXObserverRef,
    element: c.AXUIElementRef,
    notification: c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void {
    const strings = ensureAxObserverStrings() orelse return;

    const pid = refconPid(refcon);
    var wid = refconWid(refcon);

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
        // App-level (wid=0 in refcon): emit so Zig can reconcile tab groups.
        shim.bw_emit_event(shim.BW_EVENT_FOCUSED_WINDOW_CHANGED, pid, 0);
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

fn registerAppLevelAXNotifications(observer: c.AXObserverRef, app: c.AXUIElementRef, app_refcon: ?*anyopaque) bool {
    const strings = ensureAxObserverStrings() orelse return false;

    // If the critical create notification fails, the app AX interface is not ready.
    const add_err = c.AXObserverAddNotification(observer, app, strings.window_created_notification, app_refcon);
    if (add_err != c.kAXErrorSuccess) return false;

    _ = c.AXObserverAddNotification(observer, app, strings.focused_window_changed_notification, app_refcon);
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

fn removeAppObserverAtIndex(index: u32) void {
    if (index >= g_app_observer_count) return;

    const observer = g_app_observers[index].observer;
    if (observer != null and g_observer_runloop != null) {
        c.CFRunLoopRemoveSource(
            g_observer_runloop,
            c.AXObserverGetRunLoopSource(observer),
            c.kCFRunLoopCommonModes,
        );
    }
    if (observer != null) {
        c.CFRelease(@ptrCast(observer));
    }

    g_app_observer_count -= 1;
    g_app_observers[index] = g_app_observers[g_app_observer_count];
    updateWindowScanSource();
}

fn tryObserveApp(pid: i32) bool {
    if (appObserverExists(pid)) return true;
    if (g_app_observer_count >= max_observed_apps) return false;
    if (g_observer_runloop == null) return false;

    var observer: c.AXObserverRef = null;
    const err = c.AXObserverCreate(pid, axNotificationHandler, &observer);
    if (err != c.kAXErrorSuccess or observer == null) return false;
    const observer_ref = observer orelse return false;

    const app = c.AXUIElementCreateApplication(pid) orelse {
        c.CFRelease(@ptrCast(observer_ref));
        return false;
    };
    defer c.CFRelease(@ptrCast(app));

    const app_refcon = packRefcon(pid, 0);
    if (!registerAppLevelAXNotifications(observer_ref, app, app_refcon)) {
        c.CFRelease(@ptrCast(observer_ref));
        return false;
    }

    c.CFRunLoopAddSource(
        g_observer_runloop,
        c.AXObserverGetRunLoopSource(observer_ref),
        c.kCFRunLoopCommonModes,
    );
    c.CFRunLoopWakeUp(g_observer_runloop);

    g_app_observers[g_app_observer_count] = .{
        .pid = pid,
        .observer = observer_ref,
    };
    g_app_observer_count += 1;

    g_window_scan_idle_ticks = 0;
    updateWindowScanSource();
    primeObservedAppWindows(pid, observer_ref, app);

    return true;
}
