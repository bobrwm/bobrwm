//! Off-main-thread AX geometry writes.
//!
//! Every AX write is synchronous IPC answered on the target app's own main
//! thread: Chromium relays out before replying (~4ms per size write) and a
//! hung app blocks for the full messaging timeout. Issued from bobrwm's main
//! thread, that stalled event handling and every other window behind the
//! slowest app. Each app instead gets a serial dispatch queue, and the main
//! thread only records the newest target per window, so a slow app skips
//! stale intermediate frames and lags only itself.
//!
//! The main thread keeps ownership of layout and geometry state: it records
//! an intent when it enqueues, and a write the app rejects comes back through
//! the failure callback so that intent cannot mask the miss.

const std = @import("std");
const c = @import("c");
const ax = @import("ax.zig");
const osutil = @import("osutil.zig");
const window_mod = @import("window.zig");

const log = std.log.scoped(.ax_writer);

const Frame = window_mod.Window.Frame;

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

/// Which parts of the frame a write applies. Queued writes for a window merge
/// by union, so a later position-only write cannot drop an earlier resize.
pub const Write = packed struct(u8) {
    position: bool = false,
    size: bool = false,
    /// Size-position-size: survives macOS clamping a size at an origin where
    /// it does not fit. Without it a combined write is one size then one
    /// position, enough for animation steps that the next tick overwrites.
    guarded: bool = false,
    /// Issue the guarded write twice: macOS can clamp fullscreen sizes on the
    /// first pass, so they must be re-asserted.
    repeat: bool = false,
    /// Do not report rejection. Animation steps are superseded on the next
    /// tick; only their final placement decides whether the intent holds.
    quiet: bool = false,
    _padding: u3 = 0,

    pub const frame: Write = .{ .position = true, .size = true, .guarded = true };
    pub const position_only: Write = .{ .position = true };
    pub const size_only: Write = .{ .size = true };

    fn merge(older: Write, newer: Write) Write {
        var merged: Write = @bitCast(@as(u8, @bitCast(older)) | @as(u8, @bitCast(newer)));
        merged.quiet = older.quiet and newer.quiet;
        return merged;
    }
};

pub const FailureFn = *const fn (pid: i32, wid: u32) void;

/// Bounds how long a hung app can hold its own queue. AX defaults to six
/// seconds; a write that slow is already useless as feedback.
const messaging_timeout_seconds: f32 = 1.0;
/// Mirrors the main-thread cache in ax.zig: half a second spans a burst of
/// writes while bounding how long an external change goes unnoticed.
const enhanced_ui_false_ttl_ns: i128 = 500 * std.time.ns_per_ms;

const max_apps = 64;
const max_pending = 256;
const element_slots = 32;

const Pending = struct {
    pid: i32,
    wid: u32,
    frame: Frame,
    write: Write,
};

const CachedElement = struct {
    wid: u32,
    element: c.AXUIElementRef,
};

const App = struct {
    // Guarded by g_lock.
    pid: i32 = 0,
    scheduled: bool = false,
    reset: bool = false,
    queue: c.dispatch_queue_t = null,

    // Confined to the app's queue.
    elements: [element_slots]?CachedElement = @splat(null),
    enhanced_ui_false_at_ns: ?i128 = null,

    fn dropElements(self: *App) void {
        for (&self.elements) |*slot| {
            const entry = slot.* orelse continue;
            c.CFRelease(@ptrCast(entry.element));
            slot.* = null;
        }
        self.enhanced_ui_false_at_ns = null;
    }
};

var g_lock: c.os_unfair_lock = .{};
var g_apps: [max_apps]App = @splat(.{});
var g_pending: [max_pending]Pending = undefined;
var g_pending_count: usize = 0;
var g_on_failure: ?FailureFn = null;

/// Must run on the main thread before the first write: the interned AX
/// strings are created lazily without synchronization.
pub fn init(on_failure: FailureFn) void {
    _ = ax.strings();
    g_on_failure = on_failure;
}

/// Queue `frame` for `wid`. Returns false only when the tables are full, in
/// which case nothing was queued and the caller must not record an intent.
pub fn write(pid: i32, wid: u32, frame: Frame, kind: Write) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);
    std.debug.assert(kind.position or kind.size);
    if (kind.size and (frame.width <= 0 or frame.height <= 0)) return false;

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    const app = appForPid(pid) orelse {
        log.warn("writer app table full; dropping write wid={d} pid={d}", .{ wid, pid });
        return false;
    };
    if (pendingIndex(wid)) |index| {
        const pending = &g_pending[index];
        pending.frame = frame;
        pending.write = pending.write.merge(kind);
        pending.pid = pid;
    } else {
        if (g_pending_count == max_pending) {
            log.warn("writer queue full; dropping write wid={d} pid={d}", .{ wid, pid });
            return false;
        }
        g_pending[g_pending_count] = .{ .pid = pid, .wid = wid, .frame = frame, .write = kind };
        g_pending_count += 1;
    }

    if (!app.scheduled) {
        app.scheduled = true;
        c.dispatch_async_f(app.queue, app, drainApp);
    }
    return true;
}

/// Drop writes still queued for a destroyed window. One already executing
/// fails against the dead element without being reported for a new owner.
pub fn forgetWindow(wid: u32) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    if (pendingIndex(wid)) |index| removePending(index);
}

/// Drop queued writes and cached elements for a terminated app. PIDs are
/// recycled, so a later process must never inherit the old elements.
pub fn forgetApp(pid: i32) void {
    std.debug.assert(pid > 0);
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    var index: usize = 0;
    while (index < g_pending_count) {
        if (g_pending[index].pid == pid) removePending(index) else index += 1;
    }
    for (&g_apps) |*app| {
        if (app.pid != pid) continue;
        app.reset = true;
        app.pid = 0;
    }
}

/// Caller holds g_lock. Reuses an idle slot for a new pid; its queue drops
/// the previous app's elements before the first write.
fn appForPid(pid: i32) ?*App {
    var idle: ?*App = null;
    for (&g_apps) |*app| {
        if (app.pid == pid) return app;
        if (idle == null and !app.scheduled and !hasPendingFor(app.pid)) idle = app;
    }
    const app = idle orelse return null;
    if (app.queue == null) {
        const attr = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_USER_INTERACTIVE, 0);
        app.queue = c.dispatch_queue_create("com.bobrwm.ax-writer", attr);
    }
    app.reset = app.reset or app.pid != 0;
    app.pid = pid;
    return app;
}

fn hasPendingFor(pid: i32) bool {
    if (pid == 0) return false;
    for (g_pending[0..g_pending_count]) |pending| {
        if (pending.pid == pid) return true;
    }
    return false;
}

fn pendingIndex(wid: u32) ?usize {
    for (g_pending[0..g_pending_count], 0..) |pending, index| {
        if (pending.wid == wid) return index;
    }
    return null;
}

fn removePending(index: usize) void {
    g_pending_count -= 1;
    if (index != g_pending_count) g_pending[index] = g_pending[g_pending_count];
}

fn takePending(pid: i32) ?Pending {
    for (g_pending[0..g_pending_count], 0..) |pending, index| {
        if (pending.pid != pid) continue;
        removePending(index);
        return pending;
    }
    return null;
}

/// Apply every write queued for one app. Runs on that app's serial queue, so
/// `app`'s queue-confined fields need no lock.
fn drainApp(context: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(context.?));

    c.os_unfair_lock_lock(&g_lock);
    const pid = app.pid;
    const reset = app.reset;
    app.reset = false;
    c.os_unfair_lock_unlock(&g_lock);

    if (reset) app.dropElements();
    if (pid == 0) {
        markIdle(app);
        return;
    }

    const strings = ax.strings().?;
    const ax_app = c.AXUIElementCreateApplication(pid) orelse {
        markIdle(app);
        return;
    };
    defer c.CFRelease(@ptrCast(ax_app));
    _ = c.AXUIElementSetMessagingTimeout(ax_app, messaging_timeout_seconds);

    // Some apps, notably Electron, silently reject geometry writes while
    // AXEnhancedUserInterface is on. Hold it off for the whole burst rather
    // than toggling it around every write.
    var restore_enhanced_ui = false;
    defer if (restore_enhanced_ui) {
        _ = c.AXUIElementSetAttributeValue(ax_app, strings.enhanced_ui_attr, c.kCFBooleanTrue);
    };

    while (true) {
        c.os_unfair_lock_lock(&g_lock);
        const pending = takePending(pid) orelse {
            app.scheduled = false;
            c.os_unfair_lock_unlock(&g_lock);
            return;
        };
        c.os_unfair_lock_unlock(&g_lock);

        if (!restore_enhanced_ui) restore_enhanced_ui = suspendEnhancedUi(app, ax_app, strings);
        if (applyPending(app, pid, strings, pending)) continue;
        if (pending.write.quiet) continue;
        reportFailure(pending);
    }
}

fn markIdle(app: *App) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    app.scheduled = false;
    // A write can arrive between reading pid and here; keep it moving.
    if (app.pid != 0 and hasPendingFor(app.pid)) {
        app.scheduled = true;
        c.dispatch_async_f(app.queue, app, drainApp);
    }
}

/// Report a rejected write unless a newer one for the same window is already
/// queued: that one carries the current intent and may still succeed.
fn reportFailure(pending: Pending) void {
    c.os_unfair_lock_lock(&g_lock);
    const superseded = pendingIndex(pending.wid) != null;
    c.os_unfair_lock_unlock(&g_lock);
    if (superseded) return;

    log.debug("write rejected wid={d} pid={d}", .{ pending.wid, pending.pid });
    if (g_on_failure) |on_failure| on_failure(pending.pid, pending.wid);
}

fn suspendEnhancedUi(app: *App, ax_app: c.AXUIElementRef, strings: *const ax.AxStrings) bool {
    const now_ns = osutil.nanoTimestamp();
    if (app.enhanced_ui_false_at_ns) |checked_at_ns| {
        if (now_ns >= checked_at_ns and now_ns - checked_at_ns < enhanced_ui_false_ttl_ns) return false;
    }

    var value: c.CFTypeRef = null;
    if (c.AXUIElementCopyAttributeValue(ax_app, strings.enhanced_ui_attr, &value) != c.kAXErrorSuccess) return false;
    const value_ref = value orelse return false;
    defer c.CFRelease(value_ref);

    if (c.CFEqual(value_ref, @ptrCast(c.kCFBooleanTrue)) == 0) {
        app.enhanced_ui_false_at_ns = now_ns;
        return false;
    }
    app.enhanced_ui_false_at_ns = null;
    _ = c.AXUIElementSetAttributeValue(ax_app, strings.enhanced_ui_attr, c.kCFBooleanFalse);
    return true;
}

fn applyPending(app: *App, pid: i32, strings: *const ax.AxStrings, pending: Pending) bool {
    const cached = windowElement(app, pid, pending.wid) orelse return false;
    const err = writeGeometry(cached, strings, pending.frame, pending.write);
    if (err == c.kAXErrorSuccess) return true;
    if (err != c.kAXErrorInvalidUIElement and err != c.kAXErrorCannotComplete) return false;

    // The cached element died with its window or the app replaced it.
    forgetElement(app, pending.wid);
    const fresh = windowElement(app, pid, pending.wid) orelse return false;
    return writeGeometry(fresh, strings, pending.frame, pending.write) == c.kAXErrorSuccess;
}

fn writeGeometry(element: c.AXUIElementRef, strings: *const ax.AxStrings, frame: Frame, kind: Write) c.AXError {
    const position: c.CGPoint = .{ .x = frame.x, .y = frame.y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return c.kAXErrorFailure;
    defer c.CFRelease(@ptrCast(position_value));
    const size: c.CGSize = .{ .width = frame.width, .height = frame.height };
    const size_value = c.AXValueCreate(c.kAXValueTypeCGSize, &size) orelse return c.kAXErrorFailure;
    defer c.CFRelease(@ptrCast(size_value));

    const set = c.AXUIElementSetAttributeValue;
    if (kind.position and kind.size) {
        if (!kind.guarded) {
            const size_err = set(element, strings.size_attr, @ptrCast(size_value));
            const position_err = set(element, strings.position_attr, @ptrCast(position_value));
            return if (position_err != c.kAXErrorSuccess) position_err else size_err;
        }
        var result: c.AXError = c.kAXErrorSuccess;
        const passes: usize = if (kind.repeat) 2 else 1;
        for (0..passes) |_| {
            _ = set(element, strings.size_attr, @ptrCast(size_value));
            const position_err = set(element, strings.position_attr, @ptrCast(position_value));
            const size_err = set(element, strings.size_attr, @ptrCast(size_value));
            result = if (position_err != c.kAXErrorSuccess) position_err else size_err;
        }
        return result;
    }
    if (kind.size) return set(element, strings.size_attr, @ptrCast(size_value));
    return set(element, strings.position_attr, @ptrCast(position_value));
}

/// Cached element for `wid`, resolving through the app's window list on a
/// miss. Borrowed: the app's cache owns the reference.
fn windowElement(app: *App, pid: i32, wid: u32) ?c.AXUIElementRef {
    const slot = &app.elements[wid % element_slots];
    if (slot.*) |entry| {
        if (entry.wid == wid) return entry.element;
    }
    const resolved = resolveWindow(pid, wid) orelse return null;
    if (slot.*) |evicted| c.CFRelease(@ptrCast(evicted.element));
    slot.* = .{ .wid = wid, .element = resolved };
    return resolved;
}

fn forgetElement(app: *App, wid: u32) void {
    const slot = &app.elements[wid % element_slots];
    const entry = slot.* orelse return;
    if (entry.wid != wid) return;
    c.CFRelease(@ptrCast(entry.element));
    slot.* = null;
}

/// Retained element for `wid` from the app's AXWindows list. Kept separate
/// from ax.findWindow, whose call accounting belongs to the main thread.
fn resolveWindow(pid: i32, wid: u32) ?c.AXUIElementRef {
    const strings = ax.strings().?;
    const ax_app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(ax_app));
    _ = c.AXUIElementSetMessagingTimeout(ax_app, messaging_timeout_seconds);

    var windows: c.CFArrayRef = null;
    if (c.AXUIElementCopyAttributeValue(ax_app, strings.windows_attr, @ptrCast(&windows)) != c.kAXErrorSuccess) return null;
    const windows_ref = windows orelse return null;
    defer c.CFRelease(@ptrCast(windows_ref));

    const count = c.CFArrayGetCount(windows_ref);
    var index: c.CFIndex = 0;
    while (index < count) : (index += 1) {
        const candidate: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows_ref, index) orelse continue);
        var candidate_wid: u32 = 0;
        if (_AXUIElementGetWindow(candidate, &candidate_wid) != c.kAXErrorSuccess) continue;
        if (candidate_wid != wid) continue;
        _ = c.CFRetain(@ptrCast(candidate));
        _ = c.AXUIElementSetMessagingTimeout(candidate, messaging_timeout_seconds);
        return candidate;
    }
    return null;
}
