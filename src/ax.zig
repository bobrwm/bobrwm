//! Shared Accessibility (AX) helpers: the interned CFString attribute cache
//! and the window-frame plumbing used by both the window manager core and
//! the animator. Every call into AX here is synchronous IPC to the target
//! app. These used to be C-ABI exports left over from the old ObjC shim;
//! they are plain Zig now that all callers are Zig.

const std = @import("std");
const c = @import("c");

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
    };
    return &g_strings.?;
}

pub fn deinitStrings() void {
    if (g_strings) |s| {
        const refs = [_]c.CFStringRef{
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
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));

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
        return win;
    }

    return null;
}

/// Query whether AXEnhancedUserInterface is currently enabled on an app element.
pub fn enhancedUserInterface(app: c.AXUIElementRef, ax: *const AxStrings) bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, ax.enhanced_ui_attr, &value);
    if (err != c.kAXErrorSuccess or value == null) return false;
    defer c.CFRelease(value.?);
    return c.CFEqual(value.?, @ptrCast(c.kCFBooleanTrue)) != 0;
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
    const win = findWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = strings() orelse return false;
    const size_attr = ax.size_attr;
    const position_attr = ax.position_attr;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));

    const had_enhanced_ui = enhancedUserInterface(app, ax);
    if (had_enhanced_ui) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanFalse);
    }
    defer if (had_enhanced_ui) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
    };

    const position: c.CGPoint = .{ .x = x, .y = y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return false;
    defer c.CFRelease(@ptrCast(position_value));

    const size: c.CGSize = .{ .width = w, .height = h };
    const size_value = c.AXValueCreate(c.kAXValueTypeCGSize, &size) orelse return false;
    defer c.CFRelease(@ptrCast(size_value));

    _ = c.AXUIElementSetAttributeValue(win, size_attr, @ptrCast(size_value));
    const position_err = c.AXUIElementSetAttributeValue(win, position_attr, @ptrCast(position_value));
    const size_err = c.AXUIElementSetAttributeValue(win, size_attr, @ptrCast(size_value));

    // Success means the whole frame was accepted. Reporting only the final
    // size write would let callers record a target frame whose position write
    // was rejected, desynchronizing the store from on-screen reality.
    return position_err == c.kAXErrorSuccess and size_err == c.kAXErrorSuccess;
}

/// Move a window without touching its size. Off-screen parking and pure-move
/// retiles use this instead of setWindowFrame: writing AXSize when only the
/// position changes triggers a visible resize flash and a reflow storm in
/// size-sensitive apps.
pub fn setWindowPosition(pid: i32, wid: u32, x: f64, y: f64) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = strings() orelse return false;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));

    const had_enhanced_ui = enhancedUserInterface(app, ax);
    if (had_enhanced_ui) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanFalse);
    }
    defer if (had_enhanced_ui) {
        _ = c.AXUIElementSetAttributeValue(app, ax.enhanced_ui_attr, c.kCFBooleanTrue);
    };

    const position: c.CGPoint = .{ .x = x, .y = y };
    const position_value = c.AXValueCreate(c.kAXValueTypeCGPoint, &position) orelse return false;
    defer c.CFRelease(@ptrCast(position_value));

    const err = c.AXUIElementSetAttributeValue(win, ax.position_attr, @ptrCast(position_value));
    return err == c.kAXErrorSuccess;
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
            if (enhancedUserInterface(app, ax)) {
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
