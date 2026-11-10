//! Off-main-thread AX focused-window queries.
//!
//! Asking an app for its focused window is synchronous IPC answered on that
//! app's own main thread. An app that is busy or still launching can hold
//! each query for seconds, and focus retries repeat it on every role-poll
//! tick, so on the main thread one slow app froze the window manager. Each
//! app instead gets a serial dispatch queue: the main thread and the AX
//! observer thread only request a query, and the answer comes back through
//! the event ring as an observation, so a slow app delays only its own focus
//! events.

const std = @import("std");
const c = @import("c");
const ax = @import("ax.zig");
const shim = @import("shim_api.zig");

const log = std.log.scoped(.focus_query);

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

/// Why the query was requested, which decides the event its answer is
/// published as.
pub const Reason = enum {
    /// The app was activated: `window_focused`.
    activated,
    /// The app reported a new focused window: `focused_window_changed`.
    focus_changed,
    /// A focus retry is waiting on this app: `focus_retry_observed`, or
    /// `focus_retry_unanswered` if the app did not answer in time.
    retry,
};

/// Matches the readiness queries. A responsive app answers well within it,
/// even while busy; a hung one only delays its own queue, and an empty
/// answer falls through to focus retries.
const messaging_timeout_seconds: f32 = 0.25;

const max_apps = 64;

const App = struct {
    // Guarded by g_lock. A slot keeps its pid while scheduled, so pending
    // requests always belong to the app its queue is querying.
    pid: i32 = 0,
    pending: std.EnumSet(Reason) = .empty,
    scheduled: bool = false,
    queue: c.dispatch_queue_t = null,
};

var g_lock: c.os_unfair_lock = .{};
var g_apps: [max_apps]App = @splat(.{});

/// Must run on the main thread before the first request: the interned AX
/// strings are created lazily without synchronization.
pub fn init() void {
    _ = ax.strings();
}

/// Query `pid`'s focused window off the main thread and publish the answer
/// for `reason`. A request already queued for the same reason absorbs this
/// one: the query reads current state, so both would get the same answer.
/// Safe from any thread.
pub fn request(pid: i32, reason: Reason) void {
    std.debug.assert(pid > 0);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    const app = appForPid(pid) orelse {
        log.warn("app table full; dropping {s} query pid={d}", .{ @tagName(reason), pid });
        return;
    };
    app.pending.insert(reason);
    if (app.scheduled) return;

    app.scheduled = true;
    c.dispatch_async_f(app.queue, app, drainApp);
}

/// Drop queries not yet started for a terminated app, so a dead process
/// cannot re-arm focus retries the reducer already released. One already
/// running still publishes; its handlers tolerate a dead pid.
pub fn forgetApp(pid: i32) void {
    std.debug.assert(pid > 0);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_apps) |*app| {
        if (app.pid == pid) app.pending = .empty;
    }
}

/// Caller holds g_lock. An idle slot has no pending requests, so it can take
/// a new pid without misdirecting a query.
fn appForPid(pid: i32) ?*App {
    var idle: ?*App = null;
    for (&g_apps) |*app| {
        if (app.pid == pid) return app;
        if (idle == null and !app.scheduled) idle = app;
    }

    const app = idle orelse return null;
    if (app.queue == null) {
        const attr = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_USER_INTERACTIVE, 0);
        app.queue = c.dispatch_queue_create("com.bobrwm.focus-query", attr);
    }
    app.pid = pid;
    return app;
}

/// Answer every request queued for one app. Runs on that app's serial queue.
fn drainApp(context: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(context.?));

    while (true) {
        c.os_unfair_lock_lock(&g_lock);
        const pid = app.pid;
        const pending = app.pending;
        app.pending = .empty;
        if (pending.count() == 0) {
            app.scheduled = false;
            c.os_unfair_lock_unlock(&g_lock);
            return;
        }
        c.os_unfair_lock_unlock(&g_lock);

        const answer = focusedWindowId(pid);
        var reasons = pending.iterator();
        while (reasons.next()) |reason| {
            const kind = eventKind(reason, answer != null);
            shim.bw_emit_event(kind, pid, answer orelse 0);
        }
    }
}

fn eventKind(reason: Reason, has_answered: bool) u8 {
    return switch (reason) {
        .activated => shim.BW_EVENT_WINDOW_FOCUSED,
        .focus_changed => shim.BW_EVENT_FOCUSED_WINDOW_CHANGED,
        .retry => if (has_answered) shim.BW_EVENT_FOCUS_RETRY_OBSERVED else shim.BW_EVENT_FOCUS_RETRY_UNANSWERED,
    };
}

/// The app's AX-focused window ID, 0 if it answered without one, or null if
/// it did not answer in time. Not traced: trace counters are main-thread only.
fn focusedWindowId(pid: i32) ?u32 {
    const strings = ax.strings() orelse return 0;
    const app = c.AXUIElementCreateApplication(pid) orelse return 0;
    defer c.CFRelease(@ptrCast(app));
    _ = c.AXUIElementSetMessagingTimeout(app, messaging_timeout_seconds);

    var focused: c.AXUIElementRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, strings.focused_window_attr, @ptrCast(&focused));
    if (err == c.kAXErrorCannotComplete) return null;
    if (err != c.kAXErrorSuccess) return 0;
    const focused_ref = focused orelse return 0;
    defer c.CFRelease(@ptrCast(focused_ref));
    // Elements copied out of the app do not inherit its timeout.
    _ = c.AXUIElementSetMessagingTimeout(focused_ref, messaging_timeout_seconds);

    var wid: u32 = 0;
    const window_err = _AXUIElementGetWindow(focused_ref, &wid);
    if (window_err == c.kAXErrorCannotComplete) return null;
    if (window_err != c.kAXErrorSuccess) return 0;
    return wid;
}
