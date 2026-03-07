const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("dispatch/dispatch.h");
    @cInclude("pthread.h");
});
const objc = @import("objc");
const shim = @import("shim_api.zig");
const skylight = @import("skylight.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const workspace_mod = @import("workspace.zig");
const layout = @import("layout.zig");
const ipc = @import("ipc.zig");
const tabgroup = @import("tabgroup.zig");
const config_mod = @import("config.zig");
const statusbar = @import("statusbar.zig");
const tile_preview = @import("tile_preview.zig");
const ax_observer = @import("ax_observer.zig");
const launchd = @import("launchd.zig");

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

const NSPoint = extern struct {
    x: f64,
    y: f64,
};

const NSSize = extern struct {
    width: f64,
    height: f64,
};

const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const std_options = std.Options{
    .log_level = if (build_options.log_level_int) |l|
        @enumFromInt(l)
    else switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

const log = std.log.scoped(.bobrwm);

// ---------------------------------------------------------------------------
// Lock-free SPSC ring buffer
// ---------------------------------------------------------------------------
// Single-producer (main thread) only. All emitters must run on the
// main thread / main queue. The consumer is bw_drain_events, also on
// the main run-loop.

const EventRing = struct {
    const capacity = 256;

    buf: [capacity]event_mod.Event = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn push(self: *EventRing, ev: event_mod.Event) void {
        const t = self.tail.load(.acquire);
        const next = (t + 1) % capacity;
        if (next == self.head.load(.acquire)) return; // full, drop
        self.buf[t] = ev;
        self.tail.store(next, .release);
    }

    fn pop(self: *EventRing) ?event_mod.Event {
        const h = self.head.load(.acquire);
        if (h == self.tail.load(.acquire)) return null; // empty
        const ev = self.buf[h];
        self.head.store((h + 1) % capacity, .release);
        return ev;
    }
};

// ---------------------------------------------------------------------------
// Hidden-window position (bottom-right corner, barely visible)
// ---------------------------------------------------------------------------

/// Pixels visible in the corner when a window is hidden off-screen.
const hide_peek: f64 = 5;
/// Poll cadence for windows that are waiting on role readiness or visibility.
const role_poll_interval_ms: u64 = 100;
/// Retry budget for deferred candidates before they are dropped or fall back.
/// Electron-family apps can take multiple seconds before publishing stable AX roles.
const role_poll_attempts_max: u8 = 50;
/// Launch retry budget to re-run discovery after app startup settles.
const app_launch_retry_attempts_max: u8 = 10;
/// Capacity reserved for wid-keyed role/deferred maps to avoid growth churn.
const pending_role_window_capacity: usize = 256;
const deferred_window_candidate_capacity: usize = 256;
/// Capacity reserved for app launch retries (pid-keyed, bounded by observers).
const app_launch_retry_capacity: usize = 64;
/// Debounce workspace/display notifications that can fire in short bursts.
const workspace_event_debounce_interval_s: f64 = 0.05;

const DisplayInfo = struct {
    id: u32,
    visible: shim.bw_frame,
    full: shim.bw_frame,
    is_primary: bool,
};

const DragPreviewState = struct {
    source_wid: ?u32 = null,
    target_wid: ?u32 = null,
    visible: bool = false,
};

const DropTarget = struct {
    wid: u32,
    frame: window_mod.Window.Frame,
};

const HideCorner = enum { bottom_right, bottom_left };

const WindowRoleState = enum {
    reject,
    ready,
    pending,
};

const PendingRoleWindow = struct {
    pid: i32,
    attempts_remaining: u8,
};

const PendingRoleCandidate = struct {
    pid: i32,
    wid: u32,
    from_timeout: bool,
};

const DeferredWindowCandidate = struct {
    pid: i32,
    attempts_remaining: u8,
};

const DeferredWindowPromotion = struct {
    pid: i32,
    wid: u32,
};

const PendingRoleWindowMap = std.AutoHashMap(u32, PendingRoleWindow);
const DeferredWindowCandidateMap = std.AutoHashMap(u32, DeferredWindowCandidate);
const AppLaunchRetryMap = std.AutoHashMap(i32, u8);

fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse
        @panic("NSString class not found");
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}

const AxStrings = struct {
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
    unknown_subrole: c.CFStringRef,
    enhanced_ui_attr: c.CFStringRef,
};

fn createAxString(raw: [*:0]const u8) ?c.CFStringRef {
    return c.CFStringCreateWithCString(null, raw, c.kCFStringEncodingUTF8);
}

fn releaseAxString(value: c.CFStringRef) void {
    c.CFRelease(@ptrCast(value));
}

fn ensureAxStrings() ?*const AxStrings {
    if (g_ax_strings) |*strings| return strings;

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
        "AXUnknown",
        "AXEnhancedUserInterface",
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

    g_ax_strings = .{
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
        .unknown_subrole = refs[11],
        .enhanced_ui_attr = refs[12],
    };
    return &g_ax_strings.?;
}

fn deinitAxStrings() void {
    if (g_ax_strings) |strings| {
        const refs = [_]c.CFStringRef{
            strings.enhanced_ui_attr,
            strings.unknown_subrole,
            strings.standard_window_subrole,
            strings.subrole_attr,
            strings.unknown_role,
            strings.window_role,
            strings.role_attr,
            strings.main_attr,
            strings.raise_action,
            strings.position_attr,
            strings.size_attr,
            strings.windows_attr,
            strings.focused_window_attr,
        };
        for (refs) |value| {
            releaseAxString(value);
        }
        g_ax_strings = null;
    }
}

fn displayIndexById(display_id: u32) ?usize {
    for (g_displays[0..g_display_count], 0..) |display, i| {
        if (display.id == display_id) return i;
    }
    return null;
}

fn primaryDisplayId() u32 {
    std.debug.assert(g_display_count > 0);
    for (g_displays[0..g_display_count]) |display| {
        if (display.is_primary) return display.id;
    }
    return g_displays[0].id;
}

fn activeWorkspaceIdForDisplay(display_id: u32) u8 {
    const slot = displayIndexById(display_id) orelse return 1;
    return g_workspaces.activeIdForDisplaySlot(slot);
}

fn workspaceVisibleOnDisplay(workspace_id: u8, display_id: u32) bool {
    return activeWorkspaceIdForDisplay(display_id) == workspace_id;
}

fn workspaceVisibleAnywhere(workspace_id: u8) bool {
    for (0..g_display_count) |slot| {
        if (g_workspaces.activeIdForDisplaySlot(slot) == workspace_id) return true;
    }
    return false;
}

fn focusedDisplayId() u32 {
    if (g_display_count == 0) return 1;
    const slot = g_workspaces.focused_display_slot;
    if (slot < g_display_count) return g_displays[slot].id;
    return primaryDisplayId();
}

fn setFocusedDisplay(display_id: u32) void {
    const slot = displayIndexById(display_id) orelse return;
    g_workspaces.focused_display_slot = slot;
}

fn clearLayoutRoots() void {
    for (0..workspace_mod.max_workspaces) |ws_idx| {
        for (0..workspace_mod.max_displays) |slot| {
            g_layout_roots[ws_idx][slot] = null;
        }
    }
}

/// Rebuilds the current display snapshot from `NSScreen`.
///
/// Coordinates are normalized to CG top-left origin so window bounds from
/// SkyLight/CG can be compared directly against display frames.
fn refreshDisplays() void {
    const NSScreen = objc.getClass("NSScreen") orelse {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .visible = frame, .full = frame, .is_primary = true };
        g_workspaces.focused_display_slot = 0;
        return;
    };

    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    if (count == 0) {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .visible = frame, .full = frame, .is_primary = true };
        g_workspaces.focused_display_slot = 0;
        return;
    }

    const main_screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});

    var global_top: f64 = -std.math.inf(f64);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        const frame = screen.msgSend(NSRect, "frame", .{});
        const top = frame.origin.y + frame.size.height;
        if (top > global_top) global_top = top;
    }
    std.debug.assert(global_top != -std.math.inf(f64));

    const screen_number_key = nsString("NSScreenNumber");
    var next_count: usize = 0;
    var has_primary = false;

    i = 0;
    while (i < count and next_count < g_displays.len) : (i += 1) {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        const visible = screen.msgSend(NSRect, "visibleFrame", .{});
        const full = screen.msgSend(NSRect, "frame", .{});
        const description = screen.msgSend(objc.Object, "deviceDescription", .{});
        const number = description.msgSend(objc.Object, "objectForKey:", .{screen_number_key});
        if (number.value == null) continue;
        const display_id = number.msgSend(u32, "unsignedIntValue", .{});
        if (display_id == 0) continue;

        const visible_frame: shim.bw_frame = .{
            .x = visible.origin.x,
            .y = global_top - (visible.origin.y + visible.size.height),
            .w = visible.size.width,
            .h = visible.size.height,
        };
        const full_frame: shim.bw_frame = .{
            .x = full.origin.x,
            .y = global_top - (full.origin.y + full.size.height),
            .w = full.size.width,
            .h = full.size.height,
        };

        const is_primary = main_screen.value != null and screen.value == main_screen.value;
        if (is_primary) has_primary = true;

        g_displays[next_count] = .{
            .id = display_id,
            .visible = visible_frame,
            .full = full_frame,
            .is_primary = is_primary,
        };
        next_count += 1;
    }

    if (next_count == 0) {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .visible = frame, .full = frame, .is_primary = true };
        g_workspaces.focused_display_slot = 0;
        return;
    }

    if (!has_primary) g_displays[0].is_primary = true;
    g_display_count = next_count;

    if (g_workspaces.focused_display_slot >= g_display_count) {
        g_workspaces.focused_display_slot = 0;
    }
}

/// Resolves a window frame to the best display.
///
/// Fast path uses center-point containment. If a frame straddles displays,
/// we fall back to max overlap area.
fn displayIdForFrame(frame: window_mod.Window.Frame) u32 {
    const center_x = frame.x + frame.width / 2.0;
    const center_y = frame.y + frame.height / 2.0;

    for (g_displays[0..g_display_count]) |display| {
        const in_x = center_x >= display.visible.x and center_x <= display.visible.x + display.visible.w;
        const in_y = center_y >= display.visible.y and center_y <= display.visible.y + display.visible.h;
        if (in_x and in_y) return display.id;
    }

    var best_display: u32 = primaryDisplayId();
    var best_overlap: f64 = -1;
    for (g_displays[0..g_display_count]) |display| {
        const left = @max(frame.x, display.visible.x);
        const right = @min(frame.x + frame.width, display.visible.x + display.visible.w);
        const top = @max(frame.y, display.visible.y);
        const bottom = @min(frame.y + frame.height, display.visible.y + display.visible.h);
        const overlap_w = right - left;
        const overlap_h = bottom - top;
        if (overlap_w <= 0 or overlap_h <= 0) continue;
        const area = overlap_w * overlap_h;
        if (area > best_overlap) {
            best_overlap = area;
            best_display = display.id;
        }
    }
    return best_display;
}

/// Pick the bottom corner that does not border an adjacent monitor.
/// Falls back to bottom-right on single-monitor setups.
fn hideCorner(display_id: u32) HideCorner {
    const slot = displayIndexById(display_id) orelse return .bottom_right;
    const display = g_displays[slot].visible;
    const display_right = display.x + display.w;

    for (g_displays[0..g_display_count], 0..) |other, other_slot| {
        if (other_slot == slot) continue;
        if (@abs(other.visible.x - display_right) < 5) return .bottom_left;
    }
    return .bottom_right;
}

/// Precomputed hide parameters (display frame + corner), so callers that
/// hide many windows in a loop only query NSScreen once.
const HideCtx = struct {
    display: shim.bw_frame,
    corner: HideCorner,

    fn init(display_id: u32) HideCtx {
        const slot = displayIndexById(display_id) orelse return .{
            .display = g_displays[0].visible,
            .corner = .bottom_right,
        };
        return .{
            .display = g_displays[slot].visible,
            .corner = hideCorner(display_id),
        };
    }

    /// Move a single window to the chosen bottom corner, preserving its
    /// stored frame size so there is no layout shift on workspace switch.
    fn hide(self: HideCtx, pid: i32, wid: u32) void {
        const pos_y = self.display.y + self.display.h - hide_peek;

        if (g_store.get(wid)) |win| {
            if (win.frame.width > 1 and win.frame.height > 1) {
                const pos_x = switch (self.corner) {
                    .bottom_right => self.display.x + self.display.w - hide_peek,
                    .bottom_left => self.display.x - win.frame.width + hide_peek,
                };
                _ = shim.bw_ax_set_window_frame(pid, wid, pos_x, pos_y, win.frame.width, win.frame.height);
                return;
            }
        }
        // Window not yet tiled — just move off-screen with minimal size
        const pos_x = switch (self.corner) {
            .bottom_right => self.display.x + self.display.w - hide_peek,
            .bottom_left => self.display.x - 1 + hide_peek,
        };
        _ = shim.bw_ax_set_window_frame(pid, wid, pos_x, pos_y, 1, 1);
    }
};

/// Convenience wrapper for single-window hides outside of loops.
fn hideWindow(pid: i32, wid: u32) void {
    const display_id = if (g_store.get(wid)) |win| win.display_id else focusedDisplayId();
    (HideCtx.init(display_id)).hide(pid, wid);
}

/// Workspace-aware on-screen check. Windows on hidden workspaces are parked
/// in a screen corner with a few peek pixels visible — CG considers them
/// "on screen" but they should not be treated as such.
fn isVisibleOnScreen(wid: u32) bool {
    if (g_store.get(wid)) |win| {
        if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) return false;
    }
    return shim.bw_is_window_on_screen(wid);
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

var g_ring: EventRing = .{};
var g_sky: ?skylight.SkyLight = null;
var g_allocator: std.mem.Allocator = undefined;
var g_store: window_mod.WindowStore = undefined;
var g_workspaces: workspace_mod.WorkspaceManager = undefined;
var g_layout_roots: [workspace_mod.max_workspaces][workspace_mod.max_displays]?layout.Node = undefined;
var g_displays: [workspace_mod.max_displays]DisplayInfo = undefined;
var g_display_count: usize = 0;
var g_next_split_dir: layout.Direction = .horizontal;
var g_tab_groups: tabgroup.TabGroupManager = undefined;
var g_pending_role_windows: PendingRoleWindowMap = undefined;
var g_deferred_window_candidates: DeferredWindowCandidateMap = undefined;
var g_app_launch_retries: AppLaunchRetryMap = undefined;
var g_workspace_observer: ?objc.Object = null;
var g_ipc: ipc.Server = undefined;
var g_config: config_mod.Config = .{};
var g_drag_preview: DragPreviewState = .{};
var g_mouse_left_down = false;
var g_last_space_changed_at_s: f64 = 0;
var g_last_display_changed_at_s: f64 = 0;
var g_hotkey_bindings: [128]shim.bw_keybind = undefined;
var g_hotkey_binding_count: u32 = 0;
var g_waker_source: c.CFRunLoopSourceRef = null;
var g_role_poll_source: c.dispatch_source_t = null;
var g_ipc_source: c.dispatch_source_t = null;
var g_tap_port: c.CFMachPortRef = null;
var g_ax_strings: ?AxStrings = null;

fn shouldHandleWorkspaceEvent(last_event_at_s: *f64) bool {
    std.debug.assert(last_event_at_s.* >= 0);
    std.debug.assert(workspace_event_debounce_interval_s > 0);

    const now_s: f64 = c.CFAbsoluteTimeGetCurrent();
    std.debug.assert(now_s > 0);
    if (last_event_at_s.* != 0 and @abs(now_s - last_event_at_s.*) < workspace_event_debounce_interval_s) {
        return false;
    }

    last_event_at_s.* = now_s;
    std.debug.assert(last_event_at_s.* == now_s);
    return true;
}

// ---------------------------------------------------------------------------
// NSApp lifecycle (zig-objc)
// ---------------------------------------------------------------------------

/// Initialise NSApplication with accessory activation policy (menu bar icon,
/// no dock icon). Returns the shared application object for the run loop.
fn initApp() objc.Object {
    const NSApplication = objc.getClass("NSApplication") orelse
        @panic("NSApplication class not found");
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    // NSApplicationActivationPolicyAccessory = 1
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 1)});
    return app;
}

/// Register NSWorkspace/NSNotificationCenter observers via zig-objc while
/// keeping selector callbacks in BWObserver (ObjC class in shim.m).
fn initWorkspaceObservers() void {
    const BWObserver = objc.getClass("BWObserver") orelse
        @panic("BWObserver class not found");
    const NSWorkspace = objc.getClass("NSWorkspace") orelse
        @panic("NSWorkspace class not found");
    const NSNotificationCenter = objc.getClass("NSNotificationCenter") orelse
        @panic("NSNotificationCenter class not found");

    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const workspace_notification_center = workspace.msgSend(objc.Object, "notificationCenter", .{});
    const default_notification_center = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
    const observer = BWObserver.msgSend(objc.Object, "new", .{});
    std.debug.assert(observer.value != null);
    g_workspace_observer = observer;

    // NSNotificationCenter does not retain selector-based observers.
    std.debug.assert(g_workspace_observer.?.value != null);
    const nil_object: objc.Object = .{ .value = null };
    workspace_notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        observer,
        objc.sel("appLaunched:"),
        nsString("NSWorkspaceDidLaunchApplicationNotification"),
        nil_object,
    });
    workspace_notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        observer,
        objc.sel("appTerminated:"),
        nsString("NSWorkspaceDidTerminateApplicationNotification"),
        nil_object,
    });
    workspace_notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        observer,
        objc.sel("spaceChanged:"),
        nsString("NSWorkspaceActiveSpaceDidChangeNotification"),
        nil_object,
    });
    workspace_notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        observer,
        objc.sel("activeAppChanged:"),
        nsString("NSWorkspaceDidActivateApplicationNotification"),
        nil_object,
    });
    default_notification_center.msgSend(void, "addObserver:selector:name:object:", .{
        observer,
        objc.sel("displayChanged:"),
        nsString("NSApplicationDidChangeScreenParametersNotification"),
        nil_object,
    });
}

/// Get the usable display frame (menu bar / dock excluded), CG coordinates.
/// Exported for C callers while implemented in Zig via zig-objc.
export fn bw_get_display_frame() shim.bw_frame {
    const NSScreen = objc.getClass("NSScreen") orelse return .{
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
    };

    const screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (screen.value == null) return .{
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
    };

    const visible = screen.msgSend(NSRect, "visibleFrame", .{});
    const full = screen.msgSend(NSRect, "frame", .{});

    std.debug.assert(visible.size.width >= 0);
    std.debug.assert(visible.size.height >= 0);

    // AppKit uses bottom-left origin; CG uses top-left.
    const cg_y = full.size.height - visible.origin.y - visible.size.height;
    const frame: shim.bw_frame = .{
        .x = visible.origin.x,
        .y = cg_y,
        .w = visible.size.width,
        .h = visible.size.height,
    };
    std.debug.assert(frame.w >= 0);
    std.debug.assert(frame.h >= 0);
    return frame;
}

/// Accessibility trust check.
export fn bw_ax_is_trusted() bool {
    return c.AXIsProcessTrusted() != 0;
}

/// Prompt for Accessibility permission in System Settings.
fn axPrompt() void {
    const NSDictionary = objc.getClass("NSDictionary") orelse {
        _ = c.AXIsProcessTrustedWithOptions(null);
        return;
    };
    const NSNumber = objc.getClass("NSNumber") orelse {
        _ = c.AXIsProcessTrustedWithOptions(null);
        return;
    };

    const enabled = NSNumber.msgSend(objc.Object, "numberWithBool:", .{true});
    const options = NSDictionary.msgSend(objc.Object, "dictionaryWithObject:forKey:", .{
        enabled,
        nsString("AXTrustedCheckOptionPrompt"),
    });
    const options_value = options.value orelse return;

    std.debug.assert(enabled.value != null);
    std.debug.assert(options.value != null);
    _ = c.AXIsProcessTrustedWithOptions(@ptrCast(options_value));
}

/// Get the bundle identifier for a PID.
/// Writes a NUL-terminated string into `out` and returns bytes written.
export fn bw_get_app_bundle_id(pid: i32, out: ?[*]u8, max_len: u32) u32 {
    const out_ptr = out orelse return 0;
    if (max_len == 0) return 0;

    std.debug.assert(pid > 0);
    std.debug.assert(max_len > 0);

    const max_len_usize: usize = @intCast(max_len);
    const buffer = out_ptr[0..max_len_usize];

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return 0;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return 0;

    const bundle_identifier = app.msgSend(objc.Object, "bundleIdentifier", .{});
    if (bundle_identifier.value == null) return 0;

    const utf8 = bundle_identifier.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return 0;
    const bundle_id = std.mem.sliceTo(utf8, 0);
    if (bundle_id.len == 0) return 0;

    const copy_len = @min(bundle_id.len, buffer.len - 1);
    @memcpy(buffer[0..copy_len], bundle_id[0..copy_len]);
    buffer[copy_len] = 0;

    std.debug.assert(copy_len < buffer.len);
    std.debug.assert(buffer[copy_len] == 0);
    return @intCast(copy_len);
}

/// Get the focused window ID for a given application PID.
/// Returns 0 when no focused AX window is available.
export fn bw_ax_get_focused_window(pid: i32) u32 {
    std.debug.assert(pid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return 0;
    defer c.CFRelease(@ptrCast(app));

    const ax = ensureAxStrings() orelse return 0;
    const focused_attr = ax.focused_window_attr;

    var focused: c.AXUIElementRef = null;
    const err = c.AXUIElementCopyAttributeValue(
        app,
        focused_attr,
        @ptrCast(&focused),
    );
    if (err != c.kAXErrorSuccess or focused == null) return 0;
    const focused_ref = focused orelse return 0;
    defer c.CFRelease(@ptrCast(focused_ref));

    var wid: u32 = 0;
    _ = _AXUIElementGetWindow(focused_ref, &wid);
    return wid;
}

/// Check if a window currently appears in the on-screen CG window list.
/// This excludes desktop elements and naturally filters background tabs.
export fn bw_is_window_on_screen(target_wid: u32) bool {
    std.debug.assert(target_wid > 0);

    const options: c.CGWindowListOption =
        c.kCGWindowListOptionOnScreenOnly | c.kCGWindowListExcludeDesktopElements;
    const list = c.CGWindowListCopyWindowInfo(options, c.kCGNullWindowID) orelse return false;
    defer c.CFRelease(@ptrCast(list));

    const count = c.CFArrayGetCount(list);
    std.debug.assert(count >= 0);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);
        const wid_ref_any = c.CFDictionaryGetValue(info, c.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);

        var wid: u32 = 0;
        const ok = c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid);
        if (ok == 0) continue;
        if (wid == target_wid) return true;
    }

    return false;
}

/// Get all AX-backed window IDs for an application PID.
/// Includes windows that may not currently be visible on screen.
export fn bw_get_app_window_ids(pid: i32, out: ?[*]u32, max_count: u32) u32 {
    const out_ptr = out orelse return 0;
    if (max_count == 0) return 0;

    std.debug.assert(pid > 0);
    std.debug.assert(max_count > 0);

    const out_buf = out_ptr[0..@as(usize, @intCast(max_count))];
    const app = c.AXUIElementCreateApplication(pid) orelse return 0;
    defer c.CFRelease(@ptrCast(app));

    const ax = ensureAxStrings() orelse return 0;
    const windows_attr = ax.windows_attr;

    var windows: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(
        app,
        windows_attr,
        @ptrCast(&windows),
    );
    if (err != c.kAXErrorSuccess or windows == null) return 0;
    const windows_ref = windows orelse return 0;
    defer c.CFRelease(@ptrCast(windows_ref));

    var written: usize = 0;
    const total = c.CFArrayGetCount(windows_ref);
    std.debug.assert(total >= 0);

    var i: c.CFIndex = 0;
    while (i < total and written < out_buf.len) : (i += 1) {
        const win_any = c.CFArrayGetValueAtIndex(windows_ref, i) orelse continue;
        const win: c.AXUIElementRef = @ptrCast(win_any);

        var wid: u32 = 0;
        if (_AXUIElementGetWindow(win, &wid) == c.kAXErrorSuccess and wid != 0) {
            out_buf[written] = wid;
            written += 1;
        }
    }

    std.debug.assert(written <= out_buf.len);
    return @intCast(written);
}

fn isRegularActivationApp(pid: i32) bool {
    std.debug.assert(pid > 0);

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return false;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return false;

    // NSApplicationActivationPolicyRegular == 0.
    const activation_policy = app.msgSend(i64, "activationPolicy", .{});
    return activation_policy == 0;
}

fn findAxWindow(pid: i32, target_wid: u32) ?c.AXUIElementRef {
    std.debug.assert(pid > 0);
    std.debug.assert(target_wid > 0);

    const app = c.AXUIElementCreateApplication(pid) orelse return null;
    defer c.CFRelease(@ptrCast(app));

    const ax = ensureAxStrings() orelse return null;
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
export fn bw_ax_set_window_frame(pid: i32, wid: u32, x: f64, y: f64, w: f64, h: f64) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    if (w <= 0 or h <= 0) return false;
    const win = findAxWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = ensureAxStrings() orelse return false;
    const size_attr = ax.size_attr;
    const position_attr = ax.position_attr;

    const app = c.AXUIElementCreateApplication(pid) orelse return false;
    defer c.CFRelease(@ptrCast(app));

    const had_enhanced_ui = axEnhancedUserInterface(app, ax);
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
    _ = c.AXUIElementSetAttributeValue(win, position_attr, @ptrCast(position_value));
    const err = c.AXUIElementSetAttributeValue(win, size_attr, @ptrCast(size_value));

    return err == c.kAXErrorSuccess;
}

/// Query whether the AXSize attribute is settable (i.e. the window can be resized).
fn axCanResize(win_ref: c.AXUIElementRef, ax: *const AxStrings) bool {
    var result: c.Boolean = 0;
    const err = c.AXUIElementIsAttributeSettable(win_ref, ax.size_attr, &result);
    return err == c.kAXErrorSuccess and result != 0;
}

/// Query whether AXEnhancedUserInterface is currently enabled on an app element.
fn axEnhancedUserInterface(app: c.AXUIElementRef, ax: *const AxStrings) bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, ax.enhanced_ui_attr, &value);
    if (err != c.kAXErrorSuccess or value == null) return false;
    defer c.CFRelease(value.?);
    return c.CFEqual(value.?, @ptrCast(c.kCFBooleanTrue)) != 0;
}

/// Raise and focus a window, then activate its owning app.
export fn bw_ax_focus_window(pid: i32, wid: u32) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findAxWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = ensureAxStrings() orelse return false;
    const raise_action = ax.raise_action;
    const main_attr = ax.main_attr;

    _ = c.AXUIElementPerformAction(win, raise_action);
    _ = c.AXUIElementSetAttributeValue(win, main_attr, c.kCFBooleanTrue);

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return true;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value != null) {
        // NSApplicationActivateIgnoringOtherApps == 2.
        _ = app.msgSend(bool, "activateWithOptions:", .{@as(usize, 2)});
    }
    return true;
}

fn manageStateForWindow(pid: i32, wid: u32) u8 {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    if (!isRegularActivationApp(pid)) return shim.BW_MANAGE_REJECT;

    const win = findAxWindow(pid, wid) orelse return shim.BW_MANAGE_PENDING;
    defer c.CFRelease(@ptrCast(win));

    const ax = ensureAxStrings() orelse return shim.BW_MANAGE_PENDING;
    const role_attr = ax.role_attr;
    var role_any: c.CFTypeRef = null;
    const role_err = c.AXUIElementCopyAttributeValue(win, role_attr, @ptrCast(&role_any));
    if (role_err != c.kAXErrorSuccess or role_any == null) return shim.BW_MANAGE_PENDING;
    const role_ref: c.CFStringRef = @ptrCast(role_any orelse return shim.BW_MANAGE_PENDING);
    defer c.CFRelease(@ptrCast(role_ref));

    const window_role = ax.window_role;
    const unknown_role = ax.unknown_role;

    const is_window = c.CFEqual(@ptrCast(role_ref), @ptrCast(window_role)) != 0;
    const is_unknown_role = c.CFEqual(@ptrCast(role_ref), @ptrCast(unknown_role)) != 0;
    if (!is_window) {
        return if (is_unknown_role) shim.BW_MANAGE_PENDING else shim.BW_MANAGE_REJECT;
    }

    const subrole_attr = ax.subrole_attr;
    var subrole_any: c.CFTypeRef = null;
    const subrole_err = c.AXUIElementCopyAttributeValue(win, subrole_attr, @ptrCast(&subrole_any));
    if (subrole_err != c.kAXErrorSuccess or subrole_any == null) return shim.BW_MANAGE_PENDING;
    const subrole_ref: c.CFStringRef = @ptrCast(subrole_any orelse return shim.BW_MANAGE_PENDING);
    defer c.CFRelease(@ptrCast(subrole_ref));

    const standard_subrole = ax.standard_window_subrole;
    const unknown_subrole = ax.unknown_subrole;

    const is_standard = c.CFEqual(@ptrCast(subrole_ref), @ptrCast(standard_subrole)) != 0;
    const is_unknown_subrole = c.CFEqual(@ptrCast(subrole_ref), @ptrCast(unknown_subrole)) != 0;
    if (!is_standard and is_unknown_subrole) return shim.BW_MANAGE_PENDING;

    return if (is_standard) shim.BW_MANAGE_READY else shim.BW_MANAGE_REJECT;
}

/// Legacy management predicate: true for READY or PENDING states.
export fn bw_should_manage_window(pid: i32, wid: u32) bool {
    const state = manageStateForWindow(pid, wid);
    return state != shim.BW_MANAGE_REJECT;
}

/// Returns management state for a given window.
export fn bw_window_manage_state(pid: i32, wid: u32) u8 {
    return manageStateForWindow(pid, wid);
}

/// Enumerate on-screen layer-0 windows for regular applications.
export fn bw_discover_windows(out: ?[*]shim.bw_window_info, max_count: u32) u32 {
    const out_ptr = out orelse return 0;
    if (max_count == 0) return 0;

    std.debug.assert(max_count > 0);
    const out_buf = out_ptr[0..@as(usize, @intCast(max_count))];

    const options: c.CGWindowListOption =
        c.kCGWindowListOptionOnScreenOnly | c.kCGWindowListExcludeDesktopElements;
    const window_list = c.CGWindowListCopyWindowInfo(options, c.kCGNullWindowID) orelse return 0;
    defer c.CFRelease(@ptrCast(window_list));

    const total = c.CFArrayGetCount(window_list);
    std.debug.assert(total >= 0);

    var count: usize = 0;
    var i: c.CFIndex = 0;
    while (i < total and count < out_buf.len) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(window_list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);

        var layer: i32 = 0;
        if (c.CFDictionaryGetValue(info, c.kCGWindowLayer)) |layer_ref_any| {
            const layer_ref: c.CFNumberRef = @ptrCast(layer_ref_any);
            _ = c.CFNumberGetValue(layer_ref, c.kCFNumberSInt32Type, &layer);
        }
        if (layer != 0) continue;

        const wid_ref_any = c.CFDictionaryGetValue(info, c.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);
        var wid: u32 = 0;
        _ = c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid);

        const pid_ref_any = c.CFDictionaryGetValue(info, c.kCGWindowOwnerPID) orelse continue;
        const pid_ref: c.CFNumberRef = @ptrCast(pid_ref_any);
        var pid: i32 = 0;
        _ = c.CFNumberGetValue(pid_ref, c.kCFNumberSInt32Type, &pid);
        if (pid <= 0) continue;
        if (!isRegularActivationApp(pid)) continue;

        var bounds: c.CGRect = std.mem.zeroes(c.CGRect);
        if (c.CFDictionaryGetValue(info, c.kCGWindowBounds)) |bounds_ref_any| {
            const bounds_ref: c.CFDictionaryRef = @ptrCast(bounds_ref_any);
            _ = c.CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds);
        }
        if (bounds.size.width < 1 or bounds.size.height < 1) continue;

        out_buf[count] = .{
            .wid = wid,
            .pid = pid,
            .x = bounds.origin.x,
            .y = bounds.origin.y,
            .w = bounds.size.width,
            .h = bounds.size.height,
        };
        count += 1;
    }

    std.debug.assert(count <= out_buf.len);
    return @intCast(count);
}

fn wakerPerform(info: ?*anyopaque) callconv(.c) void {
    _ = info;
    bw_drain_events();
}

fn initWakerSource() void {
    if (g_waker_source != null) return;

    var context: c.CFRunLoopSourceContext = std.mem.zeroes(c.CFRunLoopSourceContext);
    context.perform = wakerPerform;

    g_waker_source = c.CFRunLoopSourceCreate(null, 0, &context);
    const source = g_waker_source orelse return;
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
}

fn signalWaker() void {
    if (g_waker_source) |source| {
        c.CFRunLoopSourceSignal(source);
    }
    const run_loop = c.CFRunLoopGetMain();
    if (run_loop != null) {
        c.CFRunLoopWakeUp(run_loop);
    }
}

fn rolePollTimerTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    bw_emit_event(shim.BW_EVENT_ROLE_POLL_TICK, 0, 0);
}

fn setRolePolling(enabled: bool) void {
    if (!enabled) {
        if (g_role_poll_source) |source| {
            c.dispatch_source_cancel(source);
            g_role_poll_source = null;
        }
        return;
    }

    if (g_role_poll_source != null) return;

    const source = c.dispatch_source_create(
        c.DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        c.dispatch_get_main_queue(),
    );
    if (source == null) return;

    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, @as(i64, 100) * c.NSEC_PER_MSEC),
        @as(u64, 100) * c.NSEC_PER_MSEC,
        @as(u64, 20) * c.NSEC_PER_MSEC,
    );
    c.dispatch_source_set_event_handler_f(source, rolePollTimerTick);
    c.dispatch_resume(.{ ._ds = source });
    g_role_poll_source = source;
}

fn modsFromEventFlags(flags: c.CGEventFlags) u8 {
    var mods: u8 = 0;
    if ((flags & c.kCGEventFlagMaskAlternate) != 0) mods |= shim.BW_MOD_ALT;
    if ((flags & c.kCGEventFlagMaskShift) != 0) mods |= shim.BW_MOD_SHIFT;
    if ((flags & c.kCGEventFlagMaskCommand) != 0) mods |= shim.BW_MOD_CMD;
    if ((flags & c.kCGEventFlagMaskControl) != 0) mods |= shim.BW_MOD_CTRL;
    return mods;
}

fn hotkeyTapCallback(
    proxy: c.CGEventTapProxy,
    event_type: c.CGEventType,
    event: c.CGEventRef,
    refcon: ?*anyopaque,
) callconv(.c) c.CGEventRef {
    _ = proxy;
    _ = refcon;

    if (event_type == c.kCGEventTapDisabledByTimeout or event_type == c.kCGEventTapDisabledByUserInput) {
        if (g_tap_port) |tap| c.CGEventTapEnable(tap, true);
        return event;
    }

    if (event_type == c.kCGEventLeftMouseDown) {
        bw_hotkey_mouse_down();
        return event;
    }
    if (event_type == c.kCGEventLeftMouseUp) {
        bw_hotkey_mouse_up();
        return event;
    }

    const flags = c.CGEventGetFlags(event);
    const keycode_raw = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
    const keycode: u16 = @intCast(keycode_raw);
    const mods = modsFromEventFlags(flags);

    if (bw_hotkey_handle_keydown(keycode, mods)) {
        return null;
    }
    return event;
}

fn setupHotkeyEventTap() void {
    const mask: c.CGEventMask =
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventKeyDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseUp));

    g_tap_port = c.CGEventTapCreate(
        c.kCGSessionEventTap,
        c.kCGHeadInsertEventTap,
        c.kCGEventTapOptionDefault,
        mask,
        hotkeyTapCallback,
        null,
    );
    const tap = g_tap_port orelse return;

    const tap_source = c.CFMachPortCreateRunLoopSource(null, tap, 0) orelse return;
    defer c.CFRelease(@ptrCast(tap_source));

    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), tap_source, c.kCFRunLoopCommonModes);
    c.CGEventTapEnable(tap, true);
}

fn ipcSourceTick(context: ?*anyopaque) callconv(.c) void {
    const fd_raw = @intFromPtr(context orelse return);
    const server_fd: c_int = @intCast(fd_raw);
    bw_handle_ipc_client(server_fd);
}

fn initIpcSource(server_fd: c_int) void {
    if (g_ipc_source) |source| {
        c.dispatch_source_cancel(source);
        g_ipc_source = null;
    }

    const source = c.dispatch_source_create(
        c.DISPATCH_SOURCE_TYPE_READ,
        @intCast(server_fd),
        0,
        c.dispatch_get_main_queue(),
    );
    if (source == null) return;

    c.dispatch_set_context(.{ ._ds = source }, @ptrFromInt(@as(usize, @intCast(server_fd))));
    c.dispatch_source_set_event_handler_f(source, ipcSourceTick);
    c.dispatch_resume(.{ ._ds = source });
    g_ipc_source = source;
}

fn cancelIpcSource() void {
    if (g_ipc_source) |source| {
        c.dispatch_source_cancel(source);
        g_ipc_source = null;
    }
}

/// Signal the main run loop to drain queued events.
export fn bw_signal_waker() void {
    signalWaker();
}

/// Enable or disable periodic role polling.
export fn bw_set_role_polling(enabled: bool) void {
    setRolePolling(enabled);
}

// ---------------------------------------------------------------------------
// Event bridge (called from ObjC shim)
// ---------------------------------------------------------------------------

// Single-producer (main thread) only — all ObjC emitters must dispatch
// on the main queue so the ring buffer stays SPSC.
export fn bw_emit_event(kind: u8, pid: i32, wid: u32) void {
    std.debug.assert(c.pthread_main_np() != 0);
    g_ring.push(.{
        .kind = @enumFromInt(kind),
        .pid = pid,
        .wid = wid,
    });
    signalWaker();
}

/// Callback target for BWObserver.appTerminated: selector.
export fn bw_workspace_app_terminated(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_TERMINATED, pid, 0);
}

/// Callback target for BWObserver.appLaunched: selector.
export fn bw_workspace_app_launched(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_LAUNCHED, pid, 0);
}

/// Callback target for BWObserver.activeAppChanged: selector.
export fn bw_workspace_active_app_changed(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_WINDOW_FOCUSED, pid, 0);
}

/// Callback target for BWObserver.spaceChanged: selector.
export fn bw_workspace_space_changed() void {
    bw_emit_event(shim.BW_EVENT_SPACE_CHANGED, 0, 0);
}

/// Callback target for BWObserver.displayChanged: selector.
export fn bw_workspace_display_changed() void {
    bw_emit_event(shim.BW_EVENT_DISPLAY_CHANGED, 0, 0);
}

/// Callback target for shim hotkey mouse down events.
export fn bw_hotkey_mouse_down() void {
    bw_emit_event(shim.BW_EVENT_MOUSE_DOWN, 0, 0);
}

/// Callback target for shim hotkey mouse up events.
export fn bw_hotkey_mouse_up() void {
    bw_emit_event(shim.BW_EVENT_MOUSE_UP, 0, 0);
}

/// Accept keybind table from config and keep it in Zig-owned state.
export fn bw_set_keybinds(binds: ?[*]const shim.bw_keybind, count: u32) void {
    if (count == 0) {
        g_hotkey_binding_count = 0;
        return;
    }

    const src = binds orelse {
        g_hotkey_binding_count = 0;
        return;
    };

    const max_count: u32 = @intCast(g_hotkey_bindings.len);
    const clamped_count_u32: u32 = @min(count, max_count);
    const clamped_count: usize = @intCast(clamped_count_u32);

    @memcpy(g_hotkey_bindings[0..clamped_count], src[0..clamped_count]);
    g_hotkey_binding_count = clamped_count_u32;

    std.debug.assert(g_hotkey_binding_count <= max_count);
}

/// Resolve a key press against current keybinds and emit matching action.
export fn bw_hotkey_handle_keydown(keycode: u16, mods: u8) bool {
    const total: usize = @intCast(g_hotkey_binding_count);
    std.debug.assert(total <= g_hotkey_bindings.len);

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const binding = g_hotkey_bindings[i];
        if (binding.keycode != keycode) continue;
        if (binding.mods != mods) continue;

        bw_emit_event(binding.action, 0, binding.arg);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// CLI client (sends command to running daemon)
// ---------------------------------------------------------------------------

fn runClient(cmd: []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const started_ns = std.time.nanoTimestamp();
    var response_bytes: usize = 0;

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}) catch {
        stderr.writeAll("error: socket path too long\n") catch {};
        return;
    };

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        stderr.writeAll("error: could not create socket\n") catch {};
        return;
    };
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    if (path.len < addr.path.len) addr.path[path.len] = 0;

    log.debug("[trace] ipc client connecting path={s} cmd={s}", .{ path, cmd });

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        stderr.writeAll("error: bobrwm is not running\n") catch {};
        return;
    };

    _ = posix.write(fd, cmd) catch {
        stderr.writeAll("error: write failed\n") catch {};
        return;
    };
    posix.shutdown(fd, .send) catch {};

    while (true) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, 2000) catch {
            stderr.writeAll("error: IPC poll failed\n") catch {};
            break;
        };
        if (ready == 0) {
            stderr.writeAll("error: IPC response timeout\n") catch {};
            log.warn("ipc client timeout waiting for response cmd={s}", .{cmd});
            break;
        }

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        response_bytes += n;
        stdout.writeAll(buf[0..n]) catch break;
    }

    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] ipc client completed bytes={} elapsed_ms={}", .{ response_bytes, elapsed_ms });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    // -- Arg parsing (before anything else) --
    var cmd_buf: [512]u8 = undefined;
    const args = config_mod.parseArgs(&cmd_buf);

    // Service management: handle locally (not via IPC)
    if (args.command) |cmd| {
        if (std.mem.eql(u8, cmd, "service") or std.mem.startsWith(u8, cmd, "service ")) {
            if (parseServiceCommand(cmd)) |service_cmd| {
                launchd.run(service_cmd);
            } else {
                std.fs.File.stderr().writeAll(
                    "usage: bobrwm service <install|uninstall|start|stop|restart>\n",
                ) catch {};
            }
            return;
        }
    }

    // Client mode: forward command to running daemon via IPC
    if (args.command) |cmd| {
        runClient(cmd);
        return;
    }

    // -- Daemon mode --
    log.info("bobrwm starting (log_level={s})...", .{@tagName(std_options.log_level)});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();
    defer deinitAxStrings();

    // -- Config --
    g_config = config_mod.load(g_allocator, args.config_path);
    g_config.applyKeybinds();

    // -- Accessibility check --
    if (!shim.bw_ax_is_trusted()) {
        log.warn("accessibility not trusted — prompting user", .{});
        log.warn("after granting access, restart with: bobrwm service restart", .{});
        axPrompt();
    }

    // -- SkyLight (optional) --
    g_sky = skylight.SkyLight.init();

    // -- Core state --
    g_store = window_mod.WindowStore.init(g_allocator);
    defer g_store.deinit();
    g_workspaces = workspace_mod.WorkspaceManager.init(g_allocator);
    defer g_workspaces.deinit();
    clearLayoutRoots();
    g_tab_groups = tabgroup.TabGroupManager.init(g_allocator);
    defer g_tab_groups.deinit();
    g_pending_role_windows = PendingRoleWindowMap.init(g_allocator);
    errdefer g_pending_role_windows.deinit();
    g_pending_role_windows.ensureTotalCapacity(pending_role_window_capacity) catch |err| {
        log.err("pending-role map reserve failed: {}", .{err});
        return err;
    };
    g_deferred_window_candidates = DeferredWindowCandidateMap.init(g_allocator);
    errdefer g_deferred_window_candidates.deinit();
    g_deferred_window_candidates.ensureTotalCapacity(deferred_window_candidate_capacity) catch |err| {
        log.err("deferred-window map reserve failed: {}", .{err});
        return err;
    };
    g_app_launch_retries = AppLaunchRetryMap.init(g_allocator);
    errdefer g_app_launch_retries.deinit();
    g_app_launch_retries.ensureTotalCapacity(app_launch_retry_capacity) catch |err| {
        log.err("app-launch-retry map reserve failed: {}", .{err});
        return err;
    };
    defer {
        setRolePolling(false);
        g_app_launch_retries.deinit();
        g_deferred_window_candidates.deinit();
        g_pending_role_windows.deinit();
    }
    refreshDisplays();

    // -- Apply workspace names from config --
    for (g_config.workspace_names, 0..) |name, i| {
        if (i >= workspace_mod.max_workspaces) break;
        g_workspaces.workspaces[i].name = name;
    }

    // -- Crash handlers (restore hidden windows on abnormal exit) --
    installCrashHandlers();
    errdefer restoreAllWindows();

    // -- Discover existing windows and tile --
    discoverWindows();
    log.info("discovered {} windows", .{g_store.count()});
    retileAllDisplays();

    // -- IPC server --
    g_ipc = ipc.Server.init(g_allocator) catch |err| {
        log.err("IPC init failed: {}", .{err});
        return err;
    };
    defer cancelIpcSource();
    defer g_ipc.deinit(g_allocator);
    ipc.g_dispatch = ipcDispatch;

    // -- NSApp (zig-objc) --
    const NSApp = initApp();
    initWorkspaceObservers();

    // -- Sources (observers, CGEventTap, waker, IPC) --
    ax_observer.init();
    defer ax_observer.deinit();
    setupHotkeyEventTap();
    initWakerSource();
    initIpcSource(@intCast(g_ipc.fd));
    refreshRolePolling();
    observeDiscoveredApps();

    // -- Status bar (zig-objc) --
    statusbar.init();
    const active = g_workspaces.active();
    statusbar.setTitle(active.name, active.id);

    // -- Enter NSApp run loop (never returns) --
    log.info("entering run loop", .{});
    defer restoreAllWindows();
    NSApp.msgSend(void, "run", .{});
}

// ---------------------------------------------------------------------------
// Exported callbacks (called from ObjC shim on main thread)
// ---------------------------------------------------------------------------

/// Drain the event ring buffer — called by the CFRunLoopSource waker.
export fn bw_drain_events() void {
    while (g_ring.pop()) |ev| {
        handleEvent(&ev);
    }
}

/// Accept and handle one IPC client connection — called by dispatch_source.
export fn bw_handle_ipc_client(server_fd: c_int) void {
    const client_fd = posix.accept(@intCast(server_fd), null, null, 0) catch |err| {
        log.err("accept failed: {}", .{err});
        return;
    };
    defer posix.close(client_fd);
    const started_ns = std.time.nanoTimestamp();

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| {
        log.err("IPC read: {}", .{err});
        return;
    };
    if (n == 0) return;

    const cmd = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ', 0 });
    if (cmd.len == 0) return;
    log.debug("[trace] ipc recv fd={} bytes={} cmd={s}", .{ client_fd, n, cmd });

    if (ipc.g_dispatch) |dispatch| {
        dispatch(cmd, client_fd);
        const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
        log.debug("[trace] ipc handled fd={} cmd={s} elapsed_ms={}", .{ client_fd, cmd, elapsed_ms });
    } else {
        log.warn("ipc dispatch callback missing", .{});
    }
}

/// Clean shutdown — called from status bar Quit action.
export fn bw_will_quit() void {
    restoreAllWindows();
}

/// Retile — called from status bar Retile action.
export fn bw_retile() void {
    retile();
}

fn layoutRootPtr(workspace_id: u8, display_id: u32) ?*?layout.Node {
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    const slot = displayIndexById(display_id) orelse return null;
    const ws_idx: usize = workspace_id - 1;
    return &g_layout_roots[ws_idx][slot];
}

fn removeFromLayout(workspace_id: u8, display_id: u32, wid: u32) void {
    const root_ptr = layoutRootPtr(workspace_id, display_id) orelse return;
    const root = root_ptr.* orelse return;
    root_ptr.* = layout.removeWindow(root, wid, g_allocator);
}

fn insertIntoLayout(workspace_id: u8, display_id: u32, wid: u32) void {
    const root_ptr = layoutRootPtr(workspace_id, display_id) orelse return;
    const updated = layout.insertWindow(root_ptr.*, wid, g_next_split_dir, g_allocator) catch return;
    root_ptr.* = updated;
}

fn clearDragPreview() void {
    if (g_drag_preview.visible) {
        tile_preview.hide();
    }
    g_drag_preview = .{};
}

fn displayContentFrame(display_id: u32) ?window_mod.Window.Frame {
    const display_slot = displayIndexById(display_id) orelse return null;
    const display = g_displays[display_slot].visible;
    const outer = g_config.gaps.outer;
    return .{
        .x = display.x + @as(f64, @floatFromInt(outer.left)),
        .y = display.y + @as(f64, @floatFromInt(outer.top)),
        .width = display.w - @as(f64, @floatFromInt(@as(u32, outer.left) + @as(u32, outer.right))),
        .height = display.h - @as(f64, @floatFromInt(@as(u32, outer.top) + @as(u32, outer.bottom))),
    };
}

fn frameContainsPoint(frame: window_mod.Window.Frame, point_x: f64, point_y: f64) bool {
    return point_x >= frame.x and
        point_x <= frame.x + frame.width and
        point_y >= frame.y and
        point_y <= frame.y + frame.height;
}

fn findDropTargetInLayout(
    node: layout.Node,
    frame: window_mod.Window.Frame,
    inner_gap: f64,
    dragged_wid: u32,
    center_x: f64,
    center_y: f64,
    workspace_id: u8,
    display_id: u32,
) ?DropTarget {
    std.debug.assert(inner_gap >= 0);
    switch (node) {
        .leaf => |leaf| {
            if (leaf.wid == dragged_wid) return null;
            if (!frameContainsPoint(frame, center_x, center_y)) return null;
            const target = g_store.get(leaf.wid) orelse return null;
            if (target.mode != .tiled or target.is_fullscreen) return null;
            if (target.workspace_id != workspace_id or target.display_id != display_id) return null;
            return .{ .wid = leaf.wid, .frame = frame };
        },
        .split => |split| {
            const half_gap = inner_gap / 2.0;
            var left_frame = frame;
            var right_frame = frame;

            switch (split.direction) {
                .horizontal => {
                    const left_width = frame.width * split.ratio;
                    left_frame.width = left_width - half_gap;
                    right_frame.x = frame.x + left_width + half_gap;
                    right_frame.width = frame.width - left_width - half_gap;
                },
                .vertical => {
                    const top_height = frame.height * split.ratio;
                    left_frame.height = top_height - half_gap;
                    right_frame.y = frame.y + top_height + half_gap;
                    right_frame.height = frame.height - top_height - half_gap;
                },
            }

            if (frameContainsPoint(left_frame, center_x, center_y)) {
                if (findDropTargetInLayout(split.left, left_frame, inner_gap, dragged_wid, center_x, center_y, workspace_id, display_id)) |target| {
                    return target;
                }
            }
            if (frameContainsPoint(right_frame, center_x, center_y)) {
                if (findDropTargetInLayout(split.right, right_frame, inner_gap, dragged_wid, center_x, center_y, workspace_id, display_id)) |target| {
                    return target;
                }
            }
            return null;
        },
    }
}

fn updateWindowMovePreview(wid: u32) void {
    const win = g_store.get(wid) orelse {
        clearDragPreview();
        return;
    };

    if (win.mode != .tiled or win.is_fullscreen) {
        clearDragPreview();
        return;
    }
    if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) {
        clearDragPreview();
        return;
    }

    const root_ptr = layoutRootPtr(win.workspace_id, win.display_id) orelse {
        clearDragPreview();
        return;
    };
    const root = root_ptr.* orelse {
        clearDragPreview();
        return;
    };
    const display_frame = displayContentFrame(win.display_id) orelse {
        clearDragPreview();
        return;
    };

    const center_x = win.frame.x + win.frame.width / 2.0;
    const center_y = win.frame.y + win.frame.height / 2.0;
    const target_entry = findDropTargetInLayout(
        root,
        display_frame,
        @floatFromInt(g_config.gaps.inner),
        wid,
        center_x,
        center_y,
        win.workspace_id,
        win.display_id,
    );

    g_drag_preview.source_wid = wid;

    if (target_entry) |entry| {
        const target_changed = g_drag_preview.target_wid == null or g_drag_preview.target_wid.? != entry.wid;
        g_drag_preview.target_wid = entry.wid;
        if (!g_drag_preview.visible or target_changed) {
            tile_preview.show(entry.frame.x, entry.frame.y, entry.frame.width, entry.frame.height);
            g_drag_preview.visible = true;
        }
        return;
    }

    g_drag_preview.target_wid = null;
    if (g_drag_preview.visible) {
        tile_preview.hide();
        g_drag_preview.visible = false;
    }
}

fn commitWindowMovePreview(wid: u32) void {
    if (g_drag_preview.source_wid == null or g_drag_preview.source_wid.? != wid) return;
    defer clearDragPreview();

    const source = g_store.get(wid) orelse return;
    if (source.mode != .tiled or source.is_fullscreen) return;

    const target_wid = g_drag_preview.target_wid orelse {
        // Drag ended without crossing another tiled slot, so snap the window
        // back to its managed frame instead of waiting for a later retile.
        retile();
        return;
    };
    if (target_wid == wid) return;

    const target = g_store.get(target_wid) orelse return;
    if (source.mode != .tiled or target.mode != .tiled) return;
    if (source.is_fullscreen or target.is_fullscreen) return;
    if (source.workspace_id != target.workspace_id) return;
    if (source.display_id != target.display_id) return;

    const root_ptr = layoutRootPtr(source.workspace_id, source.display_id) orelse return;
    if (root_ptr.*) |*root| {
        if (layout.swapWindowIds(root, wid, target_wid)) {
            log.info("window move swap wid={d} target={d}", .{ wid, target_wid });
            retile();
        }
    }
}

fn retile() void {
    clearDragPreview();
    retileAllDisplays();
}

// ---------------------------------------------------------------------------
// Event handling
// ---------------------------------------------------------------------------

fn handleEvent(ev: *const event_mod.Event) void {
    switch (ev.kind) {
        // -- Window / app events --
        .app_launched => {
            log.info("app launched pid={}", .{ev.pid});
            discoverWindows();
            ax_observer.observeApp(ev.pid);
            trackAppLaunchRetry(ev.pid);
            retile();
        },
        .app_terminated => {
            log.info("app terminated pid={}", .{ev.pid});
            untrackAppLaunchRetry(ev.pid);
            ax_observer.unobserveApp(ev.pid);
            removeAppWindows(ev.pid);
            retile();
        },
        .window_focused => {
            log.info("window focused pid={}", .{ev.pid});
            const removed_stale = cleanupWorkspaceWindowsForPid(ev.pid);
            const removed_offscreen = cleanupOffscreenManagedWindows();
            const wid = shim.bw_ax_get_focused_window(ev.pid);
            if (wid != 0) {
                if (g_store.get(wid) == null) {
                    ax_observer.observeApp(ev.pid);
                    discoverWindows();
                    retile();
                }
                // Track leader in workspace, not raw active tab
                const leader = g_tab_groups.resolveLeader(wid);
                if (g_store.get(leader)) |win| {
                    setFocusedDisplay(win.display_id);
                    if (g_workspaces.get(win.workspace_id)) |ws| {
                        ws.focused_wid = leader;
                    }
                }
            }
            if (removed_stale or removed_offscreen) {
                retile();
            }
        },
        .focused_window_changed => {
            log.info("focused window changed pid={}", .{ev.pid});
            const removed_stale = cleanupWorkspaceWindowsForPid(ev.pid);
            const removed_offscreen = cleanupOffscreenManagedWindows();
            reconcileAppTabs(ev.pid);
            if (removed_stale or removed_offscreen) {
                retile();
            }
        },
        .window_created => {
            log.info("window created pid={} wid={}", .{ ev.pid, ev.wid });
            addNewWindow(ev.pid, ev.wid);
            retile();
        },
        .window_destroyed => {
            log.info("window destroyed wid={}", .{ev.wid});
            removeWindow(ev.wid);
            retile();
        },
        .window_minimized => {
            log.info("window minimized wid={}", .{ev.wid});
            removeWindow(ev.wid);
            retile();
        },
        .window_deminimized => {
            log.info("window deminimized wid={}", .{ev.wid});
            discoverWindows();
            retile();
        },
        .display_changed => {
            if (!shouldHandleWorkspaceEvent(&g_last_display_changed_at_s)) return;
            log.info("display changed", .{});
            reconcileDisplayChange();
            discoverWindows();
            retile();
        },
        .space_changed => {
            if (!shouldHandleWorkspaceEvent(&g_last_space_changed_at_s)) return;
            log.info("space changed", .{});
        },
        .role_poll_tick => {
            const promoted_pending = processPendingRoleWindows();
            const promoted_deferred = processDeferredWindowCandidates();
            const retried_launch = processAppLaunchRetries();
            if (promoted_pending or promoted_deferred or retried_launch) {
                retile();
            }
        },
        .mouse_down => {
            g_mouse_left_down = true;
        },
        .mouse_up => {
            g_mouse_left_down = false;
            if (g_drag_preview.source_wid) |source_wid| {
                commitWindowMovePreview(source_wid);
            } else {
                clearDragPreview();
            }
        },
        .window_moved, .window_resized => {
            log.info("window {s} wid={}", .{
                if (ev.kind == .window_moved) "moved" else "resized",
                ev.wid,
            });
            if (updateWindowDisplayAssignment(ev.wid)) {
                retile();
                return;
            }
            // Snap fullscreen windows back to display frame
            if (g_store.get(ev.wid)) |win| {
                if (win.is_fullscreen) {
                    retile();
                    return;
                }
            }
            checkTabDragOut(ev.pid, ev.wid);
            if (ev.kind == .window_moved) {
                // Ignore synthetic move events generated by our own retile calls.
                if (g_mouse_left_down) {
                    updateWindowMovePreview(ev.wid);
                }
            } else {
                clearDragPreview();
            }
        },

        // -- Hotkey actions --
        .hk_focus_workspace => {
            const target: u8 = @intCast(ev.wid);
            log.info("hotkey: focus workspace {}", .{target});
            switchWorkspace(target);
        },
        .hk_move_to_workspace => {
            const target: u8 = @intCast(ev.wid);
            log.info("hotkey: move to workspace {}", .{target});
            moveWindowToWorkspace(target);
        },
        .hk_focus_left => focusDirection(.left),
        .hk_focus_right => focusDirection(.right),
        .hk_focus_up => focusDirection(.up),
        .hk_focus_down => focusDirection(.down),
        .hk_toggle_split => {
            g_next_split_dir = switch (g_next_split_dir) {
                .horizontal => .vertical,
                .vertical => .horizontal,
            };
            log.info("split direction: {s}", .{@tagName(g_next_split_dir)});
        },
        .hk_toggle_fullscreen => {
            const ws = g_workspaces.active();
            const focused = ws.focused_wid orelse return;
            var win = g_store.get(focused) orelse return;
            win.is_fullscreen = !win.is_fullscreen;
            g_store.put(win) catch {};
            log.info("fullscreen {s} wid={d}", .{
                if (win.is_fullscreen) "on" else "off", focused,
            });
            retile();
        },
        .hk_toggle_float => {
            const ws = g_workspaces.active();
            const focused = ws.focused_wid orelse return;
            const win = g_store.get(focused) orelse return;
            const target: window_mod.WindowMode = if (win.mode != .tiled) .tiled else .floating;
            setWindowMode(focused, target);
        },
    }
}

// ---------------------------------------------------------------------------
// Window mode (tiled / floating / fullscreen)
// ---------------------------------------------------------------------------

fn setWindowMode(wid: u32, target: window_mod.WindowMode) void {
    var win = g_store.get(wid) orelse return;
    const old = win.mode;
    if (old == target) return;

    // Leaving tiled → remove from BSP so remaining windows fill the space
    if (old == .tiled) {
        removeFromLayout(win.workspace_id, win.display_id, wid);
    }

    // Entering tiled → re-insert into BSP
    if (target == .tiled) {
        insertIntoLayout(win.workspace_id, win.display_id, wid);
    }

    win.mode = target;
    g_store.put(win) catch {};
    log.info("window {d} mode: {s} → {s}", .{ wid, @tagName(old), @tagName(target) });
    retile();
}

// ---------------------------------------------------------------------------
// Window management helpers
// ---------------------------------------------------------------------------

fn windowRoleState(pid: i32, wid: u32) WindowRoleState {
    std.debug.assert(wid != 0);
    const raw_state = shim.bw_window_manage_state(pid, wid);
    return switch (raw_state) {
        shim.BW_MANAGE_REJECT => .reject,
        shim.BW_MANAGE_READY => .ready,
        shim.BW_MANAGE_PENDING => .pending,
        else => {
            log.warn("pending-role: unknown manage state pid={d} wid={d} state={d}", .{ pid, wid, raw_state });
            return .pending;
        },
    };
}

fn refreshRolePolling() void {
    const has_pending = g_pending_role_windows.count() > 0 or
        g_deferred_window_candidates.count() > 0 or
        g_app_launch_retries.count() > 0;
    setRolePolling(has_pending);
}

fn trackAppLaunchRetry(pid: i32) void {
    std.debug.assert(pid > 0);

    if (g_app_launch_retries.getPtr(pid)) |attempts_remaining| {
        attempts_remaining.* = app_launch_retry_attempts_max;
    } else {
        g_app_launch_retries.put(pid, app_launch_retry_attempts_max) catch {
            log.err("app-launch-retry: failed to track pid={d}", .{pid});
            return;
        };
    }

    refreshRolePolling();
}

fn untrackAppLaunchRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    if (g_app_launch_retries.remove(pid)) {
        refreshRolePolling();
    }
}

fn processAppLaunchRetries() bool {
    if (g_app_launch_retries.count() == 0) {
        refreshRolePolling();
        return false;
    }

    var retry_pids: [64]i32 = undefined;
    var retry_count: usize = 0;
    var truncated = false;

    var it = g_app_launch_retries.iterator();
    while (it.next()) |entry| {
        const pid = entry.key_ptr.*;
        std.debug.assert(pid > 0);

        if (entry.value_ptr.* == 0) {
            if (retry_count == retry_pids.len) {
                truncated = true;
                break;
            }
            retry_pids[retry_count] = pid;
            retry_count += 1;
        } else {
            entry.value_ptr.* -= 1;
        }
    }

    for (retry_pids[0..retry_count]) |pid| {
        _ = g_app_launch_retries.remove(pid);
    }
    refreshRolePolling();

    if (truncated) {
        log.warn("app-launch-retry: batch truncated remaining={d}", .{g_app_launch_retries.count()});
    }

    if (retry_count == 0) return false;

    for (retry_pids[0..retry_count]) |pid| {
        log.info("app-launch-retry: retrying discovery for pid={d}", .{pid});
        ax_observer.observeApp(pid);
    }
    discoverWindows();
    return true;
}

fn trackPendingRoleWindow(pid: i32, wid: u32) void {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) return;

    if (g_pending_role_windows.getPtr(wid)) |pending| {
        pending.pid = pid;
        pending.attempts_remaining = role_poll_attempts_max;
    } else {
        g_pending_role_windows.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
        }) catch {
            log.err("pending-role: failed to track pid={d} wid={d}", .{ pid, wid });
            return;
        };
    }

    refreshRolePolling();
}

fn untrackPendingRoleWindow(wid: u32) void {
    std.debug.assert(wid != 0);
    if (g_pending_role_windows.remove(wid)) {
        refreshRolePolling();
    }
}

/// Remove all entries matching `pid` from a wid-keyed map whose values
/// carry a `.pid` field. Batched to avoid iterator invalidation.
fn removeEntriesForPid(comptime V: type, map: *std.AutoHashMap(u32, V), pid: i32) bool {
    var removed_any = false;

    while (true) {
        var remove_batch: [64]u32 = undefined;
        var remove_count: usize = 0;

        var it = map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pid != pid) continue;
            if (remove_count == remove_batch.len) break;
            remove_batch[remove_count] = entry.key_ptr.*;
            remove_count += 1;
        }

        if (remove_count == 0) break;

        for (remove_batch[0..remove_count]) |wid| {
            if (map.remove(wid)) {
                removed_any = true;
            }
        }

        if (remove_count < remove_batch.len) break;
    }

    return removed_any;
}

fn untrackPendingRoleWindowsForPid(pid: i32) void {
    if (removeEntriesForPid(PendingRoleWindow, &g_pending_role_windows, pid)) {
        refreshRolePolling();
    }
}

fn trackDeferredWindowCandidate(pid: i32, wid: u32) void {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) {
        if (g_deferred_window_candidates.remove(wid)) {
            refreshRolePolling();
        }
        return;
    }

    if (g_deferred_window_candidates.getPtr(wid)) |candidate| {
        candidate.pid = pid;
        candidate.attempts_remaining = role_poll_attempts_max;
    } else {
        g_deferred_window_candidates.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
        }) catch {
            log.err("deferred-window: failed to track pid={d} wid={d}", .{ pid, wid });
            return;
        };
    }

    refreshRolePolling();
}

fn untrackDeferredWindowCandidate(wid: u32) void {
    std.debug.assert(wid != 0);
    if (g_deferred_window_candidates.remove(wid)) {
        refreshRolePolling();
    }
}

fn untrackDeferredWindowCandidatesForPid(pid: i32) void {
    if (removeEntriesForPid(DeferredWindowCandidate, &g_deferred_window_candidates, pid)) {
        refreshRolePolling();
    }
}

fn addNewWindowLegacyPendingFallback(pid: i32, wid: u32) bool {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) return false;
    if (!shim.bw_should_manage_window(pid, wid)) {
        log.debug("pending-role: fallback rejected pid={d} wid={d}", .{ pid, wid });
        return false;
    }
    return addNewWindowManaged(pid, wid);
}

fn processPendingRoleWindows() bool {
    if (g_pending_role_windows.count() == 0) {
        refreshRolePolling();
        return false;
    }

    var remove_wids: [128]u32 = undefined;
    var remove_count: usize = 0;
    var candidates: [128]PendingRoleCandidate = undefined;
    var candidate_count: usize = 0;
    var truncated = false;

    var it = g_pending_role_windows.iterator();
    while (it.next()) |entry| {
        const wid = entry.key_ptr.*;
        const pid = entry.value_ptr.pid;

        const state = windowRoleState(pid, wid);
        switch (state) {
            .reject => {
                if (remove_count == remove_wids.len) {
                    truncated = true;
                    break;
                }
                remove_wids[remove_count] = wid;
                remove_count += 1;
            },
            .ready => {
                if (remove_count == remove_wids.len or candidate_count == candidates.len) {
                    truncated = true;
                    break;
                }
                remove_wids[remove_count] = wid;
                remove_count += 1;
                candidates[candidate_count] = .{ .pid = pid, .wid = wid, .from_timeout = false };
                candidate_count += 1;
            },
            .pending => {
                if (entry.value_ptr.attempts_remaining == 0) {
                    if (remove_count == remove_wids.len or candidate_count == candidates.len) {
                        truncated = true;
                        break;
                    }
                    remove_wids[remove_count] = wid;
                    remove_count += 1;
                    candidates[candidate_count] = .{ .pid = pid, .wid = wid, .from_timeout = true };
                    candidate_count += 1;
                } else {
                    entry.value_ptr.attempts_remaining -= 1;
                }
            },
        }
    }

    for (remove_wids[0..remove_count]) |wid| {
        _ = g_pending_role_windows.remove(wid);
    }
    refreshRolePolling();

    if (truncated) {
        log.warn("pending-role: batch truncated remaining={d}", .{g_pending_role_windows.count()});
    }

    var added_any = false;
    for (candidates[0..candidate_count]) |candidate| {
        if (candidate.from_timeout) {
            const timeout_ms = @as(u64, role_poll_attempts_max) * role_poll_interval_ms;
            log.info("pending-role: timeout pid={d} wid={d} after {d}ms, applying legacy fallback", .{ candidate.pid, candidate.wid, timeout_ms });
            if (addNewWindowLegacyPendingFallback(candidate.pid, candidate.wid)) {
                added_any = true;
            }
            continue;
        }

        if (addNewWindowManaged(candidate.pid, candidate.wid)) {
            added_any = true;
        }
    }

    return added_any;
}

fn processDeferredWindowCandidates() bool {
    if (g_deferred_window_candidates.count() == 0) {
        refreshRolePolling();
        return false;
    }

    var remove_wids: [128]u32 = undefined;
    var remove_count: usize = 0;
    var promote_candidates: [128]DeferredWindowPromotion = undefined;
    var promote_count: usize = 0;
    var truncated = false;
    const timeout_ms = @as(u64, role_poll_attempts_max) * role_poll_interval_ms;

    var it = g_deferred_window_candidates.iterator();
    while (it.next()) |entry| {
        const wid = entry.key_ptr.*;
        const pid = entry.value_ptr.pid;

        if (g_store.get(wid) != null) {
            if (remove_count == remove_wids.len) {
                truncated = true;
                break;
            }
            remove_wids[remove_count] = wid;
            remove_count += 1;
            continue;
        }

        switch (windowRoleState(pid, wid)) {
            .reject => {
                if (remove_count == remove_wids.len) {
                    truncated = true;
                    break;
                }
                remove_wids[remove_count] = wid;
                remove_count += 1;
            },
            .pending => {
                if (entry.value_ptr.attempts_remaining == 0) {
                    if (remove_count == remove_wids.len) {
                        truncated = true;
                        break;
                    }
                    remove_wids[remove_count] = wid;
                    remove_count += 1;
                    log.info("deferred-window: timeout pid={d} wid={d} after {d}ms while role is pending", .{ pid, wid, timeout_ms });
                } else {
                    entry.value_ptr.attempts_remaining -= 1;
                }
            },
            .ready => {
                if (isVisibleOnScreen(wid)) {
                    if (remove_count == remove_wids.len or promote_count == promote_candidates.len) {
                        truncated = true;
                        break;
                    }
                    remove_wids[remove_count] = wid;
                    remove_count += 1;
                    promote_candidates[promote_count] = .{ .pid = pid, .wid = wid };
                    promote_count += 1;
                } else {
                    if (entry.value_ptr.attempts_remaining == 0) {
                        if (remove_count == remove_wids.len) {
                            truncated = true;
                            break;
                        }
                        remove_wids[remove_count] = wid;
                        remove_count += 1;
                        log.info("deferred-window: timeout pid={d} wid={d} after {d}ms while still off-screen", .{ pid, wid, timeout_ms });
                    } else {
                        entry.value_ptr.attempts_remaining -= 1;
                    }
                }
            },
        }
    }

    for (remove_wids[0..remove_count]) |wid| {
        _ = g_deferred_window_candidates.remove(wid);
    }
    refreshRolePolling();

    if (truncated) {
        log.warn("deferred-window: batch truncated remaining={d}", .{g_deferred_window_candidates.count()});
    }

    var added_any = false;
    for (promote_candidates[0..promote_count]) |candidate| {
        if (addNewWindowManaged(candidate.pid, candidate.wid)) {
            added_any = true;
        }
    }
    return added_any;
}

fn discoverWindows() void {
    var buf: [256]shim.bw_window_info = undefined;
    const count = shim.bw_discover_windows(&buf, 256);
    var observed_pids: [128]i32 = undefined;
    var observed_pid_count: usize = 0;

    // Sort windows by current x-position so the BSP tree order matches
    // their on-screen placement. Without this, windows discovered in
    // arbitrary order get swapped to the opposite side on the first retile.
    const slice = buf[0..count];
    std.mem.sortUnstable(shim.bw_window_info, slice, {}, struct {
        fn lessThan(_: void, a: shim.bw_window_info, b: shim.bw_window_info) bool {
            return a.x < b.x;
        }
    }.lessThan);

    for (slice) |info| {
        std.debug.assert(info.pid > 0);

        var already_observed = false;
        for (observed_pids[0..observed_pid_count]) |observed_pid| {
            if (observed_pid == info.pid) {
                already_observed = true;
                break;
            }
        }

        // Observe the owning app even if this specific window is not yet
        // manageable (for example AX role/subrole is still pending).
        if (!already_observed) {
            ax_observer.observeApp(info.pid);
            if (observed_pid_count < observed_pids.len) {
                observed_pids[observed_pid_count] = info.pid;
                observed_pid_count += 1;
            }
        }

        if (g_store.get(info.wid) != null) continue;

        switch (windowRoleState(info.pid, info.wid)) {
            .reject => {
                untrackPendingRoleWindow(info.wid);
                continue;
            },
            .pending => {
                trackPendingRoleWindow(info.pid, info.wid);
                continue;
            },
            .ready => {
                untrackPendingRoleWindow(info.wid);
                untrackDeferredWindowCandidate(info.wid);
            },
        }

        const frame: window_mod.Window.Frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h };
        const display_id = displayIdForFrame(frame);
        const target_ws = resolveWorkspace(info.pid, display_id);

        const win = window_mod.Window{
            .wid = info.wid,
            .pid = info.pid,
            .title = null,
            .frame = frame,
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = target_ws.id,
            .display_id = display_id,
        };

        g_store.put(win) catch continue;
        target_ws.addWindow(info.wid) catch continue;
        insertIntoLayout(target_ws.id, display_id, info.wid);

        // If assigned to a non-visible workspace, hide immediately
        if (!workspaceVisibleOnDisplay(target_ws.id, display_id)) {
            hideWindow(info.pid, info.wid);
        }
    }

    // Ensure a focused window is set on the active workspace
    const active_ws = g_workspaces.active();
    if (active_ws.focused_wid == null and active_ws.windows.items.len > 0) {
        active_ws.focused_wid = active_ws.windows.items[0];
    }
}

/// Guards tab inference against standalone window creation races.
/// If another managed on-screen sibling already occupies the same frame,
/// the focused/created window should be treated as a standalone window.
fn hasOnScreenMatchingManagedSibling(
    pid: i32,
    exclude_wid: u32,
    target_frame: window_mod.Window.Frame,
    sky: skylight.SkyLight,
    conn: c_int,
) bool {
    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        const candidate_wid = entry.key_ptr.*;
        const candidate = entry.value_ptr.*;
        if (candidate_wid == exclude_wid) continue;
        if (candidate.pid != pid) continue;
        if (!isVisibleOnScreen(candidate_wid)) continue;

        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(conn, candidate_wid, &rect) != 0) continue;

        const candidate_frame = window_mod.Window.Frame{
            .x = rect.origin.x,
            .y = rect.origin.y,
            .width = rect.size.width,
            .height = rect.size.height,
        };
        const matches = tabgroup.TabGroupManager.framesMatch(candidate_frame, target_frame);
        log.debug("tab-match-guard: candidate wid={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) match={}", .{
            candidate_wid,
            candidate_frame.x,
            candidate_frame.y,
            candidate_frame.width,
            candidate_frame.height,
            matches,
        });

        if (matches) return true;
    }

    return false;
}

fn addNewWindowManaged(pid: i32, wid: u32) bool {
    log.debug("addNewWindow: pid={d} wid={d}", .{ pid, wid });
    if (g_store.get(wid) != null) {
        log.debug("addNewWindow: already in store, skipping", .{});
        return false;
    }

    const on_screen = isVisibleOnScreen(wid);
    log.debug("addNewWindow: on_screen={}", .{on_screen});

    // New windows from Electron-family apps can be created before WindowServer
    // reports them as on-screen. Queue them for bounded re-evaluation rather
    // than dropping them on a one-shot check.
    if (!on_screen) {
        trackDeferredWindowCandidate(pid, wid);
        log.info("addNewWindow: deferred pid={d} wid={d} while off-screen", .{ pid, wid });
        return false;
    }
    defer untrackDeferredWindowCandidate(wid);

    // Check if this new on-screen window replaces an existing same-PID window
    // that just went off-screen (i.e. a new tab was created and became active,
    // pushing the old tab to background). If so, form a tab group.
    if (tryFormTabGroupOnCreate(pid, wid)) return false;

    var window_frame: window_mod.Window.Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var display_id = focusedDisplayId();
    if (g_sky) |sky| {
        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) == 0) {
            window_frame = .{
                .x = rect.origin.x,
                .y = rect.origin.y,
                .width = rect.size.width,
                .height = rect.size.height,
            };
            display_id = displayIdForFrame(window_frame);
        }
    }
    // Non-resizable windows that are undersized (≤500px in either dimension)
    // are floated instead of tiled. This catches transient splash screens and
    // updater dialogs (e.g. Discord Updater at 300x300) that have standard
    // AX roles but are not real application windows.
    const should_float = blk: {
        if (window_frame.width > 500 and window_frame.height > 500) break :blk false;
        const ax_win = findAxWindow(pid, wid) orelse break :blk false;
        defer c.CFRelease(@ptrCast(ax_win));
        const ax = ensureAxStrings() orelse break :blk false;
        break :blk !axCanResize(ax_win, ax);
    };

    const ws = resolveWorkspace(pid, display_id);
    const mode: window_mod.WindowMode = if (should_float) .floating else .tiled;

    const win = window_mod.Window{
        .wid = wid,
        .pid = pid,
        .title = null,
        .frame = window_frame,
        .is_minimized = false,
        .mode = mode,
        .workspace_id = ws.id,
        .display_id = display_id,
    };

    g_store.put(win) catch return false;
    ws.addWindow(wid) catch return false;
    if (mode == .tiled) {
        insertIntoLayout(ws.id, display_id, wid);
    }
    ws.focused_wid = wid;

    // If assigned to a non-visible workspace, hide immediately
    if (!workspaceVisibleOnDisplay(ws.id, display_id)) {
        hideWindow(pid, wid);
    }

    log.info("addNewWindow: {s} wid={d} on workspace {d}", .{
        if (mode == .tiled) "tiled" else "floated (undersized+non-resizable)",
        wid,
        ws.id,
    });
    return true;
}

fn addNewWindow(pid: i32, wid: u32) void {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) return;

    switch (windowRoleState(pid, wid)) {
        .reject => {
            untrackPendingRoleWindow(wid);
            untrackDeferredWindowCandidate(wid);
            log.debug("addNewWindow: role gate rejected pid={d} wid={d}", .{ pid, wid });
        },
        .ready => {
            untrackPendingRoleWindow(wid);
            _ = addNewWindowManaged(pid, wid);
        },
        .pending => {
            trackPendingRoleWindow(pid, wid);
            trackDeferredWindowCandidate(pid, wid);
            log.debug("addNewWindow: role gate pending pid={d} wid={d}", .{ pid, wid });
        },
    }
}

/// When a new on-screen window appears, check if an existing managed window
/// from the same PID just went off-screen. If so, the new window is a tab
/// that replaced the old one — form a tab group instead of tiling independently.
/// Returns true if a tab group was formed (caller should NOT tile the window).
fn tryFormTabGroupOnCreate(pid: i32, new_wid: u32) bool {
    const sky = g_sky orelse return false;
    const conn = sky.mainConnectionID();

    // Get bounds of the new window
    var new_rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, new_wid, &new_rect) != 0) return false;

    const new_frame = window_mod.Window.Frame{
        .x = new_rect.origin.x,
        .y = new_rect.origin.y,
        .width = new_rect.size.width,
        .height = new_rect.size.height,
    };
    log.debug("tryFormTabGroup: new wid={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
        new_wid, new_frame.x, new_frame.y, new_frame.width, new_frame.height,
    });

    if (hasOnScreenMatchingManagedSibling(pid, new_wid, new_frame, sky, conn)) {
        log.debug("tryFormTabGroup: on-screen sibling matches new wid={d}, treating as standalone", .{new_wid});
        return false;
    }

    // Collect stale windows for deferred cleanup — can't call removeWindow
    // while iterating workspace window lists (swapRemove invalidates indices).
    var stale_wids: [64]u32 = undefined;
    var stale_count: usize = 0;
    var formed = false;

    // Scan all workspaces for a same-PID window that is now off-screen
    outer: for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |existing_wid| {
            const existing = g_store.get(existing_wid) orelse continue;
            if (existing.pid != pid) continue;

            const still_on_screen = isVisibleOnScreen(existing_wid);
            log.debug("tryFormTabGroup: existing wid={d} on_screen={} frame=({d:.0},{d:.0},{d:.0},{d:.0})", .{
                existing_wid,         still_on_screen,
                existing.frame.x,     existing.frame.y,
                existing.frame.width, existing.frame.height,
            });

            if (still_on_screen) continue;

            // Verify the window still exists in CG. A destroyed window
            // (e.g. a splash screen, closed dialog) fails the SkyLight
            // lookup — mark for removal so ghost windows don't persist.
            var existing_rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, existing_wid, &existing_rect) != 0) {
                log.debug("tryFormTabGroup: existing wid={d} destroyed (SkyLight lookup failed), queuing removal", .{existing_wid});
                if (stale_count < stale_wids.len) {
                    stale_wids[stale_count] = existing_wid;
                    stale_count += 1;
                }
                continue;
            }

            const existing_sky_frame = window_mod.Window.Frame{
                .x = existing_rect.origin.x,
                .y = existing_rect.origin.y,
                .width = existing_rect.size.width,
                .height = existing_rect.size.height,
            };
            log.debug("tryFormTabGroup: existing wid={d} SkyLight bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
                existing_wid,
                existing_sky_frame.x,
                existing_sky_frame.y,
                existing_sky_frame.width,
                existing_sky_frame.height,
            });

            // Native tab members share the same frame. If bounds diverge
            // this is a different transition (splash→main, popup, etc.).
            if (!tabgroup.TabGroupManager.framesMatch(new_frame, existing_sky_frame)) {
                log.debug("tryFormTabGroup: bounds mismatch with wid={d}, not a tab", .{existing_wid});
                continue;
            }

            // Form tab group: existing_wid is the leader (already in layout),
            // new_wid is a member stored but NOT in the layout tree.
            const group_id = if (g_tab_groups.groupOf(existing_wid)) |g|
                g.id
            else
                g_tab_groups.createGroup(pid, existing_wid, existing.frame) catch break :outer;

            g_tab_groups.addMember(group_id, new_wid) catch break :outer;
            g_tab_groups.setActive(new_wid);

            // Store the new window (suppressed — not in workspace/layout)
            g_store.put(.{
                .wid = new_wid,
                .pid = pid,
                .title = null,
                .frame = new_frame,
                .is_minimized = false,
                .mode = .tiled,
                .workspace_id = ws.id,
                .display_id = existing.display_id,
            }) catch break :outer;

            // Also discover any other background tabs
            var ax_wids: [128]u32 = undefined;
            const ax_count = shim.bw_get_app_window_ids(pid, &ax_wids, 128);
            log.debug("tryFormTabGroup: AX found {d} windows for pid={d}", .{ ax_count, pid });
            for (ax_wids[0..ax_count]) |ax_wid| {
                if (ax_wid == existing_wid or ax_wid == new_wid) continue;
                if (g_store.get(ax_wid) != null) continue;

                var rect: skylight.CGRect = undefined;
                if (sky.getWindowBounds(conn, ax_wid, &rect) != 0) continue;
                const f = window_mod.Window.Frame{
                    .x = rect.origin.x,
                    .y = rect.origin.y,
                    .width = rect.size.width,
                    .height = rect.size.height,
                };

                g_tab_groups.addMember(group_id, ax_wid) catch continue;
                g_store.put(.{
                    .wid = ax_wid,
                    .pid = pid,
                    .title = null,
                    .frame = f,
                    .is_minimized = false,
                    .mode = .tiled,
                    .workspace_id = ws.id,
                    .display_id = existing.display_id,
                }) catch continue;
            }

            ws.focused_wid = existing_wid; // leader stays
            log.info("tryFormTabGroup: formed group leader={d} active={d} members={d}", .{
                existing_wid,
                new_wid,
                if (g_tab_groups.groupOf(existing_wid)) |g| g.members.items.len else 1,
            });
            formed = true;
            break :outer;
        }
    }

    // Remove stale windows whose backing CG window no longer exists.
    // Deferred to here because removeWindow mutates workspace window lists.
    for (stale_wids[0..stale_count]) |stale_wid| {
        log.info("tryFormTabGroup: removing stale window wid={d}", .{stale_wid});
        removeWindow(stale_wid);
    }

    if (!formed) {
        log.debug("tryFormTabGroup: no off-screen sibling found, proceeding as standalone", .{});
    }
    return formed;
}

fn removeWindow(wid: u32) void {
    untrackPendingRoleWindow(wid);
    untrackDeferredWindowCandidate(wid);
    if (g_drag_preview.source_wid == wid or g_drag_preview.target_wid == wid) {
        clearDragPreview();
    }
    // Clean up tab group membership first
    const survivor = g_tab_groups.removeMember(wid);

    const win = g_store.get(wid) orelse return;
    g_store.remove(wid);
    if (g_workspaces.get(win.workspace_id)) |ws| {
        ws.removeWindow(wid);
    }
    removeFromLayout(win.workspace_id, win.display_id, wid);

    // If the group dissolved, restore the survivor to workspace and layout
    if (survivor) |solo_wid| {
        if (g_workspaces.get(win.workspace_id)) |ws| {
            var in_ws = false;
            for (ws.windows.items) |w| {
                if (w == solo_wid) {
                    in_ws = true;
                    break;
                }
            }
            if (!in_ws) {
                log.info("removeWindow: restoring tab survivor wid={d} to workspace", .{solo_wid});
                ws.addWindow(solo_wid) catch {};
                insertIntoLayout(win.workspace_id, win.display_id, solo_wid);
            }
        }
    }
}

fn removeAppWindows(pid: i32) void {
    untrackPendingRoleWindowsForPid(pid);
    untrackDeferredWindowCandidatesForPid(pid);
    clearDragPreview();
    var wids: [128]u32 = undefined;
    var ws_ids: [128]u8 = undefined;
    var display_ids: [128]u32 = undefined;
    var n: usize = 0;

    // Collect managed windows across all workspaces
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (win.pid == pid and n < wids.len) {
                    wids[n] = wid;
                    ws_ids[n] = ws.id;
                    display_ids[n] = win.display_id;
                    n += 1;
                }
            }
        }
    }

    // Also collect suppressed tab members from the store
    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        if (entry.value_ptr.pid == pid and n < wids.len) {
            var already = false;
            for (wids[0..n]) |existing| {
                if (existing == entry.key_ptr.*) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                wids[n] = entry.key_ptr.*;
                ws_ids[n] = entry.value_ptr.workspace_id;
                display_ids[n] = entry.value_ptr.display_id;
                n += 1;
            }
        }
    }

    for (wids[0..n], ws_ids[0..n], display_ids[0..n]) |wid, ws_id, display_id| {
        _ = g_tab_groups.removeMember(wid);
        g_store.remove(wid);
        if (g_workspaces.get(ws_id)) |ws| {
            ws.removeWindow(wid);
        }
        removeFromLayout(ws_id, display_id, wid);
    }
}

/// Remove stale or ineligible managed windows for a single app process.
///
/// This catches cases where AX/WindowServer event ordering misses a
/// destroy notification and a ghost window remains in workspace state.
fn cleanupWorkspaceWindowsForPid(pid: i32) bool {
    const sky = g_sky orelse return false;
    const conn = sky.mainConnectionID();

    var stale_wids: [128]u32 = undefined;
    var stale_count: usize = 0;

    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;
            if (win.pid != pid) continue;

            var should_remove = false;
            var rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, wid, &rect) != 0) {
                should_remove = true;
                log.info("cleanup: removing wid={d} pid={d} reason=missing-windowserver", .{ wid, pid });
            } else if (!shim.bw_should_manage_window(pid, wid)) {
                should_remove = true;
                log.info("cleanup: removing wid={d} pid={d} reason=should-manage=false", .{ wid, pid });
            }

            if (!should_remove) continue;

            var already_queued = false;
            for (stale_wids[0..stale_count]) |existing| {
                if (existing == wid) {
                    already_queued = true;
                    break;
                }
            }
            if (already_queued) continue;

            if (stale_count < stale_wids.len) {
                stale_wids[stale_count] = wid;
                stale_count += 1;
            }
        }
    }

    for (stale_wids[0..stale_count]) |wid| {
        removeWindow(wid);
    }

    return stale_count > 0;
}

/// Remove managed windows that are no longer physically on-screen.
///
/// Some Electron apps (Discord) close-to-background without emitting AX
/// destroy/minimize notifications. This catches those ghost entries.
fn cleanupOffscreenManagedWindows() bool {
    var stale_wids: [128]u32 = undefined;
    var stale_count: usize = 0;

    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;

            // Tab-group members can be intentionally off-screen when a sibling
            // tab is active; treating them as ghosts causes layout churn.
            if (g_tab_groups.groupOf(wid) != null) continue;

            if (shim.bw_is_window_on_screen(wid)) continue;

            var already_queued = false;
            for (stale_wids[0..stale_count]) |existing| {
                if (existing == wid) {
                    already_queued = true;
                    break;
                }
            }
            if (already_queued) continue;

            log.info("cleanup: removing wid={d} pid={d} reason=offscreen", .{ wid, win.pid });
            if (stale_count < stale_wids.len) {
                stale_wids[stale_count] = wid;
                stale_count += 1;
            }
        }
    }

    for (stale_wids[0..stale_count]) |wid| {
        removeWindow(wid);
    }

    return stale_count > 0;
}

/// Updates `display_id` when a moved/resized window crosses monitors.
/// Returns true when display ownership changed and callers should retile.
fn updateWindowDisplayAssignment(wid: u32) bool {
    var win = g_store.get(wid) orelse return false;
    const sky = g_sky orelse return false;

    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) != 0) return false;

    const frame: window_mod.Window.Frame = .{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };
    const next_display_id = displayIdForFrame(frame);
    if (next_display_id == win.display_id) {
        win.frame = frame;
        g_store.put(win) catch {};
        return false;
    }

    removeFromLayout(win.workspace_id, win.display_id, wid);
    win.frame = frame;
    win.display_id = next_display_id;
    g_store.put(win) catch return false;
    if (win.mode == .tiled) {
        insertIntoLayout(win.workspace_id, win.display_id, wid);
    }

    if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) {
        hideWindow(win.pid, wid);
    }
    setFocusedDisplay(win.display_id);
    log.info("window moved to display wid={d} display={d}", .{ wid, win.display_id });
    return true;
}

/// Reconciles workspace/display state after monitor topology changes.
///
/// Existing display IDs keep their active workspace and layout roots. Windows
/// whose previous display disappeared are moved to the primary display's
/// active workspace so they remain reachable.
fn reconcileDisplayChange() void {
    const old_displays = g_displays;
    const old_display_count = g_display_count;
    const old_active_ids = g_workspaces.active_ids_by_display;
    const old_layout_roots = g_layout_roots;

    refreshDisplays();
    clearLayoutRoots();

    for (g_displays[0..g_display_count], 0..) |display, new_slot| {
        var active_id: u8 = 1;
        var found = false;
        for (old_displays[0..old_display_count], 0..) |old_display, old_slot| {
            if (old_display.id == display.id) {
                active_id = old_active_ids[old_slot];
                found = true;
                break;
            }
        }
        if (!found) active_id = 1;
        g_workspaces.setActiveForDisplaySlot(new_slot, active_id);
    }

    for (old_displays[0..old_display_count], 0..) |old_display, old_slot| {
        const new_slot = displayIndexById(old_display.id) orelse continue;
        for (0..workspace_mod.max_workspaces) |ws_idx| {
            if (old_layout_roots[ws_idx][old_slot]) |root| {
                g_layout_roots[ws_idx][new_slot] = root;
            }
        }
    }

    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        var win = entry.value_ptr.*;
        if (displayIndexById(win.display_id) != null) continue;

        if (g_workspaces.get(win.workspace_id)) |old_ws| {
            old_ws.removeWindow(win.wid);
        }
        removeFromLayout(win.workspace_id, win.display_id, win.wid);

        const target_display_id = primaryDisplayId();
        const target_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
        win.display_id = target_display_id;
        win.workspace_id = target_workspace_id;
        entry.value_ptr.* = win;

        if (g_workspaces.get(target_workspace_id)) |target_ws| {
            target_ws.addWindow(win.wid) catch {};
            if (target_ws.focused_wid == null) target_ws.focused_wid = win.wid;
        }
        if (win.mode == .tiled) {
            insertIntoLayout(target_workspace_id, target_display_id, win.wid);
        }
    }
}

fn layoutLeafCount(node: layout.Node) usize {
    return switch (node) {
        .leaf => 1,
        .split => |split| layoutLeafCount(split.left) + layoutLeafCount(split.right),
    };
}

fn retileDisplay(display_id: u32) void {
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    const root_ptr = layoutRootPtr(ws_id, display_id) orelse return;
    const root = root_ptr.* orelse return;
    const display_slot = displayIndexById(display_id) orelse return;
    const display = g_displays[display_slot].visible;

    const outer = g_config.gaps.outer;
    const frame = window_mod.Window.Frame{
        .x = display.x + @as(f64, @floatFromInt(outer.left)),
        .y = display.y + @as(f64, @floatFromInt(outer.top)),
        .width = display.w - @as(f64, @floatFromInt(@as(u32, outer.left) + @as(u32, outer.right))),
        .height = display.h - @as(f64, @floatFromInt(@as(u32, outer.top) + @as(u32, outer.bottom))),
    };

    var stack_buf: [256 * @sizeOf(layout.LayoutEntry)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    var entries: std.ArrayList(layout.LayoutEntry) = .{};
    var entries_allocator = fba.allocator();
    var using_heap_entries = false;
    defer if (using_heap_entries) {
        entries.deinit(g_allocator);
    };

    layout.applyLayout(root, frame, @floatFromInt(g_config.gaps.inner), &entries, entries_allocator) catch |err| {
        if (err != error.OutOfMemory) return;

        const leaf_count = layoutLeafCount(root);
        std.debug.assert(leaf_count > 0);

        entries = .{};
        entries.ensureTotalCapacity(g_allocator, leaf_count) catch {
            log.err("retile: fallback reserve failed display={d} leaves={d}", .{ display_id, leaf_count });
            return;
        };
        using_heap_entries = true;
        entries_allocator = g_allocator;

        layout.applyLayout(root, frame, @floatFromInt(g_config.gaps.inner), &entries, entries_allocator) catch {
            log.err("retile: fallback apply failed display={d} leaves={d}", .{ display_id, leaf_count });
            return;
        };

        log.warn("retile: stack layout buffer overflowed display={d} leaves={d}", .{ display_id, leaf_count });
    };

    for (entries.items) |entry| {
        const win = g_store.get(entry.wid) orelse continue;
        if (win.display_id != display_id) continue;
        if (win.workspace_id != ws_id) continue;

        // Fullscreen windows fill the outer-gap-inset frame, skipping BSP splits and inner gaps
        const target_frame = if (win.is_fullscreen) frame else entry.frame;

        _ = shim.bw_ax_set_window_frame(
            win.pid,
            entry.wid,
            target_frame.x,
            target_frame.y,
            target_frame.width,
            target_frame.height,
        );
        // Two-pass for fullscreen to handle macOS size clamping
        if (win.is_fullscreen) {
            _ = shim.bw_ax_set_window_frame(
                win.pid,
                entry.wid,
                target_frame.x,
                target_frame.y,
                target_frame.width,
                target_frame.height,
            );
        }
        var updated = win;
        updated.frame = target_frame;
        g_store.put(updated) catch {};

        // If this is a tab group leader, apply the same frame to all members
        if (g_tab_groups.groupOfMut(entry.wid)) |g| {
            if (g.leader_wid == entry.wid) {
                g.canonical_frame = entry.frame;
                for (g.members.items) |member_wid| {
                    if (member_wid == entry.wid) continue;
                    if (g_store.get(member_wid)) |member| {
                        _ = shim.bw_ax_set_window_frame(
                            member.pid,
                            member_wid,
                            entry.frame.x,
                            entry.frame.y,
                            entry.frame.width,
                            entry.frame.height,
                        );
                        var m_updated = member;
                        m_updated.frame = entry.frame;
                        g_store.put(m_updated) catch {};
                    }
                }
            }
        }
    }
}

fn retileAllDisplays() void {
    for (g_displays[0..g_display_count]) |display| {
        retileDisplay(display.id);
    }
}

fn observeDiscoveredApps() void {
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                ax_observer.observeApp(win.pid);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Crash / exit recovery — restore all hidden windows to screen center
// ---------------------------------------------------------------------------

fn restoreAllWindows() void {
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (workspaceVisibleOnDisplay(ws.id, win.display_id)) continue;
                const display_slot = displayIndexById(win.display_id) orelse continue;
                const display = g_displays[display_slot].visible;
                // Place at screen center with stored size (or sensible default)
                const w = if (win.frame.width > 1) win.frame.width else display.w * 0.5;
                const h = if (win.frame.height > 1) win.frame.height else display.h * 0.5;
                const x = display.x + (display.w - w) / 2.0;
                const y = display.y + (display.h - h) / 2.0;
                _ = shim.bw_ax_set_window_frame(win.pid, wid, x, y, w, h);
            }
        }
    }
}

fn crashSignalHandler(sig: c_int) callconv(.c) void {
    restoreAllWindows();

    // Re-raise with default handler so the OS produces a core dump / correct exit code
    const sig_u8: u8 = @intCast(sig);
    var default_sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig_u8, &default_sa, null);
    posix.raise(sig_u8) catch {};
}

fn installCrashHandlers() void {
    const signals = [_]u8{
        posix.SIG.INT,  posix.SIG.TERM,
        posix.SIG.HUP,  posix.SIG.QUIT,
        posix.SIG.ABRT, posix.SIG.SEGV,
        posix.SIG.BUS,  posix.SIG.TRAP,
    };

    for (signals) |sig| {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = crashSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESETHAND, // one-shot: avoid infinite re-entry
        };
        posix.sigaction(sig, &sa, null);
    }
}

// ---------------------------------------------------------------------------
// Tab group reconciliation
// ---------------------------------------------------------------------------

/// Called on kAXFocusedWindowChangedNotification — detects tab switches and
/// forms/updates tab groups so only the active tab occupies a layout slot.
fn reconcileAppTabs(pid: i32) void {
    const focused_wid = shim.bw_ax_get_focused_window(pid);
    log.debug("reconcile: pid={d} focused_wid={d}", .{ pid, focused_wid });
    if (focused_wid == 0) {
        log.debug("reconcile: focused_wid=0, aborting", .{});
        return;
    }

    const in_store = g_store.get(focused_wid) != null;
    const suppressed = g_tab_groups.isSuppressed(focused_wid);
    const in_group = g_tab_groups.groupOf(focused_wid) != null;
    log.debug("reconcile: wid={d} in_store={} suppressed={} in_group={}", .{
        focused_wid, in_store, suppressed, in_group,
    });

    // Case 1: focused wid is already managed and not suppressed → just update
    if (in_store and !suppressed) {
        g_tab_groups.setActive(focused_wid);
        const leader = g_tab_groups.resolveLeader(focused_wid);
        if (g_store.get(leader)) |win| {
            setFocusedDisplay(win.display_id);
            if (g_workspaces.get(win.workspace_id)) |ws| {
                ws.focused_wid = leader;
            }
        }
        log.debug("reconcile case 1: known window, leader={d}", .{leader});
        return;
    }

    // Case 2: focused wid is suppressed → tab switch within existing group
    if (suppressed) {
        g_tab_groups.setActive(focused_wid);
        const leader = g_tab_groups.resolveLeader(focused_wid);
        if (g_store.get(leader)) |win| {
            setFocusedDisplay(win.display_id);
            if (g_workspaces.get(win.workspace_id)) |ws| {
                ws.focused_wid = leader;
            }
        }
        log.info("reconcile case 2: tab switch, active={d} leader={d}", .{ focused_wid, leader });
        return;
    }

    // Case 3: focused wid is unknown — new tab becoming active, or new window.
    log.debug("reconcile case 3: unknown wid={d}, checking bounds", .{focused_wid});

    const sky = g_sky orelse {
        log.debug("reconcile: no SkyLight, falling back to addNewWindow", .{});
        addNewWindow(pid, focused_wid);
        retile();
        return;
    };
    const conn = sky.mainConnectionID();

    var focused_rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, focused_wid, &focused_rect) != 0) {
        log.debug("reconcile: SkyLight.getWindowBounds failed for wid={d}", .{focused_wid});
        addNewWindow(pid, focused_wid);
        retile();
        return;
    }

    const focused_frame = window_mod.Window.Frame{
        .x = focused_rect.origin.x,
        .y = focused_rect.origin.y,
        .width = focused_rect.size.width,
        .height = focused_rect.size.height,
    };
    log.debug("reconcile: focused bounds x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
        focused_frame.x, focused_frame.y, focused_frame.width, focused_frame.height,
    });

    const on_screen = isVisibleOnScreen(focused_wid);
    log.debug("reconcile: on_screen={}", .{on_screen});

    if (hasOnScreenMatchingManagedSibling(pid, focused_wid, focused_frame, sky, conn)) {
        log.debug("reconcile: on-screen sibling matches focused wid={d}, treating as new window", .{focused_wid});
        addNewWindow(pid, focused_wid);
        retile();
        return;
    }

    // Look for a managed off-screen window (in any workspace) with the same
    // PID and matching bounds. Matching an on-screen sibling is not a native
    // tab transition signal because standalone windows can share the same
    // tiled frame during focus/create event races.
    var matching_wid: ?u32 = null;
    var matching_ws_id: u8 = 0;
    var matching_display_id: u32 = 0;
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (win.pid == pid) {
                    const candidate_on_screen = isVisibleOnScreen(wid);
                    const matches = tabgroup.TabGroupManager.framesMatch(win.frame, focused_frame);
                    log.debug("reconcile: candidate wid={d} ws={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) on_screen={} match={}", .{
                        wid,
                        ws.id,
                        win.frame.x,
                        win.frame.y,
                        win.frame.width,
                        win.frame.height,
                        candidate_on_screen,
                        matches,
                    });
                    if (matches and !candidate_on_screen) {
                        matching_wid = wid;
                        matching_ws_id = ws.id;
                        matching_display_id = win.display_id;
                        break;
                    }
                }
            }
        }
        if (matching_wid != null) break;
    }

    if (matching_wid) |managed_wid| {
        log.debug("reconcile: matched managed_wid={d} ws={d} → forming tab group", .{
            managed_wid, matching_ws_id,
        });

        const group_id = if (g_tab_groups.groupOf(managed_wid)) |g|
            g.id
        else
            g_tab_groups.createGroup(pid, managed_wid, focused_frame) catch return;

        g_tab_groups.addMember(group_id, focused_wid) catch return;
        g_tab_groups.setActive(focused_wid);

        g_store.put(.{
            .wid = focused_wid,
            .pid = pid,
            .title = null,
            .frame = focused_frame,
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = matching_ws_id,
            .display_id = matching_display_id,
        }) catch return;

        // Discover additional background tabs
        var ax_wids: [128]u32 = undefined;
        const ax_count = shim.bw_get_app_window_ids(pid, &ax_wids, 128);
        log.debug("reconcile: AX enumeration found {d} windows for pid={d}", .{ ax_count, pid });
        for (ax_wids[0..ax_count]) |ax_wid| {
            if (ax_wid == managed_wid or ax_wid == focused_wid) continue;
            if (g_store.get(ax_wid) != null) continue;

            var rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, ax_wid, &rect) != 0) {
                log.debug("reconcile: SkyLight.getWindowBounds failed for ax_wid={d}", .{ax_wid});
                continue;
            }

            const f = window_mod.Window.Frame{
                .x = rect.origin.x,
                .y = rect.origin.y,
                .width = rect.size.width,
                .height = rect.size.height,
            };
            const bg_match = tabgroup.TabGroupManager.framesMatch(f, focused_frame);
            log.debug("reconcile: bg tab ax_wid={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) match={}", .{
                ax_wid, f.x, f.y, f.width, f.height, bg_match,
            });
            if (!bg_match) continue;

            g_tab_groups.addMember(group_id, ax_wid) catch continue;
            g_store.put(.{
                .wid = ax_wid,
                .pid = pid,
                .title = null,
                .frame = f,
                .is_minimized = false,
                .mode = .tiled,
                .workspace_id = matching_ws_id,
                .display_id = matching_display_id,
            }) catch continue;
        }

        const leader = g_tab_groups.resolveLeader(focused_wid);
        if (g_workspaces.get(matching_ws_id)) |ws| {
            ws.focused_wid = leader;
        }
        setFocusedDisplay(matching_display_id);

        log.info("reconcile: tab group formed leader={d} active={d} members={d}", .{
            leader,
            focused_wid,
            if (g_tab_groups.groupOf(leader)) |g| g.members.items.len else 1,
        });
    } else {
        log.debug("reconcile: no matching managed window, treating as new window", .{});
        addNewWindow(pid, focused_wid);
        retile();
    }
}

/// Called on window_moved / window_resized — detects tab drag-out.
/// When a suppressed tab's bounds diverge from its group's canonical frame,
/// promote it to a standalone tiled window.
fn checkTabDragOut(_: i32, wid: u32) void {
    const g = g_tab_groups.groupOfMut(wid) orelse return;
    if (g.active_wid == wid) return; // only check suppressed members

    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();
    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, wid, &rect) != 0) return;

    const frame = window_mod.Window.Frame{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };

    if (tabgroup.TabGroupManager.framesMatch(frame, g.canonical_frame)) return;

    // Bounds diverged — this tab was dragged out to a standalone window
    if (!isVisibleOnScreen(wid)) return; // still off-screen, not a drag-out

    log.info("tab drag-out detected: wid={d} promoted to standalone", .{wid});
    const survivor = g_tab_groups.removeMember(wid);

    // Update stored frame and add to workspace + layout
    if (g_store.get(wid)) |win| {
        var updated = win;
        updated.frame = frame;
        updated.display_id = displayIdForFrame(frame);
        g_store.put(updated) catch return;
    }

    const win = g_store.get(wid) orelse return;
    const ws = g_workspaces.get(win.workspace_id) orelse return;
    ws.addWindow(wid) catch return;
    insertIntoLayout(win.workspace_id, win.display_id, wid);
    ws.focused_wid = wid;
    setFocusedDisplay(win.display_id);

    // If the group dissolved, verify the survivor is still managed
    if (survivor) |solo_wid| {
        var in_ws = false;
        for (ws.windows.items) |w| {
            if (w == solo_wid) {
                in_ws = true;
                break;
            }
        }
        if (!in_ws) {
            log.info("drag-out: restoring survivor wid={d} to workspace", .{solo_wid});
            ws.addWindow(solo_wid) catch {};
            insertIntoLayout(win.workspace_id, win.display_id, solo_wid);
        }
    }

    retile();
}

// ---------------------------------------------------------------------------
// Workspace resolution (config-based app → workspace mapping)
// ---------------------------------------------------------------------------

/// Return the workspace a window should be placed on, checking
/// config workspace_assignments by bundle ID before falling back
/// to the active workspace for the target display.
fn resolveWorkspace(pid: i32, display_id: u32) *workspace_mod.Workspace {
    if (g_config.workspace_assignments.len > 0) {
        var id_buf: [256]u8 = undefined;
        if (config_mod.getAppBundleId(pid, &id_buf)) |bundle_id| {
            if (g_config.workspaceForApp(bundle_id)) |ws_id| {
                if (g_workspaces.get(ws_id)) |ws| return ws;
            }
        }
    }
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    return g_workspaces.get(ws_id) orelse g_workspaces.active();
}

// ---------------------------------------------------------------------------
// Workspace switching
// ---------------------------------------------------------------------------

fn switchWorkspace(target_id: u8) void {
    const display_id = focusedDisplayId();
    const display_slot = displayIndexById(display_id) orelse return;
    const current_id = g_workspaces.activeIdForDisplaySlot(display_slot);
    if (target_id == current_id) return;

    const target_ws = g_workspaces.get(target_id) orelse return;
    const old_ws = g_workspaces.get(current_id) orelse return;

    // Hide current workspace windows (move to safe bottom corner, keep size)
    const hctx = HideCtx.init(display_id);
    for (old_ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            if (win.display_id != display_id) continue;
            hctx.hide(win.pid, wid);
        }
    }

    // Activate target
    g_workspaces.setActiveForDisplaySlot(display_slot, target_id);

    retile();
    statusbar.setTitle(target_ws.name, target_ws.id);

    // Focus the remembered window on the target workspace
    var focus_wid = target_ws.focused_wid;
    if (focus_wid) |fwid| {
        if (g_store.get(fwid)) |win| {
            if (win.display_id != display_id) focus_wid = null;
        } else {
            focus_wid = null;
        }
    }
    if (focus_wid == null) {
        for (target_ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;
            if (win.display_id == display_id) {
                focus_wid = wid;
                break;
            }
        }
    }
    if (focus_wid) |fwid| {
        const actual_wid = g_tab_groups.resolveActive(fwid);
        if (g_store.get(actual_wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, actual_wid);
            target_ws.focused_wid = fwid;
        }
    }
}

fn moveWindowToWorkspace(target_id: u8) void {
    const display_id = focusedDisplayId();
    const current_ws_id = activeWorkspaceIdForDisplay(display_id);
    const ws = g_workspaces.get(current_ws_id) orelse return;
    var wid_opt = ws.focused_wid;
    if (wid_opt) |focused_wid| {
        if (g_store.get(focused_wid)) |focused_win| {
            if (focused_win.display_id != display_id or focused_win.workspace_id != ws.id) {
                wid_opt = null;
            }
        } else {
            wid_opt = null;
        }
    }
    if (wid_opt == null) {
        for (ws.windows.items) |candidate_wid| {
            const candidate = g_store.get(candidate_wid) orelse continue;
            if (candidate.display_id == display_id and candidate.workspace_id == ws.id) {
                wid_opt = candidate_wid;
                break;
            }
        }
    }
    const wid = wid_opt orelse return;
    if (target_id == ws.id) return;
    const target_ws = g_workspaces.get(target_id) orelse return;

    // Remove from current workspace BSP + list
    ws.removeWindow(wid);
    removeFromLayout(ws.id, display_id, wid);

    var updated = g_store.get(wid) orelse return;

    // Add to target workspace BSP + list
    target_ws.addWindow(wid) catch return;
    if (updated.mode == .tiled) {
        insertIntoLayout(target_id, display_id, wid);
    }
    if (target_ws.focused_wid == null) {
        target_ws.focused_wid = wid;
    }

    // Update window's workspace_id
    updated.workspace_id = target_id;
    updated.display_id = display_id;
    g_store.put(updated) catch {};

    // If target is not visible, hide the window
    if (!workspaceVisibleOnDisplay(target_id, display_id)) {
        if (g_store.get(wid)) |win| {
            hideWindow(win.pid, wid);
        }
    }

    retile();
}

/// Moves the focused tiled/floating window to another display slot while
/// preserving its workspace assignment.
fn moveWindowToDisplay(target_display_slot: u8) void {
    if (target_display_slot == 0) return;
    const slot: usize = @intCast(target_display_slot - 1);
    if (slot >= g_display_count) return;

    const source_display_id = focusedDisplayId();
    const target_display_id = g_displays[slot].id;
    if (source_display_id == target_display_id) return;

    const ws_id = activeWorkspaceIdForDisplay(source_display_id);
    const ws = g_workspaces.get(ws_id) orelse return;
    var wid_opt = ws.focused_wid;
    if (wid_opt) |focused_wid| {
        if (g_store.get(focused_wid)) |focused_win| {
            if (focused_win.workspace_id != ws_id or focused_win.display_id != source_display_id) {
                wid_opt = null;
            }
        } else {
            wid_opt = null;
        }
    }
    if (wid_opt == null) {
        for (ws.windows.items) |candidate_wid| {
            const candidate = g_store.get(candidate_wid) orelse continue;
            if (candidate.workspace_id == ws_id and candidate.display_id == source_display_id) {
                wid_opt = candidate_wid;
                break;
            }
        }
    }
    const wid = wid_opt orelse return;
    var win = g_store.get(wid) orelse return;
    if (win.workspace_id != ws_id) return;
    if (win.display_id != source_display_id) return;

    removeFromLayout(win.workspace_id, win.display_id, wid);
    win.display_id = target_display_id;
    g_store.put(win) catch return;
    if (win.mode == .tiled) {
        insertIntoLayout(win.workspace_id, win.display_id, wid);
    }

    if (!workspaceVisibleOnDisplay(win.workspace_id, target_display_id)) {
        hideWindow(win.pid, win.wid);
    }

    setFocusedDisplay(target_display_id);
    retile();
}

// ---------------------------------------------------------------------------
// Focus direction
// ---------------------------------------------------------------------------

const FocusDir = enum { left, right, up, down };

fn focusDirection(dir: FocusDir) void {
    const ws = g_workspaces.active();
    const focused_wid = ws.focused_wid orelse return;
    const focused = g_store.get(focused_wid) orelse return;

    const fc_x = focused.frame.x + focused.frame.width / 2.0;
    const fc_y = focused.frame.y + focused.frame.height / 2.0;

    var best_wid: ?u32 = null;
    var best_dist: f64 = std.math.inf(f64);

    for (ws.windows.items) |wid| {
        if (wid == focused_wid) continue;
        const win = g_store.get(wid) orelse continue;
        if (win.display_id != focused.display_id) continue;

        const wc_x = win.frame.x + win.frame.width / 2.0;
        const wc_y = win.frame.y + win.frame.height / 2.0;

        const dx = wc_x - fc_x;
        const dy = wc_y - fc_y;

        const in_direction = switch (dir) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };
        if (!in_direction) continue;

        const dist = @abs(dx) + @abs(dy);
        if (dist < best_dist) {
            best_dist = dist;
            best_wid = wid;
        }
    }

    if (best_wid) |wid| {
        // If target is a tab group leader, focus the active tab instead
        const actual_wid = g_tab_groups.resolveActive(wid);
        if (g_store.get(actual_wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, actual_wid);
            ws.focused_wid = wid; // track the leader
            setFocusedDisplay(win.display_id);
        }
    }
}

// ---------------------------------------------------------------------------
// Service command parsing
// ---------------------------------------------------------------------------

fn parseServiceCommand(cmd: []const u8) ?launchd.Command {
    const prefix = "service ";
    if (!std.mem.startsWith(u8, cmd, prefix)) return null;
    const sub = cmd[prefix.len..];
    return std.meta.stringToEnum(launchd.Command, sub);
}

// ---------------------------------------------------------------------------
// IPC command dispatch
// ---------------------------------------------------------------------------

fn ipcDispatch(cmd: []const u8, client_fd: posix.socket_t) void {
    const started_ns = std.time.nanoTimestamp();
    defer {
        const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
        log.debug("[trace] ipc dispatch cmd={s} elapsed_ms={}", .{ cmd, elapsed_ms });
    }

    if (std.mem.eql(u8, cmd, "retile")) {
        retile();
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.eql(u8, cmd, "toggle-split")) {
        g_next_split_dir = switch (g_next_split_dir) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "focus-workspace ")) {
        const arg = cmd["focus-workspace ".len..];
        const n = std.fmt.parseInt(u8, arg, 10) catch {
            ipc.writeResponse(client_fd, "err: invalid workspace number\n");
            return;
        };
        switchWorkspace(n);
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "move-to-workspace ")) {
        const arg = cmd["move-to-workspace ".len..];
        const n = std.fmt.parseInt(u8, arg, 10) catch {
            ipc.writeResponse(client_fd, "err: invalid workspace number\n");
            return;
        };
        moveWindowToWorkspace(n);
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "move-to-display ")) {
        const arg = cmd["move-to-display ".len..];
        const n = std.fmt.parseInt(u8, arg, 10) catch {
            ipc.writeResponse(client_fd, "err: invalid display number\n");
            return;
        };
        moveWindowToDisplay(n);
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "focus ")) {
        const dir_str = cmd["focus ".len..];
        if (std.mem.eql(u8, dir_str, "left")) {
            focusDirection(.left);
        } else if (std.mem.eql(u8, dir_str, "right")) {
            focusDirection(.right);
        } else if (std.mem.eql(u8, dir_str, "up")) {
            focusDirection(.up);
        } else if (std.mem.eql(u8, dir_str, "down")) {
            focusDirection(.down);
        } else {
            ipc.writeResponse(client_fd, "err: expected left|right|up|down\n");
            return;
        }
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.eql(u8, cmd, "query windows")) {
        ipcQueryWindows(client_fd);
    } else if (std.mem.eql(u8, cmd, "query workspaces")) {
        ipcQueryWorkspaces(client_fd);
    } else if (std.mem.eql(u8, cmd, "query displays")) {
        ipcQueryDisplays(client_fd);
    } else if (std.mem.eql(u8, cmd, "query apps")) {
        ipcQueryApps(client_fd);
    } else {
        ipc.writeResponse(client_fd, "err: unknown command\n");
    }
}

fn ipcQueryWindows(fd: posix.socket_t) void {
    const started_ns = std.time.nanoTimestamp();
    const ws = g_workspaces.active();
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    var written: usize = 0;

    for (ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            var id_buf: [256]u8 = undefined;
            const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
            const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

            w.print("{d} {d} {s} {d} {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{
                win.wid,     win.pid,     bundle_id,       win.workspace_id, win.display_id,
                win.frame.x, win.frame.y, win.frame.width, win.frame.height,
            }) catch break;
            written += 1;
        }
    }

    const payload = fbs.getWritten();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query windows rows={} bytes={} elapsed_ms={}", .{ written, payload.len, elapsed_ms });
}

fn ipcQueryApps(fd: posix.socket_t) void {
    const started_ns = std.time.nanoTimestamp();
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    var seen_pids: [256]i32 = undefined;
    var seen_count: usize = 0;
    var written: usize = 0;

    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                // Deduplicate by PID
                var already = false;
                for (seen_pids[0..seen_count]) |p| {
                    if (p == win.pid) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                if (seen_count >= seen_pids.len) break;
                seen_pids[seen_count] = win.pid;
                seen_count += 1;

                var id_buf: [256]u8 = undefined;
                const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
                const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                w.print("{s}\t{d}\n", .{ bundle_id, win.pid }) catch break;
                written += 1;
            }
        }
    }

    const payload = fbs.getWritten();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query apps rows={} unique_pids={} bytes={} elapsed_ms={}", .{ written, seen_count, payload.len, elapsed_ms });
}

fn ipcQueryWorkspaces(fd: posix.socket_t) void {
    const started_ns = std.time.nanoTimestamp();
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    for (&g_workspaces.workspaces) |*ws| {
        const focused: u32 = ws.focused_wid orelse 0;
        w.print("{d} {s} {d} {d}\n", .{
            ws.id,
            if (workspaceVisibleAnywhere(ws.id)) "visible" else "hidden",
            focused,
            ws.windows.items.len,
        }) catch break;
    }

    const payload = fbs.getWritten();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query workspaces rows={} bytes={} elapsed_ms={}", .{ g_workspaces.workspaces.len, payload.len, elapsed_ms });
}

fn ipcQueryDisplays(fd: posix.socket_t) void {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    for (g_displays[0..g_display_count], 0..) |display, slot| {
        const workspace_id = g_workspaces.activeIdForDisplaySlot(slot);
        w.print("{d} {d} {d:.0} {d:.0} {d:.0} {d:.0} {d}\n", .{
            slot + 1,
            display.id,
            display.visible.x,
            display.visible.y,
            display.visible.w,
            display.visible.h,
            workspace_id,
        }) catch break;
    }

    ipc.writeResponse(fd, fbs.getWritten());
}
