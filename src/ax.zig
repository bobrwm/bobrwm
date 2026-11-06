//! Shared Accessibility (AX) helpers: the interned CFString attribute cache
//! and main-thread window lookups. Element-only queries use no shared state.
//! Every call into AX here is synchronous IPC
//! to the target app. Geometry writes live in ax_writer.zig, off the main
//! thread.

const std = @import("std");
const c = @import("c");
const trace = @import("trace.zig");
const shim = @import("shim_api.zig");
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
    g_strings = createStrings() orelse return null;
    return &g_strings.?;
}

/// Create independently owned strings; safe for jobs that outlive the main cache.
pub fn createStrings() ?AxStrings {
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

    return .{
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
    };
}

pub fn deinitStrings() void {
    if (g_strings) |s| {
        freeStrings(s);
        g_strings = null;
    }
}

/// Release one independently owned string set, exactly once.
pub fn freeStrings(s: AxStrings) void {
    const refs = [_]c.CFStringRef{
        s.tab_group_role,
        s.tabs_attr,
        s.children_attr,
        s.focused_attr,
        s.fullscreen_button_attr,
        s.zoom_button_attr,
        s.minimize_button_attr,
        s.close_button_attr,
        s.enhanced_ui_attr,
        s.modal_attr,
        s.unknown_subrole,
        s.dialog_subrole,
        s.floating_window_subrole,
        s.standard_window_subrole,
        s.subrole_attr,
        s.unknown_role,
        s.window_role,
        s.role_attr,
        s.main_attr,
        s.raise_action,
        s.position_attr,
        s.size_attr,
        s.windows_attr,
        s.focused_window_attr,
    };
    for (refs) |value| {
        releaseAxString(value);
    }
}

/// Accessibility trust check.
pub fn isTrusted() bool {
    return c.AXIsProcessTrusted() != 0;
}

/// Resolve a window id to its AX element by scanning the app's window list.
/// The returned element is retained; the caller must CFRelease it.
pub fn findWindow(pid: i32, target_wid: u32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));

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

        var wid: u32 = 0;
        trace.countAx();
        if (_AXUIElementGetWindow(win, &wid) != c.kAXErrorSuccess) continue;
        if (wid != target_wid) continue;

        _ = c.CFRetain(@ptrCast(win));
        return win;
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

/// Resolve a window id via the app's AXFocusedWindow attribute. Open/save
/// panels are remote-hosted by openAndSavePanelService and can be the app's
/// focused window without ever appearing in its AXWindows array, so the list
/// scan in findWindow misses them. Returns the element only when its window id
/// matches `target_wid`. The returned element is retained; the caller must
/// CFRelease it.
pub fn focusedWindowIfMatches(pid: i32, target_wid: u32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));

    const ax = strings() orelse return null;
    var focused: c.AXUIElementRef = null;
    trace.countAx();
    const err = c.AXUIElementCopyAttributeValue(app, ax.focused_window_attr, @ptrCast(&focused));
    if (err != c.kAXErrorSuccess or focused == null) return null;
    const focused_ref = focused orelse return null;

    var wid: u32 = 0;
    trace.countAx();
    if (_AXUIElementGetWindow(focused_ref, &wid) != c.kAXErrorSuccess or wid != target_wid) {
        c.CFRelease(@ptrCast(focused_ref));
        return null;
    }
    return focused_ref;
}

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
///
/// Costs an AXChildren copy plus a role read per child, so callers should ask
/// once per detection pass rather than per decision.
pub fn tabCount(pid: i32, wid: u32) usize {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const ax = strings() orelse return 0;
    const win = retainWindow(pid, wid) orelse return 0;
    defer c.CFRelease(@ptrCast(win));

    var children: c.CFArrayRef = null;
    trace.countAx();
    if (c.AXUIElementCopyAttributeValue(win, ax.children_attr, @ptrCast(&children)) != c.kAXErrorSuccess) return 0;
    const children_ref = children orelse return 0;
    defer c.CFRelease(@ptrCast(children_ref));

    const count = c.CFArrayGetCount(children_ref);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const child_any = c.CFArrayGetValueAtIndex(children_ref, i) orelse continue;
        const child: c.AXUIElementRef = @ptrCast(child_any);

        var role: c.CFTypeRef = null;
        trace.countAx();
        if (c.AXUIElementCopyAttributeValue(child, ax.role_attr, &role) != c.kAXErrorSuccess) continue;
        const role_ref = role orelse continue;
        defer c.CFRelease(role_ref);
        if (c.CFEqual(role_ref, @ptrCast(ax.tab_group_role)) == 0) continue;

        var tabs: c.CFArrayRef = null;
        trace.countAx();
        if (c.AXUIElementCopyAttributeValue(child, ax.tabs_attr, @ptrCast(&tabs)) != c.kAXErrorSuccess) return 0;
        const tabs_ref = tabs orelse return 0;
        defer c.CFRelease(@ptrCast(tabs_ref));

        const tab_total = c.CFArrayGetCount(tabs_ref);
        return if (tab_total > 0) @intCast(tab_total) else 0;
    }

    return 0;
}

/// Classify an already resolved element without caches or main-thread tracing.
/// Activation policy belongs to the caller: this preserves only the AX policy.
pub fn manageStateForElement(win: c.AXUIElementRef, ax: *const AxStrings) u8 {
    // Modal panels can otherwise satisfy the top-level dialog heuristic.
    const is_modal = axBooleanAttributeTrue(win, ax.modal_attr) orelse return shim.BW_MANAGE_PENDING;
    if (is_modal) return shim.BW_MANAGE_REJECT;

    var role_any: c.CFTypeRef = null;
    const role_err = c.AXUIElementCopyAttributeValue(win, ax.role_attr, &role_any);
    defer if (role_any) |value| c.CFRelease(value);
    if (role_err != c.kAXErrorSuccess or role_any == null) return shim.BW_MANAGE_PENDING;
    const is_window = c.CFEqual(role_any, @ptrCast(ax.window_role)) != 0;
    const is_unknown_role = c.CFEqual(role_any, @ptrCast(ax.unknown_role)) != 0;
    if (!is_window) return if (is_unknown_role) shim.BW_MANAGE_PENDING else shim.BW_MANAGE_REJECT;

    var subrole_any: c.CFTypeRef = null;
    const subrole_err = c.AXUIElementCopyAttributeValue(win, ax.subrole_attr, &subrole_any);
    defer if (subrole_any) |value| c.CFRelease(value);
    if (subrole_err != c.kAXErrorSuccess or subrole_any == null) return shim.BW_MANAGE_PENDING;
    if (c.CFEqual(subrole_any, @ptrCast(ax.unknown_subrole)) != 0) return shim.BW_MANAGE_PENDING;
    if (c.CFEqual(subrole_any, @ptrCast(ax.standard_window_subrole)) != 0) return shim.BW_MANAGE_READY;

    // Electron and IDE top-level windows sometimes use these subroles, but
    // chrome-less autocomplete popups must not be admitted along with them.
    const is_dialog_like = c.CFEqual(subrole_any, @ptrCast(ax.floating_window_subrole)) != 0 or
        c.CFEqual(subrole_any, @ptrCast(ax.dialog_subrole)) != 0;
    if (is_dialog_like) {
        const real_window = windowHasRealWindowSignal(win, ax) orelse return shim.BW_MANAGE_PENDING;
        if (real_window) return shim.BW_MANAGE_READY;
    }
    return shim.BW_MANAGE_REJECT;
}

/// Title-bar buttons or main/focus distinguish real windows from transient chrome.
fn windowHasRealWindowSignal(win: c.AXUIElementRef, ax: *const AxStrings) ?bool {
    var incomplete = false;
    for ([_]c.CFStringRef{ ax.close_button_attr, ax.minimize_button_attr, ax.zoom_button_attr, ax.fullscreen_button_attr }) |attr| {
        const present = axAttributePresent(win, attr) orelse {
            incomplete = true;
            continue;
        };
        if (present) return true;
    }
    for ([_]c.CFStringRef{ ax.main_attr, ax.focused_attr }) |attr| {
        const enabled = axBooleanAttributeTrue(win, attr) orelse {
            incomplete = true;
            continue;
        };
        if (enabled) return true;
    }
    return if (incomplete) null else false;
}

/// Element-only query; deliberately does not update main-thread AX counters.
fn axAttributePresent(win: c.AXUIElementRef, attr: c.CFStringRef) ?bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(win, attr, &value);
    defer if (value) |ref| c.CFRelease(ref);
    if (err == c.kAXErrorAttributeUnsupported or err == c.kAXErrorNoValue) return false;
    if (err != c.kAXErrorSuccess) return null;
    return value != null;
}

/// A failed read is unknown, not proof that a real window has no title bar.
fn axBooleanAttributeTrue(win: c.AXUIElementRef, attr: c.CFStringRef) ?bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(win, attr, &value);
    defer if (value) |ref| c.CFRelease(ref);
    if (err == c.kAXErrorAttributeUnsupported or err == c.kAXErrorNoValue) return false;
    if (err != c.kAXErrorSuccess or value == null) return null;
    return c.CFEqual(value, @ptrCast(c.kCFBooleanTrue)) != 0;
}

/// Native tab count, or null when transport/children queries are inconclusive.
/// Unlike tabCount, this worker-safe query never resolves through shared caches.
pub fn tabCountForElement(win: c.AXUIElementRef, ax: *const AxStrings, timeout_seconds: f32, deadline_ns: i128) ?usize {
    if (osutil.nanoTimestamp() >= deadline_ns) return null;
    var children: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(win, ax.children_attr, @ptrCast(&children));
    defer if (children) |ref| c.CFRelease(@ptrCast(ref));
    if (err != c.kAXErrorSuccess or children == null) return null;
    if (c.CFGetTypeID(@ptrCast(children)) != c.CFArrayGetTypeID()) return null;

    var inconclusive = false;
    var i: c.CFIndex = 0;
    while (i < c.CFArrayGetCount(children)) : (i += 1) {
        // A normal title bar has few direct children. Treat unusually broad
        // trees as unknown rather than monopolizing this app's read queue.
        if (i >= 128 or osutil.nanoTimestamp() >= deadline_ns) return null;
        const child: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(children, i) orelse {
            inconclusive = true;
            continue;
        });
        _ = c.AXUIElementSetMessagingTimeout(child, timeout_seconds);
        var role: c.CFTypeRef = null;
        const role_err = c.AXUIElementCopyAttributeValue(child, ax.role_attr, &role);
        defer if (role) |ref| c.CFRelease(ref);
        if (role_err != c.kAXErrorSuccess or role == null) {
            inconclusive = true;
            continue;
        }
        if (c.CFEqual(role, @ptrCast(ax.tab_group_role)) == 0) continue;

        if (osutil.nanoTimestamp() >= deadline_ns) return null;
        var tabs: c.CFArrayRef = null;
        const tabs_err = c.AXUIElementCopyAttributeValue(child, ax.tabs_attr, @ptrCast(&tabs));
        defer if (tabs) |ref| c.CFRelease(@ptrCast(ref));
        // Some ordinary tab groups do not expose AXTabs; that is not a timeout.
        if (tabs_err == c.kAXErrorAttributeUnsupported or tabs_err == c.kAXErrorNoValue) continue;
        if (tabs_err != c.kAXErrorSuccess or tabs == null) return null;
        if (c.CFGetTypeID(@ptrCast(tabs)) != c.CFArrayGetTypeID()) return null;
        const total = c.CFArrayGetCount(tabs);
        return if (inconclusive or total < 0) null else @intCast(total);
    }
    return if (inconclusive) null else 0;
}
