//! Shared Accessibility (AX) helpers: the interned CFString attribute cache
//! and main-thread window lookups. Every call into AX here is synchronous IPC
//! to the target app. Geometry writes live in ax_writer.zig, off the main
//! thread.

const std = @import("std");
const c = @import("c");
const trace = @import("trace.zig");
const osutil = @import("osutil.zig");

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

pub const AxStrings = struct {
    focused_window_attr: c.CFStringRef,
    windows_attr: c.CFStringRef,
    size_attr: c.CFStringRef,
    position_attr: c.CFStringRef,
    raise_action: c.CFStringRef,
    main_attr: c.CFStringRef,
    role_attr: c.CFStringRef,
    window_role: c.CFStringRef,
    unknown_role: c.CFStringRef,
    subrole_attr: c.CFStringRef,
    standard_window_subrole: c.CFStringRef,
    floating_window_subrole: c.CFStringRef,
    dialog_subrole: c.CFStringRef,
    unknown_subrole: c.CFStringRef,
    modal_attr: c.CFStringRef,
    enhanced_ui_attr: c.CFStringRef,
    close_button_attr: c.CFStringRef,
    minimize_button_attr: c.CFStringRef,
    zoom_button_attr: c.CFStringRef,
    fullscreen_button_attr: c.CFStringRef,
    focused_attr: c.CFStringRef,
    children_attr: c.CFStringRef,
    tabs_attr: c.CFStringRef,
    tab_group_role: c.CFStringRef,
    system_dialog_subrole: c.CFStringRef,
};

var g_strings: ?AxStrings = null;

fn createAxString(raw: [*:0]const u8) ?c.CFStringRef {
    return c.CFStringCreateWithCString(null, raw, c.kCFStringEncodingUTF8);
}

fn releaseAxString(value: c.CFStringRef) void {
    c.CFRelease(@ptrCast(value));
}

/// Lazily create (and cache) the interned AX attribute strings.
pub fn strings() ?*const AxStrings {
    if (g_strings) |*s| return s;

    const names = [_][*:0]const u8{
        "AXFocusedWindow",
        "AXWindows",
        "AXSize",
        "AXPosition",
        "AXRaise",
        "AXMain",
        "AXRole",
        "AXWindow",
        "AXUnknown",
        "AXSubrole",
        "AXStandardWindow",
        "AXFloatingWindow",
        "AXDialog",
        "AXUnknown",
        "AXModal",
        "AXEnhancedUserInterface",
        "AXCloseButton",
        "AXMinimizeButton",
        "AXZoomButton",
        "AXFullScreenButton",
        "AXFocused",
        "AXChildren",
        "AXTabs",
        "AXTabGroup",
        "AXSystemDialog",
    };
    var refs: [names.len]c.CFStringRef = undefined;

    for (names, 0..) |name, i| {
        refs[i] = createAxString(name) orelse {
            var created_count: usize = i;
            while (created_count > 0) : (created_count -= 1) {
                releaseAxString(refs[created_count - 1]);
            }
            return null;
        };
    }

    g_strings = .{
        .focused_window_attr = refs[0],
        .windows_attr = refs[1],
        .size_attr = refs[2],
        .position_attr = refs[3],
        .raise_action = refs[4],
        .main_attr = refs[5],
        .role_attr = refs[6],
        .window_role = refs[7],
        .unknown_role = refs[8],
        .subrole_attr = refs[9],
        .standard_window_subrole = refs[10],
        .floating_window_subrole = refs[11],
        .dialog_subrole = refs[12],
        .unknown_subrole = refs[13],
        .modal_attr = refs[14],
        .enhanced_ui_attr = refs[15],
        .close_button_attr = refs[16],
        .minimize_button_attr = refs[17],
        .zoom_button_attr = refs[18],
        .fullscreen_button_attr = refs[19],
        .focused_attr = refs[20],
        .children_attr = refs[21],
        .tabs_attr = refs[22],
        .tab_group_role = refs[23],
        .system_dialog_subrole = refs[24],
    };
    return &g_strings.?;
}

/// Returns a retained attribute value; the caller must release it.
pub fn copyAttribute(element: c.AXUIElementRef, attr: c.CFStringRef) c.CFTypeRef {
    var value: c.CFTypeRef = null;
    trace.countAx();
    const err = c.AXUIElementCopyAttributeValue(element, attr, &value);
    return if (err == c.kAXErrorSuccess) value else null;
}

/// True when the AX attribute exists and is non-null on the element.
pub fn hasAttribute(element: c.AXUIElementRef, attr: c.CFStringRef) bool {
    const value = copyAttribute(element, attr) orelse return false;
    c.CFRelease(value);
    return true;
}

/// True when the AX attribute is a CFBoolean set to true.
pub fn isAttributeTrue(element: c.AXUIElementRef, attr: c.CFStringRef) bool {
    const value = copyAttribute(element, attr) orelse return false;
    defer c.CFRelease(value);
    return c.CFEqual(value, @ptrCast(c.kCFBooleanTrue)) != 0;
}

/// Returns true when a window exposes a real top-level-window signal: any
/// title-bar button (close/minimize/zoom/fullscreen) or being the app's main or
/// focused window. Transient popups (autocomplete lists, tooltips, context
/// menus) report a dialog or floating subrole but have none of these, so this
/// guard keeps them from being tiled.
pub fn hasRealWindowSignal(win: c.AXUIElementRef, ax: *const AxStrings) bool {
    std.debug.assert(win != null);

    for ([_]c.CFStringRef{ ax.close_button_attr, ax.minimize_button_attr, ax.zoom_button_attr, ax.fullscreen_button_attr }) |attr| {
        if (hasAttribute(win, attr)) return true;
    }
    return isAttributeTrue(win, ax.main_attr) or isAttributeTrue(win, ax.focused_attr);
}

/// True when the AX attribute can be set on the element.
pub fn isAttributeSettable(element: c.AXUIElementRef, attr: c.CFStringRef) bool {
    var is_settable: c.Boolean = 0;
    trace.countAx();
    const err = c.AXUIElementIsAttributeSettable(element, attr, &is_settable);
    return err == c.kAXErrorSuccess and is_settable != 0;
}

/// Accessibility trust check.
pub fn isTrusted() bool {
    return c.AXIsProcessTrusted() != 0;
}

/// Resolve a window id while bounding messages sent through temporary AX elements.
pub fn findWindowWithMessagingTimeout(pid: i32, target_wid: u32, timeout_seconds: f32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);
    std.debug.assert(timeout_seconds > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));
    _ = c.AXUIElementSetMessagingTimeout(app, timeout_seconds);

    const ax = strings() orelse return null;
    const windows_attr = ax.windows_attr;
    var windows: c.CFArrayRef = null;
    trace.countAx();
    const err = c.AXUIElementCopyAttributeValue(app, windows_attr, @ptrCast(&windows));
    if (err != c.kAXErrorSuccess or windows == null) return null;
    const windows_ref = windows orelse return null;
    defer c.CFRelease(@ptrCast(windows_ref));

    const count = c.CFArrayGetCount(windows_ref);
    std.debug.assert(count >= 0);

    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win_any = c.CFArrayGetValueAtIndex(windows_ref, i) orelse continue;
        const win: c.AXUIElementRef = @ptrCast(win_any);

        // Elements copied out of the list do not inherit the app's timeout.
        _ = c.AXUIElementSetMessagingTimeout(win, timeout_seconds);
        var wid: u32 = 0;
        trace.countAx();
        if (_AXUIElementGetWindow(win, &wid) != c.kAXErrorSuccess) continue;
        if (wid != target_wid) continue;

        _ = c.CFRetain(@ptrCast(win));
        return win;
    }

    return null;
}

/// Resolve several window ids from one copy of the app's window list, then
/// the app's focused window for an id the list lacks: remote-hosted panels
/// (open/save dialogs) can be focused without being listed. `out[i]` gets a
/// retained element for `target_wids[i]`, or null; the caller releases each.
pub fn findWindows(pid: i32, target_wids: []const u32, out: []?c.AXUIElementRef, timeout_seconds: f32) void {
    std.debug.assert(pid > 0);
    std.debug.assert(out.len >= target_wids.len);
    @memset(out[0..target_wids.len], null);

    const app = c.AXUIElementCreateApplication(pid) orelse return;
    defer c.CFRelease(@ptrCast(app));
    _ = c.AXUIElementSetMessagingTimeout(app, timeout_seconds);
    const ax = strings() orelse return;

    var missing_count = target_wids.len;
    var windows: c.CFArrayRef = null;
    trace.countAx();
    if (c.AXUIElementCopyAttributeValue(app, ax.windows_attr, @ptrCast(&windows)) == c.kAXErrorSuccess) {
        if (windows) |windows_ref| {
            defer c.CFRelease(@ptrCast(windows_ref));
            const count = c.CFArrayGetCount(windows_ref);
            var index: c.CFIndex = 0;
            while (index < count and missing_count > 0) : (index += 1) {
                const win: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows_ref, index) orelse continue);
                // Elements copied out of the list do not inherit the app's timeout.
                _ = c.AXUIElementSetMessagingTimeout(win, timeout_seconds);

                var wid: u32 = 0;
                trace.countAx();
                if (_AXUIElementGetWindow(win, &wid) != c.kAXErrorSuccess) continue;
                const slot = unresolvedIndex(target_wids, out, wid) orelse continue;
                _ = c.CFRetain(@ptrCast(win));
                out[slot] = win;
                missing_count -= 1;
            }
        }
    }
    if (missing_count == 0) return;

    var focused: c.AXUIElementRef = null;
    trace.countAx();
    if (c.AXUIElementCopyAttributeValue(app, ax.focused_window_attr, @ptrCast(&focused)) != c.kAXErrorSuccess) return;
    const focused_ref = focused orelse return;
    _ = c.AXUIElementSetMessagingTimeout(focused_ref, timeout_seconds);

    var wid: u32 = 0;
    trace.countAx();
    if (_AXUIElementGetWindow(focused_ref, &wid) == c.kAXErrorSuccess) {
        if (unresolvedIndex(target_wids, out, wid)) |slot| {
            out[slot] = focused_ref;
            return;
        }
    }
    c.CFRelease(@ptrCast(focused_ref));
}

fn unresolvedIndex(target_wids: []const u32, out: []const ?c.AXUIElementRef, wid: u32) ?usize {
    for (target_wids, 0..) |target_wid, index| {
        if (target_wid == wid and out[index] == null) return index;
    }
    return null;
}

/// One window from an app's AX window list.
pub const AppWindow = struct {
    wid: u32,
    /// Tabs in the window's own tab bar, 0 when it has none.
    tab_count: u32,
};

/// Membership is enough for healthy cleanup; tab reads are only for inference.
pub const AppWindowDetails = enum { membership, tabs };

pub const AppWindowsResult = struct {
    count: usize,
    /// The app listed more windows than fit in `out`.
    is_truncated: bool,
    /// Missing facts must never be interpreted as absent windows or tab bars.
    is_incomplete: bool,
};

/// Read the app's AX window list and tab counts within a whole-scan budget.
/// A timeout stops the scan so geometry and focus can use the app's queue.
pub fn appWindows(pid: i32, out: []AppWindow, details: AppWindowDetails, timeout_seconds: f32, budget_seconds: f32) AppWindowsResult {
    std.debug.assert(pid > 0);
    std.debug.assert(timeout_seconds > 0 and budget_seconds > 0);

    const budget: ScanBudget = .{
        .deadline_ns = osutil.nanoTimestamp() + @as(i128, @intFromFloat(budget_seconds * std.time.ns_per_s)),
        .timeout_seconds = timeout_seconds,
    };
    var result: AppWindowsResult = .{ .count = 0, .is_truncated = false, .is_incomplete = true };
    const ax = strings() orelse return result;
    const app = c.AXUIElementCreateApplication(pid) orelse return result;
    defer c.CFRelease(@ptrCast(app));

    const windows: c.CFArrayRef = @ptrCast((budget.copyAttribute(app, ax.windows_attr) catch return result) orelse return result);
    defer c.CFRelease(@ptrCast(windows));

    const count = c.CFArrayGetCount(windows);
    var index: c.CFIndex = 0;
    while (index < count) : (index += 1) {
        if (result.count == out.len) {
            result.is_truncated = true;
            break;
        }
        const win: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows, index) orelse continue);
        budget.prepare(win) catch return result;

        var wid: u32 = 0;
        trace.countAx();
        // A failed ID read leaves membership unknown, even if later windows answer.
        if (_AXUIElementGetWindow(win, &wid) != c.kAXErrorSuccess or wid == 0) return result;
        const tabs = if (details == .tabs) tabCount(win, ax, &budget) catch return result else 0;
        out[result.count] = .{ .wid = wid, .tab_count = tabs };
        result.count += 1;
    }

    result.is_incomplete = false;
    return result;
}

const ScanBudget = struct {
    deadline_ns: i128,
    timeout_seconds: f32,

    fn prepare(self: *const ScanBudget, element: c.AXUIElementRef) error{Incomplete}!void {
        const remaining_ns = self.deadline_ns - osutil.nanoTimestamp();
        if (remaining_ns <= 0) return error.Incomplete;
        // AX treats zero as the default timeout, not a nonblocking query.
        const remaining_seconds = @as(f32, @floatFromInt(remaining_ns)) / std.time.ns_per_s;
        if (c.AXUIElementSetMessagingTimeout(element, @min(self.timeout_seconds, remaining_seconds)) != c.kAXErrorSuccess)
            return error.Incomplete;
    }

    fn copyAttribute(self: *const ScanBudget, element: c.AXUIElementRef, attr: c.CFStringRef) error{Incomplete}!c.CFTypeRef {
        try self.prepare(element);
        var value: c.CFTypeRef = null;
        trace.countAx();
        const err = c.AXUIElementCopyAttributeValue(element, attr, &value);
        if (err == c.kAXErrorSuccess) return value;
        if (err == c.kAXErrorAttributeUnsupported or err == c.kAXErrorNoValue) return null;
        return error.Incomplete;
    }
};

/// Number of tabs in a window's native tab bar, or 0 when it has none.
///
/// AppKit puts an `AXTabGroup` titled "tab bar" among a window's AX children,
/// with one tab element per tab, and only the *selected* tab's window carries
/// it. This is the one authoritative signal that a window belongs to a native
/// tab group. Nothing else exposes the relationship: WindowServer models none
/// (`SLSWindowIteratorGetParentID` is zero for every window and
/// `SLSCopyAssociatedWindows` returns only the window itself), CG's window
/// dictionary has no tab key, and `AXWindows` omits background tabs entirely,
/// so their ids are not reachable at all.
fn tabCount(win: c.AXUIElementRef, ax: *const AxStrings, budget: *const ScanBudget) error{Incomplete}!u32 {
    const children: c.CFArrayRef = @ptrCast((try budget.copyAttribute(win, ax.children_attr)) orelse return 0);
    defer c.CFRelease(@ptrCast(children));

    const count = c.CFArrayGetCount(children);
    var index: c.CFIndex = 0;
    while (index < count) : (index += 1) {
        const child: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(children, index) orelse continue);
        const role = (try budget.copyAttribute(child, ax.role_attr)) orelse continue;
        defer c.CFRelease(role);
        if (c.CFEqual(role, @ptrCast(ax.tab_group_role)) == 0) continue;

        const tabs: c.CFArrayRef = @ptrCast((try budget.copyAttribute(child, ax.tabs_attr)) orelse return 0);
        defer c.CFRelease(@ptrCast(tabs));
        return @intCast(c.CFArrayGetCount(tabs));
    }

    return 0;
}

test "app window snapshots stop on failure or deadline and distinguish complete results" {
    // Real CF objects exercise retain/release without requiring a live AX server.
    // The exported AX fixture exists only in this test, never in the app binary.
    const Fixture = struct {
        var windows: c.CFArrayRef = null;
        var children: c.CFArrayRef = null;
        var role: c.CFStringRef = null;
        var role_reads: usize = 0;
        var fail_roles = false;
        var fail_ids = false;
        var role_delay_us: c_uint = 0;
        var last_timeout: f32 = 0;
        var observed_reasons: u8 = 0;

        export fn bw_emit_event_detail(_: u8, _: i32, _: u32, detail: u8) void {
            observed_reasons = detail;
        }

        fn barrier(_: ?*anyopaque) callconv(.c) void {}

        export fn AXUIElementCreateApplication(_: i32) c.AXUIElementRef {
            return @ptrCast(c.CFRetain(@ptrCast(windows)));
        }

        export fn AXUIElementSetMessagingTimeout(_: c.AXUIElementRef, seconds: f32) c.AXError {
            last_timeout = seconds;
            return c.kAXErrorSuccess;
        }

        export fn _AXUIElementGetWindow(_: c.AXUIElementRef, wid: *u32) c.AXError {
            if (fail_ids) return c.kAXErrorCannotComplete;
            wid.* = 17;
            return c.kAXErrorSuccess;
        }

        export fn AXUIElementCopyAttributeValue(_: c.AXUIElementRef, attr: c.CFStringRef, out: *c.CFTypeRef) c.AXError {
            const attributes = strings().?;
            const value: c.CFTypeRef = if (c.CFEqual(@ptrCast(attr), @ptrCast(attributes.windows_attr)) != 0)
                @ptrCast(windows)
            else if (c.CFEqual(@ptrCast(attr), @ptrCast(attributes.children_attr)) != 0 or
                c.CFEqual(@ptrCast(attr), @ptrCast(attributes.tabs_attr)) != 0)
                @ptrCast(children)
            else if (c.CFEqual(@ptrCast(attr), @ptrCast(attributes.role_attr)) != 0) blk: {
                role_reads += 1;
                if (fail_roles) return c.kAXErrorCannotComplete;
                if (role_delay_us > 0) _ = c.usleep(role_delay_us);
                break :blk @ptrCast(role);
            } else return c.kAXErrorAttributeUnsupported;
            out.* = c.CFRetain(value);
            return c.kAXErrorSuccess;
        }
    };
    const testing = std.testing;
    Fixture.role = c.CFStringCreateWithCString(null, "AXButton", c.kCFStringEncodingUTF8).?;
    defer c.CFRelease(@ptrCast(Fixture.role));
    var values: [40]?*const anyopaque = @splat(@ptrCast(Fixture.role));
    Fixture.windows = c.CFArrayCreate(null, @ptrCast(&values), 2, &c.kCFTypeArrayCallBacks).?;
    defer c.CFRelease(@ptrCast(Fixture.windows));
    Fixture.children = c.CFArrayCreate(null, @ptrCast(&values), values.len, &c.kCFTypeArrayCallBacks).?;
    defer c.CFRelease(@ptrCast(Fixture.children));
    var out: [4]AppWindow = undefined;

    // Healthy membership stays available even when the tab hierarchy hangs.
    Fixture.fail_roles = true;
    var result = appWindows(42, &out, .membership, 0.25, 1.0);
    try testing.expect(!result.is_incomplete);
    try testing.expectEqual(@as(usize, 2), result.count);
    try testing.expectEqual(@as(u32, 17), out[1].wid);

    result = appWindows(42, &out, .tabs, 0.25, 1.0);
    try testing.expect(result.is_incomplete);
    try testing.expectEqual(@as(usize, 0), result.count);
    // A timeout is not permission to spend another timeout on every sibling.
    try testing.expectEqual(@as(usize, 1), Fixture.role_reads);

    Fixture.fail_roles = false;
    Fixture.fail_ids = true;
    result = appWindows(42, &out, .tabs, 0.25, 1.0);
    try testing.expect(result.is_incomplete);
    try testing.expectEqual(@as(usize, 0), result.count);

    Fixture.fail_ids = false;
    Fixture.role_reads = 0;
    Fixture.role_delay_us = 1000;
    result = appWindows(42, &out, .tabs, 0.25, 0.01);
    try testing.expect(result.is_incomplete);
    try testing.expect(Fixture.role_reads < values.len);
    try testing.expect(Fixture.last_timeout > 0 and Fixture.last_timeout <= 0.01);

    Fixture.role_delay_us = 0;
    Fixture.role_reads = 0;
    result = appWindows(42, &out, .tabs, 0.25, 1.0);
    try testing.expect(!result.is_incomplete and !result.is_truncated);
    try testing.expectEqual(@as(usize, 2), result.count);
    try testing.expectEqual(@as(u32, 17), out[0].wid);
    try testing.expectEqual(@as(u32, 0), out[0].tab_count);

    result = appWindows(42, out[0..1], .tabs, 0.25, 1.0);
    try testing.expect(result.is_truncated);
    try testing.expect(!result.is_incomplete);

    // Full observations must still detect real tab bars, not merely skip them.
    const old_role = Fixture.role;
    defer Fixture.role = old_role;
    Fixture.role = c.CFStringCreateWithCString(null, "AXTabGroup", c.kCFStringEncodingUTF8).?;
    defer c.CFRelease(@ptrCast(Fixture.role));
    result = appWindows(42, &out, .tabs, 0.25, 1.0);
    try testing.expect(!result.is_incomplete);
    try testing.expectEqual(@as(u32, 40), out[0].tab_count);

    // Exercise real per-app scheduling and the cleanup's enrichment round trip.
    const app_windows = @import("app_windows.zig");
    const app_queue = @import("app_queue.zig");
    app_windows.init();
    const pid = 424242;
    const queue = app_queue.retainQueue(pid).?;
    defer app_queue.releaseQueue(queue);
    defer app_queue.forget(pid);
    defer app_windows.forgetApp(pid);
    try testing.expect(app_windows.request(pid, .offscreen_cleanup));
    c.dispatch_sync_f(queue, null, Fixture.barrier);
    var snapshot: app_windows.Snapshot = undefined;
    try testing.expect(app_windows.latest(pid, &snapshot));
    try testing.expectEqual(AppWindowDetails.membership, snapshot.details);
    try testing.expectEqual(@as(usize, 2), snapshot.count);
    try testing.expectEqual(@as(?bool, null), snapshot.hasTabGroup());
    try testing.expect(app_windows.decodeReasons(Fixture.observed_reasons).contains(.offscreen_cleanup));

    try testing.expect(app_windows.request(pid, .offscreen_tabs));
    c.dispatch_sync_f(queue, null, Fixture.barrier);
    try testing.expect(app_windows.latest(pid, &snapshot));
    try testing.expectEqual(AppWindowDetails.tabs, snapshot.details);
    try testing.expectEqual(@as(?bool, true), snapshot.hasTabGroup());
    try testing.expect(app_windows.decodeReasons(Fixture.observed_reasons).contains(.offscreen_tabs));
}

test {
    _ = @import("app_windows.zig");
}
