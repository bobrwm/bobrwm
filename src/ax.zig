//! Shared Accessibility (AX) helpers: the interned CFString attribute cache
//! and the window-frame plumbing used by both the window manager core and
//! the animator. Every call into AX here is synchronous IPC to the target
//! app. These used to be C-ABI exports left over from the old ObjC shim;
//! they are plain Zig now that all callers are Zig.

const std = @import("std");
const c = @import("c");
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
    };
    return &g_strings.?;
}

pub fn deinitStrings() void {
    if (g_strings) |s| {
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
        g_strings = null;
    }
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
        if (_AXUIElementGetWindow(win, &wid) != c.kAXErrorSuccess) continue;
        if (wid != target_wid) continue;

        _ = c.CFRetain(@ptrCast(win));
        if (timeout_seconds) |seconds| _ = c.AXUIElementSetMessagingTimeout(win, seconds);
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
/// A slot collision or a stale entry costs one re-resolve, never a write to
/// the wrong window: entries are matched on both pid and wid, and geometry
/// writes that a cached element rejects as stale re-resolve and retry.
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

/// Whether a geometry write failed because the cached element no longer refers
/// to a live window — the window was destroyed and its id recycled, or the app
/// replaced its AX element. Any other error is the app refusing the write, and
/// re-resolving would not change the outcome.
fn isStaleElementError(err: c.AXError) bool {
    return err == c.kAXErrorInvalidUIElement or err == c.kAXErrorCannotComplete;
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
    const err = c.AXUIElementCopyAttributeValue(app, ax.focused_window_attr, @ptrCast(&focused));
    if (err != c.kAXErrorSuccess or focused == null) return null;
    const focused_ref = focused orelse return null;

    var wid: u32 = 0;
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
    if (c.AXUIElementCopyAttributeValue(win, ax.children_attr, @ptrCast(&children)) != c.kAXErrorSuccess) return 0;
    const children_ref = children orelse return 0;
    defer c.CFRelease(@ptrCast(children_ref));

    const count = c.CFArrayGetCount(children_ref);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const child_any = c.CFArrayGetValueAtIndex(children_ref, i) orelse continue;
        const child: c.AXUIElementRef = @ptrCast(child_any);

        var role: c.CFTypeRef = null;
        if (c.AXUIElementCopyAttributeValue(child, ax.role_attr, &role) != c.kAXErrorSuccess) continue;
        const role_ref = role orelse continue;
        defer c.CFRelease(role_ref);
        if (c.CFEqual(role_ref, @ptrCast(ax.tab_group_role)) == 0) continue;

        var tabs: c.CFArrayRef = null;
        if (c.AXUIElementCopyAttributeValue(child, ax.tabs_attr, @ptrCast(&tabs)) != c.kAXErrorSuccess) return 0;
        const tabs_ref = tabs orelse return 0;
        defer c.CFRelease(@ptrCast(tabs_ref));

        const tab_total = c.CFArrayGetCount(tabs_ref);
        return if (tab_total > 0) @intCast(tab_total) else 0;
    }

    return 0;
}

/// Query whether AXEnhancedUserInterface is currently enabled on an app element.
fn readEnhancedUserInterface(app: c.AXUIElementRef, ax: *const AxStrings) ?bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, ax.enhanced_ui_attr, &value);
    if (err != c.kAXErrorSuccess or value == null) return null;
    defer c.CFRelease(value.?);
    return c.CFEqual(value.?, @ptrCast(c.kCFBooleanTrue)) != 0;
}

/// Return whether AXEnhancedUserInterface is enabled, treating an unreadable
/// attribute as disabled to preserve the existing best-effort behavior.
pub fn enhancedUserInterface(app: c.AXUIElementRef, ax: *const AxStrings) bool {
    return readEnhancedUserInterface(app, ax) orelse false;
}

// A workspace switch revisits the same apps several times in a short burst.
// Cache only successful false reads: a stale entry can delay geometry repair,
// but it can never make us restore a value that an assistive client changed.
// Half a second covers adjacent switch/retile batches while tightly bounding
// how long an external false -> true change can go unnoticed.
const enhanced_ui_false_cache_slots = 64;
const enhanced_ui_false_ttl_ns: i128 = 500 * std.time.ns_per_ms;

const EnhancedUiFalseEntry = struct {
    pid: i32,
    checked_at_ns: i128,
};

var g_enhanced_ui_false_cache: [enhanced_ui_false_cache_slots]?EnhancedUiFalseEntry = @splat(null);

fn enhancedUiFalseCacheSlot(pid: i32) usize {
    std.debug.assert(pid > 0);
    return @as(usize, @intCast(pid)) % enhanced_ui_false_cache_slots;
}

fn enhancedUiKnownFalse(pid: i32, now_ns: i128) bool {
    const entry = g_enhanced_ui_false_cache[enhancedUiFalseCacheSlot(pid)] orelse return false;
    if (entry.pid != pid) return false;
    if (now_ns < entry.checked_at_ns) return false;
    return now_ns - entry.checked_at_ns < enhanced_ui_false_ttl_ns;
}

fn rememberEnhancedUiFalse(pid: i32, now_ns: i128) void {
    g_enhanced_ui_false_cache[enhancedUiFalseCacheSlot(pid)] = .{
        .pid = pid,
        .checked_at_ns = now_ns,
    };
}

fn forgetEnhancedUiState(pid: i32) void {
    const slot = enhancedUiFalseCacheSlot(pid);
    const entry = g_enhanced_ui_false_cache[slot] orelse return;
    if (entry.pid == pid) g_enhanced_ui_false_cache[slot] = null;
}

/// Read the attribute unless a recent successful false result proves that no
/// suspend/restore pair is needed for this geometry burst.
fn shouldSuspendEnhancedUi(app: c.AXUIElementRef, pid: i32, ax: *const AxStrings) bool {
    const now_ns = osutil.nanoTimestamp();
    if (enhancedUiKnownFalse(pid, now_ns)) return false;

    const enabled = readEnhancedUserInterface(app, ax) orelse return false;
    if (!enabled) {
        rememberEnhancedUiFalse(pid, now_ns);
        return false;
    }

    forgetEnhancedUiState(pid);
    return true;
}

/// Drop per-process AX state when an application terminates. PIDs can be
/// recycled, so a later process must never inherit the old process's result.
pub fn invalidateApp(pid: i32) void {
    std.debug.assert(pid > 0);
    forgetEnhancedUiState(pid);
}

/// The app whose AXEnhancedUserInterface is suspended for the open batch, if
/// any. Only ever one: a batch suspends lazily, on the first write to a pid,
/// and restores as soon as a write for a different pid arrives.
var g_enhanced_ui_batch: ?struct { pid: i32, was_enabled: bool } = null;
/// Batch nesting depth. Batches nest because the operations that want one
/// compose: a workspace switch opens one around hide-then-retile, and retile
/// opens its own for the callers that reach it directly.
var g_geometry_batch_depth: u32 = 0;

/// Suspend the per-write AXEnhancedUserInterface dance for a run of geometry
/// writes. Every write otherwise reads the attribute and restores it — three
/// IPC round-trips per window on top of the write itself, paid once per window
/// during a workspace switch even though nothing between them can change it.
/// Inside a batch that cost is paid once per run of writes to the same app.
///
/// Callers must pair this with `endGeometryBatch` under `defer`: an
/// unterminated batch leaves an app's enhanced-user-interface flag off, which
/// degrades it for real assistive clients.
pub fn beginGeometryBatch() void {
    g_geometry_batch_depth += 1;
}

pub fn endGeometryBatch() void {
    std.debug.assert(g_geometry_batch_depth > 0);
    g_geometry_batch_depth -= 1;
    if (g_geometry_batch_depth > 0) return;

    restoreEnhancedUiBatch();
}

/// Disable AXEnhancedUserInterface for the duration of one write, or arrange
/// for the open batch to hold it disabled across writes to this app. Returns
/// whether the caller owns the restore.
fn suspendEnhancedUi(app: c.AXUIElementRef, pid: i32, ax: *const AxStrings) bool {
    if (g_geometry_batch_depth == 0) {
        const was_enabled = shouldSuspendEnhancedUi(app, pid, ax);
        if (was_enabled) {
            _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanFalse);
        }
        return was_enabled;
    }

    if (g_enhanced_ui_batch) |batch| {
        if (batch.pid == pid) return false;
        restoreEnhancedUiBatch();
    }

    const was_enabled = shouldSuspendEnhancedUi(app, pid, ax);
    if (was_enabled) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanFalse);
    }
    g_enhanced_ui_batch = .{ .pid = pid, .was_enabled = was_enabled };
    return false;
}

fn restoreEnhancedUiBatch() void {
    const batch = g_enhanced_ui_batch orelse return;
    g_enhanced_ui_batch = null;
    if (!batch.was_enabled) return;

    const ax = strings() orelse return;
    const app = c.AXUIElementCreateApplication(batch.pid) orelse return;
    defer c.CFRelease(@ptrCast(app));

    _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
}

/// Move and resize a window using AX attributes.
///
/// Uses a Size-Position-Size three-pass strategy because
/// macOS clamps window dimensions to the visible screen area at the current
/// origin. The first resize shrinks or grows the window while it is still at
/// its old position. The move then places it at the target origin. The second
/// resize corrects any clamping the intermediate position caused.
///
/// The entire sequence is wrapped in an AXEnhancedUserInterface toggle because
/// some apps (notably Electron) silently reject geometry writes when that flag
/// is enabled on the application element.
pub fn setWindowFrame(pid: i32, wid: u32, x: f64, y: f64, w: f64, h: f64) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    if (w <= 0 or h <= 0) return false;

    const ax = strings() orelse return false;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));

    const position: c.CGPoint = .{ .x = x, .y = y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return false;
    defer c.CFRelease(@ptrCast(position_value));

    const size: c.CGSize = .{ .width = w, .height = h };
    const size_value = c.AXValueCreate(c.kAXValueTypeCGSize, &size) orelse return false;
    defer c.CFRelease(@ptrCast(size_value));

    if (cachedElement(pid, wid)) |element| {
        const err = writeFrame(app, pid, element, ax, position_value, size_value);
        if (err == c.kAXErrorSuccess) return true;
        if (!isStaleElementError(err)) return false;
        invalidateWindow(wid);
    }

    const element = resolveElement(pid, wid) orelse return false;
    return writeFrame(app, pid, element, ax, position_value, size_value) == c.kAXErrorSuccess;
}

/// Size-Position-Size against a resolved element. Returns kAXErrorSuccess only
/// when the whole frame was accepted: reporting just the final size write
/// would let callers record a target frame whose position write was rejected,
/// desynchronizing the store from on-screen reality.
fn writeFrame(
    app: c.AXUIElementRef,
    pid: i32,
    element: c.AXUIElementRef,
    ax: *const AxStrings,
    position_value: c.AXValueRef,
    size_value: c.AXValueRef,
) c.AXError {
    const owns_restore = suspendEnhancedUi(app, pid, ax);
    defer if (owns_restore) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
    };

    _ = c.AXUIElementSetAttributeValue(element, ax.size_attr, @ptrCast(size_value));
    const position_err = c.AXUIElementSetAttributeValue(element, ax.position_attr, @ptrCast(position_value));
    const size_err = c.AXUIElementSetAttributeValue(element, ax.size_attr, @ptrCast(size_value));

    if (position_err != c.kAXErrorSuccess) return position_err;
    return size_err;
}

/// Move a window without touching its size. Pure-move retiles use this instead
/// of setWindowFrame: writing AXSize when only the
/// position changes triggers a visible resize flash and a reflow storm in
/// size-sensitive apps.
pub fn setWindowPosition(pid: i32, wid: u32, x: f64, y: f64) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const ax = strings() orelse return false;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));

    const position: c.CGPoint = .{ .x = x, .y = y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return false;
    defer c.CFRelease(@ptrCast(position_value));

    if (cachedElement(pid, wid)) |element| {
        const err = writePosition(app, pid, element, ax, position_value);
        if (err == c.kAXErrorSuccess) return true;
        if (!isStaleElementError(err)) return false;
        invalidateWindow(wid);
    }

    const element = resolveElement(pid, wid) orelse return false;
    return writePosition(app, pid, element, ax, position_value) == c.kAXErrorSuccess;
}

fn writePosition(
    app: c.AXUIElementRef,
    pid: i32,
    element: c.AXUIElementRef,
    ax: *const AxStrings,
    position_value: c.AXValueRef,
) c.AXError {
    const owns_restore = suspendEnhancedUi(app, pid, ax);
    defer if (owns_restore) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
    };

    return c.AXUIElementSetAttributeValue(element, ax.position_attr, @ptrCast(position_value));
}

/// Retained AX element plus the state needed to undo animationBegin.
pub const AnimationHandle = struct {
    win: c.AXUIElementRef,
    pid: i32,
    restore_enhanced_ui: bool,
};

/// Prepare a window for repeated animation frame writes: resolve and retain
/// its AX element once so ticks skip the per-call window-list enumeration,
/// and disable AXEnhancedUserInterface for the animation's duration (some
/// apps, notably Electron, silently reject geometry writes while it is set).
/// Returns null when the window cannot be resolved. Balance with
/// animationEnd.
pub fn animationBegin(pid: i32, wid: u32) ?AnimationHandle {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findWindow(pid, wid) orelse return null;

    var restore_enhanced_ui = false;
    if (strings()) |ax| {
        if (c.AXUIElementCreateApplication(pid)) |app| {
            defer c.CFRelease(@ptrCast(app));
            if (shouldSuspendEnhancedUi(app, pid, ax)) {
                _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanFalse);
                restore_enhanced_ui = true;
            }
        }
    }

    return .{ .win = win, .pid = pid, .restore_enhanced_ui = restore_enhanced_ui };
}

/// Single-pass frame write on the cached element of an AnimationHandle.
/// Skips the clamping-correction passes of setWindowFrame — intermediate
/// animation frames are overwritten on the next tick anyway, and the final
/// frame goes through the full three-pass set for exact placement.
/// `set_size` should be false for pure moves, halving the IPC per tick.
pub fn animationStep(handle: AnimationHandle, x: f64, y: f64, w: f64, h: f64, set_size: bool) void {
    if (w <= 0 or h <= 0) return;
    const ax = strings() orelse return;

    if (set_size) {
        const size: c.CGSize = .{ .width = w, .height = h };
        const size_value = c.AXValueCreate(c.kAXValueTypeCGSize, &size) orelse return;
        defer c.CFRelease(@ptrCast(size_value));
        _ = c.AXUIElementSetAttributeValue(handle.win, ax.size_attr, @ptrCast(size_value));
    }

    const position: c.CGPoint = .{ .x = x, .y = y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return;
    defer c.CFRelease(@ptrCast(position_value));
    _ = c.AXUIElementSetAttributeValue(handle.win, ax.position_attr, @ptrCast(position_value));
}

/// Release the cached AX element and restore AXEnhancedUserInterface if
/// animationBegin disabled it.
pub fn animationEnd(handle: AnimationHandle) void {
    c.CFRelease(@ptrCast(handle.win));
    if (handle.restore_enhanced_ui) {
        const ax = strings() orelse return;
        const app = c.AXUIElementCreateApplication(handle.pid) orelse return;
        defer c.CFRelease(@ptrCast(app));
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
    }
}

test "enhanced UI false cache expires and invalidates by pid" {
    const pid: i32 = 42;
    const collision_pid: i32 = pid + enhanced_ui_false_cache_slots;
    const checked_at_ns: i128 = 1_000;

    forgetEnhancedUiState(pid);
    forgetEnhancedUiState(collision_pid);
    defer {
        forgetEnhancedUiState(pid);
        forgetEnhancedUiState(collision_pid);
    }

    rememberEnhancedUiFalse(pid, checked_at_ns);
    try std.testing.expect(enhancedUiKnownFalse(pid, checked_at_ns));
    try std.testing.expect(enhancedUiKnownFalse(pid, checked_at_ns + enhanced_ui_false_ttl_ns - 1));
    try std.testing.expect(!enhancedUiKnownFalse(pid, checked_at_ns + enhanced_ui_false_ttl_ns));

    rememberEnhancedUiFalse(collision_pid, checked_at_ns);
    try std.testing.expect(!enhancedUiKnownFalse(pid, checked_at_ns));
    try std.testing.expect(enhancedUiKnownFalse(collision_pid, checked_at_ns));

    invalidateApp(collision_pid);
    try std.testing.expect(!enhancedUiKnownFalse(collision_pid, checked_at_ns));
}
