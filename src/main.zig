const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const c = @import("c");
const cg_extra = @import("cg_extra");
const objc = @import("objc");
const shim = @import("shim_api.zig");
const skylight = @import("skylight.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const workspace_mod = @import("workspace.zig");
const tiling = @import("tiling.zig");
const bsp_mod = tiling.bsp_mod;
const ipc = @import("ipc.zig");
const tabgroup = @import("tabgroup.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const statusbar = @import("statusbar.zig");
const tile_preview = @import("tile_preview.zig");
const ax_observer = @import("ax_observer.zig");
const launchd = @import("launchd.zig");
const osutil = @import("osutil.zig");
const objc_classes = @import("objc_classes.zig");

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

/// Monotonic wall clock in nanoseconds. Re-exported from osutil so existing
/// `nanoTimestamp()` call sites in this file keep working unchanged.
const nanoTimestamp = osutil.nanoTimestamp;

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

// Lock-free SPSC ring buffer
//
// Single-producer (main thread) only. All emitters must run on the
// main thread / main queue. The consumer is bw_drain_events, also on
// the main run-loop.

const EventRing = struct {
    const capacity = 1024;

    buf: [capacity]event_mod.Event = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dropped: usize = 0,

    fn push(self: *EventRing, ev: event_mod.Event) void {
        const t = self.tail.load(.acquire);
        const next = (t + 1) % capacity;
        if (next == self.head.load(.acquire)) {
            self.dropped += 1;
            log.err("event ring full, dropped event kind={s} pid={d} wid={d} total_dropped={d}", .{
                @tagName(ev.kind), ev.pid, ev.wid, self.dropped,
            });
            return;
        }
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

// Hidden-window position (bottom-right corner, barely visible)

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
/// Focus query retry budget. Electron apps (Discord) can report no AX
/// focused window for several hundred milliseconds after activation;
/// 10 attempts at the 100ms role-poll cadence covers that window.
const focus_retry_attempts_max: u8 = 10;
/// Capacity reserved for focus retries (pid-keyed, bounded by observers).
const focus_retry_capacity: usize = 64;
/// Debounce workspace/display notifications that can fire in short bursts.
const workspace_event_debounce_interval_s: f64 = 0.05;
/// Hard cap for workspace transition convergence before we fail closed.
const workspace_transition_watchdog_interval_s: f64 = 0.4;

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

const FocusEventSource = enum {
    keyboard,
    drag,
    ax,
};

const WorkspaceTraversalDirection = enum {
    previous,
    next,
};

const HotkeyEvent = struct {
    kind: u8,
    arg: u32,
};

const HotkeyDispatch = union(enum) {
    emit: HotkeyEvent,
    pass_through,
};

const WorkspaceTransitionKind = enum {
    idle,
    switch_workspace,
    move_workspace_to_display,
};

const WorkspaceTransitionCompletionReason = enum {
    none,
    focus_accepted,
    empty_workspace,
};

const WorkspaceTransitionState = struct {
    kind: WorkspaceTransitionKind = .idle,
    epoch: u64 = 0,
    started_at_s: f64 = 0,
    deadline_at_s: f64 = 0,
    target_workspace_id: u8 = 0,
    target_display_id: u32 = 0,

    fn isActive(self: WorkspaceTransitionState) bool {
        return self.kind != .idle;
    }
};

const PendingFocusEntry = struct {
    pid: i32,
    wid: u32,
    source: FocusEventSource,
    sequence: u64,
    workspace_id: u8,
    display_id: u32,
};

const pending_focus_capacity_per_epoch: usize = 16;
const cleanup_pid_capacity_per_drain: usize = 16;

const PendingRoleWindow = struct {
    pid: i32,
    attempts_remaining: u8,
    workspace_id: u8,
    display_id: u32,
};

const PendingRoleCandidate = struct {
    pid: i32,
    wid: u32,
    from_timeout: bool,
    workspace_id: u8,
    display_id: u32,
};

const DeferredWindowCandidate = struct {
    pid: i32,
    attempts_remaining: u8,
    workspace_id: u8,
    display_id: u32,
};

const DeferredWindowPromotion = struct {
    pid: i32,
    wid: u32,
    workspace_id: u8,
    display_id: u32,
};

const PendingRoleWindowMap = std.AutoHashMap(u32, PendingRoleWindow);
const DeferredWindowCandidateMap = std.AutoHashMap(u32, DeferredWindowCandidate);
const AppLaunchRetryMap = std.AutoHashMap(i32, u8);
const FocusRetryMap = std.AutoHashMap(i32, u8);

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
    return &g_ax_strings.?;
}

fn deinitAxStrings() void {
    if (g_ax_strings) |strings| {
        const refs = [_]c.CFStringRef{
            strings.focused_attr,
            strings.fullscreen_button_attr,
            strings.zoom_button_attr,
            strings.minimize_button_attr,
            strings.close_button_attr,
            strings.enhanced_ui_attr,
            strings.modal_attr,
            strings.unknown_subrole,
            strings.dialog_subrole,
            strings.floating_window_subrole,
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

fn workspaceTraversalDirectionFromAction(action: u8) ?WorkspaceTraversalDirection {
    if (action == shim.BW_HK_FOCUS_PREVIOUS_WORKSPACE) return .previous;
    if (action == shim.BW_HK_FOCUS_NEXT_WORKSPACE) return .next;
    return null;
}

fn adjacentWorkspaceId(direction: WorkspaceTraversalDirection) ?u8 {
    std.debug.assert(g_workspaces.workspace_count > 0);
    std.debug.assert(g_workspaces.workspace_count <= workspace_mod.max_workspaces);

    const active_id = g_workspaces.active().id;
    std.debug.assert(active_id > 0 and active_id <= g_workspaces.workspace_count);

    return switch (direction) {
        .previous => if (active_id > 1) active_id - 1 else null,
        .next => if (active_id < g_workspaces.workspace_count) active_id + 1 else null,
    };
}

fn switchAdjacentWorkspace(direction: WorkspaceTraversalDirection) void {
    _ = switchAdjacentWorkspaceHandled(direction);
}

fn switchAdjacentWorkspaceHandled(direction: WorkspaceTraversalDirection) bool {
    const target_id = adjacentWorkspaceId(direction) orelse return false;
    switchWorkspace(target_id);
    return true;
}

fn dispatchForHotkeyBinding(binding: shim.bw_keybind) HotkeyDispatch {
    if (workspaceTraversalDirectionFromAction(binding.action)) |direction| {
        const target_id = adjacentWorkspaceId(direction) orelse return .pass_through;
        return .{ .emit = .{ .kind = shim.BW_HK_FOCUS_WORKSPACE, .arg = @intCast(target_id) } };
    }

    return .{ .emit = .{ .kind = binding.action, .arg = binding.arg } };
}

fn workspaceVisibleOnDisplay(workspace_id: u8, display_id: u32) bool {
    const slot = displayIndexById(display_id) orelse return false;
    return g_workspaces.activeIdForDisplaySlot(slot) == workspace_id;
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

fn frontmostApplicationPid() ?i32 {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return null;
    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    if (workspace.value == null) return null;

    const app = workspace.msgSend(objc.Object, "frontmostApplication", .{});
    if (app.value == null) return null;

    const pid = app.msgSend(i32, "processIdentifier", .{});
    if (pid <= 0) return null;
    return pid;
}

fn focusedWindowIdForPid(pid: i32) ?u32 {
    std.debug.assert(pid > 0);

    const focused_wid = bw_ax_get_focused_window(pid);
    if (focused_wid == 0) return null;

    return focused_wid;
}

fn focusedWindowIdForLoggedEvent(comptime event_name: []const u8, pid: i32) ?u32 {
    const focused_wid = focusedWindowIdForPid(pid);
    log.info(event_name ++ " pid={} wid={}", .{ pid, focused_wid orelse 0 });
    return focused_wid;
}

fn focusedManagedLeaderWindow() ?window_mod.Window {
    const pid = frontmostApplicationPid() orelse return null;
    const focused_wid = focusedWindowIdForPid(pid) orelse return null;

    const leader_wid = g_tab_groups.resolveLeader(focused_wid);
    const leader = g_store.get(leader_wid) orelse return null;
    if (leader.pid != pid) return null;
    return leader;
}

fn clearWorkspaceTransition() void {
    g_workspace_transition = .{
        .epoch = g_workspace_transition.epoch,
    };
    g_workspace_transition_completion_reason = .none;
    g_pending_focus_count = 0;
}

fn markWorkspaceTransitionComplete(reason: WorkspaceTransitionCompletionReason) void {
    if (!g_workspace_transition.isActive()) return;
    if (g_workspace_transition_completion_reason != .none) return;
    std.debug.assert(reason != .none);

    g_workspace_transition_completion_reason = reason;
    const transition = g_workspace_transition;
    log.debug("workspace transition marked complete epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
        transition.epoch,
        @tagName(transition.kind),
        transition.target_workspace_id,
        transition.target_display_id,
        @tagName(reason),
    });
}

fn startWorkspaceTransition(kind: WorkspaceTransitionKind, target_workspace_id: u8, target_display_id: u32) void {
    std.debug.assert(kind != .idle);
    std.debug.assert(target_workspace_id > 0 and target_workspace_id <= g_workspaces.workspace_count);
    std.debug.assert(target_display_id != 0);

    const now_s = c.CFAbsoluteTimeGetCurrent();
    const next_epoch = g_workspace_transition.epoch + 1;
    g_workspace_transition = .{
        .kind = kind,
        .epoch = next_epoch,
        .started_at_s = now_s,
        .deadline_at_s = now_s + workspace_transition_watchdog_interval_s,
        .target_workspace_id = target_workspace_id,
        .target_display_id = target_display_id,
    };
    g_workspace_transition_completion_reason = .none;
    g_pending_focus_count = 0;
    log.debug("workspace transition started epoch={d} kind={s} workspace={d} display={d}", .{
        next_epoch,
        @tagName(kind),
        target_workspace_id,
        target_display_id,
    });
}

fn workspaceTransitionTimedOut() bool {
    if (!g_workspace_transition.isActive()) return false;
    return c.CFAbsoluteTimeGetCurrent() >= g_workspace_transition.deadline_at_s;
}

fn inWorkspaceTransition() bool {
    return g_workspace_transition.isActive();
}

fn shouldAcceptFocusForWindow(win: window_mod.Window, source: FocusEventSource) bool {
    if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) return false;
    if (source == .keyboard) return true;

    if (!g_workspace_transition.isActive()) return true;

    const transition = g_workspace_transition;
    if (win.workspace_id != transition.target_workspace_id) return false;
    if (win.display_id != transition.target_display_id) return false;
    return true;
}

fn pendingFocusInsertOrReplace(entry: PendingFocusEntry) void {
    std.debug.assert(entry.pid > 0);
    std.debug.assert(entry.wid != 0);
    std.debug.assert(entry.workspace_id > 0 and entry.workspace_id <= g_workspaces.workspace_count);
    std.debug.assert(entry.display_id != 0);

    var existing_idx: ?usize = null;
    var oldest_idx: usize = 0;
    var oldest_sequence: u64 = std.math.maxInt(u64);

    var i: usize = 0;
    while (i < g_pending_focus_count) : (i += 1) {
        const existing = g_pending_focus_entries[i];
        // A single process can own multiple windows across workspaces, so the
        // queue must preserve per-window focus intent instead of collapsing by PID.
        if (existing.wid == entry.wid) {
            existing_idx = i;
            break;
        }
        if (existing.sequence < oldest_sequence) {
            oldest_sequence = existing.sequence;
            oldest_idx = i;
        }
    }

    if (existing_idx) |idx| {
        g_pending_focus_entries[idx] = entry;
        return;
    }

    if (g_pending_focus_count < g_pending_focus_entries.len) {
        g_pending_focus_entries[g_pending_focus_count] = entry;
        g_pending_focus_count += 1;
        return;
    }

    g_pending_focus_entries[oldest_idx] = entry;
}

fn queuePendingFocus(win: window_mod.Window, source: FocusEventSource) void {
    if (!g_workspace_transition.isActive()) return;
    if (source == .keyboard) return;
    if (win.pid <= 0) return;

    g_pending_focus_sequence += 1;
    pendingFocusInsertOrReplace(.{
        .pid = win.pid,
        .wid = win.wid,
        .source = source,
        .sequence = g_pending_focus_sequence,
        .workspace_id = win.workspace_id,
        .display_id = win.display_id,
    });
    const transition = g_workspace_transition;
    log.debug("workspace transition pending focus queued epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d} pending={d}", .{
        transition.epoch,
        win.wid,
        win.pid,
        @tagName(source),
        win.workspace_id,
        win.display_id,
        transition.target_workspace_id,
        transition.target_display_id,
        g_pending_focus_count,
    });
}

fn applyPendingFocusEntry(entry: PendingFocusEntry) bool {
    if (!g_workspace_transition.isActive()) return false;
    const transition = g_workspace_transition;
    if (entry.workspace_id != transition.target_workspace_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=workspace-mismatch entry_workspace={d} target_workspace={d}", .{
            transition.epoch,
            entry.wid,
            entry.pid,
            entry.workspace_id,
            transition.target_workspace_id,
        });
        return false;
    }
    if (entry.display_id != transition.target_display_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=display-mismatch entry_display={d} target_display={d}", .{
            transition.epoch,
            entry.wid,
            entry.pid,
            entry.display_id,
            transition.target_display_id,
        });
        return false;
    }

    const win = g_store.get(entry.wid) orelse {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=missing-store", .{
            transition.epoch,
            entry.wid,
            entry.pid,
        });
        return false;
    };
    if (win.pid != entry.pid) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=pid-mismatch store_pid={d}", .{
            transition.epoch,
            entry.wid,
            entry.pid,
            win.pid,
        });
        return false;
    }
    if (win.workspace_id != entry.workspace_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=store-workspace-changed entry_workspace={d} store_workspace={d}", .{
            transition.epoch,
            entry.wid,
            entry.pid,
            entry.workspace_id,
            win.workspace_id,
        });
        return false;
    }
    if (win.display_id != entry.display_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=store-display-changed entry_display={d} store_display={d}", .{
            transition.epoch,
            entry.wid,
            entry.pid,
            entry.display_id,
            win.display_id,
        });
        return false;
    }

    return maybeSetFocusedDisplayForWindow(win, entry.source);
}

fn processPendingFocusQueue() bool {
    if (!g_workspace_transition.isActive()) return false;
    if (g_pending_focus_count == 0) return false;

    var best_idx: ?usize = null;
    var best_sequence: u64 = 0;

    var i: usize = 0;
    while (i < g_pending_focus_count) : (i += 1) {
        const entry = g_pending_focus_entries[i];
        if (entry.sequence > best_sequence) {
            best_sequence = entry.sequence;
            best_idx = i;
        }
    }

    if (best_idx) |idx| {
        const entry = g_pending_focus_entries[idx];
        g_pending_focus_count -= 1;
        g_pending_focus_entries[idx] = g_pending_focus_entries[g_pending_focus_count];
        if (applyPendingFocusEntry(entry)) {
            g_pending_focus_count = 0;
            return true;
        }
    }

    return false;
}

fn maybeSetFocusedDisplayForWindow(win: window_mod.Window, source: FocusEventSource) bool {
    if (!shouldAcceptFocusForWindow(win, source)) {
        if (g_workspace_transition.isActive()) {
            const transition = g_workspace_transition;
            log.debug("workspace transition focus deferred epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d} visible={}", .{
                transition.epoch,
                win.wid,
                win.pid,
                @tagName(source),
                win.workspace_id,
                win.display_id,
                transition.target_workspace_id,
                transition.target_display_id,
                workspaceVisibleOnDisplay(win.workspace_id, win.display_id),
            });
        }
        queuePendingFocus(win, source);
        return false;
    }

    setFocusedDisplay(win.display_id);

    if (g_workspace_transition.isActive()) {
        const transition = g_workspace_transition;
        log.debug("workspace transition focus accepted epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d}", .{
            transition.epoch,
            win.wid,
            win.pid,
            @tagName(source),
            win.workspace_id,
            win.display_id,
            transition.target_workspace_id,
            transition.target_display_id,
        });
        markWorkspaceTransitionComplete(.focus_accepted);
    }

    // Keyboard intent always wins — flush stale queued focus from AX/drag
    // so they don't replay against an old transition epoch.
    if (source == .keyboard and g_workspace_transition.isActive()) {
        g_pending_focus_count = 0;
    }

    return true;
}

fn switchToWindowWorkspaceIfHidden(win: window_mod.Window) void {
    std.debug.assert(win.wid != 0);
    std.debug.assert(win.workspace_id > 0 and win.workspace_id <= workspace_mod.max_workspaces);
    std.debug.assert(win.display_id != 0);

    if (g_workspace_transition.isActive()) return;
    if (workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) return;

    switchWorkspace(win.workspace_id);
}

fn syncFocusStateForWindowId(focused_wid: u32, source: FocusEventSource) bool {
    std.debug.assert(focused_wid != 0);

    const leader = g_tab_groups.resolveLeader(focused_wid);
    std.debug.assert(leader != 0);

    const win = g_store.get(leader) orelse return false;
    std.debug.assert(win.wid == leader);

    // Window ID is the canonical identity. PID-only notifications are resolved
    // before this point so same-process windows do not overwrite each other.
    g_tab_groups.setActive(focused_wid);
    _ = maybeSetFocusedDisplayForWindow(win, source);
    if (g_workspaces.get(win.workspace_id)) |ws| {
        ws.focused_wid = leader;
    }
    switchToWindowWorkspaceIfHidden(win);
    setTilingActive(win.workspace_id, focused_wid);

    return true;
}

fn tickWorkspaceTransitionState() void {
    if (processPendingFocusQueue()) return;

    if (!workspaceTransitionTimedOut()) return;

    const transition = g_workspace_transition;
    if (g_workspace_transition_completion_reason != .none) {
        log.debug("workspace transition completed epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
            transition.epoch,
            @tagName(transition.kind),
            transition.target_workspace_id,
            transition.target_display_id,
            @tagName(g_workspace_transition_completion_reason),
        });
        clearWorkspaceTransition();
        return;
    }

    const front_pid = frontmostApplicationPid() orelse 0;
    const front_wid = if (front_pid > 0) focusedWindowIdForPid(front_pid) orelse 0 else 0;
    const active_workspace_id = activeWorkspaceIdForDisplay(transition.target_display_id);
    log.warn(
        "workspace transition watchdog expired epoch={d} kind={s} workspace={d} display={d} active_workspace={d} focused_display={d} front_pid={d} front_wid={d} pending={d}",
        .{
            transition.epoch,
            @tagName(transition.kind),
            transition.target_workspace_id,
            transition.target_display_id,
            active_workspace_id,
            focusedDisplayId(),
            front_pid,
            front_wid,
            g_pending_focus_count,
        },
    );
    clearWorkspaceTransition();
}

/// Debug-only: verify every display slot has a valid active workspace
/// and no two slots share the same workspace.
fn assertDisplayCoverage() void {
    if (@import("builtin").mode != .Debug) return;
    for (0..g_display_count) |slot| {
        const ws_id = g_workspaces.activeIdForDisplaySlot(slot);
        std.debug.assert(g_workspaces.get(ws_id) != null);
        // No duplicate active workspace across displays
        for (0..g_display_count) |other| {
            if (other == slot) continue;
            std.debug.assert(g_workspaces.activeIdForDisplaySlot(other) != ws_id);
        }
    }
}

fn updateStatusBar() void {
    const focused_slot = g_workspaces.focused_display_slot;
    var entries: [workspace_mod.max_displays]statusbar.DisplayWorkspace = undefined;
    for (0..g_display_count) |slot| {
        const ws_id = g_workspaces.activeIdForDisplaySlot(slot);
        const ws = g_workspaces.get(ws_id) orelse continue;
        entries[slot] = .{
            .name = ws.name,
            .id = ws.id,
            .focused = slot == focused_slot,
        };
    }
    statusbar.setTitleMulti(entries[0..g_display_count]);
}

fn clearTilingStates() void {
    for (0..workspace_mod.max_workspaces) |ws_idx| {
        g_tiling_states[ws_idx] = null;
    }
}

fn destroyAllTilingStates() void {
    for (0..workspace_mod.max_workspaces) |ws_idx| {
        if (g_tiling_states[ws_idx]) |*st| {
            st.deinit(g_allocator);
            g_tiling_states[ws_idx] = null;
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

/// Infer the display a not-yet-managed window belongs on by querying its
/// CG/SkyLight bounds. Returns null if SkyLight isn't initialised or the
/// window has zero-sized bounds (e.g. mid-construction).
///
/// Used by the new-window pipeline so a window born on a non-focused display
/// (the canonical case: a tab torn off and dropped onto another monitor) is
/// assigned to the correct display+workspace instead of inheriting whichever
/// display happened to be focused at creation time.
fn inferDisplayIdForWindow(wid: u32) ?u32 {
    const sky = g_sky orelse return null;
    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) != 0) return null;
    if (rect.size.width <= 0 or rect.size.height <= 0) return null;
    return displayIdForFrame(.{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    });
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
    /// Updates the stored position so retileDisplay detects the move
    /// and won't skip the window via framesEqual on workspace re-activation.
    fn hide(self: HideCtx, pid: i32, wid: u32) void {
        const pos_y = self.display.y + self.display.h - hide_peek;

        if (g_store.get(wid)) |win| {
            if (win.frame.width > 1 and win.frame.height > 1) {
                const pos_x = switch (self.corner) {
                    .bottom_right => self.display.x + self.display.w - hide_peek,
                    .bottom_left => self.display.x - win.frame.width + hide_peek,
                };
                const ok = shim.bw_ax_set_window_frame(pid, wid, pos_x, pos_y, win.frame.width, win.frame.height);
                log.debug("hide window wid={d} pid={d} ok={} x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
                    wid,
                    pid,
                    ok,
                    pos_x,
                    pos_y,
                    win.frame.width,
                    win.frame.height,
                });
                if (!ok) {
                    if (self.hideFocusedFallback(pid, wid, pos_x, pos_y, win.frame.width, win.frame.height)) {
                        return;
                    }
                    log.warn("hide failed wid={d} pid={d}", .{ wid, pid });
                }
                var updated = win;
                updated.frame.x = pos_x;
                updated.frame.y = pos_y;
                g_store.put(updated) catch {};
                return;
            }
        }
        // Window not yet tiled — just move off-screen with minimal size
        const pos_x = switch (self.corner) {
            .bottom_right => self.display.x + self.display.w - hide_peek,
            .bottom_left => self.display.x - 1 + hide_peek,
        };
        const ok = shim.bw_ax_set_window_frame(pid, wid, pos_x, pos_y, 1, 1);
        log.debug("hide window wid={d} pid={d} ok={} x={d:.0} y={d:.0} w=1 h=1", .{
            wid,
            pid,
            ok,
            pos_x,
            pos_y,
        });
        if (!ok) {
            if (!self.hideFocusedFallback(pid, wid, pos_x, pos_y, 1, 1)) {
                log.warn("hide failed wid={d} pid={d}", .{ wid, pid });
            }
        }
    }

    /// Ghostty can replace the active native-tab window ID before Bobrwm has
    /// reconciled focus. If hiding the stored ID fails, hide the app's current
    /// focused AX window at the same off-screen frame so it cannot leak onto
    /// the newly activated empty workspace.
    fn hideFocusedFallback(self: HideCtx, pid: i32, failed_wid: u32, x: f64, y: f64, w: f64, h: f64) bool {
        _ = self;
        std.debug.assert(pid > 0);
        std.debug.assert(failed_wid > 0);
        std.debug.assert(w > 0 and h > 0);

        const focused_wid = focusedWindowIdForPid(pid) orelse return false;
        if (focused_wid == failed_wid) return false;

        const ok = shim.bw_ax_set_window_frame(pid, focused_wid, x, y, w, h);
        log.debug("hide fallback focused window failed_wid={d} focused_wid={d} pid={d} ok={} x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
            failed_wid,
            focused_wid,
            pid,
            ok,
            x,
            y,
            w,
            h,
        });
        if (!ok) return false;

        const replacement_frame: window_mod.Window.Frame = .{
            .x = x,
            .y = y,
            .width = w,
            .height = h,
        };
        return replaceManagedWindowId(failed_wid, focused_wid, replacement_frame);
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

fn framesEqual(lhs: window_mod.Window.Frame, rhs: window_mod.Window.Frame) bool {
    std.debug.assert(lhs.width >= 0 and lhs.height >= 0);
    std.debug.assert(rhs.width >= 0 and rhs.height >= 0);

    // Use 1px tolerance to absorb sub-pixel rounding from CG/AX,
    // avoiding redundant AX SetAttributeValue calls on every retile.
    const tol: f64 = 1.0;
    return @abs(lhs.x - rhs.x) <= tol and
        @abs(lhs.y - rhs.y) <= tol and
        @abs(lhs.width - rhs.width) <= tol and
        @abs(lhs.height - rhs.height) <= tol;
}

// Globals

var g_ring: EventRing = .{};
/// Protects g_ring.push from concurrent AX observer threads.
var g_ring_lock: c.os_unfair_lock_s = .{ ._os_unfair_lock_opaque = 0 };
var g_sky: ?skylight.SkyLight = null;
var g_allocator: std.mem.Allocator = undefined;
var g_store: window_mod.WindowStore = undefined;
var g_workspaces: workspace_mod.WorkspaceManager = undefined;
var g_tiling_states: [workspace_mod.max_workspaces]?tiling.State = undefined;
var g_displays: [workspace_mod.max_displays]DisplayInfo = undefined;
var g_display_count: usize = 0;
var g_bsp_split_mode: tiling.SplitMode = .auto;
var g_tab_groups: tabgroup.TabGroupManager = undefined;
var g_pending_role_windows: PendingRoleWindowMap = undefined;
var g_deferred_window_candidates: DeferredWindowCandidateMap = undefined;
var g_app_launch_retries: AppLaunchRetryMap = undefined;
var g_focus_retries: FocusRetryMap = undefined;
var g_workspace_observer: ?objc.Object = null;
var g_ipc: ipc.Server = undefined;
var g_config: config_mod.Config = .{};
var g_drag_preview: DragPreviewState = .{};
var g_mouse_left_down = false;
var g_drag_reconcile_on_drop = false;
/// PID of the last window we focused via bw_ax_focus_window. Used to detect
/// same-process focus switches that need a delay for Electron compatibility.
var g_last_focused_pid: i32 = 0;
var g_last_space_changed_at_s: f64 = 0;
var g_last_display_changed_at_s: f64 = 0;
var g_hotkey_bindings: [128]shim.bw_keybind = undefined;
var g_hotkey_binding_count: u32 = 0;
var g_waker_source: c.CFRunLoopSourceRef = null;
var g_role_poll_source: c.dispatch_source_t = null;
var g_ipc_source: c.dispatch_source_t = null;
var g_tap_port: c.CFMachPortRef = null;
var g_ax_strings: ?AxStrings = null;
var g_workspace_transition: WorkspaceTransitionState = .{};
var g_workspace_transition_completion_reason: WorkspaceTransitionCompletionReason = .none;
var g_pending_focus_entries: [pending_focus_capacity_per_epoch]PendingFocusEntry = undefined;
var g_pending_focus_count: usize = 0;
var g_pending_focus_sequence: u64 = 0;
var g_layout_entries: std.ArrayList(tiling.LayoutEntry) = .empty;
var g_retile_requested_all_displays = false;
var g_retile_dirty_display_ids: [workspace_mod.max_displays]u32 = [_]u32{0} ** workspace_mod.max_displays;
var g_retile_dirty_display_count: usize = 0;
var g_event_drain_active = false;
var g_cleanup_pending_offscreen = false;
var g_cleanup_pending_pids: [cleanup_pid_capacity_per_drain]i32 = undefined;
var g_cleanup_pending_pid_count: usize = 0;

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

fn clearCleanupRequests() void {
    g_cleanup_pending_offscreen = false;
    g_cleanup_pending_pid_count = 0;
}

fn requestCleanupForPid(pid: i32) void {
    std.debug.assert(pid > 0);

    var i: usize = 0;
    while (i < g_cleanup_pending_pid_count) : (i += 1) {
        if (g_cleanup_pending_pids[i] == pid) return;
    }

    if (g_cleanup_pending_pid_count >= g_cleanup_pending_pids.len) {
        log.warn("cleanup: pid queue saturated, skipping pid={d}", .{pid});
        return;
    }

    g_cleanup_pending_pids[g_cleanup_pending_pid_count] = pid;
    g_cleanup_pending_pid_count += 1;
    std.debug.assert(g_cleanup_pending_pid_count <= g_cleanup_pending_pids.len);
}

fn requestOffscreenCleanup() void {
    g_cleanup_pending_offscreen = true;
}

fn flushCleanupRequests() bool {
    if (g_workspace_transition.isActive()) {
        clearCleanupRequests();
        return false;
    }

    var removed_any = false;

    var i: usize = 0;
    while (i < g_cleanup_pending_pid_count) : (i += 1) {
        const pid = g_cleanup_pending_pids[i];
        if (cleanupWorkspaceWindowsForPid(pid)) {
            removed_any = true;
        }
    }

    if (g_cleanup_pending_offscreen) {
        if (cleanupOffscreenManagedWindows()) {
            removed_any = true;
        }
    }

    clearCleanupRequests();
    return removed_any;
}

// NSApp lifecycle (zig-objc)

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
/// keeping selector callbacks in BWObserver (registered at runtime in objc_classes.zig).
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

    const options: cg_extra.CGWindowListOption =
        cg_extra.kCGWindowListOptionOnScreenOnly | cg_extra.kCGWindowListExcludeDesktopElements;
    const list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse return false;
    defer c.CFRelease(@ptrCast(list));

    const count = c.CFArrayGetCount(list);
    std.debug.assert(count >= 0);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);
        const wid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);

        var wid: u32 = 0;
        const ok = c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid);
        if (ok == 0) continue;
        if (!cgWindowInfoVisible(info)) continue;
        if (wid == target_wid) return true;
    }

    return false;
}

fn cgWindowInfoVisible(info: c.CFDictionaryRef) bool {
    const alpha_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowAlpha) orelse return true;
    const alpha_ref: c.CFNumberRef = @ptrCast(alpha_ref_any);

    var alpha: c.CGFloat = 1;
    const ok = c.CFNumberGetValue(alpha_ref, c.kCFNumberCGFloatType, &alpha);
    if (ok == 0) return true;
    return alpha > 0.01;
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
///
/// When switching between windows within the same process, a 40ms delay is
/// inserted between the raise and the activation. Some apps (notably Electron)
/// get confused by instantaneous same-process focus switches and fail to render
/// the focus ring or route keyboard events to the wrong window. Yabai uses the
/// same 40ms delay for same-PSN switches.
export fn bw_ax_focus_window(pid: i32, wid: u32) bool {
    const same_process_focus_delay_us: c_uint = 40_000; // 40ms, matches yabai

    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findAxWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = ensureAxStrings() orelse return false;
    const raise_action = ax.raise_action;
    const main_attr = ax.main_attr;

    const is_same_process = (g_last_focused_pid == pid);
    g_last_focused_pid = pid;

    _ = c.AXUIElementPerformAction(win, raise_action);
    _ = c.AXUIElementSetAttributeValue(win, main_attr, c.kCFBooleanTrue);

    // Delay activation for same-process switches so the app has time to
    // process the deactivation of the previous window before the new
    // activation arrives.
    if (is_same_process) {
        _ = c.usleep(same_process_focus_delay_us);
    }

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
    // Native open/save panels are app-modal AX windows. They expose enough
    // top-level-window signals to pass the dialog heuristic below, but tiling
    // them resizes the parent app while the user is choosing a file.
    if (axBooleanAttributeTrue(win, ax.modal_attr)) return shim.BW_MANAGE_REJECT;

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

    const unknown_subrole = ax.unknown_subrole;
    const is_unknown_subrole = c.CFEqual(@ptrCast(subrole_ref), @ptrCast(unknown_subrole)) != 0;
    if (is_unknown_subrole) return shim.BW_MANAGE_PENDING;

    // AXStandardWindow is the canonical tileable subrole — accept unconditionally.
    if (c.CFEqual(@ptrCast(subrole_ref), @ptrCast(ax.standard_window_subrole)) != 0) {
        return shim.BW_MANAGE_READY;
    }

    // AXFloatingWindow and AXDialog are accepted only as a heuristic exception:
    // some Electron apps and IDEs report these subroles for their real, top-level
    // windows. But transient chrome-less popups also report AXDialog — Xcode's
    // autocomplete list is role=AXWindow/subrole=AXDialog with an empty title and
    // no title-bar buttons. Tiling one shrinks the editor on every keystroke as
    // the popup is created and destroyed (a resize storm).
    //
    // Distinguish a real window from a popup the way yabai/AeroSpace/OmniWM do: a
    // real window exposes title-bar controls or is the app's main/focused window;
    // a popup exposes none of these. Rejecting (not pending) matters — a window
    // that stays pending is tiled by the legacy timeout fallback.
    const is_dialog_like = c.CFEqual(@ptrCast(subrole_ref), @ptrCast(ax.floating_window_subrole)) != 0 or
        c.CFEqual(@ptrCast(subrole_ref), @ptrCast(ax.dialog_subrole)) != 0;
    if (is_dialog_like and windowHasRealWindowSignal(win, ax)) {
        return shim.BW_MANAGE_READY;
    }

    return shim.BW_MANAGE_REJECT;
}

/// Returns true when a window exposes a real top-level-window signal: any
/// title-bar button (close/minimize/zoom/fullscreen) or being the app's main or
/// focused window. Transient popups — Xcode's autocomplete list, tooltips,
/// context menus — report a dialog/floating subrole but have none of these, so
/// this guard keeps them from being tiled. Mirrors the button/subrole heuristics
/// used by yabai, AeroSpace, and OmniWM.
fn windowHasRealWindowSignal(win: c.AXUIElementRef, ax: *const AxStrings) bool {
    std.debug.assert(win != null);
    std.debug.assert(ax.modal_attr != null);

    if (axAttributePresent(win, ax.close_button_attr)) return true;
    if (axAttributePresent(win, ax.minimize_button_attr)) return true;
    if (axAttributePresent(win, ax.zoom_button_attr)) return true;
    if (axAttributePresent(win, ax.fullscreen_button_attr)) return true;
    if (axBooleanAttributeTrue(win, ax.main_attr)) return true;
    if (axBooleanAttributeTrue(win, ax.focused_attr)) return true;
    return false;
}

/// True when the AX attribute exists and is non-null on the element.
fn axAttributePresent(win: c.AXUIElementRef, attr: c.CFStringRef) bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(win, attr, &value);
    if (err != c.kAXErrorSuccess or value == null) return false;
    c.CFRelease(value.?);
    return true;
}

/// True when the AX attribute is a CFBoolean set to true.
fn axBooleanAttributeTrue(win: c.AXUIElementRef, attr: c.CFStringRef) bool {
    var value: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(win, attr, &value);
    if (err != c.kAXErrorSuccess or value == null) return false;
    defer c.CFRelease(value.?);
    return c.CFEqual(value.?, @ptrCast(c.kCFBooleanTrue)) != 0;
}

/// Returns true when a still-pending window has AXUnknown role/subrole metadata.
/// These windows are often transient host placeholders that should not be tiled
/// by the timeout fallback path.
fn isUnknownPendingRoleWindow(pid: i32, wid: u32) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findAxWindow(pid, wid) orelse return false;
    defer c.CFRelease(@ptrCast(win));

    const ax = ensureAxStrings() orelse return false;
    var role_any: c.CFTypeRef = null;
    const role_err = c.AXUIElementCopyAttributeValue(win, ax.role_attr, @ptrCast(&role_any));
    if (role_err != c.kAXErrorSuccess or role_any == null) return false;
    defer c.CFRelease(role_any.?);

    const role_is_unknown = c.CFEqual(role_any.?, @ptrCast(ax.unknown_role)) != 0;
    if (role_is_unknown) return true;

    const role_is_window = c.CFEqual(role_any.?, @ptrCast(ax.window_role)) != 0;
    if (!role_is_window) return false;

    var subrole_any: c.CFTypeRef = null;
    const subrole_err = c.AXUIElementCopyAttributeValue(win, ax.subrole_attr, @ptrCast(&subrole_any));
    if (subrole_err != c.kAXErrorSuccess or subrole_any == null) return false;
    defer c.CFRelease(subrole_any.?);

    return c.CFEqual(subrole_any.?, @ptrCast(ax.unknown_subrole)) != 0;
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
///
/// Uses a per-call PID cache to avoid redundant isRegularActivationApp calls.
/// Electron apps spawn many XPC helper processes (renderers, GPU process) that
/// share the CGWindowList but have Prohibited activation policy. Caching the
/// accept/reject decision per PID avoids an ObjC message send for every window
/// belonging to the same rejected process.
export fn bw_discover_windows(out: ?[*]shim.bw_window_info, max_count: u32) u32 {
    const out_ptr = out orelse return 0;
    if (max_count == 0) return 0;

    std.debug.assert(max_count > 0);
    const out_buf = out_ptr[0..@as(usize, @intCast(max_count))];

    const options: cg_extra.CGWindowListOption =
        cg_extra.kCGWindowListOptionOnScreenOnly | cg_extra.kCGWindowListExcludeDesktopElements;
    const window_list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse return 0;
    defer c.CFRelease(@ptrCast(window_list));

    const total = c.CFArrayGetCount(window_list);
    std.debug.assert(total >= 0);

    // Per-call PID caches to fast-path repeated lookups.
    const pid_cache_capacity = 64;
    var accepted_pids: [pid_cache_capacity]i32 = undefined;
    var accepted_pid_count: usize = 0;
    var rejected_pids: [pid_cache_capacity]i32 = undefined;
    var rejected_pid_count: usize = 0;

    var count: usize = 0;
    var i: c.CFIndex = 0;
    while (i < total and count < out_buf.len) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(window_list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);

        var layer: i32 = 0;
        if (c.CFDictionaryGetValue(info, cg_extra.kCGWindowLayer)) |layer_ref_any| {
            const layer_ref: c.CFNumberRef = @ptrCast(layer_ref_any);
            _ = c.CFNumberGetValue(layer_ref, c.kCFNumberSInt32Type, &layer);
        }
        if (layer != 0) continue;
        if (!cgWindowInfoVisible(info)) continue;

        const wid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);
        var wid: u32 = 0;
        _ = c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid);

        const pid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowOwnerPID) orelse continue;
        const pid_ref: c.CFNumberRef = @ptrCast(pid_ref_any);
        var pid: i32 = 0;
        _ = c.CFNumberGetValue(pid_ref, c.kCFNumberSInt32Type, &pid);
        if (pid <= 0) continue;

        // Fast-path: check per-call caches before the ObjC message send.
        if (pidInCache(pid, &rejected_pids, rejected_pid_count)) continue;
        if (!pidInCache(pid, &accepted_pids, accepted_pid_count)) {
            if (!isRegularActivationApp(pid)) {
                if (rejected_pid_count < pid_cache_capacity) {
                    rejected_pids[rejected_pid_count] = pid;
                    rejected_pid_count += 1;
                }
                continue;
            }
            if (accepted_pid_count < pid_cache_capacity) {
                accepted_pids[accepted_pid_count] = pid;
                accepted_pid_count += 1;
            }
        }

        var bounds: c.CGRect = std.mem.zeroes(c.CGRect);
        if (c.CFDictionaryGetValue(info, cg_extra.kCGWindowBounds)) |bounds_ref_any| {
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

fn pidInCache(pid: i32, cache: []const i32, count: usize) bool {
    for (cache[0..count]) |cached| {
        if (cached == pid) return true;
    }
    return false;
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
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
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
        if (g_tap_port) |tap| cg_extra.CGEventTapEnable(tap, true);
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

    const flags = cg_extra.CGEventGetFlags(event);
    const keycode_raw = cg_extra.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
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

    g_tap_port = cg_extra.CGEventTapCreate(
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
    cg_extra.CGEventTapEnable(tap, true);
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
        cg_extra.DISPATCH_SOURCE_TYPE_READ(),
        @intCast(server_fd),
        0,
        cg_extra.dispatch_get_main_queue(),
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

// Event bridge (called from ObjC shim)

// Thread-safe: AX observer callbacks run on per-app background threads
// and push events here.  The os_unfair_lock serialises concurrent pushes
// while the main-thread consumer (pop) is wait-free.
export fn bw_emit_event(kind: u8, pid: i32, wid: u32) void {
    c.os_unfair_lock_lock(&g_ring_lock);
    g_ring.push(.{
        .kind = @enumFromInt(kind),
        .pid = pid,
        .wid = wid,
    });
    c.os_unfair_lock_unlock(&g_ring_lock);
    signalWaker();
}

/// Callback target for BWObserver.appTerminated:. Called from
/// objc_classes.zig so it no longer needs C-symbol export.
pub fn bw_workspace_app_terminated(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_TERMINATED, pid, 0);
}

/// Callback target for BWObserver.appLaunched:.
pub fn bw_workspace_app_launched(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_LAUNCHED, pid, 0);
}

/// Callback target for BWObserver.activeAppChanged:.
pub fn bw_workspace_active_app_changed(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_WINDOW_FOCUSED, pid, 0);
}

/// Callback target for BWObserver.spaceChanged:.
pub fn bw_workspace_space_changed() void {
    bw_emit_event(shim.BW_EVENT_SPACE_CHANGED, 0, 0);
}

/// Callback target for BWObserver.displayChanged:.
pub fn bw_workspace_display_changed() void {
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

        switch (dispatchForHotkeyBinding(binding)) {
            .pass_through => return false,
            .emit => |emit| {
                bw_emit_event(emit.kind, 0, emit.arg);
                return true;
            },
        }
    }
    return false;
}

// Entry point

pub fn main(init: std.process.Init.Minimal) !void {
    // -- CLI dispatch (help, version, service, IPC client) --
    var cmd_buf: [512]u8 = undefined;
    const result = cli.parse(init.args, &cmd_buf);
    if (cli.run(result)) return;

    // -- Daemon mode --
    log.info("bobrwm starting (log_level={s})...", .{@tagName(std_options.log_level)});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();
    defer deinitAxStrings();

    // -- Config --
    var config_arena = std.heap.ArenaAllocator.init(g_allocator);
    defer config_arena.deinit();
    g_config = config_mod.load(config_arena.allocator(), cli.configPath(result));
    g_bsp_split_mode = g_config.bsp_split;
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
    const ws_count: u8 = if (g_config.workspace_names.len > 0)
        @intCast(g_config.workspace_names.len)
    else
        workspace_mod.max_workspaces;
    g_workspaces = workspace_mod.WorkspaceManager.init(g_allocator, ws_count);
    defer g_workspaces.deinit();
    clearTilingStates();
    // Free per-workspace tiling states on exit. BSP allocates Split nodes and
    // leaf ArrayLists via g_allocator; without this, DebugAllocator reports leaks.
    defer destroyAllTilingStates();
    g_tab_groups = tabgroup.TabGroupManager.init(g_allocator);
    defer g_tab_groups.deinit();
    g_pending_role_windows = PendingRoleWindowMap.init(g_allocator);
    defer g_pending_role_windows.deinit();
    g_pending_role_windows.ensureTotalCapacity(pending_role_window_capacity) catch |err| {
        log.err("pending-role map reserve failed: {}", .{err});
        return err;
    };
    g_deferred_window_candidates = DeferredWindowCandidateMap.init(g_allocator);
    defer g_deferred_window_candidates.deinit();
    g_deferred_window_candidates.ensureTotalCapacity(deferred_window_candidate_capacity) catch |err| {
        log.err("deferred-window map reserve failed: {}", .{err});
        return err;
    };
    g_app_launch_retries = AppLaunchRetryMap.init(g_allocator);
    defer g_app_launch_retries.deinit();
    g_app_launch_retries.ensureTotalCapacity(app_launch_retry_capacity) catch |err| {
        log.err("app-launch-retry map reserve failed: {}", .{err});
        return err;
    };
    g_focus_retries = FocusRetryMap.init(g_allocator);
    defer g_focus_retries.deinit();
    g_focus_retries.ensureTotalCapacity(focus_retry_capacity) catch |err| {
        log.err("focus-retry map reserve failed: {}", .{err});
        return err;
    };
    defer {
        setRolePolling(false);
        g_layout_entries.deinit(g_allocator);
    }
    refreshDisplays();

    // Assign all workspaces to primary; pull last N onto extra displays.
    const primary_id = primaryDisplayId();
    const wsc = g_workspaces.workspace_count;
    for (g_workspaces.workspaces[0..wsc]) |*ws| {
        ws.display_id = primary_id;
    }
    const primary_slot = displayIndexById(primary_id) orelse 0;
    g_workspaces.setActiveForDisplaySlot(primary_slot, 1);
    if (g_display_count > 1) {
        var extra: usize = 0;
        for (0..g_display_count) |slot| {
            if (slot == primary_slot) continue;
            const ws_id: u8 = @intCast(wsc - extra);
            g_workspaces.setActiveForDisplaySlot(slot, ws_id);
            if (g_workspaces.get(ws_id)) |ws| {
                ws.display_id = g_displays[slot].id;
            }
            extra += 1;
        }
    }

    // -- Apply workspace names from config --
    for (g_config.workspace_names, 0..) |name, i| {
        if (i >= g_workspaces.workspace_count) break;
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
    // Register runtime ObjC classes (BWStatusBarDelegate / BWObserver /
    // BWLaunchGate) before any code does objc.getClass on them.
    objc_classes.register(g_allocator);
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
    updateStatusBar();

    // -- Enter NSApp run loop --
    // Returns when CFRunLoopStop is called (e.g. graceful signal handler).
    // The defer chain then runs restoreAllWindows() safely on the main thread.
    log.info("entering run loop", .{});
    defer restoreAllWindows();
    NSApp.msgSend(void, "run", .{});
}

// Exported callbacks (called from ObjC shim on main thread)

/// Drain the event ring buffer — called by the CFRunLoopSource waker.
export fn bw_drain_events() void {
    std.debug.assert(!g_event_drain_active);
    g_event_drain_active = true;
    defer g_event_drain_active = false;

    while (g_ring.pop()) |ev| {
        handleEvent(&ev);
    }

    // Flush retile BEFORE cleanup so windows are at their layout positions
    // when cleanup checks on-screen status. Without this, cleanup sees
    // corner-parked windows and incorrectly removes them as ghosts.
    flushRetileRequests();

    if (flushCleanupRequests()) {
        // Cleanup removed windows — retile again to fill the gaps.
        requestRetileAllDisplays();
        flushRetileRequests();
    }

    // Honour pending Ctrl-C / SIGTERM by exiting NSApp.run cleanly so the
    // deferred cleanup (IPC socket unlink, layout free, restoreAllWindows)
    // actually runs. Without this, NSApp keeps spinning and the next launch
    // sees a live socket and bails out with AddressInUse.
    if (g_shutdown_requested.load(.acquire)) {
        gracefulStopNSApp();
    }
}

/// Exit `[NSApp run]` cleanly by setting NSApplication's stop flag and posting
/// a wake-up event. Must be called on the main thread inside the run loop.
fn gracefulStopNSApp() void {
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "stop:", .{@as(?*anyopaque, null)});

    // [NSApp stop:] only takes effect after nextEventMatchingMask: returns,
    // so post a dummy event to ensure the run loop wakes and re-checks.
    const NSEvent = objc.getClass("NSEvent") orelse return;
    // NSEventTypeApplicationDefined = 15
    const event = NSEvent.msgSend(
        objc.Object,
        "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
        .{
            @as(u64, 15),
            NSPoint{ .x = 0, .y = 0 },
            @as(u64, 0),
            @as(f64, 0),
            @as(i64, 0),
            @as(?*anyopaque, null),
            @as(i16, 0),
            @as(i64, 0),
            @as(i64, 0),
        },
    );
    app.msgSend(void, "postEvent:atStart:", .{ event, true });
}

/// Accept and handle one IPC client connection — called by dispatch_source.
export fn bw_handle_ipc_client(server_fd: c_int) void {
    // std.posix.accept was removed in Zig 0.16; call libc directly.
    const client_fd = std.c.accept(server_fd, null, null);
    if (client_fd < 0) {
        log.err("accept failed: errno={d}", .{std.c._errno().*});
        return;
    }
    defer _ = std.c.close(client_fd);
    ipc.disableSigpipe(client_fd);
    const started_ns = nanoTimestamp();

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| {
        log.err("IPC read: {}", .{err});
        return;
    };
    if (n == 0) return;

    const cmd = std.mem.trimEnd(u8, buf[0..n], &.{ '\n', '\r', ' ', 0 });
    if (cmd.len == 0) return;
    log.debug("[trace] ipc recv fd={} bytes={} cmd={s}", .{ client_fd, n, cmd });

    if (ipc.g_dispatch) |dispatch| {
        dispatch(cmd, client_fd);
        const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
        log.debug("[trace] ipc handled fd={} cmd={s} elapsed_ms={}", .{ client_fd, cmd, elapsed_ms });
    } else {
        log.warn("ipc dispatch callback missing", .{});
    }
}

/// Clean shutdown — called from BWStatusBarDelegate.quit:.
pub fn bw_will_quit() void {
    restoreAllWindows();
}

/// Retile — called from BWStatusBarDelegate.retile:.
pub fn bw_retile() void {
    retile();
}

fn tilingStatePtr(workspace_id: u8) *?tiling.State {
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    return &g_tiling_states[workspace_id - 1];
}

fn removeFromTiling(workspace_id: u8, wid: u32) void {
    const sp = tilingStatePtr(workspace_id);
    if (sp.*) |*st| {
        st.remove(wid, g_allocator);
        if (st.windowCount() == 0) {
            st.deinit(g_allocator);
            sp.* = null;
        }
    }
}

fn insertIntoTiling(workspace_id: u8, wid: u32) void {
    const sp = tilingStatePtr(workspace_id);
    if (sp.* == null) sp.* = tiling.newState(g_config.layout);
    const ws = g_workspaces.get(workspace_id) orelse return;
    const anchor_wid = blk: {
        const st = sp.* orelse break :blk null;
        switch (g_config.bsp_insert_point) {
            .focused => {
                const focused_wid = ws.focused_wid orelse break :blk null;
                if (focused_wid == wid) break :blk null;
                break :blk focused_wid;
            },
            .first => break :blk st.firstWid(),
            .last => break :blk st.lastWid(),
            .min_depth => break :blk null,
        }
    };
    const options: tiling.InsertOptions = .{
        .split_mode = g_bsp_split_mode,
        .child = g_config.new_window_split,
        .anchor_wid = anchor_wid,
        .root_frame = if (ws.display_id) |did| displayContentFrame(did) else null,
        .inner_gap = @floatFromInt(g_config.gaps.inner),
        .split_ratio = g_config.bsp_split_ratio,
    };
    sp.*.?.insert(wid, options, g_allocator) catch return;
}

fn setTilingActive(workspace_id: u8, wid: u32) void {
    if (tilingStatePtr(workspace_id).*) |*st| {
        const layout_wid = g_tab_groups.resolveLeader(wid);
        st.setActive(layout_wid);
    }
}

fn replaceManagedWindowId(old_wid: u32, new_wid: u32, frame: window_mod.Window.Frame) bool {
    std.debug.assert(old_wid != 0);
    std.debug.assert(new_wid != 0);
    std.debug.assert(frame.width > 0 and frame.height > 0);
    if (old_wid == new_wid) return false;
    if (g_store.get(new_wid) != null) return false;
    if (g_tab_groups.groupOf(old_wid) != null) return false;
    if (g_tab_groups.groupOf(new_wid) != null) return false;

    const old = g_store.get(old_wid) orelse return false;
    const ws = g_workspaces.get(old.workspace_id) orelse return false;
    const sp = tilingStatePtr(old.workspace_id);
    var replaced_in_layout = false;
    if (sp.*) |*st| {
        replaced_in_layout = st.replaceWid(old_wid, new_wid);
    }

    const replaced_in_workspace = ws.replaceWindow(old_wid, new_wid);
    if (!replaced_in_workspace or (old.mode == .tiled and !replaced_in_layout)) {
        if (replaced_in_workspace) _ = ws.replaceWindow(new_wid, old_wid);
        if (replaced_in_layout) {
            if (sp.*) |*st| _ = st.replaceWid(new_wid, old_wid);
        }
        log.warn("window id replacement failed old={d} new={d} workspace={d} in_workspace={} in_layout={}", .{
            old_wid,
            new_wid,
            old.workspace_id,
            replaced_in_workspace,
            replaced_in_layout,
        });
        return false;
    }

    var updated = old;
    updated.wid = new_wid;
    updated.frame = frame;
    g_store.put(updated) catch {
        _ = ws.replaceWindow(new_wid, old_wid);
        if (replaced_in_layout) {
            if (sp.*) |*st| _ = st.replaceWid(new_wid, old_wid);
        }
        return false;
    };
    g_store.remove(old_wid);
    log.info("window id replaced old={d} new={d} pid={d} workspace={d} display={d}", .{
        old_wid,
        new_wid,
        updated.pid,
        updated.workspace_id,
        updated.display_id,
    });
    return true;
}

const FocusedLayoutContext = struct {
    focused_wid: u32,
    focused_win: window_mod.Window,
    state: *tiling.State,
};

fn focusedLayoutContext() ?FocusedLayoutContext {
    const ws = g_workspaces.active();
    const focused_wid = ws.focused_wid orelse return null;
    const focused_win = g_store.get(focused_wid) orelse return null;
    const sp = tilingStatePtr(focused_win.workspace_id);
    if (sp.*) |*st| {
        return .{
            .focused_wid = focused_wid,
            .focused_win = focused_win,
            .state = st,
        };
    }
    return null;
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
    node: bsp_mod.Node,
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
    if (g_config.layout != .bsp) {
        clearDragPreview();
        return;
    }

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

    const bsp_state: *bsp_mod.State = blk: {
        const sp = tilingStatePtr(win.workspace_id);
        const st: *tiling.State = if (sp.*) |*s| s else {
            clearDragPreview();
            return;
        };
        break :blk switch (st.*) {
            .bsp => |*s| s,
            else => {
                clearDragPreview();
                return;
            },
        };
    };
    const bsp_root = bsp_state.root orelse {
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
        bsp_root,
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

    if (tilingStatePtr(source.workspace_id).*) |*st| {
        if (st.swapWids(wid, target_wid)) {
            log.info("window move swap wid={d} target={d}", .{ wid, target_wid });
            retile();
        }
    }
}

fn resetRetileRequestState() void {
    g_retile_requested_all_displays = false;
    g_retile_dirty_display_count = 0;
    std.debug.assert(g_retile_dirty_display_count == 0);
}

fn requestRetileDisplay(display_id: u32) void {
    std.debug.assert(display_id != 0);
    if (g_retile_requested_all_displays) return;

    const display_slot = displayIndexById(display_id) orelse return;
    const normalized_display_id = g_displays[display_slot].id;

    var i: usize = 0;
    while (i < g_retile_dirty_display_count) : (i += 1) {
        if (g_retile_dirty_display_ids[i] == normalized_display_id) return;
    }

    if (g_retile_dirty_display_count == g_retile_dirty_display_ids.len) {
        requestRetileAllDisplays();
        return;
    }

    g_retile_dirty_display_ids[g_retile_dirty_display_count] = normalized_display_id;
    g_retile_dirty_display_count += 1;
    std.debug.assert(g_retile_dirty_display_count <= g_retile_dirty_display_ids.len);
}

fn requestRetileAllDisplays() void {
    g_retile_requested_all_displays = true;
    g_retile_dirty_display_count = 0;
}

fn flushRetileRequests() void {
    if (g_retile_requested_all_displays) {
        retileAllDisplays();
        resetRetileRequestState();
        return;
    }

    if (g_retile_dirty_display_count == 0) return;

    var i: usize = 0;
    while (i < g_retile_dirty_display_count) : (i += 1) {
        retileDisplay(g_retile_dirty_display_ids[i]);
    }
    resetRetileRequestState();
}

fn retile() void {
    clearDragPreview();
    requestRetileAllDisplays();
    if (!g_event_drain_active) {
        flushRetileRequests();
    }
}

// Event handling

fn handleEvent(ev: *const event_mod.Event) void {
    _ = processPendingFocusQueue();
    tickWorkspaceTransitionState();

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
            untrackFocusRetry(ev.pid);
            ax_observer.unobserveApp(ev.pid);
            removeAppWindows(ev.pid);
            retile();
        },
        .window_focused => {
            const focused_wid_opt = focusedWindowIdForLoggedEvent("window focused", ev.pid);
            if (!g_workspace_transition.isActive()) {
                requestCleanupForPid(ev.pid);
                requestOffscreenCleanup();
            }
            const focused_wid = focused_wid_opt orelse {
                trackFocusRetry(ev.pid);
                return;
            };
            untrackFocusRetry(ev.pid);
            if (!syncFocusStateForWindowId(focused_wid, .ax)) {
                reconcileFocusedWindow(ev.pid, focused_wid);
            }
        },
        .focused_window_changed => {
            const focused_wid_opt = focusedWindowIdForLoggedEvent("focused window changed", ev.pid);
            if (!g_workspace_transition.isActive()) {
                requestCleanupForPid(ev.pid);
                requestOffscreenCleanup();
            }
            const focused_wid = focused_wid_opt orelse {
                trackFocusRetry(ev.pid);
                return;
            };
            untrackFocusRetry(ev.pid);
            reconcileFocusedWindow(ev.pid, focused_wid);
        },
        .window_created => {
            log.info("window created pid={} wid={}", .{ ev.pid, ev.wid });

            // Electron browsers (Chrome, Edge, Brave) fire kAXWindowCreatedNotification
            // mid-drag during tab tear-out, before the window has settled. Defer these
            // into the existing deferred-candidate pipeline so they are picked up after
            // mouse-up, preventing a layout flash from tiling a half-positioned window.
            if (g_mouse_left_down) {
                if (g_store.get(ev.wid) == null) {
                    // Mid-drag bounds may not be settled yet, so the inferred
                    // display can be wrong; fall back to the focused display
                    // and let processDeferredWindowCandidates re-derive on
                    // promotion (it goes through addNewWindowManaged again).
                    const display_id = inferDisplayIdForWindow(ev.wid) orelse focusedDisplayId();
                    const ws = resolveWorkspace(ev.pid, display_id);
                    trackDeferredWindowCandidate(ev.pid, ev.wid, ws.id, display_id);
                    log.info("window created: deferred pid={} wid={} while mouse is down (tab tear-off guard)", .{ ev.pid, ev.wid });
                }
                return;
            }

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
            processFocusRetries();
            _ = processPendingFocusQueue();
            if (promoted_pending or promoted_deferred or retried_launch) {
                retile();
            }
        },
        .mouse_down => {
            g_mouse_left_down = true;
            g_drag_reconcile_on_drop = false;
        },
        .mouse_up => {
            g_mouse_left_down = false;
            const drag_needs_reconcile_on_drop = g_drag_reconcile_on_drop;
            defer g_drag_reconcile_on_drop = false;
            if (g_drag_preview.source_wid) |source_wid| {
                commitWindowMovePreview(source_wid);
            } else if (drag_needs_reconcile_on_drop) {
                retile();
            } else {
                clearDragPreview();
            }

            // Flush windows that were deferred during the drag (tab tear-off guard).
            // Processing them here avoids waiting for the next role_poll_tick.
            if (processDeferredWindowCandidates()) {
                retile();
            }
        },
        .window_moved, .window_resized => {
            if (inWorkspaceTransition() and !g_mouse_left_down) {
                if (ev.kind == .window_resized) {
                    clearDragPreview();
                }
                return;
            }

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
            if (g_mouse_left_down) {
                if (g_store.get(ev.wid)) |win| {
                    if (win.mode == .tiled and !win.is_fullscreen and workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) {
                        g_drag_reconcile_on_drop = true;
                    }
                }
            }
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
        .hk_focus_previous_workspace => switchAdjacentWorkspace(.previous),
        .hk_focus_next_workspace => switchAdjacentWorkspace(.next),
        .hk_focus_left => focusDirection(.left),
        .hk_focus_right => focusDirection(.right),
        .hk_focus_up => focusDirection(.up),
        .hk_focus_down => focusDirection(.down),
        .hk_toggle_split => {
            g_bsp_split_mode = switch (g_bsp_split_mode) {
                .auto => .horizontal,
                .horizontal => .vertical,
                .vertical => .auto,
            };
            log.info("split mode: {s}", .{@tagName(g_bsp_split_mode)});
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
        .hk_move_workspace_to_display => {
            const arg: u8 = @intCast(ev.wid);
            if (arg == 0) {
                log.info("hotkey: move workspace to display next", .{});
                moveWorkspaceToDisplayNext();
            } else if (arg == 255) {
                log.info("hotkey: move workspace to display prev", .{});
                moveWorkspaceToDisplayPrev();
            } else {
                log.info("hotkey: move workspace to display {}", .{arg});
                moveWorkspaceToDisplay(@as(usize, arg) - 1);
            }
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

// Window mode (tiled / floating / fullscreen)

fn setWindowMode(wid: u32, target: window_mod.WindowMode) void {
    var win = g_store.get(wid) orelse return;
    const old = win.mode;
    if (old == target) return;

    // Leaving tiled → remove from BSP so remaining windows fill the space
    if (old == .tiled) {
        removeFromTiling(win.workspace_id, wid);
    }

    // Entering tiled → re-insert into BSP
    if (target == .tiled) {
        insertIntoTiling(win.workspace_id, wid);
    }

    win.mode = target;
    g_store.put(win) catch {};
    log.info("window {d} mode: {s} → {s}", .{ wid, @tagName(old), @tagName(target) });
    retile();
}

// Window management helpers

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
        g_app_launch_retries.count() > 0 or
        g_focus_retries.count() > 0;
    setRolePolling(has_pending);
}

/// Track a pid whose AX focused-window query returned nothing. Electron apps
/// (Discord) publish AXFocusedWindow late after activation; without a retry
/// the focus event is dropped and workspace focus state silently desyncs.
fn trackFocusRetry(pid: i32) void {
    std.debug.assert(pid > 0);

    if (g_focus_retries.getPtr(pid)) |attempts_remaining| {
        attempts_remaining.* = focus_retry_attempts_max;
    } else {
        g_focus_retries.put(pid, focus_retry_attempts_max) catch {
            log.err("focus-retry: failed to track pid={d}", .{pid});
            return;
        };
    }

    refreshRolePolling();
}

fn untrackFocusRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    if (g_focus_retries.remove(pid)) {
        refreshRolePolling();
    }
}

/// Re-query the AX focused window for tracked pids on the role-poll cadence.
/// Resolved pids run the normal focus reconciliation path; exhausted pids are
/// dropped (the next real focus event will try again).
fn processFocusRetries() void {
    if (g_focus_retries.count() == 0) return;

    var resolved_pids: [64]i32 = undefined;
    var resolved_wids: [64]u32 = undefined;
    var resolved_count: usize = 0;
    var expired_pids: [64]i32 = undefined;
    var expired_count: usize = 0;

    var it = g_focus_retries.iterator();
    while (it.next()) |entry| {
        const pid = entry.key_ptr.*;
        std.debug.assert(pid > 0);

        const focused_wid = bw_ax_get_focused_window(pid);
        if (focused_wid != 0) {
            if (resolved_count < resolved_pids.len) {
                resolved_pids[resolved_count] = pid;
                resolved_wids[resolved_count] = focused_wid;
                resolved_count += 1;
            }
            continue;
        }

        if (entry.value_ptr.* == 0) {
            if (expired_count < expired_pids.len) {
                expired_pids[expired_count] = pid;
                expired_count += 1;
            }
            continue;
        }
        entry.value_ptr.* -= 1;
    }

    // Map mutations deferred until iteration is done.
    for (expired_pids[0..expired_count]) |pid| {
        log.debug("focus-retry: gave up pid={d}", .{pid});
        _ = g_focus_retries.remove(pid);
    }
    for (resolved_pids[0..resolved_count], resolved_wids[0..resolved_count]) |pid, wid| {
        _ = g_focus_retries.remove(pid);
        log.info("focus-retry: resolved pid={d} wid={d}", .{ pid, wid });
        reconcileFocusedWindow(pid, wid);
    }
    refreshRolePolling();
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

fn trackPendingRoleWindow(pid: i32, wid: u32, workspace_id: u8, display_id: u32) void {
    std.debug.assert(wid != 0);
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    std.debug.assert(display_id != 0);
    if (g_store.get(wid) != null) return;

    if (g_pending_role_windows.getPtr(wid)) |pending| {
        pending.pid = pid;
        pending.attempts_remaining = role_poll_attempts_max;
        pending.workspace_id = workspace_id;
        pending.display_id = display_id;
    } else {
        g_pending_role_windows.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
            .workspace_id = workspace_id,
            .display_id = display_id,
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

fn trackDeferredWindowCandidate(pid: i32, wid: u32, workspace_id: u8, display_id: u32) void {
    std.debug.assert(wid != 0);
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    std.debug.assert(display_id != 0);
    if (g_store.get(wid) != null) {
        if (g_deferred_window_candidates.remove(wid)) {
            refreshRolePolling();
        }
        return;
    }

    if (g_deferred_window_candidates.getPtr(wid)) |candidate| {
        candidate.pid = pid;
        candidate.attempts_remaining = role_poll_attempts_max;
        candidate.workspace_id = workspace_id;
        candidate.display_id = display_id;
    } else {
        g_deferred_window_candidates.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
            .workspace_id = workspace_id,
            .display_id = display_id,
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

fn addNewWindowLegacyPendingFallback(pid: i32, wid: u32, workspace_id: u8, display_id: u32) bool {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) return false;
    if (!shim.bw_should_manage_window(pid, wid)) {
        log.debug("pending-role: fallback rejected pid={d} wid={d}", .{ pid, wid });
        return false;
    }
    return addNewWindowManagedWithAssignment(pid, wid, workspace_id, display_id);
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
                candidates[candidate_count] = .{
                    .pid = pid,
                    .wid = wid,
                    .from_timeout = false,
                    .workspace_id = entry.value_ptr.workspace_id,
                    .display_id = entry.value_ptr.display_id,
                };
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
                    candidates[candidate_count] = .{
                        .pid = pid,
                        .wid = wid,
                        .from_timeout = true,
                        .workspace_id = entry.value_ptr.workspace_id,
                        .display_id = entry.value_ptr.display_id,
                    };
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
            if (isUnknownPendingRoleWindow(candidate.pid, candidate.wid)) {
                log.info("pending-role: timeout pid={d} wid={d} after {d}ms with AXUnknown metadata, skipping legacy fallback", .{ candidate.pid, candidate.wid, timeout_ms });
                continue;
            }
            log.info("pending-role: timeout pid={d} wid={d} after {d}ms, applying legacy fallback", .{ candidate.pid, candidate.wid, timeout_ms });
            if (addNewWindowLegacyPendingFallback(candidate.pid, candidate.wid, candidate.workspace_id, candidate.display_id)) {
                added_any = true;
            }
            continue;
        }

        // Re-derive workspace+display from the current window position; the
        // snapshot taken when the role gate first fired can be wrong if the
        // window moved (e.g. tab tear-off across monitors) before its role
        // settled.
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
                    promote_candidates[promote_count] = .{
                        .pid = pid,
                        .wid = wid,
                        .workspace_id = entry.value_ptr.workspace_id,
                        .display_id = entry.value_ptr.display_id,
                    };
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
        // Re-derive workspace+display from the *current* window position
        // rather than the snapshot taken at deferral time. Mid-drag bounds
        // can be stale or simply wrong (tab tear-off lands on a different
        // monitor than the one focused when the window first appeared);
        // by promotion time the window is guaranteed on-screen with stable
        // bounds, so addNewWindowManaged's inferDisplayIdForWindow is the
        // authoritative answer.
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

        const frame: window_mod.Window.Frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h };
        const discovered_display = displayIdForFrame(frame);
        const target_ws = resolveWorkspace(info.pid, discovered_display);
        const managed_display = target_ws.display_id orelse discovered_display;

        switch (windowRoleState(info.pid, info.wid)) {
            .reject => {
                untrackPendingRoleWindow(info.wid);
                continue;
            },
            .pending => {
                trackPendingRoleWindow(info.pid, info.wid, target_ws.id, managed_display);
                continue;
            },
            .ready => {
                untrackPendingRoleWindow(info.wid);
                untrackDeferredWindowCandidate(info.wid);
            },
        }

        const win = window_mod.Window{
            .wid = info.wid,
            .pid = info.pid,
            .title = null,
            .frame = frame,
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = target_ws.id,
            .display_id = managed_display,
        };

        g_store.put(win) catch continue;
        target_ws.addWindow(info.wid) catch continue;
        insertIntoTiling(target_ws.id, info.wid);

        // If assigned to a non-visible workspace, hide immediately
        if (!workspaceVisibleOnDisplay(target_ws.id, managed_display)) {
            hideWindow(info.pid, info.wid);
        }
    }

    // Ensure a focused window is set on the active workspace
    const active_ws = g_workspaces.active();
    if (active_ws.focused_wid == null and active_ws.windows.items.len > 0) {
        active_ws.focused_wid = active_ws.windows.items[0];
    }
}

/// Find a managed on-screen sibling of the same PID occupying the same frame.
///
/// Used to guard tab inference against standalone window creation races
/// (an on-screen sibling at the same frame means the candidate is a
/// standalone window) and to locate the active tab when adopting an
/// off-screen background tab into a group.
fn findOnScreenMatchingManagedSibling(
    pid: i32,
    exclude_wid: u32,
    target_frame: window_mod.Window.Frame,
    sky: skylight.SkyLight,
    conn: c_int,
) ?u32 {
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

        if (matches) return candidate_wid;
    }

    return null;
}

fn addNewWindowManagedWithAssignment(pid: i32, wid: u32, workspace_id: u8, assigned_display_id: u32) bool {
    log.debug("addNewWindow: pid={d} wid={d}", .{ pid, wid });
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    std.debug.assert(assigned_display_id != 0);
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
        trackDeferredWindowCandidate(pid, wid, workspace_id, assigned_display_id);
        log.info("addNewWindow: deferred pid={d} wid={d} while off-screen", .{ pid, wid });
        return false;
    }
    defer untrackDeferredWindowCandidate(wid);

    // Check if this new on-screen window replaces an existing same-PID window
    // that just went off-screen (i.e. a new tab was created and became active,
    // pushing the old tab to background). If so, form a tab group.
    if (tryFormTabGroupOnCreate(pid, wid)) return false;

    var window_frame: window_mod.Window.Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const display_id = assigned_display_id;
    if (g_sky) |sky| {
        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) == 0) {
            window_frame = .{
                .x = rect.origin.x,
                .y = rect.origin.y,
                .width = rect.size.width,
                .height = rect.size.height,
            };
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

    const ws = g_workspaces.get(workspace_id) orelse resolveWorkspace(pid, display_id);
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
        insertIntoTiling(ws.id, wid);
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

fn addNewWindowManaged(pid: i32, wid: u32) bool {
    // Prefer the window's actual on-screen position over the currently
    // focused display: a torn-off tab dropped on another monitor must land
    // on the workspace that owns the destination monitor, not on whichever
    // display happened to be focused when the window was created.
    const display_id = inferDisplayIdForWindow(wid) orelse focusedDisplayId();
    const ws = resolveWorkspace(pid, display_id);
    return addNewWindowManagedWithAssignment(pid, wid, ws.id, display_id);
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
            // Same rationale as addNewWindowManaged: derive the display from
            // the actual window position so a deferred candidate is later
            // promoted onto the correct workspace+display.
            const display_id = inferDisplayIdForWindow(wid) orelse focusedDisplayId();
            const ws = resolveWorkspace(pid, display_id);
            trackPendingRoleWindow(pid, wid, ws.id, display_id);
            trackDeferredWindowCandidate(pid, wid, ws.id, display_id);
            log.debug("addNewWindow: role gate pending pid={d} wid={d}", .{ pid, wid });
        },
    }
}

/// Add unmanaged same-PID AX windows that share the group's frame and are
/// off-screen to the group as background tabs.
///
/// The guards matter: an unmanaged window that is visible on-screen or at
/// different bounds is a standalone window racing through the role-pending
/// or deferred pipelines, not a tab. Swallowing it as a group member would
/// leave it permanently untiled (members are not in the layout) while other
/// windows tile over its position.
fn discoverBackgroundTabs(
    pid: i32,
    group_id: tabgroup.GroupId,
    group_frame: window_mod.Window.Frame,
    workspace_id: u8,
    display_id: u32,
) void {
    std.debug.assert(pid > 0);
    std.debug.assert(group_id != 0);
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);

    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();

    var ax_wids: [128]u32 = undefined;
    const ax_count = shim.bw_get_app_window_ids(pid, &ax_wids, 128);
    log.debug("discoverBackgroundTabs: AX found {d} windows for pid={d}", .{ ax_count, pid });

    for (ax_wids[0..ax_count]) |ax_wid| {
        // Managed windows (including the group's leader and active tab,
        // which are stored before discovery runs) are never re-swallowed.
        if (g_store.get(ax_wid) != null) continue;

        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(conn, ax_wid, &rect) != 0) {
            log.debug("discoverBackgroundTabs: SkyLight.getWindowBounds failed for ax_wid={d}", .{ax_wid});
            continue;
        }
        const f = window_mod.Window.Frame{
            .x = rect.origin.x,
            .y = rect.origin.y,
            .width = rect.size.width,
            .height = rect.size.height,
        };

        const frame_matches = tabgroup.TabGroupManager.framesMatch(f, group_frame);
        const on_screen = shim.bw_is_window_on_screen(ax_wid);
        log.debug("discoverBackgroundTabs: ax_wid={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) match={} on_screen={}", .{
            ax_wid, f.x, f.y, f.width, f.height, frame_matches, on_screen,
        });
        if (!frame_matches) continue;
        if (on_screen) continue;

        g_tab_groups.addMember(group_id, ax_wid) catch continue;
        // The wid may still sit in the role-pending or deferred pipelines;
        // it is accounted for as a tab member now, so promotion must not
        // race against the group.
        untrackPendingRoleWindow(ax_wid);
        untrackDeferredWindowCandidate(ax_wid);
        g_store.put(.{
            .wid = ax_wid,
            .pid = pid,
            .title = null,
            .frame = f,
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = workspace_id,
            .display_id = display_id,
        }) catch continue;
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

    if (findOnScreenMatchingManagedSibling(pid, new_wid, new_frame, sky, conn) != null) {
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
            discoverBackgroundTabs(pid, group_id, new_frame, ws.id, existing.display_id);

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
    const group_id_before: ?tabgroup.GroupId = if (g_tab_groups.groupOf(wid)) |g| g.id else null;
    const removal = g_tab_groups.removeMember(wid);

    const win = g_store.get(wid) orelse return;
    g_store.remove(wid);

    // removeMember guesses members[0] as the new active tab, but macOS
    // selects the adjacent tab when the active one closes. Align with the
    // app's actual focus so focus operations do not raise a background tab.
    if (group_id_before) |gid| {
        reconcileGroupActiveAfterRemoval(gid, win.pid);
    }

    switch (removal) {
        // The removed window led a surviving tab group. It is the group's
        // only representative in workspace/layout state, so hand its slot to
        // the new leader instead of deleting it; otherwise the remaining tabs
        // become invisible to tiling and directional focus.
        .leader_changed => |new_leader| {
            transferLeaderSlot(win.workspace_id, wid, new_leader);
        },
        .none => {
            if (g_workspaces.get(win.workspace_id)) |ws| {
                ws.removeWindow(wid);
            }
            removeFromTiling(win.workspace_id, wid);
        },
        // The group dissolved — restore the solo survivor to workspace and layout.
        .dissolved_solo => |solo_wid| {
            if (g_workspaces.get(win.workspace_id)) |ws| {
                ws.removeWindow(wid);
            }
            removeFromTiling(win.workspace_id, wid);

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
                    insertIntoTiling(win.workspace_id, solo_wid);
                }
            }
        },
    }
}

/// Align a surviving tab group's active tab with the window the app actually
/// focused after a member was removed. Best-effort: when the app has not yet
/// focused the adjacent tab (or AX reports nothing), the members[0] guess
/// stands until the next AXFocusedWindowChanged notification corrects it.
fn reconcileGroupActiveAfterRemoval(group_id: tabgroup.GroupId, pid: i32) void {
    std.debug.assert(group_id != 0);
    std.debug.assert(pid > 0);

    const focused_wid = bw_ax_get_focused_window(pid);
    if (focused_wid == 0) return;

    // Only accept the focused window when it belongs to the same group;
    // a same-process standalone window must not be recorded as a tab.
    const g = g_tab_groups.groupOf(focused_wid) orelse return;
    if (g.id != group_id) return;

    g_tab_groups.setActive(focused_wid);
}

/// Hand a removed tab-group leader's workspace and layout slot to the new
/// leader, preserving the window's position in both. Falls back to plain
/// insertion when the old leader was not present (state drift).
fn transferLeaderSlot(workspace_id: u8, old_leader: u32, new_leader: u32) void {
    std.debug.assert(old_leader != 0 and new_leader != 0);
    std.debug.assert(old_leader != new_leader);

    var replaced_in_workspace = false;
    if (g_workspaces.get(workspace_id)) |ws| {
        replaced_in_workspace = ws.replaceWindow(old_leader, new_leader);
        if (!replaced_in_workspace) {
            ws.addWindow(new_leader) catch {};
        }
    }

    var replaced_in_layout = false;
    const sp = tilingStatePtr(workspace_id);
    if (sp.*) |*st| {
        replaced_in_layout = st.replaceWid(old_leader, new_leader);
    }
    if (!replaced_in_layout) {
        insertIntoTiling(workspace_id, new_leader);
    }

    if (replaced_in_workspace and replaced_in_layout) {
        log.info("leader succession: wid={d} slot handed to wid={d} ws={d}", .{
            old_leader, new_leader, workspace_id,
        });
    } else {
        log.warn("leader succession fallback: old={d} new={d} ws={d} in_workspace={} in_layout={}", .{
            old_leader, new_leader, workspace_id, replaced_in_workspace, replaced_in_layout,
        });
    }
}

fn removeAppWindows(pid: i32) void {
    untrackPendingRoleWindowsForPid(pid);
    untrackDeferredWindowCandidatesForPid(pid);
    clearDragPreview();
    var wids: [128]u32 = undefined;
    var ws_ids: [128]u8 = undefined;
    var n: usize = 0;

    // Collect managed windows across all workspaces
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (win.pid == pid and n < wids.len) {
                    wids[n] = wid;
                    ws_ids[n] = ws.id;
                    n += 1;
                }
            }
        }
    }

    // Also collect suppressed tab members from the store
    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        const wid = entry.key_ptr.*;
        if (entry.value_ptr.pid != pid) continue;
        if (!g_tab_groups.isSuppressed(wid)) continue;
        if (n >= wids.len) continue;

        wids[n] = wid;
        ws_ids[n] = entry.value_ptr.workspace_id;
        n += 1;
    }

    for (wids[0..n], ws_ids[0..n]) |wid, ws_id| {
        _ = g_tab_groups.removeMember(wid);
        g_store.remove(wid);
        if (g_workspaces.get(ws_id)) |ws| {
            ws.removeWindow(wid);
        }
        removeFromTiling(ws_id, wid);
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
    var truncated = false;

    for (&g_workspaces.workspaces) |*ws| {
        // Windows on hidden workspaces are intentionally parked off-screen.
        // AX role queries can be flaky for windows at corner positions,
        // so skip hidden workspaces to avoid false positives.
        if (!workspaceVisibleAnywhere(ws.id)) continue;

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

            if (stale_count < stale_wids.len) {
                stale_wids[stale_count] = wid;
                stale_count += 1;
            } else {
                truncated = true;
            }
        }
    }

    if (truncated) {
        log.warn("cleanup: stale-wid batch truncated pid={d} queued={d}", .{ pid, stale_count });
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
///
/// Native background tabs are also off-screen, so windows that look like a
/// missed tab-group inference are adopted into their sibling's group instead
/// of being reaped (see adoptOffscreenWindowAsTab).
fn cleanupOffscreenManagedWindows() bool {
    var candidate_wids: [128]u32 = undefined;
    var candidate_count: usize = 0;
    var truncated = false;

    for (&g_workspaces.workspaces) |*ws| {
        // Windows on hidden workspaces are intentionally parked off-screen.
        if (!workspaceVisibleAnywhere(ws.id)) continue;

        for (ws.windows.items) |wid| {
            if (g_store.get(wid) == null) continue;

            // Tab-group members can be intentionally off-screen when a sibling
            // tab is active; treating them as ghosts causes layout churn.
            if (g_tab_groups.groupOf(wid) != null) continue;

            if (shim.bw_is_window_on_screen(wid)) continue;

            if (candidate_count < candidate_wids.len) {
                candidate_wids[candidate_count] = wid;
                candidate_count += 1;
            } else {
                truncated = true;
            }
        }
    }

    if (truncated) {
        log.warn("cleanup: offscreen batch truncated queued={d}", .{candidate_count});
    }

    // Mutations deferred to here — removeWindow/adoption modify workspace
    // window lists, which must not happen while iterating them above.
    var mutated = false;
    for (candidate_wids[0..candidate_count]) |wid| {
        const win = g_store.get(wid) orelse continue;

        if (adoptOffscreenWindowAsTab(win)) {
            mutated = true;
            continue;
        }

        log.info("cleanup: removing wid={d} pid={d} reason=offscreen", .{ wid, win.pid });
        removeWindow(wid);
        mutated = true;
    }

    return mutated;
}

/// Adopt an off-screen managed window as a member of an on-screen sibling's
/// tab group. Returns true when adoption happened.
///
/// Tab groups are inferred heuristically at window-creation / focus time;
/// when that inference is missed (event races, mid-animation bounds, events
/// dropped during workspace transitions) a background tab remains managed as
/// a standalone window that is now off-screen. Reaping it would lose the tab.
///
/// A window qualifies when the app's AXWindows list still exposes it (hidden
/// and destroyed ghosts drop out of AXWindows, native background tabs stay
/// listed) and an on-screen managed sibling occupies the same frame (the
/// active tab).
fn adoptOffscreenWindowAsTab(win: window_mod.Window) bool {
    const sky = g_sky orelse return false;
    const conn = sky.mainConnectionID();

    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, win.wid, &rect) != 0) return false;
    const frame = window_mod.Window.Frame{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };

    var ax_wids: [128]u32 = undefined;
    const ax_count = shim.bw_get_app_window_ids(win.pid, &ax_wids, 128);
    var listed_in_ax = false;
    for (ax_wids[0..ax_count]) |ax_wid| {
        if (ax_wid == win.wid) {
            listed_in_ax = true;
            break;
        }
    }
    if (!listed_in_ax) return false;

    const sibling_wid = findOnScreenMatchingManagedSibling(win.pid, win.wid, frame, sky, conn) orelse return false;
    const sibling = g_store.get(sibling_wid) orelse return false;

    const group_id = if (g_tab_groups.groupOf(sibling_wid)) |g|
        g.id
    else
        g_tab_groups.createGroup(win.pid, sibling_wid, sibling.frame) catch return false;
    g_tab_groups.addMember(group_id, win.wid) catch return false;
    g_tab_groups.setActive(sibling_wid);

    // Members live only in the store; drop the standalone workspace/layout slot.
    if (g_workspaces.get(win.workspace_id)) |ws| {
        ws.removeWindow(win.wid);
    }
    removeFromTiling(win.workspace_id, win.wid);

    var updated = win;
    updated.frame = frame;
    updated.workspace_id = sibling.workspace_id;
    updated.display_id = sibling.display_id;
    g_store.put(updated) catch {};

    log.info("cleanup: adopted wid={d} as background tab, leader={d} pid={d}", .{
        win.wid, g_tab_groups.resolveLeader(sibling_wid), win.pid,
    });
    return true;
}

/// Updates `display_id` when a user-dragged window crosses monitors.
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

    // Only reassign display when the user is actively dragging and the
    // workspace is visible. Stops our retile from triggering this.
    if (!g_mouse_left_down) {
        win.frame = frame;
        g_store.put(win) catch {};
        return false;
    }
    if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) {
        win.frame = frame;
        g_store.put(win) catch {};
        return false;
    }

    removeFromTiling(win.workspace_id, wid);
    win.frame = frame;
    win.display_id = next_display_id;
    g_store.put(win) catch return false;
    if (win.mode == .tiled) {
        insertIntoTiling(win.workspace_id, wid);
    }

    if (!workspaceVisibleOnDisplay(win.workspace_id, win.display_id)) {
        hideWindow(win.pid, wid);
    }
    _ = maybeSetFocusedDisplayForWindow(win, .drag);
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

    refreshDisplays();

    // Restore workspace-to-display bindings for surviving displays
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
        if (g_workspaces.get(active_id)) |ws| {
            ws.display_id = display.id;
        }
    }

    // Clear display_id for workspaces not active on any surviving display
    for (&g_workspaces.workspaces) |*ws| {
        if (ws.display_id) |did| {
            if (displayIndexById(did) == null) ws.display_id = null;
        }
    }

    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        var win = entry.value_ptr.*;
        if (displayIndexById(win.display_id) != null) continue;

        if (g_workspaces.get(win.workspace_id)) |old_ws| {
            old_ws.removeWindow(win.wid);
        }
        removeFromTiling(win.workspace_id, win.wid);

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
            insertIntoTiling(target_workspace_id, win.wid);
        }
    }
}

fn retileDisplay(display_id: u32) void {
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    const st = tilingStatePtr(ws_id).* orelse return;
    const display_slot = displayIndexById(display_id) orelse return;
    const display = g_displays[display_slot].visible;

    const outer = g_config.gaps.outer;
    const frame = window_mod.Window.Frame{
        .x = display.x + @as(f64, @floatFromInt(outer.left)),
        .y = display.y + @as(f64, @floatFromInt(outer.top)),
        .width = display.w - @as(f64, @floatFromInt(@as(u32, outer.left) + @as(u32, outer.right))),
        .height = display.h - @as(f64, @floatFromInt(@as(u32, outer.top) + @as(u32, outer.bottom))),
    };

    const window_count = st.windowCount();
    std.debug.assert(window_count > 0);

    g_layout_entries.clearRetainingCapacity();
    g_layout_entries.ensureTotalCapacity(g_allocator, window_count) catch {
        log.err("retile: layout buffer reserve failed display={d} windows={d}", .{ display_id, window_count });
        return;
    };
    st.computeLayout(frame, @floatFromInt(g_config.gaps.inner), &g_layout_entries, g_allocator) catch {
        log.err("retile: layout apply failed display={d} windows={d}", .{ display_id, window_count });
        return;
    };
    std.debug.assert(g_layout_entries.items.len == window_count);

    for (g_layout_entries.items) |entry| {
        const win = g_store.get(entry.wid) orelse continue;
        if (win.display_id != display_id) continue;
        if (win.workspace_id != ws_id) continue;

        // Fullscreen windows fill the outer-gap-inset frame, skipping BSP splits and inner gaps
        const target_frame = if (win.is_fullscreen) frame else entry.frame;

        if (!framesEqual(win.frame, target_frame)) {
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
        }

        // If this is a tab group leader, apply the same frame to all members
        if (g_tab_groups.groupOfMut(entry.wid)) |g| {
            if (g.leader_wid == entry.wid) {
                g.canonical_frame = entry.frame;
                for (g.members.items) |member_wid| {
                    if (member_wid == entry.wid) continue;
                    if (g_store.get(member_wid)) |member| {
                        if (framesEqual(member.frame, entry.frame)) continue;

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

// Crash / exit recovery — restore all hidden windows to screen center

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

var g_shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Graceful signal handler for INT/TERM/HUP/QUIT. Sets a flag and wakes the
/// run loop so restoreAllWindows() runs on the main thread where AX calls and
/// hash table access are safe. Only uses async-signal-safe operations.
///
/// CFRunLoopStop alone does NOT exit `[NSApp run]` reliably: NSApplication
/// re-enters the CFRunLoop internally, so a stop is a no-op for its outer
/// loop. Instead we set a flag and wake the existing waker source; the main
/// thread (in bw_drain_events) sees the flag and performs `[NSApp stop:]` +
/// posts a dummy event, which is the documented way to exit NSApp.run.
///
/// Zig 0.16 made `posix.SIG` an enum; the kernel-facing handler signature now
/// takes that enum directly rather than `c_int`.
fn gracefulSignalHandler(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    g_shutdown_requested.store(true, .release);
    signalWaker();
}

/// Crash signal handler for SEGV/BUS/TRAP/ABRT. Best-effort restore using
/// async-signal-unsafe functions. May deadlock if the crash occurs mid-
/// allocation or mid-hash-table-mutation, but leaving windows hidden is worse.
fn crashSignalHandler(sig: posix.SIG) callconv(.c) void {
    restoreAllWindows();

    // Re-raise with default handler so the OS produces a core dump / correct exit code.
    var default_sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &default_sa, null);
    posix.raise(sig) catch {};
}

fn installCrashHandlers() void {
    // Graceful signals: handled safely via run loop stop + main-thread cleanup
    const graceful_signals = [_]posix.SIG{
        posix.SIG.INT, posix.SIG.TERM,
        posix.SIG.HUP, posix.SIG.QUIT,
    };
    for (graceful_signals) |sig| {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = gracefulSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig, &sa, null);
    }

    // Crash signals: best-effort restore, then re-raise for core dump
    const crash_signals = [_]posix.SIG{
        posix.SIG.ABRT, posix.SIG.SEGV,
        posix.SIG.BUS,  posix.SIG.TRAP,
    };
    for (crash_signals) |sig| {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = crashSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESETHAND, // one-shot: avoid infinite re-entry
        };
        posix.sigaction(sig, &sa, null);
    }
}

// Tab group reconciliation

/// Called on kAXFocusedWindowChangedNotification — detects tab switches and
/// forms/updates tab groups so only the active tab occupies a layout slot.
fn reconcileFocusedWindow(pid: i32, focused_wid: u32) void {
    std.debug.assert(pid > 0);
    std.debug.assert(focused_wid != 0);

    log.debug("reconcile: pid={d} focused_wid={d}", .{ pid, focused_wid });

    const in_store = g_store.get(focused_wid) != null;
    const suppressed = g_tab_groups.isSuppressed(focused_wid);
    const in_group = g_tab_groups.groupOf(focused_wid) != null;
    log.debug("reconcile: wid={d} in_store={} suppressed={} in_group={}", .{
        focused_wid, in_store, suppressed, in_group,
    });

    if (syncFocusStateForWindowId(focused_wid, .ax)) {
        const leader = g_tab_groups.resolveLeader(focused_wid);
        if (suppressed) {
            log.info("reconcile case 2: tab switch, active={d} leader={d}", .{ focused_wid, leader });
        } else {
            log.debug("reconcile case 1: known window, leader={d}", .{leader});
        }
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

    if (findOnScreenMatchingManagedSibling(pid, focused_wid, focused_frame, sky, conn) != null) {
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
        discoverBackgroundTabs(pid, group_id, focused_frame, matching_ws_id, matching_display_id);

        const leader = g_tab_groups.resolveLeader(focused_wid);
        _ = syncFocusStateForWindowId(focused_wid, .ax);

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
    const removal = g_tab_groups.removeMember(wid);

    // Update stored frame and add to workspace + layout
    if (g_store.get(wid)) |win| {
        var updated = win;
        updated.frame = frame;
        updated.display_id = displayIdForFrame(frame);
        g_store.put(updated) catch return;
    }

    const win = g_store.get(wid) orelse return;
    const ws = g_workspaces.get(win.workspace_id) orelse return;

    // If the dragged-out tab led the group, its existing workspace/layout
    // slot belongs to the surviving group — hand it to the new leader before
    // re-adding wid as a standalone window.
    switch (removal) {
        .leader_changed => |new_leader| transferLeaderSlot(win.workspace_id, wid, new_leader),
        .none, .dissolved_solo => {},
    }

    // The wid may still occupy a workspace/layout slot when it was the
    // group's leader and the group dissolved; avoid inserting a duplicate.
    var wid_in_ws = false;
    for (ws.windows.items) |w| {
        if (w == wid) {
            wid_in_ws = true;
            break;
        }
    }
    if (!wid_in_ws) {
        ws.addWindow(wid) catch return;
        insertIntoTiling(win.workspace_id, wid);
    }
    ws.focused_wid = wid;
    _ = maybeSetFocusedDisplayForWindow(win, .drag);

    // If the group dissolved, verify the survivor is still managed
    switch (removal) {
        .dissolved_solo => |solo_wid| {
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
                insertIntoTiling(win.workspace_id, solo_wid);
            }
        },
        .none, .leader_changed => {},
    }

    retile();
}

// Workspace resolution (config-based app → workspace mapping)

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

// Workspace switching

fn switchWorkspace(target_id: u8) void {
    const target_ws = g_workspaces.get(target_id) orelse return;

    // If target is already visible on some display, just focus there.
    if (workspaceVisibleAnywhere(target_id)) {
        const target_display = target_ws.display_id orelse return;
        log.debug("workspace switch target already visible workspace={d} display={d} windows={d}", .{
            target_id,
            target_display,
            target_ws.windows.items.len,
        });
        startWorkspaceTransition(.switch_workspace, target_id, target_display);
        setFocusedDisplay(target_display);
        updateStatusBar();
        focusWorkspaceWindow(target_ws);
        return;
    }

    // Hidden workspace — show it on its assigned display.
    const target_display = target_ws.display_id orelse focusedDisplayId();
    const display_slot = displayIndexById(target_display) orelse return;
    const current_id = g_workspaces.activeIdForDisplaySlot(display_slot);
    if (target_id == current_id) return;

    const old_ws = g_workspaces.get(current_id) orelse return;
    log.debug("workspace switch preparing current_workspace={d} target_workspace={d} display={d} current_windows={d} target_windows={d}", .{
        current_id,
        target_id,
        target_display,
        old_ws.windows.items.len,
        target_ws.windows.items.len,
    });

    // Hide current workspace windows (only those on target_display)
    const hctx = HideCtx.init(target_display);
    var hidden_count: usize = 0;
    for (old_ws.windows.items) |wid| {
        const visible_wid = g_tab_groups.resolveActive(wid);
        const hide_wid = if (g_store.get(visible_wid) != null) visible_wid else wid;
        if (g_store.get(hide_wid)) |win| {
            if (win.display_id != target_display) continue;
            if (g_tab_groups.groupOf(wid)) |group| {
                log.debug("workspace switch hiding window workspace={d} layout_wid={d} hide_wid={d} group_leader={d} group_active={d} members={d}", .{
                    current_id,
                    wid,
                    hide_wid,
                    group.leader_wid,
                    group.active_wid,
                    group.members.items.len,
                });
            } else {
                log.debug("workspace switch hiding window workspace={d} layout_wid={d} hide_wid={d} group=none", .{
                    current_id,
                    wid,
                    hide_wid,
                });
            }
            hctx.hide(win.pid, hide_wid);
            hidden_count += 1;
        }
    }
    var hidden_pending_count: usize = 0;
    var pending_it = g_pending_role_windows.iterator();
    while (pending_it.next()) |entry| {
        const pending = entry.value_ptr.*;
        if (pending.workspace_id != current_id) continue;
        if (pending.display_id != target_display) continue;
        hctx.hide(pending.pid, entry.key_ptr.*);
        hidden_pending_count += 1;
    }
    log.debug("workspace switch hid current windows current_workspace={d} target_workspace={d} display={d} hidden={d} hidden_pending={d}", .{
        current_id,
        target_id,
        target_display,
        hidden_count,
        hidden_pending_count,
    });

    // Activate target; old workspace keeps its display_id (just hidden).
    g_workspaces.setActiveForDisplaySlot(display_slot, target_id);
    target_ws.display_id = target_display;

    // Reconcile window display_ids: windows moved here while the workspace
    // was hidden may carry a stale source display_id. Update them so
    // retileDisplay (which filters on display_id) includes every window.
    for (target_ws.windows.items) |wid| {
        var win = g_store.get(wid) orelse continue;
        if (win.display_id != target_display) {
            win.display_id = target_display;
            g_store.put(win) catch {};
        }
        updateTabGroupAssignment(wid, target_ws.id, target_display);
    }
    log.debug("workspace switch activated target workspace={d} display={d} windows={d}", .{
        target_id,
        target_display,
        target_ws.windows.items.len,
    });

    assertDisplayCoverage();

    startWorkspaceTransition(.switch_workspace, target_id, target_display);
    retile();
    setFocusedDisplay(target_display);
    updateStatusBar();

    focusWorkspaceWindow(target_ws);
}

/// Focus the remembered (or first available) window on a workspace.
fn focusWorkspaceWindow(ws: *workspace_mod.Workspace) void {
    var focus_wid = ws.focused_wid;
    if (focus_wid) |fwid| {
        if (g_store.get(fwid) == null) focus_wid = null;
    }
    if (focus_wid == null) {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid) == null) continue;
            focus_wid = wid;
            break;
        }
    }
    if (focus_wid) |fwid| {
        const actual_wid = g_tab_groups.resolveActive(fwid);
        if (g_store.get(actual_wid)) |win| {
            if (g_tab_groups.groupOf(fwid)) |group| {
                log.debug("workspace focus target workspace={d} focused_wid={d} actual_wid={d} group_leader={d} group_active={d} members={d}", .{
                    ws.id,
                    fwid,
                    actual_wid,
                    group.leader_wid,
                    group.active_wid,
                    group.members.items.len,
                });
            } else {
                log.debug("workspace focus target workspace={d} focused_wid={d} actual_wid={d} group=none", .{
                    ws.id,
                    fwid,
                    actual_wid,
                });
            }
            _ = shim.bw_ax_focus_window(win.pid, actual_wid);
            ws.focused_wid = fwid;
            _ = maybeSetFocusedDisplayForWindow(win, .keyboard);
        }
    }

    if (focus_wid == null) {
        log.debug("workspace focus target workspace={d} focused_wid=0 actual_wid=0 reason=empty", .{ws.id});
        if (g_workspace_transition.isActive() and
            g_workspace_transition.target_workspace_id == ws.id)
        {
            markWorkspaceTransitionComplete(.empty_workspace);
        }
    }

    if (g_workspace_transition.isActive()) {
        g_pending_focus_count = 0;
    }
}

fn updateTabGroupAssignment(leader_wid: u32, workspace_id: u8, display_id: u32) void {
    std.debug.assert(leader_wid != 0);
    std.debug.assert(workspace_id > 0 and workspace_id <= workspace_mod.max_workspaces);
    std.debug.assert(display_id != 0);

    const group = g_tab_groups.groupOf(leader_wid) orelse return;
    if (group.leader_wid != leader_wid) return;

    for (group.members.items) |member_wid| {
        if (member_wid == leader_wid) continue;
        var member = g_store.get(member_wid) orelse continue;
        member.workspace_id = workspace_id;
        member.display_id = display_id;
        g_store.put(member) catch {};
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
    removeFromTiling(ws.id, wid);

    var updated = g_store.get(wid) orelse return;

    // Add to target workspace BSP + list
    target_ws.addWindow(wid) catch return;
    if (updated.mode == .tiled) {
        insertIntoTiling(target_id, wid);
    }
    if (target_ws.focused_wid == null) {
        target_ws.focused_wid = wid;
    }

    // Update window metadata. Use the target workspace's display so that
    // retileDisplay (which filters on display_id) will include this window
    // when the target workspace becomes visible. Fall back to the source
    // display for hidden workspaces with no assigned display yet —
    // switchWorkspace will correct it when the workspace is activated.
    updated.workspace_id = target_id;
    updated.display_id = target_ws.display_id orelse display_id;
    g_store.put(updated) catch {};
    updateTabGroupAssignment(wid, target_id, updated.display_id);

    // If target is not visible on the window's new display, hide it.
    if (!workspaceVisibleOnDisplay(target_id, updated.display_id)) {
        const visible_wid = g_tab_groups.resolveActive(wid);
        if (g_store.get(visible_wid)) |win| {
            hideWindow(win.pid, visible_wid);
        }
    }

    retile();
}

/// Move a managed window to a target display and map it onto the target
/// display's active workspace so it stays visible after the move.
fn moveManagedWindowToDisplay(wid: u32, target_display_id: u32) bool {
    std.debug.assert(wid != 0);
    std.debug.assert(target_display_id != 0);

    var win = g_store.get(wid) orelse return false;
    if (win.display_id == target_display_id) return false;

    const target_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
    std.debug.assert(target_workspace_id > 0 and target_workspace_id <= g_workspaces.workspace_count);

    const source_workspace_id = win.workspace_id;
    if (source_workspace_id != target_workspace_id) {
        const source_ws = g_workspaces.get(source_workspace_id) orelse return false;
        const target_ws = g_workspaces.get(target_workspace_id) orelse return false;

        var target_had_window = false;
        for (target_ws.windows.items) |existing_wid| {
            if (existing_wid == wid) {
                target_had_window = true;
                break;
            }
        }

        target_ws.addWindow(wid) catch return false;

        var updated = win;
        updated.workspace_id = target_workspace_id;
        updated.display_id = target_display_id;
        g_store.put(updated) catch {
            if (!target_had_window) {
                target_ws.removeWindow(wid);
            }
            return false;
        };
        updateTabGroupAssignment(wid, target_workspace_id, target_display_id);

        removeFromTiling(source_workspace_id, wid);
        source_ws.removeWindow(wid);
        target_ws.focused_wid = wid;
        if (updated.mode == .tiled) {
            insertIntoTiling(target_workspace_id, wid);
        }

        win = updated;
    } else {
        removeFromTiling(source_workspace_id, wid);
        win.display_id = target_display_id;
        g_store.put(win) catch return false;
        updateTabGroupAssignment(wid, source_workspace_id, target_display_id);
        if (win.mode == .tiled) {
            insertIntoTiling(source_workspace_id, wid);
        }
    }

    _ = maybeSetFocusedDisplayForWindow(win, .keyboard);
    retile();
    return true;
}

/// Moves the currently focused managed window to another display slot.
fn moveWindowToDisplay(target_display_slot: u8) void {
    if (target_display_slot == 0) return;
    const slot: usize = @intCast(target_display_slot - 1);
    if (slot >= g_display_count) return;

    const target_display_id = g_displays[slot].id;
    if (focusedManagedLeaderWindow()) |focused_win| {
        _ = moveManagedWindowToDisplay(focused_win.wid, target_display_id);
        return;
    }

    const source_display_id = focusedDisplayId();
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
    _ = moveManagedWindowToDisplay(wid, target_display_id);
}

fn moveWorkspaceToDisplay(target_display_slot: usize) void {
    if (target_display_slot >= g_display_count) return;

    const source_display_id = focusedDisplayId();
    const source_slot = displayIndexById(source_display_id) orelse return;
    const target_display_id = g_displays[target_display_slot].id;
    if (source_display_id == target_display_id) return;

    const moving_ws_id = g_workspaces.activeIdForDisplaySlot(source_slot);
    const displaced_ws_id = g_workspaces.activeIdForDisplaySlot(target_display_slot);
    const moving_ws = g_workspaces.get(moving_ws_id) orelse return;
    const displaced_ws = g_workspaces.get(displaced_ws_id) orelse return;

    // Hide displaced workspace's windows on target display
    const hctx = HideCtx.init(target_display_id);
    for (displaced_ws.windows.items) |wid| {
        const visible_wid = g_tab_groups.resolveActive(wid);
        const hide_wid = if (g_store.get(visible_wid) != null) visible_wid else wid;
        if (g_store.get(hide_wid)) |win| {
            if (win.display_id != target_display_id) continue;
            hctx.hide(win.pid, hide_wid);
        }
    }

    // Migrate moving workspace's windows to the target display
    for (moving_ws.windows.items) |wid| {
        if (g_store.get(wid)) |w| {
            var updated = w;
            updated.display_id = target_display_id;
            g_store.put(updated) catch {};
            updateTabGroupAssignment(wid, moving_ws.id, target_display_id);
        }
    }

    // Moving workspace takes the target display
    g_workspaces.setActiveForDisplaySlot(target_display_slot, moving_ws_id);
    moving_ws.display_id = target_display_id;

    // Source display needs a new active workspace; pick first hidden one
    // assigned to it, or fall back to the displaced workspace.
    var fallback_id: u8 = displaced_ws_id;
    for (g_workspaces.workspaces[0..g_workspaces.workspace_count]) |ws| {
        if (ws.id == moving_ws_id) continue;
        if (ws.display_id != source_display_id) continue;
        if (workspaceVisibleAnywhere(ws.id)) continue;
        fallback_id = ws.id;
        break;
    }
    g_workspaces.setActiveForDisplaySlot(source_slot, fallback_id);
    if (g_workspaces.get(fallback_id)) |fb_ws| {
        fb_ws.display_id = source_display_id;
    }
    assertDisplayCoverage();

    startWorkspaceTransition(.move_workspace_to_display, moving_ws_id, target_display_id);
    retile();
    setFocusedDisplay(target_display_id);
    updateStatusBar();

    if (g_workspace_transition.isActive()) {
        g_pending_focus_count = 0;
    }

    if (g_workspace_transition.isActive()) {
        if (g_workspaces.get(moving_ws_id)) |ws| {
            focusWorkspaceWindow(ws);
        }
    }
}

fn moveWorkspaceToDisplayNext() void {
    if (g_display_count <= 1) return;
    const source_slot = displayIndexById(focusedDisplayId()) orelse return;
    const target_slot = (source_slot + 1) % g_display_count;
    moveWorkspaceToDisplay(target_slot);
}

fn moveWorkspaceToDisplayPrev() void {
    if (g_display_count <= 1) return;
    const source_slot = displayIndexById(focusedDisplayId()) orelse return;
    const target_slot = if (source_slot == 0) g_display_count - 1 else source_slot - 1;
    moveWorkspaceToDisplay(target_slot);
}

// Focus direction

const FocusDir = ipc.IpcCommand.FocusDir;

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
            _ = maybeSetFocusedDisplayForWindow(win, .keyboard);
            setTilingActive(win.workspace_id, actual_wid);
        }
        return;
    }

    const sp = tilingStatePtr(focused.workspace_id);
    const st = sp.* orelse return;
    const stack_forward = switch (dir) {
        .left, .up => false,
        .right, .down => true,
    };
    if (st.cycleFocus(focused_wid, stack_forward)) |stack_wid| {
        if (g_store.get(stack_wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, stack_wid);
            ws.focused_wid = stack_wid;
            _ = maybeSetFocusedDisplayForWindow(win, .keyboard);
            setTilingActive(win.workspace_id, stack_wid);
        }
    }
}

// IPC command dispatch

fn ipcDispatch(cmd: []const u8, client_fd: posix.socket_t) void {
    const started_ns = nanoTimestamp();
    defer {
        const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
        log.debug("[trace] ipc dispatch cmd={s} elapsed_ms={}", .{ cmd, elapsed_ms });
    }

    const command = ipc.IpcCommand.parse(cmd) orelse {
        ipc.writeResponse(client_fd, "err: unknown or invalid command\n");
        return;
    };

    switch (command) {
        .retile => {
            retile();
            ipc.writeResponse(client_fd, "ok\n");
        },
        .toggle_split => {
            g_bsp_split_mode = switch (g_bsp_split_mode) {
                .auto => .horizontal,
                .horizontal => .vertical,
                .vertical => .auto,
            };
            ipc.writeResponse(client_fd, "ok\n");
        },
        .focus => |dir| {
            focusDirection(dir);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .focus_workspace => |target| {
            switch (target) {
                .prev => {
                    if (!switchAdjacentWorkspaceHandled(.previous)) {
                        ipc.writeResponse(client_fd, "pass\n");
                        return;
                    }
                },
                .next => {
                    if (!switchAdjacentWorkspaceHandled(.next)) {
                        ipc.writeResponse(client_fd, "pass\n");
                        return;
                    }
                },
                .index => |n| switchWorkspace(n),
            }
            ipc.writeResponse(client_fd, "ok\n");
        },
        .move_to_workspace => |n| {
            moveWindowToWorkspace(n);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .move_to_display => |n| {
            moveWindowToDisplay(n);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .move_workspace_to_display => |target| switch (target) {
            .next => {
                moveWorkspaceToDisplayNext();
                ipc.writeResponse(client_fd, "ok\n");
            },
            .prev => {
                moveWorkspaceToDisplayPrev();
                ipc.writeResponse(client_fd, "ok\n");
            },
            .index => |n| {
                if (n == 0) {
                    ipc.writeResponse(client_fd, "err: display number starts at 1\n");
                    return;
                }
                moveWorkspaceToDisplay(@as(usize, n) - 1);
                ipc.writeResponse(client_fd, "ok\n");
            },
        },
        .bsp_ratio_rel => |delta| {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            if (!bsp_state.adjustParentRatio(ctx.focused_wid, delta)) {
                ipc.writeResponse(client_fd, "err: no parent split\n");
                return;
            }
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_ratio_abs => |ratio| {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            if (!bsp_state.setParentRatio(ctx.focused_wid, ratio)) {
                ipc.writeResponse(client_fd, "err: no parent split\n");
                return;
            }
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_insert_point => |point| {
            g_config.bsp_insert_point = point;
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_mirror => |axis| {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            bsp_state.mirrorTree(axis);
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_equalize => {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            bsp_state.equalizeTree(null, g_config.bsp_split_ratio);
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_balance => {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            bsp_state.balanceTree(null);
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_rotate => |degrees| {
            if (!(degrees == 90 or degrees == 180 or degrees == 270)) {
                ipc.writeResponse(client_fd, "err: expected 90|180|270\n");
                return;
            }
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            const bsp_state: *bsp_mod.State = switch (ctx.state.*) {
                .bsp => |*s| s,
                else => {
                    ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                    return;
                },
            };
            bsp_state.rotateTree(degrees);
            retileDisplay(ctx.focused_win.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .query_windows => |format| ipcQueryWindows(client_fd, format),
        .query_workspaces => |format| ipcQueryWorkspaces(client_fd, format),
        .query_displays => |format| ipcQueryDisplays(client_fd, format),
        .query_apps => |format| ipcQueryApps(client_fd, format),
    }
}

fn ipcQueryWindows(fd: posix.socket_t, format: ipc.IpcCommand.QueryFormat) void {
    const started_ns = nanoTimestamp();
    const ws = g_workspaces.active();
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;
    var written: usize = 0;

    switch (format) {
        .text => for (ws.windows.items) |wid| {
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
        },
        .json => {
            var json: std.json.Stringify = .{ .writer = w };
            json.beginArray() catch {};
            for (ws.windows.items) |wid| {
                if (g_store.get(wid)) |win| {
                    var id_buf: [256]u8 = undefined;
                    const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
                    const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                    writeWindowJson(&json, win, bundle_id) catch break;
                    written += 1;
                }
            }
            json.endArray() catch {};
            w.writeByte('\n') catch {};
        },
    }

    const payload = out.written();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query windows rows={} bytes={} elapsed_ms={}", .{ written, payload.len, elapsed_ms });
}

fn ipcQueryApps(fd: posix.socket_t, format: ipc.IpcCommand.QueryFormat) void {
    const started_ns = nanoTimestamp();
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;

    var seen_pids: [256]i32 = undefined;
    var seen_count: usize = 0;
    var written: usize = 0;

    var json: std.json.Stringify = .{ .writer = w };
    if (format == .json) json.beginArray() catch {};

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

                switch (format) {
                    .text => w.print("{s}\t{d}\n", .{ bundle_id, win.pid }) catch break,
                    .json => {
                        json.beginObject() catch break;
                        json.objectField("bundle_id") catch break;
                        json.write(bundle_id) catch break;
                        json.objectField("process_id") catch break;
                        json.write(win.pid) catch break;
                        json.endObject() catch break;
                    },
                }
                written += 1;
            }
        }
    }

    if (format == .json) {
        json.endArray() catch {};
        w.writeByte('\n') catch {};
    }

    const payload = out.written();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query apps rows={} unique_pids={} bytes={} elapsed_ms={}", .{ written, seen_count, payload.len, elapsed_ms });
}

fn ipcQueryWorkspaces(fd: posix.socket_t, format: ipc.IpcCommand.QueryFormat) void {
    const started_ns = nanoTimestamp();
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;

    switch (format) {
        .text => for (&g_workspaces.workspaces) |*ws| {
            const focused: u32 = ws.focused_wid orelse 0;
            w.print("{d} {s} {d} {d}\n", .{
                ws.id,
                if (workspaceVisibleAnywhere(ws.id)) "visible" else "hidden",
                focused,
                ws.windows.items.len,
            }) catch break;
        },
        .json => {
            var json: std.json.Stringify = .{ .writer = w };
            json.beginArray() catch {};
            for (&g_workspaces.workspaces) |*ws| {
                json.beginObject() catch break;
                json.objectField("workspace_id") catch break;
                json.write(ws.id) catch break;
                json.objectField("visible") catch break;
                json.write(workspaceVisibleAnywhere(ws.id)) catch break;
                json.objectField("focused_window") catch break;
                json.write(ws.focused_wid) catch break;
                json.objectField("windows") catch break;
                json.beginArray() catch break;
                for (ws.windows.items) |wid| {
                    const win = g_store.get(wid) orelse continue;
                    var id_buf: [256]u8 = undefined;
                    const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
                    const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                    writeWindowJson(&json, win, bundle_id) catch break;
                }
                json.endArray() catch break;
                json.endObject() catch break;
            }
            json.endArray() catch {};
            w.writeByte('\n') catch {};
        },
    }

    const payload = out.written();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query workspaces rows={} bytes={} elapsed_ms={}", .{ g_workspaces.workspaces.len, payload.len, elapsed_ms });
}

fn ipcQueryDisplays(fd: posix.socket_t, format: ipc.IpcCommand.QueryFormat) void {
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;

    switch (format) {
        .text => for (g_displays[0..g_display_count], 0..) |display, slot| {
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
        },
        .json => {
            var json: std.json.Stringify = .{ .writer = w };
            json.beginArray() catch {};
            for (g_displays[0..g_display_count], 0..) |display, slot| {
                const workspace_id = g_workspaces.activeIdForDisplaySlot(slot);
                json.beginObject() catch break;
                json.objectField("display_num") catch break;
                json.write(slot + 1) catch break;
                json.objectField("display_id") catch break;
                json.write(display.id) catch break;
                json.objectField("workspace_id") catch break;
                json.write(workspace_id) catch break;
                json.objectField("visible_frame") catch break;
                json.beginObject() catch break;
                json.objectField("x") catch break;
                json.print("{d:.0}", .{display.visible.x}) catch break;
                json.objectField("y") catch break;
                json.print("{d:.0}", .{display.visible.y}) catch break;
                json.objectField("width") catch break;
                json.print("{d:.0}", .{display.visible.w}) catch break;
                json.objectField("height") catch break;
                json.print("{d:.0}", .{display.visible.h}) catch break;
                json.endObject() catch break;
                json.endObject() catch break;
            }
            json.endArray() catch {};
            w.writeByte('\n') catch {};
        },
    }

    ipc.writeResponse(fd, out.written());
}

fn writeWindowJson(json: *std.json.Stringify, win: window_mod.Window, bundle_id: []const u8) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("window_id");
    try json.write(win.wid);
    try json.objectField("process_id");
    try json.write(win.pid);
    try json.objectField("bundle_id");
    try json.write(bundle_id);
    try json.objectField("workspace_id");
    try json.write(win.workspace_id);
    try json.objectField("display_id");
    try json.write(win.display_id);
    try json.objectField("frame");
    try json.beginObject();
    try json.objectField("x");
    try json.print("{d:.0}", .{win.frame.x});
    try json.objectField("y");
    try json.print("{d:.0}", .{win.frame.y});
    try json.objectField("width");
    try json.print("{d:.0}", .{win.frame.width});
    try json.objectField("height");
    try json.print("{d:.0}", .{win.frame.height});
    try json.endObject();
    try json.endObject();
}
