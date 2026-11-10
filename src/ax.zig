//! Shared Accessibility (AX) helpers: the interned CFString attribute cache
//! and main-thread window lookups. Every call into AX here is synchronous IPC
//! to the target app. Geometry writes live in ax_writer.zig, off the main
//! thread.

const std = @import("std");
const c = @import("c");
const osutil = @import("osutil.zig");
const trace = @import("trace.zig");

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

/// Accessibility trust check.
pub fn isTrusted() bool {
    return c.AXIsProcessTrusted() != 0;
}

/// Resolve a window id to its AX element by scanning the app's window list.
/// The returned element is retained; the caller must CFRelease it.
pub fn findWindow(pid: i32, target_wid: u32) ?c.AXUIElementRef {
    return findWindowWithTimeout(pid, target_wid, null);
}

/// Resolve a window id while bounding messages sent through temporary AX elements.
pub fn findWindowWithMessagingTimeout(pid: i32, target_wid: u32, timeout_seconds: f32) ?c.AXUIElementRef {
    std.debug.assert(timeout_seconds > 0);
    return findWindowWithTimeout(pid, target_wid, timeout_seconds);
}

fn findWindowWithTimeout(pid: i32, target_wid: u32, timeout_seconds: ?f32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));
    if (timeout_seconds) |seconds| _ = c.AXUIElementSetMessagingTimeout(app, seconds);

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
        if (timeout_seconds) |seconds| _ = c.AXUIElementSetMessagingTimeout(win, seconds);
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

/// Direct-mapped cache of resolved AX window elements, keyed by window id.
/// findWindow costs one AXWindows copy plus an _AXUIElementGetWindow per
/// element in the app's list — for a workspace switch, which moves every
/// window of both workspaces, that dominates the whole operation and is
/// visible as the desktop showing between hide and show. Elements stay valid
/// for a window's lifetime, so resolve each one once.
///
/// Main thread only: every caller runs on the main queue, either during event
/// drain or from the animator's dispatch timer.
///
/// A slot collision costs one re-resolve, never the wrong window: entries are
/// matched on both pid and wid, and destroyed windows are invalidated.
const element_cache_slots = 128;

const CachedElement = struct {
    pid: i32,
    wid: u32,
    element: c.AXUIElementRef,
};

var g_element_cache: [element_cache_slots]?CachedElement = @splat(null);

fn elementCacheSlot(wid: u32) usize {
    return wid % element_cache_slots;
}

/// Cached element for (pid, wid), or null on a miss. Borrowed — the cache owns
/// the reference, callers must not release it.
fn cachedElement(pid: i32, wid: u32) ?c.AXUIElementRef {
    const entry = g_element_cache[elementCacheSlot(wid)] orelse return null;
    if (entry.pid != pid or entry.wid != wid) return null;
    return entry.element;
}

/// Resolve (pid, wid) through findWindow and cache it, evicting whatever
/// shared its slot. Borrowed — the cache owns the reference.
fn resolveElement(pid: i32, wid: u32) ?c.AXUIElementRef {
    const element = findWindow(pid, wid) orelse return null;

    const slot = elementCacheSlot(wid);
    if (g_element_cache[slot]) |evicted| c.CFRelease(@ptrCast(evicted.element));
    g_element_cache[slot] = .{ .pid = pid, .wid = wid, .element = element };
    return element;
}

/// Acquire a retained AX element for a known window, reusing the geometry
/// cache when possible. Workspace switches retile the incoming window before
/// focusing it, so a second AXWindows enumeration here would repeat the most
/// expensive part of resolving the focus target.
///
/// The caller owns the returned reference and must CFRelease it.
pub fn retainWindow(pid: i32, wid: u32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const element = cachedElement(pid, wid) orelse resolveElement(pid, wid) orelse return null;
    _ = c.CFRetain(@ptrCast(element));
    return element;
}

/// Drop a window's cached element. WindowServer recycles window ids, so
/// callers must invalidate when a window is destroyed or its id replaced
/// rather than leave the retry path to discover it.
pub fn invalidateWindow(wid: u32) void {
    const slot = elementCacheSlot(wid);
    const entry = g_element_cache[slot] orelse return;
    if (entry.wid != wid) return;

    c.CFRelease(@ptrCast(entry.element));
    g_element_cache[slot] = null;
}

pub fn deinitElementCache() void {
    for (&g_element_cache) |*slot| {
        const entry = slot.* orelse continue;
        c.CFRelease(@ptrCast(entry.element));
        slot.* = null;
    }
}

/// Number of tabs in a window's native tab bar, or null when the read failed.
///
/// AppKit puts an `AXTabGroup` titled "tab bar" among a window's AX children,
/// with one tab element per tab, and only the *selected* tab's window carries
/// it. This is the one authoritative signal that a window belongs to a native
/// tab group. Nothing else exposes the relationship: WindowServer models none
/// (`SLSWindowIteratorGetParentID` is zero for every window and
/// `SLSCopyAssociatedWindows` returns only the window itself), CG's window
/// dictionary has no tab key, and `AXWindows` omits background tabs entirely,
/// so their ids are not reachable at all.
///
/// Costs an AXChildren copy plus a role read per child, so callers should ask
/// once per detection pass rather than per decision.
pub fn tabCountForElement(win: c.AXUIElementRef, ax: *const AxStrings, timeout_seconds: f32, deadline_ns: i128) ?usize {
    var children: c.CFArrayRef = null;
    if (c.AXUIElementCopyAttributeValue(win, ax.children_attr, @ptrCast(&children)) != c.kAXErrorSuccess) return null;
    const children_ref = children orelse return null;
    defer c.CFRelease(@ptrCast(children_ref));
    if (c.CFGetTypeID(@ptrCast(children_ref)) != c.CFArrayGetTypeID()) return null;

    const count = c.CFArrayGetCount(children_ref);
    var incomplete = false;
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        // A broad or slow AX tree is unknown, not proof that tabs are absent.
        if (i >= 128 or osutil.nanoTimestamp() >= deadline_ns) return null;
        const child_any = c.CFArrayGetValueAtIndex(children_ref, i) orelse {
            incomplete = true;
            continue;
        };
        const child: c.AXUIElementRef = @ptrCast(child_any);
        _ = c.AXUIElementSetMessagingTimeout(child, timeout_seconds);

        var role: c.CFTypeRef = null;
        const role_err = c.AXUIElementCopyAttributeValue(child, ax.role_attr, &role);
        defer if (role) |ref| c.CFRelease(ref);
        if (role_err != c.kAXErrorSuccess or role == null) {
            incomplete = true;
            continue;
        }
        if (c.CFEqual(role, @ptrCast(ax.tab_group_role)) == 0) continue;

        if (osutil.nanoTimestamp() >= deadline_ns) return null;
        var tabs: c.CFArrayRef = null;
        const tabs_err = c.AXUIElementCopyAttributeValue(child, ax.tabs_attr, @ptrCast(&tabs));
        defer if (tabs) |ref| c.CFRelease(@ptrCast(ref));
        if (tabs_err == c.kAXErrorAttributeUnsupported or tabs_err == c.kAXErrorNoValue) continue;
        if (tabs_err != c.kAXErrorSuccess or tabs == null) return null;
        if (c.CFGetTypeID(@ptrCast(tabs)) != c.CFArrayGetTypeID()) return null;
        return if (incomplete) null else @intCast(c.CFArrayGetCount(tabs));
    }

    return if (incomplete) null else 0;
}
