//! AX focused-window queries, answered on the app's queue.
//!
//! The main thread and the AX observer thread request a query, and the answer
//! comes back through the event ring as an observation, so an app that is
//! slow to answer delays only its own focus events.

const std = @import("std");
const c = @import("c");
const app_queue = @import("app_queue.zig");
const ax = @import("ax.zig");
const shim = @import("shim_api.zig");

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

/// Must run on the main thread before the first request: the interned AX
/// strings are created lazily without synchronization.
pub fn init() void {
    _ = ax.strings();
    app_queue.setHandler(.query_activated, answerActivated);
    app_queue.setHandler(.query_focus_changed, answerFocusChanged);
    app_queue.setHandler(.query_retry, answerRetry);
}

/// Query `pid`'s focused window off the main thread and publish the answer
/// for `reason`. Safe from any thread.
pub fn request(pid: i32, reason: Reason) void {
    std.debug.assert(pid > 0);
    const job: app_queue.Job = switch (reason) {
        .activated => .query_activated,
        .focus_changed => .query_focus_changed,
        .retry => .query_retry,
    };
    _ = app_queue.submit(pid, job);
}

fn answerActivated(app: app_queue.App) void {
    publish(app.pid, .activated);
}

fn answerFocusChanged(app: app_queue.App) void {
    publish(app.pid, .focus_changed);
}

fn answerRetry(app: app_queue.App) void {
    publish(app.pid, .retry);
}

fn publish(pid: i32, reason: Reason) void {
    const answer = focusedWindowId(pid);
    shim.bw_emit_event(eventKind(reason, answer != null), pid, answer orelse 0);
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
