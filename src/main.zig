const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const filelog = @import("filelog.zig");
const log_options = @import("log_options.zig");
const c = @import("c");
const cg_extra = @import("cg_extra");
const objc = @import("objc");
const shim = @import("shim_api.zig");
const skylight = @import("skylight.zig");
const state_mod = @import("state.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const workspace_mod = @import("workspace.zig");
const tiling = @import("tiling.zig");
const bsp_mod = tiling.bsp_mod;
const ipc = @import("ipc.zig");
const ipc_transport = @import("ipc_transport.zig");
const signal_transport = @import("signal_transport.zig");
const tabgroup = @import("tabgroup.zig");
const config_mod = @import("config.zig");
const dim = @import("dim.zig");
const statusbar = @import("statusbar.zig");
const tile_preview = @import("tile_preview.zig");
const ax_observer = @import("ax_observer.zig");
const osutil = @import("osutil.zig");
const loginitem = @import("loginitem.zig");
const objc_classes = @import("objc_classes.zig");
const animation_mod = @import("animation.zig");
const ax_mod = @import("ax.zig");
const geometry_mod = @import("geometry.zig");
const spsc_queue = @import("spsc_queue.zig");

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
    .log_level = log_options.level,
    .logFn = filelog.logFn,
};

const log = std.log.scoped(.bobrwm);

const EventQueue = spsc_queue.Queue(event_mod.Event, 1024);

// Hidden-window position (bottom-right corner, barely visible)

/// Pixels visible in the corner when a window is hidden off-screen.
const hide_peek: f64 = 5;
/// Poll cadence for windows that are waiting on role readiness or visibility.
const role_poll_interval_ms: u64 = 100;
/// Keep one slow app AX server from monopolizing the main event drain.
const role_poll_ax_timeout_s: f32 = 0.025;
const role_poll_work_budget_ms: i128 = 30;
/// Retry budget for deferred candidates before they are dropped or fall back.
/// Electron-family apps can take multiple seconds before publishing stable AX roles.
const role_poll_attempts_max: u8 = 50;
/// Launch retry budget to re-run discovery after app startup settles.
const app_launch_retry_attempts_max: u8 = 10;
/// Capacity reserved for wid-keyed role/deferred maps to avoid growth churn.
const pending_role_window_capacity: usize = 256;
const deferred_window_candidate_capacity: usize = 256;
/// Geometry entries are wid-keyed and include suppressed native-tab members.
/// Match the bounded WindowServer snapshots used by discovery and cleanup.
const geometry_window_capacity: u32 = 512;
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
/// Quiet period after the last display notification before the trailing
/// reconcile runs. macOS emits a burst of display_changed events while a
/// hotplug/wake arrangement settles; the leading-edge debounce can land us on
/// an intermediate topology, so a reconcile this long after the final event
/// converges on the settled arrangement.
const display_settle_delay_s: f64 = 0.25;
/// A successful AX write can precede the corresponding WindowServer move.
/// Keep the outgoing workspace covering the display while polling for the
/// incoming physical frames; the deferred path handles slower applications.
const workspace_reveal_poll_interval_us: u32 = 500;
const workspace_reveal_wait_max_us: u32 = 50_000;
const workspace_reveal_deferred_timeout_s: f64 = 1.0;

const DisplayInfo = struct {
    id: u32,
    /// Stable per-display identity (CGDisplayCreateUUIDFromDisplayID) used to
    /// re-match a monitor across sleep/wake and unplug/replug, when macOS may
    /// hand it a different `id`. Null only for the synthetic fallback display.
    uuid: ?[16]u8,
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

const FocusEventSource = state_mod.FocusEventSource;

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

const WorkspaceTransitionKind = state_mod.WorkspaceTransitionKind;
const WorkspaceTransitionCompletionReason = state_mod.WorkspaceTransitionCompletionReason;

const PendingWorkspacePark = struct {
    outgoing: state_mod.SpaceRef,
    target: state_mod.SpaceRef,
    deadline_at_s: f64,
};

const cleanup_pid_capacity_per_drain: usize = 16;

const PendingRoleWindow = struct {
    pid: i32,
    attempts_remaining: u8,
    space: state_mod.SpaceRef,
};

const PendingRoleCandidate = struct {
    pid: i32,
    wid: u32,
    from_timeout: bool,
    space: state_mod.SpaceRef,
};

const DeferredWindowCandidate = struct {
    pid: i32,
    attempts_remaining: u8,
    space: state_mod.SpaceRef,
};

const DeferredWindowPromotion = struct {
    pid: i32,
    wid: u32,
    space: state_mod.SpaceRef,
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

// AX attribute strings and window-frame plumbing live in ax.zig; aliases
// keep the many existing call sites unchanged.
const AxStrings = ax_mod.AxStrings;
const ensureAxStrings = ax_mod.strings;
const deinitAxStrings = ax_mod.deinitStrings;
const findAxWindow = ax_mod.findWindow;
const axEnhancedUserInterface = ax_mod.enhancedUserInterface;

fn displayIndexById(display_id: u32) ?usize {
    for (g_displays[0..g_display_count], 0..) |display, i| {
        if (display.id == display_id) return i;
    }
    return null;
}

/// Resolve a display UUID snapshot to the present display's numeric id.
/// Returns null for a null snapshot or when the monitor is no longer attached.
fn displayIdForUuid(uuid_opt: ?[16]u8) ?u32 {
    const uuid = uuid_opt orelse return null;
    for (g_displays[0..g_display_count]) |display| {
        const display_uuid = display.uuid orelse continue;
        if (std.mem.eql(u8, &display_uuid, &uuid)) return display.id;
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
    return g_state.activeWorkspace(display_id) orelse unreachable;
}

fn spaceForWorkspace(display_id: u32, workspace_id: u8) ?*workspace_mod.Space {
    const ref = g_state.spaceForWorkspace(display_id, workspace_id) orelse return null;
    return g_workspaces.get(ref.key);
}

fn spaceForWindow(win: window_mod.Window) ?*workspace_mod.Space {
    return g_workspaces.get(win.space.key);
}

fn spaceForCommand(_: u32, workspace_id: u8) ?*workspace_mod.Space {
    const space_ref = g_state.logicalWorkspace(workspace_id) orelse return null;
    return g_workspaces.get(space_ref.key);
}

fn applySpaceCatalog(catalog: state_mod.SpaceCatalog) void {
    dispatchStateEvent(.{ .replace_space_catalog = catalog });

    for (catalog.spaces[0..catalog.space_count]) |space_ref| {
        const space = g_workspaces.get(space_ref.key) orelse continue;
        space.ref = space_ref;
        for (space.windows.items) |wid| {
            if (!assignManagedWindowSpace(wid, space_ref)) continue;
            updateTabGroupAssignment(wid, space_ref);
        }
    }
}

fn setVirtualSpaceDisplay(catalog: *state_mod.SpaceCatalog, workspace_id: u8, display_id: u32) void {
    for (catalog.spaces[0..catalog.space_count]) |*space_ref| {
        if (!space_ref.key.eql(.{ .virtual = workspace_id })) continue;
        space_ref.display_id = display_id;
        return;
    }
    unreachable;
}

fn activeWorkspace() *workspace_mod.Space {
    const workspace_id = activeWorkspaceIdForDisplay(focusedDisplayId());
    return spaceForWorkspace(focusedDisplayId(), workspace_id) orelse unreachable;
}

fn focusedWorkspaceWindow(space: *const workspace_mod.Space) ?u32 {
    return g_state.focusedWorkspaceWindow(space.ref.workspace_id);
}

fn recordWorkspaceFocus(space: *const workspace_mod.Space, wid: u32) void {
    dispatchStateEvent(.{ .record_workspace_focus = .{
        .workspace_id = space.ref.workspace_id,
        .window_id = wid,
    } });
}

fn nativeStateNowMs() state_mod.TimestampMs {
    const seconds = c.CFAbsoluteTimeGetCurrent();
    if (seconds <= 0) return 0;
    return @intFromFloat(seconds * std.time.ms_per_s);
}

fn nativeSwitchPending() bool {
    return nativeSpacesEnabled() and g_state.isNativeSwitchPending();
}

fn workspaceTraversalDirectionFromAction(action: u8) ?WorkspaceTraversalDirection {
    if (action == shim.BW_HK_FOCUS_PREVIOUS_WORKSPACE) return .previous;
    if (action == shim.BW_HK_FOCUS_NEXT_WORKSPACE) return .next;
    return null;
}

fn adjacentWorkspaceId(direction: WorkspaceTraversalDirection) ?u8 {
    const focused_display_id = focusedDisplayId();
    const workspace_count = g_workspaces.workspace_count;
    std.debug.assert(workspace_count > 0);
    std.debug.assert(workspace_count <= workspace_mod.max_workspaces);

    const base_id = if (nativeSpacesEnabled())
        g_state.desiredWorkspace(focused_display_id) orelse activeWorkspaceIdForDisplay(focused_display_id)
    else
        activeWorkspace().ref.workspace_id;
    std.debug.assert(base_id > 0 and base_id <= workspace_count);

    return switch (direction) {
        .previous => if (base_id > 1) base_id - 1 else null,
        .next => if (base_id < workspace_count) base_id + 1 else null,
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
        _ = adjacentWorkspaceId(direction) orelse return .pass_through;
        return .{ .emit = .{ .kind = binding.action, .arg = 0 } };
    }

    return .{ .emit = .{ .kind = binding.action, .arg = binding.arg } };
}

fn spaceVisible(space: state_mod.SpaceRef) bool {
    const active = g_state.spaceForWorkspace(space.display_id, activeWorkspaceIdForDisplay(space.display_id)) orelse return false;
    return active.key.eql(space.key);
}

/// A managed window is "visible" for borders/dimming when it is on a visible
/// workspace and is not a suppressed tab member. Shared predicate so the
/// borders and dimming snapshots stay in agreement about what is on screen.
fn isVisibleManaged(win: *const window_mod.Window) bool {
    if (g_tab_groups.isSuppressed(win.wid)) return false;
    return spaceVisible(win.space);
}

/// Dim every visible managed window except the focused one with black overlay
/// panels. Callers must gate on `dim.enabled`. Uses the store's settled frames
/// directly (no WindowServer round-trip): retile and move/resize events have
/// already synchronized them by the time this runs at the end of the drain.
fn pushDimSnapshot() void {
    // Precondition: callers gate on dim.enabled, so the disabled feature never
    // reaches the window-scan loops below. Assert rather than early-return so
    // the invariant is documented and compiles out in release builds.
    std.debug.assert(dim.enabled);

    // An overlay is placed over the window's *stored* frame, so a store entry
    // that is not on screen — a stale native-tab id, a window an app closed to
    // background — darkens whatever sits underneath it instead. One entry
    // holding a display-sized frame blacks out the display.
    const on_screen = OnScreenWindows.snapshot();

    var entries: [256]dim.Entry = undefined;
    var n: usize = 0;
    var it = g_store.windows.valueIterator();
    while (it.next()) |win| {
        if (n >= entries.len) break;
        if (!isVisibleManaged(win)) continue;
        if (!on_screen.contains(win.wid)) continue;
        entries[n] = .{
            .wid = win.wid,
            .x = win.frame.x,
            .y = win.frame.y,
            .w = win.frame.width,
            .h = win.frame.height,
        };
        n += 1;
    }

    // Keep the focused window of every display's visible workspace bright, not
    // just the single globally-focused one, so a multi-display active window
    // is not dimmed.
    var focused: [g_displays.len]u32 = undefined;
    var fn_count: usize = 0;
    for (0..g_display_count) |slot| {
        const ws_id = activeWorkspaceIdForDisplay(g_displays[slot].id);
        const ws = spaceForWorkspace(g_displays[slot].id, ws_id) orelse continue;
        const wid = focusedWorkspaceWindow(ws) orelse continue;
        // Workspace focus records the tab-group leader, but the window on
        // screen (and in `entries`) is the group's active tab. Resolve so a
        // focused non-leader tab is exempted instead of dimmed.
        focused[fn_count] = g_tab_groups.resolveActive(wid);
        fn_count += 1;
    }

    dim.apply(focused[0..fn_count], entries[0..n]);
}

fn focusedDisplayId() u32 {
    return g_state.focusedDisplay() orelse unreachable;
}

fn setFocusedDisplay(display_id: u32) void {
    if (displayIndexById(display_id) == null) return;
    dispatchStateEvent(.{ .focus_display = display_id });
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

fn managedLeaderForFocusedWindow(pid: i32, focused_wid: u32) ?window_mod.Window {
    std.debug.assert(pid > 0);
    std.debug.assert(focused_wid != 0);
    const leader_wid = g_tab_groups.resolveLeader(focused_wid);
    const leader = g_store.get(leader_wid) orelse return null;
    if (leader.pid != pid) return null;
    return leader;
}

/// Resolve the frontmost app's AX-focused window to its visible layout owner.
fn reconciledFocusedWindowId() ?u32 {
    const pid = frontmostApplicationPid() orelse return null;
    const focused_wid = focusedWindowIdForPid(pid) orelse return null;

    if (managedLeaderForFocusedWindow(pid, focused_wid)) |win| {
        if (spaceVisible(win.space)) {
            // A known suppressed member can become AX-focused without a
            // notification reaching the main loop first. The leader owns the
            // fullscreen flag, but retile must address this active member.
            if (!g_state.isWorkspaceTransitionActive()) {
                _ = syncFocusStateForWindowId(focused_wid, .keyboard);
            }
            return win.wid;
        }
    }

    // Native tabs can replace the focused CG window ID without emitting a
    // creation event. Do not send the first hotkey after a tab switch to the
    // stale workspace cache: reconcile the AX-reported ID synchronously, then
    // resolve it back to the group's slot. Transition focus remains isolated
    // until its settle window closes, as with asynchronous AX focus events.
    if (!g_state.isWorkspaceTransitionActive()) {
        log.debug("hotkey target reconciling unknown focused window pid={d} wid={d}", .{ pid, focused_wid });
        reconcileFocusedWindow(pid, focused_wid);
        if (managedLeaderForFocusedWindow(pid, focused_wid)) |win| {
            if (spaceVisible(win.space)) return win.wid;
        }
    }

    return null;
}

const ActionContext = struct {
    focused_wid: u32,
    focused_win: window_mod.Window,
    workspace: *workspace_mod.Space,
};

fn actionContext() ?ActionContext {
    const focused_wid = reconciledFocusedWindowId() orelse return null;
    const focused_win = g_store.get(focused_wid) orelse return null;
    if (!spaceVisible(focused_win.space)) return null;

    const workspace = spaceForWindow(focused_win) orelse return null;
    return .{
        .focused_wid = focused_wid,
        .focused_win = focused_win,
        .workspace = workspace,
    };
}

fn markWorkspaceTransitionComplete(reason: WorkspaceTransitionCompletionReason) void {
    const transition = g_state.workspace_transition orelse return;
    if (transition.completion_reason != null) return;

    dispatchStateEvent(.{ .complete_workspace_transition = .{
        .epoch = transition.epoch,
        .reason = reason,
        .at_ms = nativeStateNowMs(),
    } });
    log.debug("workspace transition marked complete epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
        transition.epoch,
        @tagName(transition.kind),
        transition.target.workspace_id,
        transition.target.display_id,
        @tagName(reason),
    });
}

fn startWorkspaceTransition(kind: WorkspaceTransitionKind, target_space: state_mod.SpaceRef) void {
    target_space.assertValid();
    std.debug.assert(g_state.space(target_space.key) != null);

    dispatchStateEvent(.{ .start_workspace_transition = .{
        .kind = kind,
        .target = target_space,
        .at_ms = nativeStateNowMs(),
    } });
}

fn inWorkspaceTransition() bool {
    return g_state.isWorkspaceTransitionActive();
}

fn applyPendingFocusEntry(entry: state_mod.PendingFocus) void {
    if (!g_state.isWorkspaceTransitionActive()) return;
    const transition = g_state.workspace_transition.?;
    const target_space = transition.target;
    if (!entry.space_key.eql(target_space.key)) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=workspace-mismatch entry_workspace={d} target_workspace={d}", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
            if (g_state.space(entry.space_key)) |space| space.workspace_id else 0,
            target_space.workspace_id,
        });
        return;
    }

    const win = g_store.get(entry.window_id) orelse {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=missing-store", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
        });
        return;
    };
    if (win.pid != entry.process_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=pid-mismatch store_pid={d}", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
            win.pid,
        });
        return;
    }
    if (!win.space.key.eql(entry.space_key)) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=store-space-changed store_workspace={d}", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
            win.space.workspace_id,
        });
        return;
    }

    observeWindowFocus(win, entry.source, entry.transition_epoch);
}

fn processPendingFocusQueue() void {
    if (!g_state.isWorkspaceTransitionActive()) return;
    if (!g_state.hasPendingFocus()) return;

    dispatchStateEvent(.request_pending_focus);
}

fn clearPendingFocusQueue() void {
    if (!g_state.hasPendingFocus()) return;
    dispatchStateEvent(.clear_pending_focus);
}

fn observeWindowFocus(win: window_mod.Window, source: FocusEventSource, pending_transition_epoch: ?state_mod.Epoch) void {
    dispatchStateEvent(.{ .window_focus_observed = .{
        .process_id = win.pid,
        .window_id = win.wid,
        .source = source,
        .target = win.space,
        .is_target_visible = spaceVisible(win.space),
        .at_ms = nativeStateNowMs(),
        .pending_transition_epoch = pending_transition_epoch,
    } });
}

/// Follow focus into a hidden workspace. `focused_wid` is the window the AX
/// event named; `win` is its group leader, which owns the workspace slot.
///
/// Hidden focus is deferred through the entire transition, including the
/// settle tail: late AX focus from the workspace just parked can otherwise
/// reverse an accepted switch and create a two-workspace feedback loop. The
/// deferred replay validates the frontmost app once synthetic events settle,
/// preserving a genuine fast Cmd+Tab without following stale AX fallout.
fn switchToWindowWorkspaceIfHidden(win: window_mod.Window, focused_wid: u32, source: FocusEventSource) void {
    std.debug.assert(win.wid != 0);
    std.debug.assert(focused_wid != 0);
    win.space.assertValid();

    dispatchStateEvent(.{ .follow_focus_observed = .{
        .process_id = win.pid,
        .window_id = focused_wid,
        .leader_window_id = win.wid,
        .source = source,
        .target = win.space,
        .is_target_visible = spaceVisible(win.space),
    } });
}

/// Replay a follow-focus intent that a mid-flight transition deferred. Called
/// the moment the transition clears. Bails when the window is gone, already
/// visible, or no longer owns app focus — by then the intent is stale.
fn applyDeferredFollowFocus(deferred: ?state_mod.DeferredFollowFocus) void {
    std.debug.assert(!g_state.isWorkspaceTransitionActive());

    const focus = deferred orelse return;

    const leader = g_store.get(g_tab_groups.resolveLeader(focus.window_id)) orelse return;
    if (leader.pid != focus.process_id) return;
    if (spaceVisible(leader.space)) return;

    const front_pid = frontmostApplicationPid() orelse return;
    if (front_pid != focus.process_id) {
        log.debug("follow focus replay dropped wid={d} pid={d} reason=focus-moved front_pid={d}", .{
            focus.window_id,
            focus.process_id,
            front_pid,
        });
        return;
    }

    log.debug("follow focus replaying wid={d} pid={d} workspace={d} display={d}", .{
        focus.window_id,
        focus.process_id,
        leader.space.workspace_id,
        leader.space.display_id,
    });
    _ = syncFocusStateForWindowId(focus.window_id, focus.source);
}

/// During a workspace transition, AX focus events from non-target
/// workspaces/displays are lagging or synthetic (hide/retile side effects,
/// native-tab ID swaps). Recording them would clobber the source workspace's
/// remembered focus, so switching back would focus the wrong window.
fn shouldRecordWorkspaceFocusForWindow(win: window_mod.Window) bool {
    if (!g_state.isWorkspaceTransitionActive()) return true;

    const transition = g_state.workspace_transition.?;
    return win.space.key.eql(transition.target.key);
}

fn syncFocusStateForWindowId(focused_wid: u32, source: FocusEventSource) bool {
    std.debug.assert(focused_wid != 0);

    const leader = g_tab_groups.resolveLeader(focused_wid);
    std.debug.assert(leader != 0);

    const win = g_store.get(leader) orelse return false;
    std.debug.assert(win.wid == leader);

    // Window ID is the canonical identity. PID-only notifications are resolved
    // before this point so same-process windows do not overwrite each other.
    setTabGroupActive(focused_wid);
    observeWindowFocus(win, source, null);
    if (shouldRecordWorkspaceFocusForWindow(win)) {
        if (spaceForWindow(win)) |ws| recordWorkspaceFocus(ws, leader);
        setTilingActive(win.space.key, focused_wid);
    } else {
        const transition = g_state.workspace_transition.?;
        const target = transition.target;
        log.debug("workspace transition focus memory skipped epoch={d} wid={d} leader={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d}", .{
            transition.epoch,
            focused_wid,
            leader,
            @tagName(source),
            win.space.workspace_id,
            win.space.display_id,
            target.workspace_id,
            target.display_id,
        });
    }
    switchToWindowWorkspaceIfHidden(win, focused_wid, source);

    return true;
}

/// Refresh stored frames of visible managed windows from WindowServer bounds.
///
/// Move/resize events are suppressed while a workspace transition is active,
/// so a retile whose target is smaller than an app's minimum size (the app
/// clamps the resize) leaves the store holding the intended tile frame while
/// the real window is larger. Nothing re-reads the frame after the transition,
/// so frame consumers such as the dimming overlays stay mismatched until the
/// app happens to emit another move/resize. Called when a transition clears —
/// the moment suppression ends — to converge the store on physical geometry.
fn reconcileVisibleFramesFromWindowServer() void {
    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();

    var it = g_store.windows.valueIterator();
    while (it.next()) |win| {
        if (!isVisibleManaged(win)) continue;

        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(conn, win.wid, &rect) != 0) continue;

        const frame: window_mod.Window.Frame = .{
            .x = rect.origin.x,
            .y = rect.origin.y,
            .width = rect.size.width,
            .height = rect.size.height,
        };
        seedObservedFrame(win.wid, frame);
        if (framesEqual(win.frame, frame)) continue;

        log.debug("frame reconcile wid={d} stored x={d:.0} y={d:.0} w={d:.0} h={d:.0} actual x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
            win.wid,
            win.frame.x,
            win.frame.y,
            win.frame.width,
            win.frame.height,
            frame.x,
            frame.y,
            frame.width,
            frame.height,
        });
        win.frame = frame;
    }
}

fn tickWorkspaceTransitionState() void {
    processPendingFocusQueue();

    const transition = g_state.workspace_transition orelse return;
    const at_ms = nativeStateNowMs();
    if (at_ms < transition.deadline_at_ms) return;

    dispatchStateEvent(.{ .workspace_transition_timer_fired = .{
        .epoch = transition.epoch,
        .at_ms = at_ms,
    } });
}

fn assertDisplayCoverage() void {
    if (@import("builtin").mode != .Debug) return;
    for (0..g_display_count) |slot| {
        const ws_id = activeWorkspaceIdForDisplay(g_displays[slot].id);
        std.debug.assert(spaceForWorkspace(g_displays[slot].id, ws_id) != null);
        if (nativeSpacesEnabled()) continue;

        for (0..g_display_count) |other| {
            if (other == slot) continue;
            std.debug.assert(activeWorkspaceIdForDisplay(g_displays[other].id) != ws_id);
        }
    }
}

fn updateStatusBar() void {
    const summaries = g_state.workspaceSummaries(g_workspaces.workspace_count);
    statusbar.updateState(summaries[0..g_workspaces.workspace_count]);
}

fn clearTilingStates() void {
    for (0..workspace_mod.max_spaces) |ws_idx| {
        g_tiling_states[ws_idx] = null;
    }
}

fn destroyAllTilingStates() void {
    for (0..workspace_mod.max_spaces) |ws_idx| {
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
/// Stable UUID bytes for a display id, or null if unavailable.
fn displayUuidBytes(display_id: u32) ?[16]u8 {
    const uuid_ref = cg_extra.CGDisplayCreateUUIDFromDisplayID(display_id) orelse return null;
    defer c.CFRelease(@ptrCast(uuid_ref));
    const bytes: [16]u8 = @bitCast(c.CFUUIDGetUUIDBytes(uuid_ref));
    return bytes;
}

/// Remembers, per physical display (keyed by stable UUID), the workspace that
/// was active on it. Persists across a display being absent so a monitor that
/// returns (staggered wake, replug) reclaims its workspace instead of
/// defaulting. In-memory only. Deliberately does not remember numeric display
/// ids: macOS reuses CGDirectDisplayIDs, so a remembered id can belong to a
/// different monitor by the time it is recalled.
const DisplayMemoryEntry = struct {
    uuid: [16]u8,
    active_ws: u8,
};

const display_memory_capacity = 16;
var g_display_memory: [display_memory_capacity]DisplayMemoryEntry = undefined;
var g_display_memory_count: usize = 0;

/// Record each present display's active workspace, keyed by UUID.
fn rememberDisplayWorkspaces() void {
    for (g_displays[0..g_display_count]) |display| {
        const uuid = display.uuid orelse continue;
        upsertDisplayMemory(uuid, activeWorkspaceIdForDisplay(display.id));
    }
}

fn upsertDisplayMemory(uuid: [16]u8, active_ws: u8) void {
    for (g_display_memory[0..g_display_memory_count]) |*entry| {
        if (std.mem.eql(u8, &entry.uuid, &uuid)) {
            entry.active_ws = active_ws;
            return;
        }
    }
    if (g_display_memory_count == display_memory_capacity) {
        // Evict oldest; cycling through more than 16 distinct monitors in one
        // session is not a real scenario.
        std.mem.copyForwards(
            DisplayMemoryEntry,
            g_display_memory[0 .. display_memory_capacity - 1],
            g_display_memory[1..],
        );
        g_display_memory_count -= 1;
    }
    g_display_memory[g_display_memory_count] = .{ .uuid = uuid, .active_ws = active_ws };
    g_display_memory_count += 1;
}

fn recallDisplayMemory(uuid: [16]u8) ?DisplayMemoryEntry {
    for (g_display_memory[0..g_display_memory_count]) |entry| {
        if (std.mem.eql(u8, &entry.uuid, &uuid)) return entry;
    }
    return null;
}

fn refreshDisplays() void {
    const NSScreen = objc.getClass("NSScreen") orelse {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .uuid = null, .visible = frame, .full = frame, .is_primary = true };
        return;
    };

    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    if (count == 0) {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .uuid = null, .visible = frame, .full = frame, .is_primary = true };
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
            .uuid = displayUuidBytes(display_id),
            .visible = visible_frame,
            .full = full_frame,
            .is_primary = is_primary,
        };
        next_count += 1;
    }

    if (next_count == 0) {
        const frame = bw_get_display_frame();
        g_display_count = 1;
        g_displays[0] = .{ .id = 1, .uuid = null, .visible = frame, .full = frame, .is_primary = true };
        return;
    }

    // Every display needs a distinct active workspace (assertDisplayCoverage),
    // so at most workspace_count displays can be managed. Ignore the excess
    // instead of silently giving two displays the same active workspace,
    // which corrupts workspace visibility checks everywhere downstream.
    if (next_count > g_workspaces.workspace_count) {
        log.warn("{d} displays but only {d} workspaces; ignoring the excess displays", .{
            next_count,
            g_workspaces.workspace_count,
        });
        next_count = g_workspaces.workspace_count;
        has_primary = false;
        for (g_displays[0..next_count]) |display| {
            if (display.is_primary) has_primary = true;
        }
    }

    if (!has_primary) g_displays[0].is_primary = true;
    g_display_count = next_count;
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
    const frame = liveWindowFrame(wid) orelse return null;
    if (frame.width <= 0 or frame.height <= 0) return null;
    return displayIdForFrame(frame);
}

/// Live WindowServer bounds for a window. `Window.frame` records bobrwm's last
/// accepted target or adopted user/external geometry; callers that need what
/// is physically visible now must still ask WindowServer.
fn liveWindowFrame(wid: u32) ?window_mod.Window.Frame {
    const sky = g_sky orelse return null;
    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) != 0) return null;
    return .{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };
}

fn seedObservedFrame(wid: u32, frame: window_mod.Window.Frame) void {
    g_geometry.seedObserved(wid, frame) catch |err| {
        log.warn("geometry: failed to seed observed frame wid={d}: {}", .{ wid, err });
    };
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

    /// Off-screen park position for a window of the given stored width.
    /// bottom_left parks the window off the left edge, which needs its width;
    /// without a usable width it falls back to bottom_right, which does not.
    fn parkPosition(self: HideCtx, width: f64) struct { x: f64, y: f64 } {
        std.debug.assert(width >= 0);
        const corner: HideCorner = if (width > 1) self.corner else .bottom_right;
        return .{
            .x = switch (corner) {
                .bottom_right => self.display.x + self.display.w - hide_peek,
                .bottom_left => self.display.x - width + hide_peek,
            },
            .y = self.display.y + self.display.h - hide_peek,
        };
    }

    /// Whether a stored frame already sits at its park position. Park
    /// positions are only recorded for AX writes the app accepted, so this is
    /// a reliable "already hidden" signal and the write can be skipped —
    /// worth doing because the skipped write is synchronous IPC into an app
    /// that may be slow or hung.
    fn isParked(self: HideCtx, frame: window_mod.Window.Frame) bool {
        const park = self.parkPosition(frame.width);
        const tol = window_mod.Window.Frame.tolerance;
        return @abs(frame.x - park.x) <= tol and @abs(frame.y - park.y) <= tol;
    }

    /// Move a single window off-screen by POSITION only — never resizing it.
    /// Resizing on hide causes a visible flash and a reflow storm in
    /// size-sensitive apps; the parked size is irrelevant and retile restores
    /// the real frame on re-activation. Updates the stored position so
    /// retileDisplay detects the move and re-places the window when its
    /// workspace becomes visible again. The size is never written.
    fn hide(self: HideCtx, pid: i32, wid: u32) void {
        self.captureFloatFrame(wid);

        const width: f64 = if (g_store.get(wid)) |win| blk: {
            if (self.isParked(win.frame)) return;
            break :blk win.frame.width;
        } else 0;
        const park = self.parkPosition(width);
        const pos_x = park.x;
        const pos_y = park.y;

        const ok = setWindowPositionTracked(pid, wid, pos_x, pos_y, .workspace_park);
        log.debug("hide window wid={d} pid={d} ok={} x={d:.0} y={d:.0}", .{ wid, pid, ok, pos_x, pos_y });
        if (!ok and !self.hideFocusedFallback(pid, wid, pos_x, pos_y)) {
            log.warn("hide failed wid={d} pid={d}", .{ wid, pid });
        }

        // Record the park position only when this window's own AX write was
        // accepted. The focused-window fallback updates the replacement id's
        // metadata itself, and recording a failed park would make the stored
        // frame claim the window is off-screen while it is still visible —
        // parkHiddenWorkspaceWindows compares stored frames and would never
        // retry it.
        if (ok) {
            if (g_store.get(wid)) |win| {
                var updated = win;
                updated.frame.x = pos_x;
                updated.frame.y = pos_y;
                g_store.put(updated) catch {};
            }
        }
    }

    /// Snapshot a floating window's live on-screen frame before it is parked in
    /// the corner. retileDisplay only restores tiled windows from BSP, so a
    /// floating window would otherwise stay parked when its workspace is shown.
    /// Reads WindowServer bounds directly because floating frames are not kept
    /// in the store on user drags. Skips capture when the window is already
    /// off-screen (center outside the display) so a re-hide cannot overwrite the
    /// remembered position with the parked corner.
    fn captureFloatFrame(self: HideCtx, wid: u32) void {
        var win = g_store.get(wid) orelse return;
        if (win.mode != .floating) return;
        // A fullscreen window's bounds are Bobrwm's own placement, not a user
        // one. Capturing them would overwrite the pre-fullscreen frame that
        // toggling fullscreen off has to restore.
        if (win.is_fullscreen) return;

        const sky = g_sky orelse return;
        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(sky.mainConnectionID(), wid, &rect) != 0) return;

        const center_x = rect.origin.x + rect.size.width / 2.0;
        const center_y = rect.origin.y + rect.size.height / 2.0;
        const on_x = center_x >= self.display.x and center_x <= self.display.x + self.display.w;
        const on_y = center_y >= self.display.y and center_y <= self.display.y + self.display.h;
        if (!on_x or !on_y) return;

        win.float_frame = .{
            .x = rect.origin.x,
            .y = rect.origin.y,
            .width = rect.size.width,
            .height = rect.size.height,
        };
        g_store.put(win) catch {};
    }

    /// Ghostty can replace the active native-tab window ID before Bobrwm has
    /// reconciled focus. If moving the stored ID fails, move the app's current
    /// focused AX window to the same off-screen position so it cannot leak onto
    /// the newly activated empty workspace, then reconcile the ID swap.
    fn hideFocusedFallback(self: HideCtx, pid: i32, failed_wid: u32, x: f64, y: f64) bool {
        _ = self;
        std.debug.assert(pid > 0);
        std.debug.assert(failed_wid > 0);

        const focused_wid = focusedWindowIdForPid(pid) orelse return false;
        if (focused_wid == failed_wid) return false;

        const ok = setWindowPositionTracked(pid, focused_wid, x, y, .workspace_park);
        log.debug("hide fallback focused window failed_wid={d} focused_wid={d} pid={d} ok={} x={d:.0} y={d:.0}", .{
            failed_wid,
            focused_wid,
            pid,
            ok,
            x,
            y,
        });
        if (!ok) return false;

        // Record the ID swap at the parked position using the failed window's
        // stored size. replaceManagedWindowId needs a non-degenerate frame, so
        // clamp a degenerate stored size (not yet tiled, or discovered
        // mid-construction) to 1x1 metadata instead of bailing: the focused
        // window has already been moved off-screen, and skipping the swap
        // here would leave the stale id managed and the moved window
        // untracked. Retile restores the real frame on re-activation.
        const stored = g_store.get(failed_wid) orelse return false;
        const replacement_frame: window_mod.Window.Frame = .{
            .x = x,
            .y = y,
            .width = @max(stored.frame.width, 1),
            .height = @max(stored.frame.height, 1),
        };
        return replaceManagedWindowId(failed_wid, focused_wid, replacement_frame);
    }
};

/// Convenience wrapper for single-window hides outside of loops.
fn hideWindow(pid: i32, wid: u32) void {
    const display_id = if (g_store.get(wid)) |win| win.space.display_id else focusedDisplayId();
    g_animator.finish(wid);
    (HideCtx.init(display_id)).hide(pid, wid);
}

/// Workspace-aware on-screen check. Windows on hidden workspaces are parked
/// in a screen corner with a few peek pixels visible — CG considers them
/// "on screen" but they should not be treated as such.
fn isVisibleOnScreen(wid: u32) bool {
    if (g_store.get(wid)) |win| {
        if (!spaceVisible(win.space)) return false;
    }
    return bw_is_window_on_screen(wid);
}

fn framesEqual(lhs: window_mod.Window.Frame, rhs: window_mod.Window.Frame) bool {
    std.debug.assert(lhs.width >= 0 and lhs.height >= 0);
    std.debug.assert(rhs.width >= 0 and rhs.height >= 0);

    return lhs.approxEqual(rhs, window_mod.Window.Frame.tolerance);
}

// Globals

var g_event_queue: EventQueue = .{};
var g_event_overflowed: std.atomic.Value(bool) = .init(false);
var g_event_dropped: usize = 0;
/// Serializes producers before they enter the single-producer event queue.
var g_ring_lock: c.os_unfair_lock_s = .{ ._os_unfair_lock_opaque = 0 };
var g_sky: ?skylight.SkyLight = null;
var g_allocator: std.mem.Allocator = undefined;
var g_store: window_mod.WindowStore = undefined;
var g_workspaces: workspace_mod.WorkspaceManager = undefined;
var g_state: state_mod.Model = .{};
var g_tiling_states: [workspace_mod.max_spaces]?tiling.State = undefined;
var g_displays: [workspace_mod.max_displays]DisplayInfo = undefined;
var g_display_count: usize = 0;
var g_bsp_split_mode: tiling.SplitMode = .auto;
var g_tab_groups: tabgroup.TabGroupManager = undefined;
var g_geometry: geometry_mod = undefined;
var g_pending_role_windows: PendingRoleWindowMap = undefined;
var g_deferred_window_candidates: DeferredWindowCandidateMap = undefined;
var g_app_launch_retries: AppLaunchRetryMap = undefined;
var g_focus_retries: FocusRetryMap = undefined;
var g_workspace_observer: ?objc.Object = null;
var g_ipc: ipc.Server = undefined;
var g_config: config_mod.Config = .{};
var g_config_runtime: ?ConfigRuntime = null;
var g_config_path: ?[:0]const u8 = null;
var g_drag_preview: DragPreviewState = .{};
var g_mouse_left_down = false;
var g_mouse_down_location: c.CGPoint = .{ .x = 0, .y = 0 };
var g_pointer_drag_candidate_wid: ?u32 = null;
var g_pointer_drag_wid: ?u32 = null;
var g_mouse_drag_event_emitted = false;
var g_drag_reconcile_on_drop = false;

fn nativeSpacesEnabled() bool {
    return g_config.native_spaces and g_sky != null and g_sky.?.supportsNativeSpaces();
}

fn moveTabGroupToNativeSpace(wid: u32, target: state_mod.SpaceRef) bool {
    if (!nativeSpacesEnabled()) return false;
    const space_id = switch (target.key) {
        .native => |value| value,
        .virtual => return false,
    };
    const sky = &g_sky.?;
    if (g_tab_groups.groupOf(wid)) |group| {
        return sky.moveWindowsToNativeSpace(group.members.items, space_id);
    }
    return sky.moveWindowToNativeSpace(wid, space_id);
}

fn trackPendingNativeWindowMove(wid: u32, source: state_mod.SpaceRef, target: state_mod.SpaceRef) void {
    source.assertValid();
    target.assertValid();
    const leader_wid = g_tab_groups.resolveLeader(wid);
    dispatchStateEvent(.{ .track_native_window_move = .{
        .window_id = leader_wid,
        .source = source,
        .target = target,
    } });
}

fn untrackPendingNativeWindowMove(wid: u32) void {
    if (g_state.pendingNativeWindowMove(wid) == null) return;
    dispatchStateEvent(.{ .cancel_native_window_move = wid });
}

fn nativeTabGroupMoveConfirmed(wid: u32, pending: state_mod.PendingNativeWindowMove) ?bool {
    const sky = &g_sky.?;
    const target_space_id = switch (pending.target.key) {
        .native => |value| value,
        .virtual => return null,
    };
    const source_space_id = switch (pending.source.key) {
        .native => |value| value,
        .virtual => return null,
    };
    if (g_tab_groups.groupOf(wid)) |group| {
        var checked_count: usize = 0;
        for (group.members.items) |member_wid| {
            if (g_store.get(member_wid) == null) continue;
            checked_count += 1;
            if (!(sky.nativeWindowMoveConfirmed(member_wid, target_space_id, source_space_id) orelse return null)) return false;
        }
        return checked_count > 0;
    }
    if (g_store.get(wid) == null) return false;
    return sky.nativeWindowMoveConfirmed(wid, target_space_id, source_space_id);
}

/// PID of the last window we focused via bw_ax_focus_window. Used to detect
/// same-process focus switches that need a delay for Electron compatibility.
var g_last_focused_pid: i32 = 0;
var g_last_space_changed_at_s: f64 = 0;
var g_last_display_changed_at_s: f64 = 0;
/// Absolute time at which a trailing display reconcile is due, or 0 when none
/// is pending. Re-armed on every display_changed so the reconcile fires once,
/// after the arrangement stops changing.
var g_display_resettle_at_s: f64 = 0;
/// Compiled keybind table referenced (not copied) by the hotkey event tap.
/// The caller of bw_set_keybinds owns the storage and must keep it alive for
/// as long as the event tap can fire; main's KeybindTable guarantees this.
var g_hotkey_bindings: []const shim.bw_keybind = &.{};
var g_waker_source: c.CFRunLoopSourceRef = null;
var g_role_poll_source: c.dispatch_source_t = null;
var g_tap_port: c.CFMachPortRef = null;
var g_pending_workspace_parks: [workspace_mod.max_displays]?PendingWorkspacePark = @splat(null);
var g_layout_entries: std.ArrayList(tiling.LayoutEntry) = .empty;
var g_retile_requested_all_displays = false;
var g_retile_dirty_display_ids: [workspace_mod.max_displays]u32 = [_]u32{0} ** workspace_mod.max_displays;
var g_retile_dirty_display_count: usize = 0;
var g_event_drain_active = false;
var g_event_overflow_recovery_pending = false;
var g_on_screen_truncation_logged = false;
var g_cleanup_pending_offscreen = false;
var g_cleanup_pending_pids: [cleanup_pid_capacity_per_drain]i32 = undefined;
var g_cleanup_pending_pid_count: usize = 0;

var g_animator: animation_mod.Animator = undefined;
var g_animator_source: c.dispatch_source_t = null;
var g_ipc_transport: ipc_transport.Transport = .{};

const ConfigRuntime = struct {
    arena: std.heap.ArenaAllocator,
    config: config_mod.Config,
    keybind_table: config_mod.KeybindTable,

    fn init(parent_allocator: std.mem.Allocator, path: ?[]const u8, use_defaults_on_error: bool) !ConfigRuntime {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const config = if (path) |p| blk: {
            break :blk config_mod.loadFromPath(allocator, p) orelse {
                if (!use_defaults_on_error) return error.InvalidConfig;
                break :blk config_mod.Config{};
            };
        } else config_mod.Config{};
        const keybind_table = try config_mod.KeybindTable.init(allocator, &config);
        return .{ .arena = arena, .config = config, .keybind_table = keybind_table };
    }

    fn deinit(self: *ConfigRuntime) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

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
        log.warn("cleanup: pid queue saturated, scheduling broad reconciliation pid={d}", .{pid});
        g_event_overflow_recovery_pending = true;
        g_cleanup_pending_offscreen = true;
        refreshRolePolling();
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
    if (g_state.isWorkspaceTransitionActive()) {
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
fn bw_get_display_frame() shim.bw_frame {
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

/// Get the focused window ID for a given application PID.
/// Returns 0 when no focused AX window is available.
fn bw_ax_get_focused_window(pid: i32) u32 {
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
fn bw_is_window_on_screen(target_wid: u32) bool {
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

/// Resolve the topmost managed layer-0 window under a pointer-down location.
/// CG's list is front-to-back, so skipping unmanaged overlays still reaches
/// the actual window below them. Binding the drag candidate here lets the
/// first real leftMouseDragged event establish exact per-window ownership;
/// a mouse button merely held elsewhere never authorizes geometry adoption.
fn managedWindowAtPoint(point: c.CGPoint) ?u32 {
    const options: cg_extra.CGWindowListOption =
        cg_extra.kCGWindowListOptionOnScreenOnly | cg_extra.kCGWindowListExcludeDesktopElements;
    const list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse return null;
    defer c.CFRelease(@ptrCast(list));

    const count = c.CFArrayGetCount(list);
    std.debug.assert(count >= 0);
    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);
        if (!cgWindowInfoVisible(info)) continue;

        const layer_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowLayer) orelse continue;
        const layer_ref: c.CFNumberRef = @ptrCast(layer_ref_any);
        var layer: i32 = 0;
        if (c.CFNumberGetValue(layer_ref, c.kCFNumberSInt32Type, &layer) == 0 or layer != 0) continue;

        const wid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);
        var wid: u32 = 0;
        if (c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid) == 0) continue;
        if (g_store.get(wid) == null) continue;

        const bounds_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowBounds) orelse continue;
        const bounds_ref: c.CFDictionaryRef = @ptrCast(bounds_ref_any);
        var bounds: c.CGRect = std.mem.zeroes(c.CGRect);
        if (!c.CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;

        const inside_x = point.x >= bounds.origin.x and point.x <= bounds.origin.x + bounds.size.width;
        const inside_y = point.y >= bounds.origin.y and point.y <= bounds.origin.y + bounds.size.height;
        if (inside_x and inside_y) return wid;
    }

    return null;
}

/// Get all AX-backed window IDs for an application PID.
/// Includes windows that may not currently be visible on screen.
const BoundedSnapshotResult = struct {
    count: usize,
    truncated: bool,
};

fn bw_get_app_window_ids(pid: i32, out: []u32) BoundedSnapshotResult {
    if (out.len == 0) return .{ .count = 0, .truncated = true };

    std.debug.assert(pid > 0);

    const out_buf = out;
    const app = c.AXUIElementCreateApplication(pid) orelse return .{ .count = 0, .truncated = false };
    defer c.CFRelease(@ptrCast(app));

    const ax = ensureAxStrings() orelse return .{ .count = 0, .truncated = false };
    const windows_attr = ax.windows_attr;

    var windows: c.CFArrayRef = null;
    const err = c.AXUIElementCopyAttributeValue(
        app,
        windows_attr,
        @ptrCast(&windows),
    );
    if (err != c.kAXErrorSuccess or windows == null) return .{ .count = 0, .truncated = false };
    const windows_ref = windows orelse return .{ .count = 0, .truncated = false };
    defer c.CFRelease(@ptrCast(windows_ref));

    var written: usize = 0;
    const total = c.CFArrayGetCount(windows_ref);
    std.debug.assert(total >= 0);

    var i: c.CFIndex = 0;
    var truncated = false;
    while (i < total) : (i += 1) {
        const win_any = c.CFArrayGetValueAtIndex(windows_ref, i) orelse continue;
        const win: c.AXUIElementRef = @ptrCast(win_any);

        var wid: u32 = 0;
        if (_AXUIElementGetWindow(win, &wid) == c.kAXErrorSuccess and wid != 0) {
            if (written == out_buf.len) {
                truncated = true;
                break;
            }
            out_buf[written] = wid;
            written += 1;
        }
    }

    std.debug.assert(written <= out_buf.len);
    return .{ .count = written, .truncated = truncated };
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

/// Query whether the AXSize attribute is settable (i.e. the window can be resized).
fn axCanResize(win_ref: c.AXUIElementRef, ax: *const AxStrings) bool {
    var result: c.Boolean = 0;
    const err = c.AXUIElementIsAttributeSettable(win_ref, ax.size_attr, &result);
    return err == c.kAXErrorSuccess and result != 0;
}

/// Raise and focus a window, then activate its owning app.
///
/// When switching between windows within the same process, a 40ms delay is
/// inserted between the raise and the activation. Some apps (notably Electron)
/// get confused by instantaneous same-process focus switches and fail to render
/// the focus ring or route keyboard events to the wrong window. Yabai uses the
/// same 40ms delay for same-PSN switches.
fn bw_ax_focus_window(pid: i32, wid: u32) bool {
    const same_process_focus_delay_us: c_uint = 40_000; // 40ms, matches yabai

    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = ax_mod.retainWindow(pid, wid) orelse return false;
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

    return setFrontProcessViaSkylight(pid, wid);
}

/// Carbon PSN lookup. Deprecated since 10.9 but still exported and functional;
/// not present in the aggregated C header surface, so declared directly.
extern fn GetProcessForPID(pid: i32, psn: *skylight.ProcessSerialNumber) c_int;

/// kCPSUserGenerated — marks the activation as user-driven so the WindowServer
/// honors the focus change. Not a public constant; value from CoreGraphics CPS.
const kCPSUserGenerated: u32 = 0x200;

/// Move keyboard focus by making the target the front process and posting the
/// two focus event records SkyLight expects (yabai's mechanism). This actually
/// moves input focus, unlike NSRunningApplication.activate on modern macOS.
/// Returns false if the SkyLight symbols or the process's PSN are unavailable.
fn setFrontProcessViaSkylight(pid: i32, wid: u32) bool {
    const sky = g_sky orelse return false;
    const set_front = sky.setFrontProcessWithOptions orelse return false;
    const post_event = sky.postEventRecordTo orelse return false;

    var psn: skylight.ProcessSerialNumber = .{ .high = 0, .low = 0 };
    if (GetProcessForPID(pid, &psn) != 0) {
        log.debug("focus activation: GetProcessForPID failed pid={d}", .{pid});
        return false;
    }

    if (set_front(&psn, wid, kCPSUserGenerated) != 0) {
        log.debug("focus activation: SLPSSetFrontProcessWithOptions failed pid={d} wid={d}", .{ pid, wid });
        return false;
    }

    var focus_event = focusEventRecord(wid, 0x01);
    _ = post_event(&psn, &focus_event);
    var raise_event = focusEventRecord(wid, 0x02);
    _ = post_event(&psn, &raise_event);
    return true;
}

/// One 0xF8-byte SkyLight event record targeting `wid`. `kind` is 0x01 for the
/// focus record and 0x02 for the raise record. Byte offsets are SkyLight's.
fn focusEventRecord(wid: u32, kind: u8) [0xf8]u8 {
    var bytes = [_]u8{0} ** 0xf8;
    bytes[0x04] = 0xf8;
    bytes[0x08] = kind;
    bytes[0x3a] = 0x10;
    @memset(bytes[0x20..0x30], 0xFF);
    std.mem.writeInt(u32, bytes[0x3c..0x40], wid, .little);
    return bytes;
}

fn manageStateForWindow(pid: i32, wid: u32) u8 {
    return manageStateForWindowWithMessagingTimeout(pid, wid, null);
}

fn manageStateForWindowWithMessagingTimeout(pid: i32, wid: u32, timeout_seconds: ?f32) u8 {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    if (!isRegularActivationApp(pid)) return shim.BW_MANAGE_REJECT;

    // Remote-hosted panels (open/save dialogs) can be the app's focused window
    // without appearing in AXWindows; without the focused-window fallback they
    // stay PENDING and never reach the AXModal rejection below.
    const win = if (timeout_seconds) |seconds|
        ax_mod.findWindowWithMessagingTimeout(pid, wid, seconds)
    else
        findAxWindow(pid, wid) orelse ax_mod.focusedWindowIfMatches(pid, wid);
    const win_ref = win orelse return shim.BW_MANAGE_PENDING;
    defer c.CFRelease(@ptrCast(win_ref));

    const ax = ensureAxStrings() orelse return shim.BW_MANAGE_PENDING;
    // Native open/save panels are app-modal AX windows. They expose enough
    // top-level-window signals to pass the dialog heuristic below, but tiling
    // them resizes the parent app while the user is choosing a file.
    if (axBooleanAttributeTrue(win_ref, ax.modal_attr)) return shim.BW_MANAGE_REJECT;

    const role_attr = ax.role_attr;
    var role_any: c.CFTypeRef = null;
    const role_err = c.AXUIElementCopyAttributeValue(win_ref, role_attr, @ptrCast(&role_any));
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
    const subrole_err = c.AXUIElementCopyAttributeValue(win_ref, subrole_attr, @ptrCast(&subrole_any));
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
    if (is_dialog_like and windowHasRealWindowSignal(win_ref, ax)) {
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

/// Returns true when a still-pending window must not be tiled by the timeout
/// fallback: no AX element resolved after the full poll budget (a window
/// invisible to AX for that long is never a tileable standard window), or the
/// role/subrole is AXUnknown (transient host placeholders).
fn isUntileablePendingRoleWindow(pid: i32, wid: u32) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);

    const win = findAxWindow(pid, wid) orelse
        ax_mod.focusedWindowIfMatches(pid, wid) orelse return true;
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
fn bw_should_manage_window(pid: i32, wid: u32) bool {
    const state = manageStateForWindow(pid, wid);
    return state != shim.BW_MANAGE_REJECT;
}

/// Returns management state for a given window.
fn bw_window_manage_state(pid: i32, wid: u32) u8 {
    return manageStateForWindow(pid, wid);
}

/// Enumerate on-screen layer-0 windows for regular applications.
///
/// Uses a per-call PID cache to avoid redundant isRegularActivationApp calls.
/// Electron apps spawn many XPC helper processes (renderers, GPU process) that
/// share the CGWindowList but have Prohibited activation policy. Caching the
/// accept/reject decision per PID avoids an ObjC message send for every window
/// belonging to the same rejected process.
fn bw_discover_windows(out: []shim.bw_window_info, on_screen: ?*OnScreenWindows) BoundedSnapshotResult {
    if (out.len == 0) return .{ .count = 0, .truncated = true };
    const out_buf = out;

    const options: cg_extra.CGWindowListOption =
        cg_extra.kCGWindowListOptionOnScreenOnly | cg_extra.kCGWindowListExcludeDesktopElements;
    const window_list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse
        return .{ .count = 0, .truncated = false };
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
    var truncated = false;
    var i: c.CFIndex = 0;
    while (i < total) : (i += 1) {
        const info_any = c.CFArrayGetValueAtIndex(window_list, i) orelse continue;
        const info: c.CFDictionaryRef = @ptrCast(info_any);

        if (!cgWindowInfoVisible(info)) continue;

        const wid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue;
        const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);
        var wid: u32 = 0;
        _ = c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid);
        if (on_screen) |snapshot| snapshot.append(wid);

        var layer: i32 = 0;
        if (c.CFDictionaryGetValue(info, cg_extra.kCGWindowLayer)) |layer_ref_any| {
            const layer_ref: c.CFNumberRef = @ptrCast(layer_ref_any);
            _ = c.CFNumberGetValue(layer_ref, c.kCFNumberSInt32Type, &layer);
        }
        if (layer != 0) continue;
        if (g_store.get(wid) != null) continue;

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

        if (count == out_buf.len) {
            truncated = true;
            if (on_screen) |snapshot| snapshot.truncated = true;
            break;
        }

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
    return .{ .count = count, .truncated = truncated };
}

fn pidInCache(pid: i32, cache: []const i32, count: usize) bool {
    return std.mem.findScalar(i32, cache[0..count], pid) != null;
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

fn animatorTimerTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    g_animator.tick();
    if (!g_animator.isAnimating()) {
        if (g_animator_source) |source| {
            c.dispatch_source_cancel(source);
            // Unlike the long-lived role-poll source, this one is recreated
            // for every animation burst — drop our reference or each burst
            // leaks a source. GCD keeps it alive until cancellation completes.
            c.dispatch_release(.{ ._ds = source });
            g_animator_source = null;
        }
    }
}

fn ensureAnimatorTimer() void {
    if (g_animator_source != null) return;
    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
    ) orelse return;
    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, 0),
        16 * c.NSEC_PER_MSEC,
        0,
    );
    c.dispatch_source_set_event_handler_f(source, animatorTimerTick);
    c.dispatch_resume(.{ ._ds = source });
    g_animator_source = source;
}

fn rolePollTimerTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    bw_emit_event(shim.BW_EVENT_ROLE_POLL_TICK, 0, 0);
}

fn rebuildTilingStatesForConfig() void {
    destroyAllTilingStates();
    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        for (ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;
            // Workspace lists contain only tab-group leaders; a leader may be
            // "suppressed" while another native tab is active but still owns
            // the group's one layout slot.
            if (win.mode != .tiled) continue;
            insertIntoTiling(ws.ref.key, wid);
        }
        if (focusedWorkspaceWindow(ws)) |focused_wid| setTilingActive(ws.ref.key, focused_wid);
    }
}

fn applyReloadedConfig(next: ConfigRuntime) void {
    std.debug.assert(config_mod.workspaceCount(&next.config) == g_workspaces.workspace_count);

    var replacement = next;
    replacement.config.applyKeybinds(&replacement.keybind_table);

    var previous = g_config_runtime.?;
    const layout_changed = previous.config.layout != replacement.config.layout;
    g_config_runtime = replacement;
    g_config = replacement.config;
    g_bsp_split_mode = g_config.bsp_split;
    g_animator.finishAll();
    g_animator.init(g_config.animation);
    dim.configure(g_config.dimmed_inactive);
    loginitem.reconcile(g_config.start_at_login);

    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        const index = ws.ref.workspace_id - 1;
        ws.name = if (index < g_config.workspace_names.len) g_config.workspace_names[index] else "";
    }
    // Preserve BSP topology and runtime split edits for ordinary config saves.
    // Only changing the layout algorithm requires reconstructing state.
    if (layout_changed) rebuildTilingStatesForConfig();
    statusbar.updateWorkspaceMenu(g_workspaces.workspace_count, &g_config);
    updateStatusBar();
    retile();
    if (dim.enabled) pushDimSnapshot();

    previous.deinit();
    log.info("config reloaded from {s}", .{g_config_path.?});
}

var g_config_error_generation: usize = 0;

fn restoreStatusBarAfterConfigError(context: ?*anyopaque) callconv(.c) void {
    const generation = @intFromPtr(context orelse return);
    if (generation == g_config_error_generation) updateStatusBar();
}

fn notifyConfigReloadFailed() void {
    statusbar.setMessage("⚠ Config reload failed");
    g_config_error_generation +%= 1;
    if (g_config_error_generation == 0) g_config_error_generation = 1;
    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, 4 * c.NSEC_PER_SEC),
        cg_extra.dispatch_get_main_queue(),
        @ptrFromInt(g_config_error_generation),
        restoreStatusBarAfterConfigError,
    );
}

fn reloadConfig() bool {
    const path = g_config_path orelse return false;
    var next = ConfigRuntime.init(g_allocator, path, false) catch |err| {
        log.err("config reload failed, keeping current config: {}", .{err});
        notifyConfigReloadFailed();
        return false;
    };
    const configured_count = config_mod.workspaceCount(&next.config);
    if (configured_count != g_workspaces.workspace_count) {
        log.err("config reload cannot change workspace count ({d} running, {d} configured); restart to apply it", .{
            g_workspaces.workspace_count,
            configured_count,
        });
        next.deinit();
        notifyConfigReloadFailed();
        return false;
    }
    if (next.config.native_spaces != g_config.native_spaces) {
        log.err("config reload cannot change native_spaces; restart to apply it", .{});
        next.deinit();
        notifyConfigReloadFailed();
        return false;
    }
    applyReloadedConfig(next);
    return true;
}

fn setRolePolling(enabled: bool) void {
    if (!enabled) {
        if (g_role_poll_source) |source| {
            c.dispatch_source_cancel(source);
            c.dispatch_release(.{ ._ds = source });
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
        g_mouse_down_location = cg_extra.CGEventGetLocation(event);
        g_mouse_drag_event_emitted = false;
        bw_hotkey_mouse_down();
        return event;
    }
    if (event_type == c.kCGEventLeftMouseDragged) {
        if (!g_mouse_drag_event_emitted) {
            g_mouse_drag_event_emitted = true;
            bw_hotkey_mouse_dragged();
        }
        return event;
    }
    if (event_type == c.kCGEventLeftMouseUp) {
        g_mouse_drag_event_emitted = false;
        bw_hotkey_mouse_up();
        return event;
    }
    if (event_type == 29 or event_type == 30) {
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
    var mask: c.CGEventMask =
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventKeyDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseDragged)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseUp));
    if (g_config.native_spaces) {
        mask |= (@as(c.CGEventMask, 1) << 29) | (@as(c.CGEventMask, 1) << 30);
    }

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

// Event bridge (called from ObjC shim)

// Thread-safe: AX observer callbacks run on per-app background threads
// and push events here.  The os_unfair_lock serialises concurrent pushes
// while the main-thread consumer (pop) is wait-free.
export fn bw_emit_event(kind: u8, pid: i32, wid: u32) void {
    const event: event_mod.Event = .{
        .kind = @enumFromInt(kind),
        .pid = pid,
        .wid = wid,
    };

    c.os_unfair_lock_lock(&g_ring_lock);
    if (!g_event_queue.push(event)) {
        g_event_dropped += 1;
        g_event_overflowed.store(true, .release);
        log.err("event queue full, dropped event kind={s} pid={d} wid={d} total_dropped={d}", .{
            @tagName(event.kind), event.pid, event.wid, g_event_dropped,
        });
    }
    c.os_unfair_lock_unlock(&g_ring_lock);
    signalWaker();
}

/// Callback target for BWObserver.appTerminated:.
fn workspaceAppTerminated(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_TERMINATED, pid, 0);
}

/// Callback target for BWObserver.appLaunched:.
fn workspaceAppLaunched(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_APP_LAUNCHED, pid, 0);
}

/// Callback target for BWObserver.activeAppChanged:.
fn workspaceActiveAppChanged(pid: i32) void {
    std.debug.assert(pid > 0);
    bw_emit_event(shim.BW_EVENT_WINDOW_FOCUSED, pid, 0);
}

/// Callback target for BWObserver.spaceChanged:.
fn workspaceSpaceChanged() void {
    bw_emit_event(shim.BW_EVENT_SPACE_CHANGED, 0, 0);
}

/// Callback target for BWObserver.displayChanged:.
fn workspaceDisplayChanged() void {
    bw_emit_event(shim.BW_EVENT_DISPLAY_CHANGED, 0, 0);
}

/// Callback target for shim hotkey mouse down events.
fn bw_hotkey_mouse_down() void {
    bw_emit_event(shim.BW_EVENT_MOUSE_DOWN, 0, 0);
}

/// Callback target for shim hotkey mouse up events.
fn bw_hotkey_mouse_up() void {
    bw_emit_event(shim.BW_EVENT_MOUSE_UP, 0, 0);
}

/// Mark the first actual pointer-drag event separately from mouse-down. A
/// click held while bobrwm retiles is not a user geometry change.
fn bw_hotkey_mouse_dragged() void {
    bw_emit_event(shim.BW_EVENT_MOUSE_DRAGGED, 0, 0);
}

/// Accept the keybind table from config. Stores a reference to caller-owned
/// storage instead of copying, so the table has no fixed size cap. Called on
/// the main thread both at startup and when config is hot-reloaded.
export fn bw_set_keybinds(binds: ?[*]const shim.bw_keybind, count: u32) void {
    const src = binds orelse {
        g_hotkey_bindings = &.{};
        return;
    };

    g_hotkey_bindings = src[0..count];
}

/// Resolve a key press against current keybinds and emit matching action.
fn bw_hotkey_handle_keydown(keycode: u16, mods: u8) bool {
    for (g_hotkey_bindings) |binding| {
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

/// Read `-c` / `--config` off the command line. The window manager takes no
/// other arguments; everything users type goes to the `bobrwm` client, which
/// forwards it over IPC.
fn parseConfigPath(process_args: std.process.Args) ?[]const u8 {
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            return args.next();
        }
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Before any thread starts, so logFn never races on the descriptor.
    filelog.init();
    defer filelog.deinit();
    log.info("bobrwm starting (log_level={s})...", .{@tagName(std_options.log_level)});

    var debug_allocator: ?std.heap.DebugAllocator(.{}) = switch (builtin.mode) {
        .Debug => .init,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => null,
    };
    defer {
        if (debug_allocator) |*value| _ = value.deinit();
    }
    g_allocator = if (debug_allocator) |*value|
        value.allocator()
    else
        std.heap.c_allocator;
    defer deinitAxStrings();
    defer ax_mod.deinitElementCache();

    // Claim the single-instance endpoint before config reconciliation,
    // accessibility prompts, SkyLight, or window discovery can mutate any
    // external state. A losing second launch must be completely inert.
    g_ipc = ipc.Server.init(g_allocator) catch |err| {
        log.err("IPC init failed: {}", .{err});
        return err;
    };
    defer g_ipc.deinit(g_allocator);
    ipc.g_dispatch = ipcDispatch;

    // -- Config --
    const config_path = config_mod.resolvePath(g_allocator, parseConfigPath(init.args)) catch null;
    defer if (config_path) |path| g_allocator.free(path);
    g_config_path = config_path;
    g_config_runtime = try ConfigRuntime.init(g_allocator, config_path, true);
    defer g_config_runtime.?.deinit();
    g_config = g_config_runtime.?.config;

    g_bsp_split_mode = g_config.bsp_split;
    g_config.applyKeybinds(&g_config_runtime.?.keybind_table);
    g_animator.init(g_config.animation);

    // Inactive-window dimming via SkyLight (SLSSetWindowListBrightness).
    dim.configure(g_config.dimmed_inactive);
    loginitem.reconcile(g_config.start_at_login);

    // -- Accessibility check --
    if (!ax_mod.isTrusted()) {
        log.warn("accessibility not trusted — prompting user", .{});
        log.warn("after granting access, quit from the menu bar and relaunch Bobrwm.app", .{});
        axPrompt();
    }

    // -- SkyLight (optional) --
    g_sky = skylight.SkyLight.init();
    if (g_config.native_spaces and (g_sky == null or !g_sky.?.supportsNativeSpaces())) {
        log.err("native_spaces requested but required SkyLight symbols are unavailable", .{});
        return error.NativeSpacesUnavailable;
    }

    // -- Core state --
    g_store = window_mod.WindowStore.init(g_allocator);
    defer g_store.deinit();
    const ws_count = config_mod.workspaceCount(&g_config);
    g_workspaces = workspace_mod.WorkspaceManager.init(g_allocator, ws_count);
    defer g_workspaces.deinit();
    clearTilingStates();
    // Free per-workspace tiling states on exit. BSP allocates Split nodes and
    // leaf ArrayLists via g_allocator; without this, DebugAllocator reports leaks.
    defer destroyAllTilingStates();
    g_tab_groups = tabgroup.TabGroupManager.init(g_allocator);
    defer g_tab_groups.deinit();
    g_geometry = geometry_mod.init(g_allocator);
    defer g_geometry.deinit();
    g_geometry.ensureTotalCapacity(geometry_window_capacity) catch |err| {
        log.err("geometry coordinator reserve failed: {}", .{err});
        return err;
    };
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

    const primary_id = primaryDisplayId();
    const wsc = g_workspaces.workspace_count;
    const primary_slot = displayIndexById(primary_id) orelse 0;
    var workspace_topology: state_mod.WorkspaceTopology = .{};
    var space_catalog: state_mod.SpaceCatalog = .{};
    var workspace_displays: [workspace_mod.max_workspaces]u32 = @splat(primary_id);
    var extra: usize = 0;
    for (g_displays[0..g_display_count], 0..) |display, slot| {
        const workspace_id: u8 = if (slot == primary_slot) 1 else @intCast(wsc - extra);
        workspace_topology.addDisplay(.{
            .display_id = display.id,
            .active_workspace_id = workspace_id,
        });
        if (slot == primary_slot) continue;

        workspace_displays[workspace_id - 1] = display.id;
        extra += 1;
    }
    var workspace_id: u8 = 1;
    while (workspace_id <= wsc) : (workspace_id += 1) {
        space_catalog.add(.{
            .key = .{ .virtual = workspace_id },
            .workspace_id = workspace_id,
            .display_id = workspace_displays[workspace_id - 1],
        });
    }
    workspace_topology.focused_display_id = primary_id;
    dispatchStateEvent(.{ .replace_space_catalog = space_catalog });
    dispatchStateEvent(.{ .replace_workspace_topology = workspace_topology });
    g_workspaces.configure(g_state.spaces.spaces[0..g_state.spaces.space_count]);

    if (g_display_count > 1) {
        std.debug.assert(extra == g_display_count - 1);
    }
    // Start from WindowServer's truth. Assuming space 1 here would immediately
    // tile windows from whichever native space happened to be visible into the
    // wrong internal workspace after a relaunch.
    if (nativeSpacesEnabled()) {
        const topology = captureNativeTopology() orelse {
            log.err("could not capture configured native Space topology", .{});
            return error.NativeSpaceMappingUnavailable;
        };
        for (topology.displays[0..topology.display_count]) |display| {
            if (display.workspaceForSpace(display.observed_space_id) != null) continue;
            log.err("current native Space {d} is not a configured ordinary workspace on display {d}", .{
                display.observed_space_id,
                display.display_id,
            });
            return error.NativeSpaceMappingUnavailable;
        }
        dispatchStateEvent(.{ .initialize_native_topology = topology });
        g_workspaces.configure(g_state.spaces.spaces[0..g_state.spaces.space_count]);
    }

    // -- Apply workspace names from config --
    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*space| {
        const index = space.ref.workspace_id - 1;
        if (index >= g_config.workspace_names.len) continue;
        space.name = g_config.workspace_names[index];
    }

    // -- Signal transport (handler writes only; cleanup runs on main) --
    try signal_transport.init(gracefulStopNSApp);
    defer signal_transport.deinit();
    errdefer restoreAllWindows();

    // -- Discover existing windows and tile --
    discoverWindows();
    log.info("discovered {} windows", .{g_store.count()});
    retileAllDisplays();

    // -- NSApp (zig-objc) --
    // Register runtime ObjC classes (BWObserver / BWLaunchGate) before
    // any code does objc.getClass on them.
    objc_classes.register(g_allocator, .{
        .app_launched = workspaceAppLaunched,
        .app_terminated = workspaceAppTerminated,
        .active_app_changed = workspaceActiveAppChanged,
        .space_changed = workspaceSpaceChanged,
        .display_changed = workspaceDisplayChanged,
    });
    const NSApp = initApp();
    initWorkspaceObservers();

    // -- Sources (observers, CGEventTap, waker, IPC) --
    ax_observer.init();
    defer ax_observer.deinit();
    setupHotkeyEventTap();
    initWakerSource();
    try g_ipc_transport.start(g_ipc.fd, signalWaker);
    defer g_ipc_transport.stop();
    refreshRolePolling();
    observeDiscoveredApps();

    // Status bar (zig-objc) --
    statusbar.init(
        g_workspaces.workspace_count,
        &g_config,
        .{
            .retile = statusBarRetile,
            .open_config = statusBarOpenConfig,
            .previous_workspace = statusBarPreviousWorkspace,
            .next_workspace = statusBarNextWorkspace,
            .switch_to_workspace = statusBarSwitchToWorkspace,
            .quit = statusBarQuit,
        },
    );
    defer statusbar.deinit();
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
fn bw_drain_events() void {
    std.debug.assert(!g_event_drain_active);
    g_event_drain_active = true;
    defer g_event_drain_active = false;

    if (!nativeSwitchPending()) {
        refreshTabGroupActiveTabs();
    }

    while (g_event_queue.pop()) |ev| {
        handleEvent(&ev);
    }
    drainIpcRequests();

    if (g_event_overflowed.swap(false, .acq_rel)) {
        g_event_overflow_recovery_pending = true;
        refreshRolePolling();
    }
    recoverFromEventOverflow();

    // Flush retile BEFORE cleanup so windows are at their layout positions
    // when cleanup checks on-screen status. Without this, cleanup sees
    // corner-parked windows and incorrectly removes them as ghosts.
    flushRetileRequests();

    if (flushCleanupRequests()) {
        // Cleanup removed windows — retile again to fill the gaps.
        requestRetileAllDisplays();
        flushRetileRequests();
    }

    // Same settled point: dim inactive windows (diffed, no-op if unchanged).
    // Guard at the call site so a disabled feature costs exactly one branch
    // here and never enters the snapshot path — no call, no loop, no reliance
    // on the optimizer eliding a no-op body.
    if (dim.enabled and !nativeSwitchPending()) {
        pushDimSnapshot();
    }
}

/// A dropped event has unknown semantics, so recover from authoritative OS
/// state instead of guessing which individual mutation was lost. Cleanup is
/// deferred through workspace transitions because parked windows are expected
/// to be off-screen during that interval.
fn recoverFromEventOverflow() void {
    if (!g_event_overflow_recovery_pending) return;
    if (g_state.isWorkspaceTransitionActive()) return;

    g_event_overflow_recovery_pending = false;
    log.warn("event overflow: reconciling window, app, focus, and frame state", .{});

    // Mouse-up may be the lost event. Abandon transient drag state rather than
    // leaving every later AX move classified as a user drag indefinitely.
    g_mouse_left_down = false;
    g_pointer_drag_candidate_wid = null;
    g_pointer_drag_wid = null;
    g_geometry.clearIntents();
    g_drag_reconcile_on_drop = false;
    clearDragPreview();

    _ = removeStoppedAppWindows();
    discoverWindows();
    refreshTabGroupActiveTabs();
    reconcileVisibleFramesFromWindowServer();

    if (frontmostApplicationPid()) |pid| {
        if (focusedWindowIdForPid(pid)) |wid| {
            reconcileFocusedWindow(pid, wid);
        }
        requestCleanupForPid(pid);
    }
    requestOffscreenCleanup();
    requestRetileAllDisplays();
    refreshRolePolling();
}

/// Re-read WindowServer after AX notification delivery has settled. The
/// immediate event handler can still see the prior frame, and some apps emit
/// no follow-up notification after the physical geometry finally changes.
fn reconcileDueGeometryObservations() void {
    const now_ns = nanoTimestamp();
    var due_wids: [geometry_window_capacity]u32 = undefined;
    const due_count = g_geometry.collectDueResamples(now_ns, &due_wids);

    for (due_wids[0..due_count]) |wid| {
        if (g_pointer_drag_wid == wid) {
            g_geometry.deferResample(wid, now_ns);
            continue;
        }

        const observed = liveWindowFrame(wid) orelse {
            if (g_geometry.get(wid)) |entry| {
                if (entry.intent) |intent| {
                    if (now_ns <= intent.settle_deadline_ns) {
                        g_geometry.deferResample(wid, now_ns);
                        continue;
                    }
                    if (reconcileDivergedGeometryIntent(wid, intent)) {
                        g_geometry.forget(wid);
                        continue;
                    }
                }
            }
            // No physical window exists after the ownership interval. Drop
            // the sample state; cleanup/tab reconciliation owns any remaining
            // store entry and a later write will create fresh provenance.
            g_geometry.forget(wid);
            continue;
        };
        const pending_intent = if (g_geometry.get(wid)) |entry| entry.intent else null;
        switch (g_geometry.settle(wid, observed, now_ns)) {
            .manager => log.debug("geometry: trailing sample manager-owned wid={d}", .{wid}),
            .external => {
                log.debug("geometry: trailing sample external wid={d}", .{wid});
                if (pending_intent) |intent| {
                    if (reconcileDivergedGeometryIntent(wid, intent)) continue;
                }
                handleExternalWindowGeometry(wid, observed);
            },
        }
    }
}

/// An accepted AX write can target a native-tab ID that disappeared from the
/// visible AX window set while the application simultaneously surfaced a new
/// focused ID. Reconcile through the existing tab-aware focus path before
/// retrying geometry; blindly reissuing the stale ID would loop forever.
fn reconcileDivergedGeometryIntent(wid: u32, intent: geometry_mod.Intent) bool {
    switch (intent.source) {
        .tab_sync, .workspace_park, .exit_restore => return false,
        .layout, .floating_restore, .user_command, .animation => {},
    }

    const win = g_store.get(wid) orelse return false;
    if (!spaceVisible(win.space)) return false;
    if (bw_is_window_on_screen(wid)) return false;

    const focused_wid = focusedWindowIdForPid(win.pid) orelse return false;
    if (focused_wid == wid) return false;

    log.debug("geometry: divergent intent reconciling stale wid={d} focused_wid={d} pid={d} source={s}", .{
        wid,
        focused_wid,
        win.pid,
        @tagName(intent.source),
    });
    reconcileFocusedWindow(win.pid, focused_wid);
    requestRetileDisplay(win.space.display_id);
    return true;
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

fn handleIpcRequest(request: ipc_transport.Request) void {
    defer _ = std.c.close(request.fd);
    const started_ns = nanoTimestamp();
    const cmd = request.command();
    log.debug("[trace] ipc recv fd={} bytes={} cmd={s}", .{ request.fd, request.len, cmd });

    if (ipc.g_dispatch) |dispatch| {
        dispatch(cmd, request.fd);
        const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
        log.debug("[trace] ipc handled fd={} cmd={s} elapsed_ms={}", .{ request.fd, cmd, elapsed_ms });
    } else {
        log.warn("ipc dispatch callback missing", .{});
    }
}

fn drainIpcRequests() void {
    while (g_ipc_transport.pop()) |request| {
        handleIpcRequest(request);
    }
}

// Menu callbacks run on the main thread while AppKit dismisses the menu, so
// state mutations are safe here. Keeping them in the application root makes
// the UI adapter depend only on the callbacks it is given.
fn statusBarRetile() callconv(.c) void {
    retile();
}

fn statusBarOpenConfig() callconv(.c) void {
    openConfigFile();
}

fn statusBarPreviousWorkspace() callconv(.c) void {
    switchAdjacentWorkspace(.previous);
}

fn statusBarNextWorkspace() callconv(.c) void {
    switchAdjacentWorkspace(.next);
}

fn statusBarSwitchToWorkspace(workspace_id: u8) callconv(.c) void {
    if (workspace_id == 0 or workspace_id > g_workspaces.workspace_count) return;
    switchWorkspace(workspace_id);
}

/// Restore windows before asking AppKit to terminate; the UI library must not
/// own shutdown because restoration mutates all window-management state.
fn statusBarQuit() callconv(.c) void {
    restoreAllWindows();

    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "terminate:", .{@as(objc.Object, .{ .value = null })});
}

fn openConfigFile() void {
    const path = g_config_path orelse {
        log.warn("cannot open config file because its path could not be resolved", .{});
        return;
    };
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSURL = objc.getClass("NSURL") orelse return;
    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    if (workspace.value == null) {
        log.warn("cannot open config file at {s}", .{path});
        return;
    }
    const ns_path = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{path.ptr});
    if (ns_path.value == null) {
        log.warn("cannot open config file at {s}", .{path});
        return;
    }
    const url = NSURL.msgSend(objc.Object, "fileURLWithPath:", .{ns_path});
    if (url.value == null) {
        log.warn("cannot open config file at {s}", .{path});
        return;
    }
    if (!workspace.msgSend(bool, "openURL:", .{url})) {
        log.warn("failed to open config file at {s}", .{path});
    }
}

fn tilingStatePtr(space_key: state_mod.SpaceKey) *?tiling.State {
    const index = g_workspaces.indexOf(space_key) orelse unreachable;
    return &g_tiling_states[index];
}

fn removeFromTiling(space_key: state_mod.SpaceKey, wid: u32) void {
    const sp = tilingStatePtr(space_key);
    if (sp.*) |*st| {
        st.remove(wid, g_allocator);
        if (st.windowCount() == 0) {
            st.deinit(g_allocator);
            sp.* = null;
        }
    }
}

fn windowIsTiled(wid: u32) bool {
    const win = g_store.get(wid) orelse return false;
    return win.mode == .tiled;
}

fn tryInsertIntoTiling(space_key: state_mod.SpaceKey, wid: u32) !void {
    const sp = tilingStatePtr(space_key);
    const created_state = sp.* == null;
    if (created_state) sp.* = tiling.newState(g_config.layout);
    errdefer if (created_state) {
        sp.*.?.deinit(g_allocator);
        sp.* = null;
    };

    const ws = g_workspaces.get(space_key) orelse return error.InvalidWorkspace;
    const anchor_wid = blk: {
        const st = sp.* orelse break :blk null;
        switch (g_config.bsp_insert_point) {
            .focused => {
                const focused_wid = focusedWorkspaceWindow(ws) orelse break :blk null;
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
        .root_frame = displayContentFrame(ws.ref.display_id),
        .inner_gap = @floatFromInt(g_config.gaps.inner),
        .split_ratio = g_config.bsp_split_ratio,
    };
    try sp.*.?.insert(wid, options, g_allocator);
}

fn insertIntoTiling(space_key: state_mod.SpaceKey, wid: u32) void {
    tryInsertIntoTiling(space_key, wid) catch |err| {
        log.err("failed to insert wid={d} into workspace layout: {}", .{ wid, err });
    };
}

fn adoptWindowIdentity(win: window_mod.Window) bool {
    if (g_state.window(win.wid) != null) return false;

    dispatchStateEvent(.{ .adopt_window = .{
        .window_id = win.wid,
        .process_id = win.pid,
        .space_key = win.space.key,
    } });
    const adopted = g_state.window(win.wid) orelse return false;
    return adopted.process_id == win.pid and adopted.space_key.eql(win.space.key);
}

fn removeWindowIdentity(wid: u32) void {
    dispatchStateEvent(.{ .remove_window = wid });
}

fn replaceWindowIdentity(old_wid: u32, new_wid: u32) bool {
    if (g_state.window(old_wid) == null or g_state.window(new_wid) != null) return false;

    dispatchStateEvent(.{ .replace_window_id = .{
        .old_window_id = old_wid,
        .new_window_id = new_wid,
    } });
    return g_state.window(old_wid) == null and g_state.window(new_wid) != null;
}

fn syncWindowTabGroup(group_id: tabgroup.GroupId) bool {
    const group = g_tab_groups.groups.getPtr(group_id) orelse return false;
    var observation: state_mod.WindowTabGroupObservation = .{
        .leader_window_id = group.leader_wid,
        .active_window_id = group.active_wid,
    };
    for (group.members.items) |member_wid| {
        if (observation.addMember(member_wid)) continue;
        log.warn("tab group state rejected group={d} member={d}", .{ group_id, member_wid });
        return false;
    }

    dispatchStateEvent(.{ .observe_window_tab_group = observation });
    for (group.members.items) |member_wid| {
        const member = g_state.window(member_wid) orelse return false;
        if (member.tab_leader_window_id != group.leader_wid) return false;
        if (member.is_suppressed != (member_wid != group.active_wid)) return false;
    }
    return true;
}

fn dissolveWindowTabGroup(wid: u32) void {
    if (g_state.window(wid) == null) return;
    dispatchStateEvent(.{ .dissolve_window_tab_group = wid });
}

fn setTabGroupActive(wid: u32) void {
    g_tab_groups.setActive(wid);
    const group = g_tab_groups.groupOf(wid) orelse return;
    _ = syncWindowTabGroup(group.id);
}

fn assignManagedWindowSpace(wid: u32, space: state_mod.SpaceRef) bool {
    var win = g_store.get(wid) orelse return false;
    const managed = g_state.window(wid) orelse return false;

    if (!managed.space_key.eql(space.key)) {
        dispatchStateEvent(.{ .assign_window_space = .{
            .window_id = wid,
            .space_key = space.key,
        } });
        const assigned = g_state.window(wid) orelse return false;
        if (!assigned.space_key.eql(space.key)) return false;
    }

    win.space = space;
    g_store.putAssumeCapacity(win);
    return true;
}

/// Reserve every allocating container before committing a managed window.
/// Layout insertion happens before the no-fail store/workspace append, so an
/// allocation failure cannot leave a window present in only part of the model.
fn adoptWindow(ws: *workspace_mod.Space, win: window_mod.Window) !void {
    std.debug.assert(g_store.get(win.wid) == null);
    std.debug.assert(win.space.key.eql(ws.ref.key));
    try g_store.ensureUnusedCapacity(1);
    try ws.ensureUnusedWindowCapacity(1);
    if (win.mode == .tiled) try tryInsertIntoTiling(ws.ref.key, win.wid);
    if (!adoptWindowIdentity(win)) {
        if (win.mode == .tiled) removeFromTiling(ws.ref.key, win.wid);
        return error.WindowCatalogRejected;
    }

    g_store.putAssumeCapacity(win);
    ws.addWindowAssumeCapacity(win.wid);
    seedObservedFrame(win.wid, win.frame);
}

fn setTilingActive(space_key: state_mod.SpaceKey, wid: u32) void {
    if (tilingStatePtr(space_key).*) |*st| {
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
    g_store.ensureUnusedCapacity(1) catch return false;
    const ws = spaceForWindow(old) orelse return false;
    const sp = tilingStatePtr(old.space.key);
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
            old.space.workspace_id,
            replaced_in_workspace,
            replaced_in_layout,
        });
        return false;
    }

    var updated = old;
    updated.wid = new_wid;
    updated.frame = frame;
    if (!replaceWindowIdentity(old_wid, new_wid)) {
        _ = ws.replaceWindow(new_wid, old_wid);
        if (replaced_in_layout) {
            if (sp.*) |*st| _ = st.replaceWid(new_wid, old_wid);
        }
        return false;
    }
    g_store.putAssumeCapacity(updated);
    g_store.remove(old_wid);
    g_geometry.forget(old_wid);
    seedObservedFrame(new_wid, frame);
    ax_mod.invalidateWindow(old_wid);
    log.info("window id replaced old={d} new={d} pid={d} workspace={d} display={d}", .{
        old_wid,
        new_wid,
        updated.pid,
        updated.space.workspace_id,
        updated.space.display_id,
    });
    return true;
}

const FocusedLayoutContext = struct {
    focused_wid: u32,
    focused_win: window_mod.Window,
    state: *tiling.State,
};

fn focusedLayoutContext() ?FocusedLayoutContext {
    const ctx = actionContext() orelse return null;
    const sp = tilingStatePtr(ctx.focused_win.space.key);
    if (sp.*) |*st| {
        return .{
            .focused_wid = ctx.focused_wid,
            .focused_win = ctx.focused_win,
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
    space_key: state_mod.SpaceKey,
) ?DropTarget {
    std.debug.assert(inner_gap >= 0);
    switch (node) {
        .leaf => |leaf| {
            if (leaf.wid == dragged_wid) return null;
            if (!frameContainsPoint(frame, center_x, center_y)) return null;
            const target = g_store.get(leaf.wid) orelse return null;
            if (target.mode != .tiled or target.is_fullscreen) return null;
            if (!target.space.key.eql(space_key)) return null;
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
                if (findDropTargetInLayout(split.left, left_frame, inner_gap, dragged_wid, center_x, center_y, space_key)) |target| {
                    return target;
                }
            }
            if (frameContainsPoint(right_frame, center_x, center_y)) {
                if (findDropTargetInLayout(split.right, right_frame, inner_gap, dragged_wid, center_x, center_y, space_key)) |target| {
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
    if (!spaceVisible(win.space)) {
        clearDragPreview();
        return;
    }

    const bsp_state: *bsp_mod.State = blk: {
        const sp = tilingStatePtr(win.space.key);
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
    const display_frame = displayContentFrame(win.space.display_id) orelse {
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
        win.space.key,
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
    if (!source.space.key.eql(target.space.key)) return;

    if (tilingStatePtr(source.space.key).*) |*st| {
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
    processPendingFocusQueue();
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
            ax_mod.invalidateApp(ev.pid);
            ax_observer.unobserveApp(ev.pid);
            removeAppWindows(ev.pid);
            retile();
        },
        .window_focused => {
            const focused_wid_opt = focusedWindowIdForLoggedEvent("window focused", ev.pid);
            if (!g_state.isWorkspaceTransitionActive()) {
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
            if (!g_state.isWorkspaceTransitionActive()) {
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

            if (g_pending_role_windows.contains(ev.wid)) {
                log.debug("window created: role check already pending pid={} wid={}", .{ ev.pid, ev.wid });
                return;
            }

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
                    const ws = resolveWorkspaceForWindow(ev.pid, ev.wid, display_id);
                    trackDeferredWindowCandidate(ev.pid, ev.wid, ws.ref);
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
            // Arm the trailing reconcile on every event, even ones the debounce
            // drops, so it fires once the burst quiets on the final topology.
            armDisplayResettle();
            if (!shouldHandleWorkspaceEvent(&g_last_display_changed_at_s)) return;
            log.info("display changed", .{});
            reconcileDisplays();
        },
        .space_changed => {
            if (nativeSpacesEnabled()) {
                log.info("native space changed", .{});
                dispatchStateEvent(.{ .native_space_changed = nativeStateNowMs() });
                return;
            }
            if (!shouldHandleWorkspaceEvent(&g_last_space_changed_at_s)) return;
            log.info("space changed", .{});
        },
        .role_poll_tick => {
            reconcileDueGeometryObservations();
            processPendingWorkspaceParks();
            processPendingNativeWindowMoves();
            processPendingNativeWorkspaceMove();
            if (processDueNativeStateObservation()) return;
            if (processDueDisplayResettle()) return;
            if (nativeSwitchPending()) return;
            const promoted_pending = processPendingRoleWindows();
            const promoted_deferred = processDeferredWindowCandidates();
            const retried_launch = processAppLaunchRetries();
            processFocusRetries();
            processPendingFocusQueue();
            if (promoted_pending or promoted_deferred or retried_launch) {
                retile();
                updateStatusBar();
            }
        },
        .mouse_down => {
            g_mouse_left_down = true;
            g_pointer_drag_candidate_wid = managedWindowAtPoint(g_mouse_down_location);
            g_pointer_drag_wid = null;
            g_drag_reconcile_on_drop = false;
        },
        .mouse_dragged => {
            if (g_mouse_left_down and g_pointer_drag_wid == null) {
                g_pointer_drag_wid = g_pointer_drag_candidate_wid;
                if (g_pointer_drag_wid) |wid| {
                    log.debug("geometry: pointer drag claimed wid={d}", .{wid});
                }
            }
        },
        .mouse_up => {
            g_mouse_left_down = false;
            g_pointer_drag_candidate_wid = null;
            g_pointer_drag_wid = null;
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
            // Every animation tick sets the AX frame, which echoes back here
            // as moved/resized notifications (~60/sec per window). Ignore
            // them: reacting would overwrite the stored target frame with a
            // mid-flight position and, for fullscreen windows, trigger a full
            // retile per tick.
            if (g_animator.isAnimatingWindow(ev.wid)) return;

            if (inWorkspaceTransition() and g_pointer_drag_wid != ev.wid) {
                if (ev.kind == .window_resized) {
                    clearDragPreview();
                }
                return;
            }

            log.info("window {s} wid={}", .{
                if (ev.kind == .window_moved) "moved" else "resized",
                ev.wid,
            });

            const observed = liveWindowFrame(ev.wid) orelse return;
            const owner = g_geometry.observe(
                ev.wid,
                observed,
                nanoTimestamp(),
                g_pointer_drag_wid,
            ) catch |err| {
                log.warn("geometry: failed to record observation wid={d}: {}", .{ ev.wid, err });
                return;
            };
            refreshRolePolling();

            if (owner == .manager) {
                log.debug("geometry: ignored manager echo wid={d}", .{ev.wid});
                return;
            }
            if (owner == .external) {
                handleExternalWindowGeometry(ev.wid, observed);
                return;
            }

            // A suppressed tab can become a standalone window during the
            // drag. Resolve layout ownership only after that reconciliation:
            // native-tab AX notifications carry the physical member wid,
            // while workspace and BSP state carry the group leader.
            const tab_dragged_out = checkTabDragOut(ev.pid, ev.wid);
            const layout_wid = g_tab_groups.resolveLeader(ev.wid);

            if (updateDraggedWindowGeometry(ev.wid, observed)) {
                retile();
                return;
            }
            if (tab_dragged_out) {
                if (g_store.get(layout_wid)) |win| {
                    observeWindowFocus(win, .drag, null);
                }
                retile();
            }
            // Snap fullscreen windows back to display frame
            if (g_store.get(layout_wid)) |win| {
                if (win.is_fullscreen) {
                    retile();
                    return;
                }
            }
            if (g_pointer_drag_wid == ev.wid) {
                if (g_store.get(layout_wid)) |win| {
                    if (win.mode == .tiled and !win.is_fullscreen and spaceVisible(win.space)) {
                        g_drag_reconcile_on_drop = true;
                    }
                }
            }
            if (ev.kind == .window_moved) {
                updateWindowMovePreview(layout_wid);
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
        .hk_swap_left => swapDirection(.left),
        .hk_swap_right => swapDirection(.right),
        .hk_swap_up => swapDirection(.up),
        .hk_swap_down => swapDirection(.down),
        .hk_toggle_split => {
            g_bsp_split_mode = switch (g_bsp_split_mode) {
                .auto => .horizontal,
                .horizontal => .vertical,
                .vertical => .auto,
            };
            log.info("split mode: {s}", .{@tagName(g_bsp_split_mode)});
        },
        .hk_toggle_fullscreen => {
            const ctx = actionContext() orelse return;
            toggleWindowFullscreen(ctx.focused_wid);
        },
        .hk_move_workspace_to_display => {
            const arg: u8 = @intCast(ev.wid);
            if (arg == config_mod.next_display_arg) {
                log.info("hotkey: move workspace to display next", .{});
                moveWorkspaceToDisplayNext();
            } else if (arg == config_mod.previous_display_arg) {
                log.info("hotkey: move workspace to display prev", .{});
                moveWorkspaceToDisplayPrev();
            } else {
                log.info("hotkey: move workspace to display {}", .{arg});
                moveWorkspaceToDisplay(@as(usize, arg) - 1);
            }
        },
        .hk_toggle_float => {
            const ctx = actionContext() orelse return;
            const target: window_mod.WindowMode = if (ctx.focused_win.mode != .tiled) .tiled else .floating;
            setWindowMode(ctx.focused_wid, target);
        },
        .hk_center_float => {
            const ctx = actionContext() orelse return;
            centerFloatingWindow(ctx.focused_wid);
        },
        .hk_reload_config => _ = reloadConfig(),
        .hk_toggle_dimming => {
            const on = dim.toggle();
            log.info("hotkey: dimming {s}", .{if (on) "on" else "off"});
            // Re-apply immediately when enabling so overlays appear without
            // waiting for the next settled drain. Disabling already hid them.
            if (on) pushDimSnapshot();
        },
    }
}

// Window mode (tiled / floating / fullscreen)

fn setWindowMode(wid: u32, target: window_mod.WindowMode) void {
    var win = g_store.get(wid) orelse return;
    const old = win.mode;
    if (old == target) return;

    // Allocate the new layout slot before changing the stored mode. On
    // failure the window remains consistently floating.
    if (target == .tiled) {
        tryInsertIntoTiling(win.space.key, wid) catch |err| {
            log.err("failed to tile wid={d}: {}", .{ wid, err });
            return;
        };
    }

    // Leaving tiled → remove from BSP so remaining windows fill the space
    if (old == .tiled) {
        removeFromTiling(win.space.key, wid);
    }

    win.mode = target;
    g_store.putAssumeCapacity(win);
    log.info("window {d} mode: {s} → {s}", .{ wid, @tagName(old), @tagName(target) });
    retile();
}

/// Toggle fullscreen for a window. A tiled window gets its non-fullscreen
/// frame back from the BSP tree, but a floating window has no layout slot to
/// fall back to: capture where it was on the way in and write it back on the
/// way out, because retile only ever re-asserts the fullscreen frame.
///
/// `wid` is a tab-group leader when the window is grouped — the leader carries
/// the fullscreen intent because it owns the workspace slot, but the pixels
/// belong to the active tab.
fn toggleWindowFullscreen(wid: u32) void {
    var win = g_store.get(wid) orelse return;
    win.is_fullscreen = !win.is_fullscreen;

    const visible_wid = g_tab_groups.resolveActive(wid);
    const restore_to: ?window_mod.Window.Frame = blk: {
        if (win.mode != .floating) break :blk null;
        if (!win.is_fullscreen) break :blk win.float_frame;

        win.float_frame = liveWindowFrame(visible_wid) orelse win.frame;
        break :blk null;
    };

    g_store.put(win) catch {};

    if (restore_to) |target| {
        if (g_store.get(visible_wid)) |visible| {
            if (applyWindowFrame(visible.pid, visible_wid, visible.frame, target, false, .floating_restore)) {
                var updated = visible;
                updated.frame = target;
                g_store.put(updated) catch {};
            }
        }
        applyFrameToTabGroup(wid, target);
    }

    log.info("fullscreen {s} wid={d} mode={s}", .{
        if (win.is_fullscreen) "on" else "off",
        wid,
        @tagName(win.mode),
    });
    retile();
}

/// Center a floating window on its display and remember the centered position
/// so a later hide/show restores it there. No-op for tiled or fullscreen
/// windows, whose geometry is owned by the layout.
fn centerFloatingWindow(wid: u32) void {
    var win = g_store.get(wid) orelse return;
    if (win.mode != .floating or win.is_fullscreen) return;

    const display_slot = displayIndexById(win.space.display_id) orelse return;
    const display = g_displays[display_slot].visible;

    const size = liveWindowFrame(wid) orelse win.frame;
    const target = centeredFrame(size.width, size.height, display);
    if (!setWindowFrameTracked(win.pid, wid, target, .user_command)) {
        log.warn("center floating: frame write rejected wid={d}", .{wid});
        return;
    }
    win.frame = target;
    win.float_frame = target;
    g_store.put(win) catch {};
    log.info("center floating wid={d} → x={d:.0} y={d:.0}", .{ wid, target.x, target.y });
}

// Window management helpers

fn windowRoleState(pid: i32, wid: u32) WindowRoleState {
    return windowRoleStateFromRaw(pid, wid, bw_window_manage_state(pid, wid));
}

fn windowRoleStateWithMessagingTimeout(pid: i32, wid: u32) WindowRoleState {
    const raw_state = manageStateForWindowWithMessagingTimeout(pid, wid, role_poll_ax_timeout_s);
    return windowRoleStateFromRaw(pid, wid, raw_state);
}

fn windowRoleStateFromRaw(pid: i32, wid: u32, raw_state: u8) WindowRoleState {
    std.debug.assert(wid != 0);
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
        g_focus_retries.count() > 0 or
        g_state.hasPendingNativeWindowMoves() or
        g_state.pendingNativeWorkspaceMove() != null or
        g_state.hasDeferredFollowFocus() or
        g_state.hasScheduledObservation() or
        g_state.isWorkspaceTransitionActive() or
        g_display_resettle_at_s != 0 or
        hasPendingWorkspaceParks() or
        g_event_overflow_recovery_pending or
        g_geometry.hasPendingResamples();
    setRolePolling(has_pending);
}

fn rollbackNativeWindowMove(wid: u32, pending: state_mod.PendingNativeWindowMove) bool {
    var win = g_store.get(wid) orelse return true;
    if (!win.space.key.eql(pending.target.key)) return true;

    const source_ws = g_workspaces.get(pending.source.key) orelse return false;
    const target_ws = g_workspaces.get(pending.target.key) orelse return false;
    source_ws.ensureUnusedWindowCapacity(1) catch return false;
    if (win.mode == .tiled) {
        tryInsertIntoTiling(source_ws.ref.key, wid) catch |err| {
            log.err("native window move: rollback layout failed wid={d}: {}", .{ wid, err });
            return false;
        };
    }
    if (!moveTabGroupToNativeSpace(wid, pending.source)) {
        if (win.mode == .tiled) removeFromTiling(source_ws.ref.key, wid);
        return false;
    }
    if (!assignManagedWindowSpace(wid, source_ws.ref)) {
        if (win.mode == .tiled) removeFromTiling(source_ws.ref.key, wid);
        return false;
    }

    source_ws.addWindowAssumeCapacity(wid);
    target_ws.removeWindow(wid);
    removeFromTiling(target_ws.ref.key, wid);
    if (focusedWorkspaceWindow(source_ws) == null) recordWorkspaceFocus(source_ws, wid);

    updateTabGroupAssignment(wid, source_ws.ref);
    return true;
}

fn processPendingNativeWindowMoves() void {
    if (!g_state.hasPendingNativeWindowMoves()) return;

    const snapshot = g_state.pending_native_window_moves;
    for (snapshot.items()) |pending| {
        const wid = pending.window_id;
        const win = g_store.get(wid);
        const observation: state_mod.NativeWindowMoveObservation = if (win == null)
            .window_missing
        else if (!win.?.space.key.eql(pending.target.key))
            .ownership_changed
        else if (nativeTabGroupMoveConfirmed(wid, pending) == true)
            .confirmed
        else
            .pending;

        dispatchStateEvent(.{ .native_window_move_observed = .{
            .window_id = wid,
            .epoch = pending.epoch,
            .observation = observation,
        } });
    }
}

fn executeNativeWorkspaceMove(pending: state_mod.PendingNativeWorkspaceMove) void {
    const succeeded = moveNativeWorkspaceContents(pending, true);
    dispatchStateEvent(.{ .native_workspace_move_started = .{
        .epoch = pending.epoch,
        .succeeded = succeeded,
        .at_ms = nativeStateNowMs(),
    } });
}

fn executeNativeWorkspaceMoveRollback(pending: state_mod.PendingNativeWorkspaceMove) void {
    const succeeded = moveNativeWorkspaceContents(pending, false);
    dispatchStateEvent(.{ .native_workspace_move_rollback_result = .{
        .epoch = pending.epoch,
        .succeeded = succeeded,
    } });
}

fn moveNativeWorkspaceContents(pending: state_mod.PendingNativeWorkspaceMove, is_forward: bool) bool {
    const source_target = if (is_forward) pending.target else pending.source;
    const target_target = if (is_forward) pending.source else pending.target;
    var source_window_ids: [state_mod.max_managed_windows]u32 = undefined;
    var target_window_ids: [state_mod.max_managed_windows]u32 = undefined;
    const source_windows = g_state.workspaceWindowIds(pending.source.key, &source_window_ids);
    const target_windows = g_state.workspaceWindowIds(pending.target.key, &target_window_ids);

    for (source_windows) |wid| {
        if (!moveTabGroupToNativeSpace(wid, source_target)) {
            if (is_forward) _ = moveNativeWorkspaceContents(pending, false);
            return false;
        }
    }
    for (target_windows) |wid| {
        if (!moveTabGroupToNativeSpace(wid, target_target)) {
            if (is_forward) _ = moveNativeWorkspaceContents(pending, false);
            return false;
        }
    }
    return true;
}

fn processPendingNativeWorkspaceMove() void {
    const pending = g_state.pendingNativeWorkspaceMove() orelse return;
    if (!pending.has_started or pending.is_rolling_back) return;

    dispatchStateEvent(.{ .native_workspace_move_observed = .{
        .epoch = pending.epoch,
        .observation = if (nativeWorkspaceContentsConfirmed(pending)) .confirmed else .pending,
        .at_ms = nativeStateNowMs(),
    } });
}

fn nativeWorkspaceContentsConfirmed(pending: state_mod.PendingNativeWorkspaceMove) bool {
    var source_window_ids: [state_mod.max_managed_windows]u32 = undefined;
    var target_window_ids: [state_mod.max_managed_windows]u32 = undefined;
    const source_windows = g_state.workspaceWindowIds(pending.source.key, &source_window_ids);
    const target_windows = g_state.workspaceWindowIds(pending.target.key, &target_window_ids);

    for (source_windows) |wid| {
        const move: state_mod.PendingNativeWindowMove = .{
            .window_id = wid,
            .source = pending.source,
            .target = pending.target,
            .epoch = pending.epoch,
        };
        if (nativeTabGroupMoveConfirmed(wid, move) != true) return false;
    }
    for (target_windows) |wid| {
        const move: state_mod.PendingNativeWindowMove = .{
            .window_id = wid,
            .source = pending.target,
            .target = pending.source,
            .epoch = pending.epoch,
        };
        if (nativeTabGroupMoveConfirmed(wid, move) != true) return false;
    }
    return true;
}

fn completeNativeWorkspaceMove(pending: state_mod.PendingNativeWorkspaceMove) void {
    const source_index = g_workspaces.indexOf(pending.source.key) orelse return;
    const target_index = g_workspaces.indexOf(pending.target.key) orelse return;
    const moved_ref = g_state.space(pending.target.key) orelse return;
    const displaced_ref = g_state.space(pending.source.key) orelse return;

    g_workspaces.spaces[source_index].ref = moved_ref;
    g_workspaces.spaces[target_index].ref = displaced_ref;
    refreshLegacyWorkspaceWindows(&g_workspaces.spaces[source_index]);
    refreshLegacyWorkspaceWindows(&g_workspaces.spaces[target_index]);

    assertDisplayCoverage();
    setFocusedDisplay(moved_ref.display_id);
    retile();
    updateStatusBar();
    focusWorkspaceWindow(&g_workspaces.spaces[source_index]);
}

fn refreshLegacyWorkspaceWindows(space: *workspace_mod.Space) void {
    var window_ids: [state_mod.max_managed_windows]u32 = undefined;
    const workspace_windows = g_state.workspaceWindowIds(space.ref.key, &window_ids);
    std.debug.assert(workspace_windows.len == space.windows.items.len);

    for (workspace_windows) |wid| {
        std.debug.assert(legacyWorkspaceContainsWindow(space, wid));
        if (g_store.get(wid)) |window| {
            var updated = window;
            updated.space = space.ref;
            g_store.putAssumeCapacity(updated);
        }
        updateTabGroupAssignment(wid, space.ref);
    }
}

fn legacyWorkspaceContainsWindow(space: *const workspace_mod.Space, wid: u32) bool {
    for (space.windows.items) |candidate| {
        if (candidate == wid) return true;
    }
    return false;
}

/// Full reconcile after a topology change: rebuild display/workspace state,
/// pick up windows, retile, refresh the bar.
fn reconcileDisplays() void {
    reconcileDisplayChange();
    discoverWindows();
    retile();
    updateStatusBar();
}

fn captureNativeTopology() ?state_mod.NativeTopology {
    const sky = &g_sky.?;
    var snapshot = sky.nativeSpaceTopology() orelse {
        log.warn("native topology: WindowServer snapshot unavailable", .{});
        return null;
    };
    defer snapshot.deinit();

    var observation: state_mod.NativeTopologyObservation = .{};
    for (g_displays[0..g_display_count]) |display| {
        const observed_space_id = snapshot.currentSpaceId(display.id) orelse {
            log.warn("native topology: current Space unavailable display={d}", .{display.id});
            return null;
        };
        const available_count = snapshot.ordinarySpaceCount(display.id) orelse {
            log.warn("native topology: ordinary Space count unavailable display={d}", .{display.id});
            return null;
        };
        const captured_count = @min(available_count, state_mod.max_spaces_per_display);
        if (captured_count == 0) {
            log.warn("native topology: display has no ordinary Spaces display={d}", .{display.id});
            return null;
        }

        var observed_display: state_mod.NativeDisplayObservation = .{
            .display_id = display.id,
            .observed_space_id = observed_space_id,
            .space_count = captured_count,
        };
        var ordinal: u8 = 1;
        while (ordinal <= captured_count) : (ordinal += 1) {
            observed_display.space_ids[ordinal - 1] = snapshot.ordinarySpaceIdAtOrdinal(display.id, ordinal) orelse {
                log.warn("native topology: Space unavailable display={d} ordinal={d}", .{ display.id, ordinal });
                return null;
            };
        }
        if (std.mem.indexOfScalar(u64, observed_display.space_ids[0..captured_count], observed_space_id) == null) {
            log.warn("native topology: observed Space outside managed range display={d} space={d}", .{ display.id, observed_space_id });
            return null;
        }
        observation.addDisplay(observed_display);
    }

    return state_mod.mapNativeTopology(
        observation,
        &g_state.native_topology,
        &g_state.workspace_topology,
        &g_state.spaces,
        g_workspaces.workspace_count,
    );
}

fn dispatchStateEvent(event: state_mod.Event) void {
    const transition = state_mod.reduce(g_state, event);
    g_state = transition.model;

    for (transition.effects[0..transition.effect_count]) |effect| {
        executeStateEffect(effect);
    }
    refreshRolePolling();
}

fn executeStateEffect(effect: state_mod.Effect) void {
    switch (effect) {
        .switch_native_space => |value| executeNativeSwitch(value),
        .observe_native_topology => |epoch| observeNativeTopology(epoch),
        .focus_observed_space => |space| focusObservedNativeSpace(space),
        .native_switch_completed => |value| completeNativeSwitch(value.space, value.epoch),
        .native_switch_failed => |value| failNativeSwitch(value),
        .native_topology_changed => reconcileObservedNativeTopology(),
        .native_switch_rejected => |space| log.warn("native workspace switch rejected display={d} workspace={d}", .{
            space.display_id,
            space.workspace_id,
        }),
        .window_catalog_rejected => |rejection| log.warn("window catalog rejected wid={d} reason={s}", .{
            rejection.window_id,
            @tagName(rejection.reason),
        }),
        .workspace_transition_started => |transition| executeWorkspaceTransitionStarted(transition),
        .workspace_transition_settled => |settlement| executeWorkspaceTransitionSettled(settlement),
        .retry_native_window_move => |pending| retryNativeWindowMove(pending),
        .rollback_native_window_move => |pending| executeNativeWindowMoveRollback(pending),
        .native_window_move_confirmed => |pending| log.debug("native window move: confirmed wid={d} workspace={d}", .{
            pending.window_id,
            pending.target.workspace_id,
        }),
        .native_window_move_cancelled => |pending| log.debug("native window move: cancelled wid={d} workspace={d}", .{
            pending.window_id,
            pending.target.workspace_id,
        }),
        .native_window_move_rolled_back => |pending| completeNativeWindowMoveRollback(pending),
        .native_window_move_rollback_deferred => |pending| log.warn("native window move: rollback deferred wid={d} source={d} target={d}", .{
            pending.window_id,
            pending.source.workspace_id,
            pending.target.workspace_id,
        }),
        .native_window_move_rejected => |request| log.warn("native window move: tracking rejected wid={d} source={d} target={d}", .{
            request.window_id,
            request.source.workspace_id,
            request.target.workspace_id,
        }),
        .move_native_workspace_contents => |pending| executeNativeWorkspaceMove(pending),
        .rollback_native_workspace_contents => |pending| executeNativeWorkspaceMoveRollback(pending),
        .native_workspace_move_completed => |pending| completeNativeWorkspaceMove(pending),
        .native_workspace_move_failed => |failure| log.warn("native workspace move failed source={d} target={d} rollback={}", .{
            failure.move.source.workspace_id,
            failure.move.target.workspace_id,
            failure.rollback_succeeded,
        }),
        .native_workspace_move_rejected => |request| log.warn("native workspace move rejected source={d} target={d}", .{
            request.source.workspace_id,
            request.target.workspace_id,
        }),
        .apply_pending_focus => |pending| applyPendingFocusEntry(pending),
        .window_focus_deferred => |deferred| executeWindowFocusDeferred(deferred),
        .window_focus_accepted => |accepted| executeWindowFocusAccepted(accepted),
        .follow_focus_ignored_during_native_switch => |ignored| log.debug("follow focus ignored during native switch wid={d} pid={d} workspace={d} target_workspace={d}", .{
            ignored.observation.window_id,
            ignored.observation.process_id,
            ignored.observation.target.workspace_id,
            ignored.pending_target.workspace_id,
        }),
        .follow_focus_deferred => |deferred| log.debug("follow focus deferred wid={d} leader={d} pid={d} workspace={d} display={d} epoch={d} target_workspace={d} completion={s}", .{
            deferred.observation.window_id,
            deferred.observation.leader_window_id,
            deferred.observation.process_id,
            deferred.observation.target.workspace_id,
            deferred.observation.target.display_id,
            deferred.transition.epoch,
            deferred.transition.target.workspace_id,
            if (deferred.transition.completion_reason) |reason| @tagName(reason) else "none",
        }),
        .follow_focus_workspace => |observation| executeFollowFocusWorkspace(observation),
    }
}

fn executeWindowFocusDeferred(deferred: @FieldType(state_mod.Effect, "window_focus_deferred")) void {
    const observation = deferred.observation;
    const transition = deferred.transition;
    log.debug("workspace transition focus deferred epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d} visible={}", .{
        transition.epoch,
        observation.window_id,
        observation.process_id,
        @tagName(observation.source),
        observation.target.workspace_id,
        observation.target.display_id,
        transition.target.workspace_id,
        transition.target.display_id,
        observation.is_target_visible,
    });
    if (observation.source == .keyboard) return;

    log.debug("workspace transition pending focus queued epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d} pending={d}", .{
        transition.epoch,
        observation.window_id,
        observation.process_id,
        @tagName(observation.source),
        observation.target.workspace_id,
        observation.target.display_id,
        transition.target.workspace_id,
        transition.target.display_id,
        deferred.pending_count,
    });
}

fn executeWindowFocusAccepted(accepted: @FieldType(state_mod.Effect, "window_focus_accepted")) void {
    const observation = accepted.observation;
    const transition = accepted.transition;
    log.debug("workspace transition focus accepted epoch={d} wid={d} pid={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d}", .{
        transition.epoch,
        observation.window_id,
        observation.process_id,
        @tagName(observation.source),
        observation.target.workspace_id,
        observation.target.display_id,
        transition.target.workspace_id,
        transition.target.display_id,
    });
    if (transition.completion_reason != null) return;

    log.debug("workspace transition marked complete epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
        transition.epoch,
        @tagName(transition.kind),
        transition.target.workspace_id,
        transition.target.display_id,
        @tagName(state_mod.WorkspaceTransitionCompletionReason.focus_accepted),
    });
}

fn executeFollowFocusWorkspace(observation: state_mod.FollowFocusObservation) void {
    log.debug("follow focus switching wid={d} leader={d} pid={d} workspace={d} display={d}", .{
        observation.window_id,
        observation.leader_window_id,
        observation.process_id,
        observation.target.workspace_id,
        observation.target.display_id,
    });
    setFocusedDisplay(observation.target.display_id);
    switchWorkspace(observation.target.workspace_id);
}

fn retryNativeWindowMove(pending: state_mod.PendingNativeWindowMove) void {
    if (!moveTabGroupToNativeSpace(pending.window_id, pending.target)) {
        log.warn("native window move: retry failed wid={d} workspace={d}", .{
            pending.window_id,
            pending.target.workspace_id,
        });
        return;
    }
    log.debug("native window move: retry wid={d} workspace={d}", .{
        pending.window_id,
        pending.target.workspace_id,
    });
}

fn executeNativeWindowMoveRollback(pending: state_mod.PendingNativeWindowMove) void {
    const succeeded = rollbackNativeWindowMove(pending.window_id, pending);
    dispatchStateEvent(.{ .native_window_move_rollback_result = .{
        .window_id = pending.window_id,
        .epoch = pending.epoch,
        .succeeded = succeeded,
    } });
}

fn completeNativeWindowMoveRollback(pending: state_mod.PendingNativeWindowMove) void {
    log.warn("native window move: destination not confirmed; restored wid={d} workspace={d}", .{
        pending.window_id,
        pending.source.workspace_id,
    });
    retile();
    updateStatusBar();
}

fn executeWorkspaceTransitionStarted(transition: state_mod.WorkspaceTransition) void {
    const current = g_state.workspace_transition orelse return;
    if (current.epoch != transition.epoch) return;

    log.debug("workspace transition started epoch={d} kind={s} workspace={d} display={d}", .{
        transition.epoch,
        @tagName(transition.kind),
        transition.target.workspace_id,
        transition.target.display_id,
    });
}

fn executeWorkspaceTransitionSettled(settlement: state_mod.WorkspaceTransitionSettlement) void {
    if (g_state.workspace_transition != null) return;

    const transition = settlement.transition;
    if (settlement.reason == .completed) {
        const reason = transition.completion_reason.?;
        log.debug("workspace transition completed epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
            transition.epoch,
            @tagName(transition.kind),
            transition.target.workspace_id,
            transition.target.display_id,
            @tagName(reason),
        });
    } else if (settlement.reason == .deadline_expired) {
        const front_pid = frontmostApplicationPid() orelse 0;
        const front_wid = if (front_pid > 0) focusedWindowIdForPid(front_pid) orelse 0 else 0;
        const active_workspace_id = activeWorkspaceIdForDisplay(transition.target.display_id);
        log.warn(
            "workspace transition watchdog expired epoch={d} kind={s} workspace={d} display={d} active_workspace={d} focused_display={d} front_pid={d} front_wid={d}",
            .{
                transition.epoch,
                @tagName(transition.kind),
                transition.target.workspace_id,
                transition.target.display_id,
                active_workspace_id,
                focusedDisplayId(),
                front_pid,
                front_wid,
            },
        );
    } else {
        log.debug("workspace transition cancelled epoch={d} kind={s} workspace={d} display={d} reason={s}", .{
            transition.epoch,
            @tagName(transition.kind),
            transition.target.workspace_id,
            transition.target.display_id,
            @tagName(settlement.reason),
        });
    }

    reconcileVisibleFramesFromWindowServer();
    applyDeferredFollowFocus(settlement.deferred_follow_focus);
}

fn executeNativeSwitch(effect: @FieldType(state_mod.Effect, "switch_native_space")) void {
    const request = effect.request;
    const native_space_id = switch (request.target.key) {
        .native => |space_id| space_id,
        .virtual => unreachable,
    };
    if (!g_sky.?.switchNativeSpaceId(request.target.display_id, native_space_id)) {
        dispatchStateEvent(.{ .native_switch_effect_failed = .{
            .epoch = effect.epoch,
            .at_ms = nativeStateNowMs(),
        } });
        return;
    }

    log.debug("native workspace switch requested epoch={d} display={d} workspace={d} space={d}", .{
        effect.epoch,
        request.target.display_id,
        request.target.workspace_id,
        native_space_id,
    });
    setFocusedDisplay(request.target.display_id);
    updateStatusBar();
}

fn observeNativeTopology(epoch: state_mod.Epoch) void {
    const at_ms = nativeStateNowMs();
    const topology = captureNativeTopology() orelse {
        dispatchStateEvent(.{ .native_topology_unavailable = .{
            .epoch = epoch,
            .at_ms = at_ms,
        } });
        return;
    };
    dispatchStateEvent(.{ .native_topology_observed = .{
        .topology = topology,
        .epoch = epoch,
        .at_ms = at_ms,
    } });
}

fn focusObservedNativeSpace(space: state_mod.SpaceRef) void {
    const workspace = g_workspaces.get(space.key) orelse return;
    setFocusedDisplay(space.display_id);
    updateStatusBar();
    focusWorkspaceWindow(workspace);
}

fn completeNativeSwitch(space: state_mod.SpaceRef, epoch: state_mod.Epoch) void {
    const started_ns = nanoTimestamp();
    const workspace = g_workspaces.get(space.key) orelse return;
    for (workspace.windows.items) |wid| {
        if (!assignManagedWindowSpace(wid, workspace.ref)) continue;
        updateTabGroupAssignment(wid, workspace.ref);
    }

    clearPendingFocusQueue();

    _ = discoverWindowsAfterNativeSpaceSwitch();
    clearDragPreview();
    requestRetileDisplay(space.display_id);
    if (!g_event_drain_active) flushRetileRequests();
    updateStatusBar();

    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] native workspace switch completed state_epoch={d} workspace={d} display={d} elapsed_ms={}", .{
        epoch,
        space.workspace_id,
        space.display_id,
        elapsed_ms,
    });
}

fn failNativeSwitch(failure: @FieldType(state_mod.Effect, "native_switch_failed")) void {
    log.warn("native workspace switch failed state_epoch={d} display={d} workspace={d} target_space={d} reason={s} actual_space={d} actual_workspace={d}", .{
        failure.epoch,
        failure.request.target.display_id,
        failure.request.target.workspace_id,
        switch (failure.request.target.key) {
            .native => |space_id| space_id,
            .virtual => 0,
        },
        @tagName(failure.reason),
        if (failure.actual) |actual| switch (actual.key) {
            .native => |space_id| space_id,
            .virtual => 0,
        } else 0,
        if (failure.actual) |actual| actual.workspace_id else 0,
    });
    reconcileObservedNativeTopology();
}

fn reconcileObservedNativeTopology() void {
    const started_ns = nanoTimestamp();
    const sky = &g_sky.?;
    var topology = sky.nativeSpaceTopology();
    defer if (topology) |*snapshot| snapshot.deinit();

    if (topology) |*snapshot| {
        reconcileNativeWindowAssignments(snapshot);
    } else {
        log.warn("native workspace reconcile could not snapshot window assignments", .{});
    }
    discoverWindows();
    retile();
    updateStatusBar();

    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] native topology reconcile elapsed_ms={}", .{elapsed_ms});
}

fn reconcileNativeWindowAssignments(topology: *const skylight.NativeSpaceTopology) void {
    const sky = &g_sky.?;
    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return;
    var repairs: [256]struct { wid: u32, target: state_mod.SpaceRef } = undefined;
    var repair_count: usize = 0;

    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        const win = entry.value_ptr.*;
        if (g_tab_groups.resolveLeader(win.wid) != win.wid) continue;
        if (g_state.pendingNativeWindowMove(win.wid) != null) continue;
        const visible_wid = g_tab_groups.resolveActive(win.wid);
        if (!on_screen.contains(visible_wid)) continue;

        const space_id = topology.spaceIdForWindow(sky, visible_wid, win.space.display_id) orelse continue;
        if (win.space.key.eql(.{ .native = space_id })) continue;
        if (repair_count == repairs.len) {
            log.warn("native workspace assignment repair truncated limit={d}", .{repairs.len});
            break;
        }
        const target = g_state.space(.{ .native = space_id }) orelse continue;
        repairs[repair_count] = .{ .wid = win.wid, .target = target };
        repair_count += 1;
    }

    for (repairs[0..repair_count]) |repair| {
        reassignManagedWindowToNativeWorkspace(repair.wid, repair.target);
    }
}

fn reassignManagedWindowToNativeWorkspace(wid: u32, target: state_mod.SpaceRef) void {
    var win = g_store.get(wid) orelse return;
    if (win.space.key.eql(target.key)) return;

    const source_ws = spaceForWindow(win) orelse return;
    const target_ws = g_workspaces.get(target.key) orelse return;
    target_ws.ensureUnusedWindowCapacity(1) catch return;
    if (win.mode == .tiled) {
        tryInsertIntoTiling(target_ws.ref.key, wid) catch |err| {
            log.warn("native workspace assignment layout repair failed wid={d} workspace={d}: {}", .{ wid, target.workspace_id, err });
            return;
        };
    }
    if (!assignManagedWindowSpace(wid, target_ws.ref)) {
        if (win.mode == .tiled) removeFromTiling(target_ws.ref.key, wid);
        return;
    }

    const source_workspace_id = win.space.workspace_id;
    target_ws.addWindowAssumeCapacity(wid);
    source_ws.removeWindow(wid);
    removeFromTiling(source_ws.ref.key, wid);
    if (focusedWorkspaceWindow(target_ws) == null) recordWorkspaceFocus(target_ws, wid);

    updateTabGroupAssignment(wid, target_ws.ref);
    log.debug("native workspace assignment repaired wid={d} source={d} target={d}", .{ wid, source_workspace_id, target.workspace_id });
}

fn processDueNativeStateObservation() bool {
    const now_ms = nativeStateNowMs();
    const timer = g_state.dueObservation(now_ms) orelse return false;
    dispatchStateEvent(.{ .observation_timer_fired = .{
        .epoch = timer.epoch,
        .at_ms = now_ms,
    } });
    return true;
}

/// (Re-)arm the trailing display reconcile for `display_settle_delay_s` from
/// now and keep the poll timer alive to service it.
fn armDisplayResettle() void {
    g_display_resettle_at_s = c.CFAbsoluteTimeGetCurrent() + display_settle_delay_s;
    refreshRolePolling();
}

/// On a role-poll tick, run the trailing reconcile once the arrangement has
/// been quiet for the settle delay. Returns true when it fired so the tick
/// skips the rest of its work this round.
fn processDueDisplayResettle() bool {
    if (g_display_resettle_at_s == 0) return false;
    if (c.CFAbsoluteTimeGetCurrent() < g_display_resettle_at_s) return false;

    g_display_resettle_at_s = 0;
    log.info("display resettle", .{});
    reconcileDisplays();
    refreshRolePolling();
    return true;
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

fn trackPendingRoleWindow(pid: i32, wid: u32, space: state_mod.SpaceRef) void {
    std.debug.assert(wid != 0);
    space.assertValid();
    if (g_store.get(wid) != null) return;

    if (g_pending_role_windows.getPtr(wid)) |pending| {
        pending.pid = pid;
        pending.attempts_remaining = role_poll_attempts_max;
        pending.space = space;
    } else {
        g_pending_role_windows.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
            .space = space,
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
        forgetGeometryIfUnmanaged(wid);
        refreshRolePolling();
    }
}

fn forgetGeometryIfUnmanaged(wid: u32) void {
    if (g_store.get(wid) != null) return;
    if (g_pending_role_windows.contains(wid)) return;
    if (g_deferred_window_candidates.contains(wid)) return;
    g_geometry.forget(wid);
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
                forgetGeometryIfUnmanaged(wid);
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

fn trackDeferredWindowCandidate(pid: i32, wid: u32, space: state_mod.SpaceRef) void {
    std.debug.assert(wid != 0);
    space.assertValid();
    if (g_store.get(wid) != null) {
        if (g_deferred_window_candidates.remove(wid)) {
            refreshRolePolling();
        }
        return;
    }

    if (g_deferred_window_candidates.getPtr(wid)) |candidate| {
        // Update metadata but keep the remaining retry budget: re-tracking an
        // existing candidate is a continuation of the same wait, not a new
        // window. Resetting here would let a window that repeatedly fails
        // promotion (e.g. permanently degenerate bounds) re-arm its budget
        // every cycle and poll forever.
        candidate.pid = pid;
        candidate.space = space;
    } else {
        g_deferred_window_candidates.put(wid, .{
            .pid = pid,
            .attempts_remaining = role_poll_attempts_max,
            .space = space,
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
        forgetGeometryIfUnmanaged(wid);
        refreshRolePolling();
    }
}

fn untrackDeferredWindowCandidatesForPid(pid: i32) void {
    if (removeEntriesForPid(DeferredWindowCandidate, &g_deferred_window_candidates, pid)) {
        refreshRolePolling();
    }
}

fn addNewWindowLegacyPendingFallback(pid: i32, wid: u32, space: state_mod.SpaceRef) bool {
    std.debug.assert(wid != 0);
    if (g_store.get(wid) != null) return false;
    if (!bw_should_manage_window(pid, wid)) {
        log.debug("pending-role: fallback rejected pid={d} wid={d}", .{ pid, wid });
        return false;
    }
    return addNewWindowManagedWithAssignment(pid, wid, space);
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
    const started_ns = nanoTimestamp();

    var it = g_pending_role_windows.iterator();
    while (it.next()) |entry| {
        const elapsed_ns = nanoTimestamp() - started_ns;
        if (elapsed_ns >= role_poll_work_budget_ms * std.time.ns_per_ms) break;

        const wid = entry.key_ptr.*;
        const pid = entry.value_ptr.pid;

        const state = windowRoleStateWithMessagingTimeout(pid, wid);
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
                    .space = entry.value_ptr.space,
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
                        .space = entry.value_ptr.space,
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
        forgetGeometryIfUnmanaged(wid);
    }
    refreshRolePolling();

    if (truncated) {
        log.warn("pending-role: batch truncated remaining={d}", .{g_pending_role_windows.count()});
    }

    var added_any = false;
    for (candidates[0..candidate_count]) |candidate| {
        if (candidate.from_timeout) {
            const timeout_ms = @as(u64, role_poll_attempts_max) * role_poll_interval_ms;
            if (isUntileablePendingRoleWindow(candidate.pid, candidate.wid)) {
                log.info("pending-role: timeout pid={d} wid={d} after {d}ms unresolved or AXUnknown, skipping legacy fallback", .{ candidate.pid, candidate.wid, timeout_ms });
                continue;
            }
            log.info("pending-role: timeout pid={d} wid={d} after {d}ms, applying legacy fallback", .{ candidate.pid, candidate.wid, timeout_ms });
            // The display captured at tracking time cannot be trusted after a
            // topology change: the monitor can be gone, or its numeric id can
            // now belong to a different monitor while still looking present.
            // The workspace home is reconciled by UUID and is the single
            // source of truth for where its windows live, so always derive
            // the fallback display from it.
            const current_space = g_state.space(candidate.space.key) orelse continue;
            if (addNewWindowLegacyPendingFallback(candidate.pid, candidate.wid, current_space)) {
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
                    // Do not remove yet: promotion can fail (unsettled
                    // bounds) and re-defer, and the entry must survive so its
                    // retry budget keeps depleting. Removal happens after the
                    // promotion attempt below.
                    if (promote_count == promote_candidates.len) {
                        truncated = true;
                        break;
                    }
                    promote_candidates[promote_count] = .{
                        .pid = pid,
                        .wid = wid,
                        .space = entry.value_ptr.space,
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
        forgetGeometryIfUnmanaged(wid);
    }

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
        if (addNewWindowManaged(candidate.pid, candidate.wid) or g_store.get(candidate.wid) != null) {
            // Managed (or resolved another way, e.g. adopted into a tab
            // group, which stores the window without returning true).
            _ = g_deferred_window_candidates.remove(candidate.wid);
            forgetGeometryIfUnmanaged(candidate.wid);
            added_any = true;
        } else if (g_deferred_window_candidates.getPtr(candidate.wid)) |entry| {
            // Promotion failed and re-deferred (e.g. bounds still unsettled).
            // Deplete the surviving entry's budget so a window whose bounds
            // never settle expires instead of cycling forever.
            if (entry.attempts_remaining == 0) {
                _ = g_deferred_window_candidates.remove(candidate.wid);
                forgetGeometryIfUnmanaged(candidate.wid);
                log.info("deferred-window: giving up pid={d} wid={d} after {d}ms with unsettled bounds", .{
                    candidate.pid,
                    candidate.wid,
                    timeout_ms,
                });
            } else {
                entry.attempts_remaining -= 1;
            }
        }
        // Promotion returned false without re-deferring: the candidate was
        // rejected or resolved elsewhere and needs no further tracking.
    }
    refreshRolePolling();
    return added_any;
}

fn discoverWindows() void {
    _ = discoverWindowsImpl(false);
}

fn discoverWindowsAfterNativeSpaceSwitch() usize {
    return discoverWindowsImpl(true);
}

fn discoverWindowsImpl(should_refresh_tabs: bool) usize {
    // A multi-step native switch exposes intermediate Spaces long enough for
    // CG and AX discovery. Adopt only after SkyLight confirms the destination.
    if (nativeSwitchPending()) return 0;
    const started_ns = nanoTimestamp();

    var buf: [256]shim.bw_window_info = undefined;
    var on_screen: OnScreenWindows = .{};
    const discovery = bw_discover_windows(&buf, if (should_refresh_tabs) &on_screen else null);
    const enumerated_ns = nanoTimestamp();
    if (discovery.truncated) {
        log.warn("window discovery truncated limit={d}; excess windows remain unmanaged", .{buf.len});
    }
    if (should_refresh_tabs) refreshTabGroupActiveTabsFromSnapshot(&on_screen);
    const tabs_refreshed_ns = nanoTimestamp();
    var observed_pids: [128]i32 = undefined;
    var observed_pid_count: usize = 0;
    var adopted_count: usize = 0;

    // Sort windows by current x-position so the BSP tree order matches
    // their on-screen placement. Without this, windows discovered in
    // arbitrary order get swapped to the opposite side on the first retile.
    const slice = buf[0..discovery.count];
    std.mem.sortUnstable(shim.bw_window_info, slice, {}, struct {
        fn lessThan(_: void, a: shim.bw_window_info, b: shim.bw_window_info) bool {
            return a.x < b.x;
        }
    }.lessThan);

    for (slice) |info| {
        std.debug.assert(info.pid > 0);

        const already_observed = std.mem.findScalar(
            i32,
            observed_pids[0..observed_pid_count],
            info.pid,
        ) != null;

        // Observe the owning app even if this specific window is not yet
        // manageable (for example AX role/subrole is still pending).
        if (!already_observed) {
            if (should_refresh_tabs) {
                ax_observer.observeAppDeferred(info.pid);
            } else {
                ax_observer.observeApp(info.pid);
            }
            if (observed_pid_count < observed_pids.len) {
                observed_pids[observed_pid_count] = info.pid;
                observed_pid_count += 1;
            }
        }

        if (g_store.get(info.wid) != null) continue;

        const frame: window_mod.Window.Frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h };
        const discovered_display = displayIdForFrame(frame);
        // Discovery only returns visible windows, so an unassigned window
        // belongs to the display's active native Space.
        const target_ws = resolveWorkspace(info.pid, discovered_display);
        // A landing must not wait on an app's AX server. The role poll applies
        // the same gate after the switch path is free to accept more input.
        if (should_refresh_tabs) {
            trackPendingRoleWindow(info.pid, info.wid, target_ws.ref);
            continue;
        }

        switch (windowRoleState(info.pid, info.wid)) {
            .reject => {
                untrackPendingRoleWindow(info.wid);
                continue;
            },
            .pending => {
                trackPendingRoleWindow(info.pid, info.wid, target_ws.ref);
                continue;
            },
            .ready => {
                untrackPendingRoleWindow(info.wid);
                // Degenerate discovery bounds mean the window is still
                // mid-construction. Defer for bounded re-evaluation instead
                // of storing a garbage frame that would be tiled or parked
                // at zero size. Deliberately not untracked first: tracking an
                // existing candidate preserves its remaining retry budget.
                if (frame.width <= 1 or frame.height <= 1) {
                    trackDeferredWindowCandidate(info.pid, info.wid, target_ws.ref);
                    log.info("discover: deferred pid={d} wid={d} unsettled bounds", .{ info.pid, info.wid });
                    continue;
                }
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
            .space = target_ws.ref,
        };

        adoptWindow(target_ws, win) catch |err| {
            log.err("discover: failed to adopt pid={d} wid={d}: {}", .{ info.pid, info.wid, err });
            continue;
        };
        adopted_count += 1;

        if (!spaceVisible(target_ws.ref)) {
            if (nativeSpacesEnabled()) {
                const target_display = target_ws.ref.display_id;
                if (!moveTabGroupToNativeSpace(info.wid, target_ws.ref)) {
                    log.warn("failed to move discovered wid={d} to native workspace {d} on display {d}", .{
                        info.wid,
                        target_ws.ref.workspace_id,
                        target_display,
                    });
                } else {
                    const source = (spaceForWorkspace(discovered_display, activeWorkspaceIdForDisplay(discovered_display)) orelse continue).ref;
                    trackPendingNativeWindowMove(info.wid, source, target_ws.ref);
                }
            } else {
                hideWindow(info.pid, info.wid);
            }
        }
    }

    // Ensure a focused window is set on the active workspace
    const active_ws = activeWorkspace();
    if (focusedWorkspaceWindow(active_ws) == null and active_ws.windows.items.len > 0) {
        recordWorkspaceFocus(active_ws, active_ws.windows.items[0]);
    }

    const completed_ns = nanoTimestamp();
    log.debug("[trace] window discovery candidates={} adopted={} enumerate_ms={} tabs_ms={} adopt_ms={}", .{
        discovery.count,
        adopted_count,
        @divTrunc(enumerated_ns - started_ns, std.time.ns_per_ms),
        @divTrunc(tabs_refreshed_ns - enumerated_ns, std.time.ns_per_ms),
        @divTrunc(completed_ns - tabs_refreshed_ns, std.time.ns_per_ms),
    });
    return adopted_count;
}

/// Snapshot of the window ids CG reports on screen, excluding desktop elements
/// and fully transparent windows.
///
/// One copy answers for every window in a detection pass; asking per window
/// costs a full list copy each time.
const OnScreenWindows = struct {
    wids: [512]u32 = undefined,
    count: usize = 0,
    truncated: bool = false,

    fn snapshot() OnScreenWindows {
        var self: OnScreenWindows = .{};

        const options: cg_extra.CGWindowListOption =
            cg_extra.kCGWindowListOptionOnScreenOnly | cg_extra.kCGWindowListExcludeDesktopElements;
        const list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse return self;
        defer c.CFRelease(@ptrCast(list));

        const total = c.CFArrayGetCount(list);
        std.debug.assert(total >= 0);
        var i: c.CFIndex = 0;
        while (i < total) : (i += 1) {
            const info_any = c.CFArrayGetValueAtIndex(list, i) orelse continue;
            const info: c.CFDictionaryRef = @ptrCast(info_any);
            const wid_ref_any = c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue;
            const wid_ref: c.CFNumberRef = @ptrCast(wid_ref_any);

            var wid: u32 = 0;
            if (c.CFNumberGetValue(wid_ref, c.kCFNumberSInt32Type, &wid) == 0) continue;
            if (!cgWindowInfoVisible(info)) continue;

            self.append(wid);
            if (self.truncated) break;
        }

        return self;
    }

    fn append(self: *OnScreenWindows, wid: u32) void {
        if (self.truncated) return;
        if (self.count < self.wids.len) {
            self.wids[self.count] = wid;
            self.count += 1;
            return;
        }

        self.truncated = true;
        if (g_on_screen_truncation_logged) return;
        log.warn("on-screen window snapshot truncated limit={d}", .{self.wids.len});
        g_on_screen_truncation_logged = true;
    }

    fn contains(self: *const OnScreenWindows, wid: u32) bool {
        return std.mem.findScalar(u32, self.wids[0..self.count], wid) != null;
    }
};

/// Snapshot the managed windows of `pid` that tabgroup.detect reasons about.
///
/// Every OS query the heuristics need happens here, so the decisions themselves
/// stay pure. `owns_workspace_slot` is the inverse of suppression: a group's
/// leader holds the slot, its other members exist only in the store.
fn tabCandidates(
    pid: i32,
    on_screen: *const OnScreenWindows,
    out: []tabgroup.detect.Candidate,
) BoundedSnapshotResult {
    std.debug.assert(pid > 0);

    var count: usize = 0;
    var truncated = false;
    var it = g_store.windows.valueIterator();
    while (it.next()) |win| {
        if (win.pid != pid) continue;
        if (count == out.len) {
            truncated = true;
            break;
        }

        const on_visible_workspace = spaceVisible(win.space);
        out[count] = .{
            .wid = win.wid,
            .pid = win.pid,
            .live_frame = liveWindowFrame(win.wid),
            .is_visible_on_screen = on_visible_workspace and on_screen.contains(win.wid),
            .owns_workspace_slot = !g_tab_groups.isSuppressed(win.wid),
        };
        count += 1;
    }
    return .{ .count = count, .truncated = truncated };
}

/// Snapshot the windows an application exposes in its AX window list.
fn appWindowSnapshot(
    pid: i32,
    on_screen: *const OnScreenWindows,
    out: []tabgroup.detect.AppWindow,
) BoundedSnapshotResult {
    std.debug.assert(pid > 0);

    var ax_wids: [128]u32 = undefined;
    const ax_snapshot = bw_get_app_window_ids(pid, &ax_wids);

    var count: usize = 0;
    var truncated = ax_snapshot.truncated;
    for (ax_wids[0..ax_snapshot.count]) |ax_wid| {
        if (count == out.len) {
            truncated = true;
            break;
        }
        out[count] = .{
            .wid = ax_wid,
            .live_frame = liveWindowFrame(ax_wid),
            .is_on_screen = on_screen.contains(ax_wid),
            .is_managed = g_store.get(ax_wid) != null,
            .tab_count = ax_mod.tabCount(pid, ax_wid),
        };
        log.debug("tab facts pid={d} wid={d} tabs={d} on_screen={} managed={}", .{
            pid,
            ax_wid,
            out[count].tab_count,
            out[count].is_on_screen,
            out[count].is_managed,
        });
        count += 1;
    }
    return .{ .count = count, .truncated = truncated };
}

fn addNewWindowManagedWithAssignment(pid: i32, wid: u32, assigned_space: state_mod.SpaceRef) bool {
    log.debug("addNewWindow: pid={d} wid={d}", .{ pid, wid });
    assigned_space.assertValid();
    if (g_store.get(wid) != null) {
        log.debug("addNewWindow: already in store, skipping", .{});
        return false;
    }
    if (nativeSwitchPending()) {
        log.debug("addNewWindow: deferred during native switch pid={d} wid={d}", .{ pid, wid });
        return false;
    }

    const on_screen = isVisibleOnScreen(wid);
    log.debug("addNewWindow: on_screen={}", .{on_screen});

    // New windows from Electron-family apps can be created before WindowServer
    // reports them as on-screen. Queue them for bounded re-evaluation rather
    // than dropping them on a one-shot check.
    if (!on_screen) {
        trackDeferredWindowCandidate(pid, wid, assigned_space);
        log.info("addNewWindow: deferred pid={d} wid={d} while off-screen", .{ pid, wid });
        return false;
    }
    var window_frame: window_mod.Window.Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const display_id = assigned_space.display_id;
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

    // On-screen but no settled SkyLight bounds yet means mid-construction.
    // Proceeding would store a garbage frame and, for an app assigned to a
    // hidden workspace, park a zero-size window. Defer for bounded
    // re-evaluation. Tracked before the untrack-defer below so it survives
    // this early return. Only when SkyLight is available: without it bounds
    // are always zero, and deferring would leave every new window unmanaged;
    // keep the legacy zero-frame path in that degraded mode.
    if (g_sky != null and (window_frame.width <= 1 or window_frame.height <= 1)) {
        trackDeferredWindowCandidate(pid, wid, assigned_space);
        log.info("addNewWindow: deferred pid={d} wid={d} unsettled bounds", .{ pid, wid });
        return false;
    }

    defer untrackDeferredWindowCandidate(wid);

    // Check if this new on-screen window replaces an existing same-PID window
    // that just went off-screen (i.e. a new tab was created and became active,
    // pushing the old tab to background). If so, form a tab group.
    if (tryFormTabGroupOnCreate(pid, wid)) return false;
    // An app_rules entry with .float = true floats every window of that app.
    const rule_float = blk: {
        if (g_config.app_rules.len == 0) break :blk false;
        var id_buf: [256]u8 = undefined;
        const bundle_id = config_mod.getAppBundleId(pid, &id_buf) orelse break :blk false;
        break :blk g_config.shouldFloatApp(bundle_id);
    };

    // Non-resizable windows that are undersized (≤500px in either dimension)
    // are floated instead of tiled. This catches transient splash screens and
    // updater dialogs (e.g. Discord Updater at 300x300) that have standard
    // AX roles but are not real application windows.
    const should_float = rule_float or blk: {
        if (window_frame.width > 500 and window_frame.height > 500) break :blk false;
        const ax_win = findAxWindow(pid, wid) orelse break :blk false;
        defer c.CFRelease(@ptrCast(ax_win));
        const ax = ensureAxStrings() orelse break :blk false;
        break :blk !axCanResize(ax_win, ax);
    };

    const current_space = g_state.space(assigned_space.key) orelse return false;
    const ws = g_workspaces.get(current_space.key) orelse return false;
    const mode: window_mod.WindowMode = if (should_float) .floating else .tiled;

    const win = window_mod.Window{
        .wid = wid,
        .pid = pid,
        .title = null,
        .frame = window_frame,
        .is_minimized = false,
        .mode = mode,
        .space = ws.ref,
    };

    adoptWindow(ws, win) catch |err| {
        log.err("addNewWindow: failed to adopt pid={d} wid={d}: {}", .{ pid, wid, err });
        return false;
    };
    recordWorkspaceFocus(ws, wid);

    // A native-space move must happen after the window exists in WindowServer
    // but before it can flash on the current workspace as managed content.
    if (!spaceVisible(ws.ref)) {
        if (nativeSpacesEnabled()) {
            const target_display = ws.ref.display_id;
            const source_display = inferDisplayIdForWindow(wid) orelse display_id;
            if (!moveTabGroupToNativeSpace(wid, ws.ref)) {
                log.warn("failed to move new wid={d} to native workspace {d} on display {d}", .{ wid, ws.ref.workspace_id, target_display });
            } else {
                const source = (spaceForWorkspace(source_display, activeWorkspaceIdForDisplay(source_display)) orelse return true).ref;
                trackPendingNativeWindowMove(wid, source, ws.ref);
            }
        } else {
            hideWindow(pid, wid);
        }
    }

    const float_reason = if (mode == .tiled) "tiled" else if (rule_float) "floated (app rule)" else "floated (undersized+non-resizable)";
    log.info("addNewWindow: {s} wid={d} on workspace {d}", .{ float_reason, wid, ws.ref.workspace_id });
    return true;
}

fn addNewWindowManaged(pid: i32, wid: u32) bool {
    // Prefer the window's actual on-screen position over the currently
    // focused display: a torn-off tab dropped on another monitor must land
    // on the workspace that owns the destination monitor, not on whichever
    // display happened to be focused when the window was created.
    const display_id = inferDisplayIdForWindow(wid) orelse focusedDisplayId();
    const ws = resolveWorkspaceForWindow(pid, wid, display_id);

    // A rule-pinned app's transient launch position is meaningless: place it
    // on the display that currently owns its assigned workspace, not wherever
    // it happened to launch.
    return addNewWindowManagedWithAssignment(pid, wid, ws.ref);
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
            const ws = resolveWorkspaceForWindow(pid, wid, display_id);
            trackPendingRoleWindow(pid, wid, ws.ref);
            trackDeferredWindowCandidate(pid, wid, ws.ref);
            log.debug("addNewWindow: role gate pending pid={d} wid={d}", .{ pid, wid });
        },
    }
}

/// Correct each tab group's recorded active tab against the window carrying its
/// app's tab bar.
///
/// macOS emits no notification of any kind when the user switches native tabs,
/// so the recorded active tab is stale from that moment, and everything keyed
/// off it — parking, restoring, retiling, focusing — would act on a window that
/// is not on screen. The bar moves with the selection, so read it rather than
/// track it.
///
/// The cheap gate is the point: a group whose recorded active tab is still on
/// screen cannot have changed selection, so the AX work only happens on an actual
/// switch. Only the active tab moves here; membership is decided elsewhere.
fn refreshTabGroupActiveTabs() void {
    if (g_tab_groups.groups.count() == 0) return;

    const on_screen = OnScreenWindows.snapshot();
    refreshTabGroupActiveTabsFromSnapshot(&on_screen);
}

fn refreshTabGroupActiveTabsFromSnapshot(on_screen: *const OnScreenWindows) void {
    if (g_tab_groups.groups.count() == 0) return;
    if (on_screen.truncated) return;

    const Move = struct { group_id: tabgroup.GroupId, selected: u32 };
    var moves: std.ArrayList(Move) = .empty;
    defer moves.deinit(g_allocator);
    moves.ensureTotalCapacity(g_allocator, g_tab_groups.groups.count()) catch |err| {
        log.err("tab refresh skipped: failed to allocate move snapshot: {}", .{err});
        return;
    };

    var it = g_tab_groups.groups.valueIterator();
    while (it.next()) |group| {
        const leader = g_store.get(group.leader_wid) orelse continue;
        // A parked group is off-screen on purpose and nothing acts on it until
        // its workspace is shown again.
        if (!spaceVisible(leader.space)) continue;
        if (on_screen.contains(group.active_wid)) continue;

        var app_windows: [128]tabgroup.detect.AppWindow = undefined;
        const app_snapshot = appWindowSnapshot(group.pid, on_screen, &app_windows);
        if (app_snapshot.truncated) {
            log.warn("tab refresh skipped: AX window snapshot truncated pid={d} limit={d}", .{ group.pid, app_windows.len });
            continue;
        }
        const selected = tabgroup.detect.selectedTabWindow(
            app_windows[0..app_snapshot.count],
            group.canonical_frame,
        ) orelse continue;
        if (selected == group.active_wid) continue;

        moves.appendAssumeCapacity(.{ .group_id = group.id, .selected = selected });
    }

    // Applied after the walk: adopting a tab writes to the store and to the
    // group's member list.
    for (moves.items) |move| {
        const group = g_tab_groups.groups.getPtr(move.group_id) orelse continue;
        const leader = g_store.get(group.leader_wid) orelse continue;

        // The user can select a tab Bobrwm has never seen: background tabs are
        // absent from AXWindows, so they are only discovered as they surface.
        if (g_store.get(move.selected) == null) {
            g_store.ensureUnusedCapacity(1) catch continue;
            const discovered: window_mod.Window = .{
                .wid = move.selected,
                .pid = group.pid,
                .title = null,
                .frame = group.canonical_frame,
                .is_minimized = false,
                .mode = leader.mode,
                .space = leader.space,
            };
            if (!adoptWindowIdentity(discovered)) continue;
            g_tab_groups.addMember(move.group_id, move.selected) catch {
                removeWindowIdentity(move.selected);
                continue;
            };
            g_store.putAssumeCapacity(discovered);
            seedObservedFrame(move.selected, group.canonical_frame);
        }

        log.debug("tab group {d} active tab {d} → {d} (tab bar)", .{
            move.group_id, group.active_wid, move.selected,
        });
        setTabGroupActive(move.selected);
    }
}

/// Check whether a window that just appeared — created, or focused while
/// unknown — is a native tab of an already-managed window, and if so hand it
/// the group's slot. Returns true when a group absorbed it, meaning the caller
/// must not manage it as its own window.
///
/// Gathers the OS facts, asks tabgroup.detect to decide, applies the outcome.
fn tryFormTabGroupOnCreate(pid: i32, new_wid: u32) bool {
    const new_frame = liveWindowFrame(new_wid) orelse return false;
    log.debug("tab detect: new wid={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
        new_wid, new_frame.x, new_frame.y, new_frame.width, new_frame.height,
    });

    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return false;
    var candidates: [128]tabgroup.detect.Candidate = undefined;
    const candidate_snapshot = tabCandidates(pid, &on_screen, &candidates);
    if (candidate_snapshot.truncated) {
        log.warn("tab detect skipped: managed candidate snapshot truncated pid={d} limit={d}", .{ pid, candidates.len });
        return false;
    }

    var app_windows: [128]tabgroup.detect.AppWindow = undefined;
    const app_snapshot = appWindowSnapshot(pid, &on_screen, &app_windows);
    if (app_snapshot.truncated) {
        log.warn("tab detect skipped: AX window snapshot truncated pid={d} limit={d}", .{ pid, app_windows.len });
        return false;
    }
    const has_tab_group = tabgroup.detect.appHasTabGroup(app_windows[0..app_snapshot.count]);

    // Collected before any removal: removeWindow mutates the workspace window
    // lists that the snapshot describes.
    var stale_wids: [128]u32 = undefined;
    const stale_count = tabgroup.detect.staleCandidates(pid, candidates[0..candidate_snapshot.count], &stale_wids);

    const formed = switch (tabgroup.detect.classifyNewWindow(pid, new_wid, new_frame, candidates[0..candidate_snapshot.count], has_tab_group)) {
        .standalone => blk: {
            log.debug("tab detect: wid={d} is standalone", .{new_wid});
            break :blk false;
        },
        .tab_of => |sibling_wid| joinTabGroup(pid, sibling_wid, new_wid, new_frame),
    };

    for (stale_wids[0..stale_count]) |stale_wid| {
        log.info("tab detect: removing stale window wid={d}", .{stale_wid});
        removeWindow(stale_wid);
    }

    return formed;
}

/// Add `new_wid` to `sibling_wid`'s tab group as the active tab.
///
/// The sibling keeps the group's workspace and layout slot; the new window is
/// stored but suppressed, so nothing tiles, parks or dims it directly. Members
/// inherit the leader's mode — a member claiming to be tiled under a floating
/// leader would be inserted into the BSP tree the moment it inherited the slot.
fn joinTabGroup(pid: i32, sibling_wid: u32, new_wid: u32, new_frame: window_mod.Window.Frame) bool {
    const sibling = g_store.get(sibling_wid) orelse return false;
    const ws = spaceForWindow(sibling) orelse return false;
    std.debug.assert(g_store.get(new_wid) == null);

    // Reserve the store first. Once the group mutation succeeds, publishing
    // the new member's Window record cannot fail.
    g_store.ensureUnusedCapacity(1) catch return false;
    const member: window_mod.Window = .{
        .wid = new_wid,
        .pid = pid,
        .title = null,
        .frame = new_frame,
        .is_minimized = false,
        .mode = sibling.mode,
        .space = sibling.space,
    };
    if (!adoptWindowIdentity(member)) return false;

    if (g_tab_groups.groupOf(sibling_wid)) |g| {
        g_tab_groups.addMember(g.id, new_wid) catch {
            removeWindowIdentity(new_wid);
            return false;
        };
    } else {
        _ = g_tab_groups.createGroupWithMember(pid, sibling_wid, new_wid, sibling.frame) catch {
            removeWindowIdentity(new_wid);
            return false;
        };
    }

    setTabGroupActive(new_wid);

    g_store.putAssumeCapacity(member);
    seedObservedFrame(new_wid, new_frame);

    const leader = g_tab_groups.resolveLeader(sibling_wid);
    recordWorkspaceFocus(ws, leader);
    log.info("tab group formed pid={d} leader={d} active={d} members={d}", .{
        pid,
        leader,
        new_wid,
        if (g_tab_groups.groupOf(leader)) |g| g.members.items.len else 1,
    });
    return true;
}

fn removeWindow(wid: u32) void {
    const win = g_store.get(wid) orelse return;
    g_animator.cancel(wid);
    g_geometry.forget(wid);
    ax_mod.invalidateWindow(wid);
    untrackPendingRoleWindow(wid);
    untrackDeferredWindowCandidate(wid);
    untrackPendingNativeWindowMove(wid);
    if (g_drag_preview.source_wid == wid or g_drag_preview.target_wid == wid) {
        clearDragPreview();
    }
    // Clean up tab group membership first
    const group_id_before: ?tabgroup.GroupId = if (g_tab_groups.groupOf(wid)) |g| g.id else null;
    removeWindowIdentity(wid);
    const removal = g_tab_groups.removeMember(wid);

    g_store.remove(wid);

    // removeMember guesses members[0] as the new active tab, but macOS
    // selects the adjacent tab when the active one closes. Align with the
    // app's actual focus so focus operations do not raise a background tab.
    if (group_id_before) |gid| {
        reconcileGroupActiveAfterRemoval(gid, win.pid);
        _ = syncWindowTabGroup(gid);
    }

    switch (removal) {
        // The removed window led a surviving tab group. It is the group's
        // only representative in workspace/layout state, so hand its slot to
        // the new leader instead of deleting it; otherwise the remaining tabs
        // become invisible to tiling and directional focus.
        .leader_changed => |new_leader| {
            transferLeaderSlot(win.space.key, wid, new_leader);
        },
        .none => {
            if (spaceForWindow(win)) |ws| {
                ws.removeWindow(wid);
            }
            removeFromTiling(win.space.key, wid);
        },
        // The group dissolved — restore the solo survivor to workspace and layout.
        .dissolved_solo => |solo_wid| {
            if (spaceForWindow(win)) |ws| {
                ws.removeWindow(wid);
            }
            removeFromTiling(win.space.key, wid);

            if (spaceForWindow(win)) |ws| {
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
                    if (windowIsTiled(solo_wid)) insertIntoTiling(win.space.key, solo_wid);
                }
            }
        },
    }

    if (spaceForWindow(win)) |space| _ = focusedWorkspaceWindow(space);
}

/// Align a surviving tab group's active tab with the window the app actually
/// focused after a member was removed. Best-effort: when the app has not yet
/// focused the adjacent tab (or AX reports nothing), the members[0] guess
/// stands until the next AXFocusedWindowChanged notification corrects it.
fn reconcileGroupActiveAfterRemoval(group_id: tabgroup.GroupId, pid: i32) void {
    std.debug.assert(group_id != 0);
    std.debug.assert(pid > 0);

    const g = g_tab_groups.groups.getPtr(group_id) orelse return;

    const focused_wid = bw_ax_get_focused_window(pid);
    const app_focused: ?u32 = if (focused_wid == 0) null else focused_wid;
    const active = tabgroup.detect.activeAfterRemoval(app_focused, g.members.items) orelse return;

    setTabGroupActive(active);
}

/// Hand a removed tab-group leader's workspace and layout slot to the new
/// leader, preserving the window's position in both. Falls back to plain
/// insertion when the old leader was not present (state drift).
fn transferLeaderSlot(space_key: state_mod.SpaceKey, old_leader: u32, new_leader: u32) void {
    std.debug.assert(old_leader != 0 and new_leader != 0);
    std.debug.assert(old_leader != new_leader);

    var replaced_in_workspace = false;
    if (g_workspaces.get(space_key)) |ws| {
        replaced_in_workspace = ws.replaceWindow(old_leader, new_leader);
        if (!replaced_in_workspace) {
            ws.addWindow(new_leader) catch {};
        }
    }

    var replaced_in_layout = false;
    const sp = tilingStatePtr(space_key);
    if (sp.*) |*st| {
        replaced_in_layout = st.replaceWid(old_leader, new_leader);
    }
    // A floating group never held a layout slot, so a missing replacement is
    // expected there and inserting would tile a window the user floated.
    const wants_layout = windowIsTiled(new_leader);
    if (!replaced_in_layout and wants_layout) {
        insertIntoTiling(space_key, new_leader);
    }

    if (replaced_in_workspace and (replaced_in_layout or !wants_layout)) {
        log.info("leader succession: wid={d} slot handed to wid={d} ws={d}", .{
            old_leader, new_leader, if (g_workspaces.get(space_key)) |ws| ws.ref.workspace_id else 0,
        });
    } else {
        log.warn("leader succession fallback: old={d} new={d} ws={d} in_workspace={} in_layout={}", .{
            old_leader, new_leader, if (g_workspaces.get(space_key)) |ws| ws.ref.workspace_id else 0, replaced_in_workspace, replaced_in_layout,
        });
    }
}

fn removeAppWindows(pid: i32) void {
    untrackPendingRoleWindowsForPid(pid);
    untrackDeferredWindowCandidatesForPid(pid);
    clearDragPreview();
    var total_removed: usize = 0;

    // Iterate in batches because removeWindow mutates the store. Rescan until
    // no matching entries remain; the old single 128-entry batch silently
    // leaked every window above the cap after an app termination.
    while (true) {
        var wids: [128]u32 = undefined;
        var count: usize = 0;

        var store_it = g_store.windows.iterator();
        while (store_it.next()) |entry| {
            if (entry.value_ptr.pid != pid) continue;
            if (count == wids.len) break;
            wids[count] = entry.key_ptr.*;
            count += 1;
        }

        if (count == 0) break;
        for (wids[0..count]) |wid| removeWindow(wid);
        total_removed += count;
    }

    if (total_removed > 128) {
        log.warn("app termination cleanup exceeded one batch pid={d} removed={d}", .{ pid, total_removed });
    }
}

fn isAppRunning(pid: i32) ?bool {
    std.debug.assert(pid > 0);
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return null;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    return app.value != null;
}

/// Recover app-termination notifications lost to event-ring overflow. Find one
/// stopped process at a time so store mutation never overlaps map iteration.
fn removeStoppedAppWindows() bool {
    var removed_any = false;
    while (true) {
        const stopped_pid: ?i32 = blk: {
            var it = g_store.windows.valueIterator();
            while (it.next()) |win| {
                const running = isAppRunning(win.pid) orelse {
                    log.warn("event overflow: cannot query running applications; skipping termination recovery", .{});
                    return removed_any;
                };
                if (!running) break :blk win.pid;
            }
            break :blk null;
        };
        const pid = stopped_pid orelse return removed_any;

        ax_mod.invalidateApp(pid);
        ax_observer.unobserveApp(pid);
        removeAppWindows(pid);
        removed_any = true;
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

    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        // Windows on hidden workspaces are intentionally parked off-screen.
        // AX role queries can be flaky for windows at corner positions,
        // so skip hidden workspaces to avoid false positives.
        if (!spaceVisible(ws.ref)) continue;

        for (ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;
            if (win.pid != pid) continue;

            var should_remove = false;
            var rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, wid, &rect) != 0) {
                should_remove = true;
                log.info("cleanup: removing wid={d} pid={d} reason=missing-windowserver", .{ wid, pid });
            } else if (!bw_should_manage_window(pid, wid)) {
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

/// Remove managed windows that are no longer physically on-screen, and hand a
/// slot held by a background tab back to the tab group it belongs to.
///
/// Some Electron apps (Discord) close-to-background without emitting AX
/// destroy/minimize notifications. This catches those ghost entries.
///
/// A background tab looks the same to WindowServer, so every suspect goes
/// through adoptWindowAsBackgroundTab, which keeps a window the app still lists,
/// adopts a genuine background tab into its group, and reaps the rest.
fn cleanupOffscreenManagedWindows() bool {
    const Suspect = struct { wid: u32, is_on_screen: bool };
    var suspects: [128]Suspect = undefined;
    var suspect_count: usize = 0;
    var truncated = false;

    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        // Windows on hidden workspaces are intentionally parked off-screen.
        if (!spaceVisible(ws.ref)) continue;

        for (ws.windows.items) |wid| {
            const win = g_store.get(wid) orelse continue;

            // Tab-group members can be intentionally off-screen when a sibling
            // tab is active; treating them as ghosts causes layout churn.
            if (g_tab_groups.groupOf(wid) != null) continue;

            // An on-screen window is healthy unless its app has stopped listing
            // it. A window whose native tab bar moved on still reports the
            // group's on-screen state for a while, and a slot left in its name
            // is never placed again: every geometry write for it is addressed to
            // a window that no longer exists, so the slot silently stops
            // responding to tiling, fullscreen and parking.
            const is_on_screen = bw_is_window_on_screen(wid);
            if (is_on_screen and appListsWindow(win.pid, wid)) continue;

            if (suspect_count < suspects.len) {
                suspects[suspect_count] = .{ .wid = wid, .is_on_screen = is_on_screen };
                suspect_count += 1;
            } else {
                truncated = true;
            }
        }
    }

    if (truncated) {
        log.warn("cleanup: offscreen batch truncated queued={d}", .{suspect_count});
    }

    // Mutations deferred to here — removeWindow/adoption modify workspace
    // window lists, which must not happen while iterating them above.
    var mutated = false;
    for (suspects[0..suspect_count]) |suspect| {
        const win = g_store.get(suspect.wid) orelse continue;

        switch (adoptWindowAsBackgroundTab(win)) {
            .adopt => mutated = true,
            .keep => {},
            .reap => {
                // Only the off-screen scan reaps. An on-screen window is not a
                // ghost however little its app admits to it, and dropping one
                // would unmanage a window the user is looking at.
                if (suspect.is_on_screen) {
                    log.debug("cleanup: keeping on-screen wid={d} pid={d} the app no longer lists", .{
                        win.wid, win.pid,
                    });
                    continue;
                }
                log.info("cleanup: removing wid={d} pid={d} reason=offscreen", .{ win.wid, win.pid });
                removeWindow(suspect.wid);
                mutated = true;
            },
        }
    }

    return mutated;
}

/// Whether an app still exposes `wid` in its AX window list. A window it has
/// dropped is either destroyed or a native background tab, which macOS omits
/// from that list entirely. An unreadable list counts as listing the window, so
/// an AX timeout on a busy app cannot make every one of its windows look
/// dropped at once.
fn appListsWindow(pid: i32, wid: u32) bool {
    std.debug.assert(pid > 0);
    std.debug.assert(wid != 0);

    var ax_wids: [128]u32 = undefined;
    const snapshot = bw_get_app_window_ids(pid, &ax_wids);
    if (snapshot.count == 0) return true;

    if (std.mem.findScalar(u32, ax_wids[0..snapshot.count], wid) != null) return true;
    if (snapshot.truncated) {
        log.warn("AX window membership inconclusive: snapshot truncated pid={d} wid={d} limit={d}", .{ pid, wid, ax_wids.len });
        return true;
    }
    return false;
}

/// Adopt a managed window as a member of an on-screen sibling's tab group.
/// Returns true when adoption happened.
///
/// Tab groups are inferred heuristically at window-creation / focus time;
/// when that inference is missed (event races, mid-animation bounds, events
/// dropped during workspace transitions) a background tab remains managed as
/// a standalone window holding a slot of its own. Reaping it would lose the tab,
/// and leaving it there gives one physical window two slots that fight over its
/// geometry.
///
/// A window qualifies when its app's AXWindows list has dropped it (which is
/// what a background tab looks like, and also what a destroyed ghost looks like)
/// and an on-screen managed sibling occupies the same frame — the active tab.
fn adoptWindowAsBackgroundTab(win: window_mod.Window) tabgroup.detect.OffscreenOutcomeKind {
    const frame = liveWindowFrame(win.wid);

    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return .keep;
    var app_windows: [128]tabgroup.detect.AppWindow = undefined;
    const app_snapshot = appWindowSnapshot(win.pid, &on_screen, &app_windows);
    if (app_snapshot.truncated) {
        log.warn("background-tab adoption skipped: AX window snapshot truncated pid={d} limit={d}", .{ win.pid, app_windows.len });
        return .keep;
    }
    const listed_in_app = blk: {
        for (app_windows[0..app_snapshot.count]) |app_window| {
            if (app_window.wid == win.wid) break :blk true;
        }
        break :blk false;
    };

    var candidates: [128]tabgroup.detect.Candidate = undefined;
    const candidate_snapshot = tabCandidates(win.pid, &on_screen, &candidates);
    if (candidate_snapshot.truncated) {
        log.warn("background-tab adoption skipped: candidate snapshot truncated pid={d} limit={d}", .{ win.pid, candidates.len });
        return .keep;
    }

    const has_tab_group = tabgroup.detect.appHasTabGroup(app_windows[0..app_snapshot.count]);
    const sibling_wid = switch (tabgroup.detect.classifyOffscreenManaged(
        win.wid,
        win.pid,
        frame,
        listed_in_app,
        has_tab_group,
        candidates[0..candidate_snapshot.count],
    )) {
        .keep => {
            log.debug("cleanup: keeping wid={d} pid={d}, the app still lists it", .{ win.wid, win.pid });
            return .keep;
        },
        .reap => return .reap,
        .adopt_into => |sibling_wid| sibling_wid,
    };

    const sibling = g_store.get(sibling_wid) orelse return .reap;
    if (!assignManagedWindowSpace(win.wid, sibling.space)) return .reap;

    if (g_tab_groups.groupOf(sibling_wid)) |group| {
        g_tab_groups.addMember(group.id, win.wid) catch {
            _ = assignManagedWindowSpace(win.wid, win.space);
            return .reap;
        };
    } else {
        _ = g_tab_groups.createGroupWithMember(win.pid, sibling_wid, win.wid, sibling.frame) catch {
            _ = assignManagedWindowSpace(win.wid, win.space);
            return .reap;
        };
    }
    setTabGroupActive(sibling_wid);

    // Members live only in the store; drop the standalone workspace/layout slot.
    if (spaceForWindow(win)) |ws| {
        ws.removeWindow(win.wid);
    }
    removeFromTiling(win.space.key, win.wid);

    var updated = win;
    if (frame) |f| updated.frame = f;
    updated.space = sibling.space;
    g_store.put(updated) catch {};

    log.info("cleanup: adopted wid={d} as background tab, leader={d} pid={d}", .{
        win.wid, g_tab_groups.resolveLeader(sibling_wid), win.pid,
    });
    return .adopt;
}

/// Adopt geometry from the exact window claimed by a real pointer drag while
/// mutating workspace/layout ownership through its native-tab group leader.
/// Returns true when display ownership changed and callers should retile.
fn updateDraggedWindowGeometry(dragged_wid: u32, frame: window_mod.Window.Frame) bool {
    if (g_pointer_drag_wid != dragged_wid) return false;
    const leader_wid = g_tab_groups.resolveLeader(dragged_wid);
    const leader = g_store.get(leader_wid) orelse return false;
    const next_display_id = displayIdForFrame(frame);
    if (next_display_id == leader.space.display_id) {
        adoptDraggedFrame(dragged_wid, leader_wid, frame);
        return false;
    }

    // Only reassign display while its workspace is visible. A notification
    // from a hidden window must not transfer ownership to the visible display.
    if (!spaceVisible(leader.space)) {
        adoptDraggedFrame(dragged_wid, leader_wid, frame);
        return false;
    }

    if (!reassignManagedWindowToDisplay(leader_wid, next_display_id)) return false;
    adoptDraggedFrame(dragged_wid, leader_wid, frame);

    if (g_store.get(leader_wid)) |updated| {
        observeWindowFocus(updated, .drag, null);
    }
    log.info("window moved to display dragged_wid={d} leader={d} display={d}", .{
        dragged_wid,
        leader_wid,
        next_display_id,
    });
    return true;
}

/// Keep the physical tab and its layout owner in sync after accepting a real
/// pointer sample. Other members are placed from the canonical frame by the
/// next retile; writing them during the drag would fight AppKit's tab motion.
fn adoptDraggedFrame(
    dragged_wid: u32,
    leader_wid: u32,
    frame: window_mod.Window.Frame,
) void {
    if (g_store.get(dragged_wid)) |dragged| {
        var updated = dragged;
        updated.frame = frame;
        if (updated.mode == .floating and !updated.is_fullscreen) updated.float_frame = frame;
        g_store.putAssumeCapacity(updated);
    }
    if (leader_wid != dragged_wid) {
        if (g_store.get(leader_wid)) |leader| {
            var updated = leader;
            updated.frame = frame;
            if (updated.mode == .floating and !updated.is_fullscreen) updated.float_frame = frame;
            g_store.putAssumeCapacity(updated);
        }
    }
    g_tab_groups.updateFrame(leader_wid, frame);
}

/// Apply ownership policy to geometry changed without an active pointer drag.
/// Layout-owned windows are repaired from their desired frame; floating
/// windows accept same-display application changes as their new restore frame.
fn handleExternalWindowGeometry(wid: u32, frame: window_mod.Window.Frame) void {
    var win = g_store.get(wid) orelse return;

    if (!spaceVisible(win.space)) {
        // Parked windows intentionally differ from their layout frame while
        // hidden. Never let their trailing AX echoes retile the visible
        // workspace or adopt the parked position as floating restore state.
        log.debug("geometry: ignored external sample for hidden wid={d}", .{wid});
        return;
    }

    if (win.mode == .tiled or win.is_fullscreen) {
        log.debug("geometry: external layout drift wid={d}; scheduling retile", .{wid});
        requestRetileDisplay(win.space.display_id);
        return;
    }

    const next_display_id = displayIdForFrame(frame);
    if (next_display_id != win.space.display_id) {
        // Workspace/display ownership changes only through the pointer-drag or
        // explicit move paths, which update every correlated data structure.
        // Accepting just the frame here would strand the floating window on a
        // display where its workspace is not visible.
        log.debug("geometry: external floating cross-display drift wid={d}; scheduling restore", .{wid});
        requestRetileDisplay(win.space.display_id);
        return;
    }

    win.frame = frame;
    win.float_frame = frame;
    g_store.put(win) catch |err| {
        log.warn("geometry: failed to store external floating frame wid={d}: {}", .{ wid, err });
    };
}

/// Lowest workspace id (1-based) not yet claimed as active on a display.
/// refreshDisplays caps the display count at workspace_count, so a caller that
/// has claimed at most one workspace per display always finds one.
fn firstUnclaimedWorkspace(claimed: []const bool) u8 {
    std.debug.assert(g_display_count <= g_workspaces.workspace_count);
    var id: u8 = 1;
    while (id <= g_workspaces.workspace_count) : (id += 1) {
        if (!claimed[id]) return id;
    }
    unreachable;
}

/// Reconciles workspace/display state after monitor topology changes.
///
/// Surviving displays keep their active workspace and layout roots, recalled by
/// stable UUID from a persistent table so a monitor absent across several
/// events (staggered wake) or unplugged and replugged still reclaims the
/// workspace it had — even if macOS hands it a new id. Every workspace stays
/// homed on a surviving display (re-homed to primary if its monitor vanished,
/// never left homeless), and each display gets a distinct active workspace.
/// Window display assignment is then derived from the workspace home, so
/// windows always follow their workspace — to the primary display when their
/// monitor vanished, and back when it returns and reclaims the workspace.
fn reconcileDisplayChange() void {
    // Display slots and ids are about to be rebuilt. Any delayed park keyed
    // by the old topology is invalid; parkHiddenWorkspaceWindows below
    // re-establishes visibility from the new authoritative mapping.
    g_pending_workspace_parks = @splat(null);

    // Snapshot present displays' active workspaces (by UUID) before the
    // topology changes, so a monitor that vanishes keeps its binding and
    // reclaims its workspace on return.
    rememberDisplayWorkspaces();

    const focused_uuid: ?[16]u8 = blk: {
        const slot = displayIndexById(focusedDisplayId()) orelse break :blk null;
        break :blk g_displays[slot].uuid;
    };

    // Snapshot every workspace home as a display UUID before the table is
    // rebuilt. Numeric ids cannot be trusted across a topology change: macOS
    // reuses CGDirectDisplayIDs, so a stale home id can name a different
    // monitor afterwards while still looking "present".
    var home_uuids: [workspace_mod.max_workspaces]?[16]u8 = @splat(null);
    for (g_workspaces.spaces[0..g_workspaces.space_count]) |space| {
        const slot = displayIndexById(space.ref.display_id) orelse continue;
        home_uuids[space.ref.workspace_id - 1] = g_displays[slot].uuid;
    }

    refreshDisplays();

    const restored_focused_display_id = displayIdForUuid(focused_uuid) orelse primaryDisplayId();
    if (nativeSpacesEnabled()) {
        const native_topology = captureNativeTopology() orelse {
            log.warn("display reconcile could not observe native Space topology", .{});
            return;
        };
        dispatchStateEvent(.{ .initialize_native_topology = native_topology });
        applySpaceCatalog(g_state.spaces);
        setFocusedDisplay(restored_focused_display_id);
        assertDisplayCoverage();
        refreshRolePolling();
        return;
    }

    // A monitor can return from sleep/unplug under a new CGDirectDisplayID.
    // Recall each surviving display by stable UUID and restore the workspace
    // it last had active. Numeric ids are deliberately never remapped
    // old-to-new: macOS reuses CGDirectDisplayIDs, so an absent monitor's
    // remembered id can be legitimately owned by a different present display,
    // and a global rewrite would move that display's workspaces and windows
    // wholesale. Stored display references are re-derived from workspace
    // homes below instead.

    // A workspace can be active on at most one display (assertDisplayCoverage).
    // Track which workspaces are already claimed so two displays that resolve
    // to the same one (two newly-appeared displays both defaulting to 1, or
    // stale memory pointing two monitors at the same workspace) get distinct
    // active workspaces.
    var active_claimed: [workspace_mod.max_workspaces + 1]bool = @splat(false);
    var workspace_topology: state_mod.WorkspaceTopology = .{};

    var catalog = g_state.spaces;
    for (g_displays[0..g_display_count]) |display| {
        var active_id: u8 = 1;
        if (display.uuid) |uuid| {
            if (recallDisplayMemory(uuid)) |mem| {
                active_id = mem.active_ws;
            }
        }
        if (active_claimed[active_id]) active_id = firstUnclaimedWorkspace(&active_claimed);
        active_claimed[active_id] = true;

        workspace_topology.addDisplay(.{
            .display_id = display.id,
            .active_workspace_id = active_id,
        });
        setVirtualSpaceDisplay(&catalog, active_id, display.id);
    }
    workspace_topology.focused_display_id = restored_focused_display_id;
    dispatchStateEvent(.{ .replace_workspace_topology = workspace_topology });

    const home = primaryDisplayId();

    // Re-home every non-active workspace by its UUID snapshot. Numeric-id
    // survival is not enough: after a topology change the old number can be
    // owned by a different physical monitor, which would silently migrate a
    // hidden workspace across displays. Follow the monitor if it is still
    // present (under any numeric id); park on primary if it vanished — a null
    // home would later let switchWorkspace drift the workspace onto whatever
    // display is focused, which is exactly the instability this guards
    // against. Active workspaces keep the home the recall loop above assigned.
    for (catalog.spaces[0..catalog.space_count]) |space_ref| {
        if (active_claimed[space_ref.workspace_id]) continue;
        const display_id = displayIdForUuid(home_uuids[space_ref.workspace_id - 1]) orelse home;
        setVirtualSpaceDisplay(&catalog, space_ref.workspace_id, display_id);
    }
    applySpaceCatalog(catalog);

    parkHiddenWorkspaceWindows();
    rememberDisplayWorkspaces();
    assertDisplayCoverage();
    refreshRolePolling();
}

/// Park every window of every hidden workspace so a topology change never
/// leaves windows at coordinates that no longer map to a live display.
///
/// Walks workspace membership lists rather than gating on raw CG on-screen
/// state: parked windows keep peek pixels visible, so CG counts them as
/// on-screen, while genuinely stranded windows can be fully off-screen — CG
/// presence distinguishes exactly the wrong ones. Windows already at their
/// park position are skipped by comparing stored frames. Targets are
/// collected before any hide because hiding can replace window ids
/// (native-tab fallback), which mutates the structures being iterated.
fn parkHiddenWorkspaceWindows() void {
    const ParkTarget = struct { pid: i32, wid: u32 };
    var targets: [256]ParkTarget = undefined;
    var target_count: usize = 0;

    outer: for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        const home = ws.ref.display_id;
        if (spaceVisible(ws.ref)) continue;

        const ctx = HideCtx.init(home);
        for (ws.windows.items) |wid| {
            // Workspace lists hold tab-group leaders, but the on-screen
            // window of a group is its active tab — which may not be the
            // leader. Park the active tab; suppressed members are already
            // off-screen behind it.
            const visible_wid = g_tab_groups.resolveActive(wid);
            const win = g_store.get(visible_wid) orelse continue;

            if (ctx.isParked(win.frame)) continue;

            if (target_count == targets.len) {
                log.warn("park: batch truncated at {d} windows", .{targets.len});
                break :outer;
            }
            targets[target_count] = .{ .pid = win.pid, .wid = visible_wid };
            target_count += 1;
        }
    }

    ax_mod.beginGeometryBatch();
    defer ax_mod.endGeometryBatch();
    for (targets[0..target_count]) |target| {
        hideWindow(target.pid, target.wid);
    }
}

/// Apply a target frame to a window, moving without a resize whenever the
/// stored size already matches so no AXSize write (and its flash/reflow)
/// fires. `two_pass` (fullscreen) always writes the full frame and re-issues
/// it once: the stored size records intent, not what macOS actually granted,
/// and clamped fullscreen sizes must be re-asserted even when the store
/// believes they already match. Returns whether the final AX write was
/// accepted so callers can avoid recording frames that were never applied.
fn applyWindowFrame(
    pid: i32,
    wid: u32,
    current: window_mod.Window.Frame,
    target: window_mod.Window.Frame,
    two_pass: bool,
    source: geometry_mod.IntentSource,
) bool {
    // Choose position-only from observed physical geometry, not the stored
    // target. External resize drift can leave the store already equal to the
    // desired layout while WindowServer has a different size; consulting the
    // store there would issue a move and permanently leave the bad size.
    const physical = if (g_geometry.get(wid)) |entry| entry.observed orelse current else current;
    if (!two_pass and physical.sizeApproxEqual(target, window_mod.Window.Frame.tolerance)) {
        return setWindowPositionTracked(pid, wid, target.x, target.y, source);
    }

    var ok = false;
    const passes: usize = if (two_pass) 2 else 1;
    for (0..passes) |_| {
        ok = ax_mod.setWindowFrame(pid, wid, target.x, target.y, target.width, target.height);
    }
    if (ok) recordFrameIntent(wid, target, source);
    return ok;
}

fn setWindowFrameTracked(
    pid: i32,
    wid: u32,
    target: window_mod.Window.Frame,
    source: geometry_mod.IntentSource,
) bool {
    const ok = ax_mod.setWindowFrame(pid, wid, target.x, target.y, target.width, target.height);
    if (ok) recordFrameIntent(wid, target, source);
    return ok;
}

fn setWindowPositionTracked(
    pid: i32,
    wid: u32,
    x: f64,
    y: f64,
    source: geometry_mod.IntentSource,
) bool {
    const ok = ax_mod.setWindowPosition(pid, wid, x, y);
    if (ok) {
        _ = g_geometry.recordPositionAccepted(wid, x, y, source, nanoTimestamp()) catch |err| {
            log.warn("geometry: failed to record position intent wid={d}: {}", .{ wid, err });
            return ok;
        };
        refreshRolePolling();
    }
    return ok;
}

fn recordFrameIntent(wid: u32, target: window_mod.Window.Frame, source: geometry_mod.IntentSource) void {
    _ = g_geometry.recordFrameAccepted(wid, target, source, nanoTimestamp()) catch |err| {
        log.warn("geometry: failed to record frame intent wid={d}: {}", .{ wid, err });
        return;
    };
    refreshRolePolling();
}

fn recordAnimationIntent(wid: u32, target: window_mod.Window.Frame) void {
    const animation_ns = @as(i128, @intCast(g_config.animation.duration_ms)) * std.time.ns_per_ms;
    const settle_ns = animation_ns + geometry_mod.default_settle_interval_ns;
    _ = g_geometry.recordFrameAcceptedFor(
        wid,
        target,
        .animation,
        nanoTimestamp(),
        settle_ns,
    ) catch |err| {
        log.warn("geometry: failed to record animation intent wid={d}: {}", .{ wid, err });
        return;
    };
    refreshRolePolling();
}

fn clampFrameToDisplay(frame: window_mod.Window.Frame, display: shim.bw_frame) window_mod.Window.Frame {
    const max_x = display.x + display.w - frame.width;
    const max_y = display.y + display.h - frame.height;
    return .{
        .x = std.math.clamp(frame.x, display.x, @max(display.x, max_x)),
        .y = std.math.clamp(frame.y, display.y, @max(display.y, max_y)),
        .width = frame.width,
        .height = frame.height,
    };
}

fn centeredFrame(width: f64, height: f64, display: shim.bw_frame) window_mod.Window.Frame {
    return .{
        .x = display.x + (display.w - width) / 2.0,
        .y = display.y + (display.h - height) / 2.0,
        .width = width,
        .height = height,
    };
}

/// Restore floating windows of a shown workspace to their remembered on-screen
/// position. Only acts on windows whose live bounds are currently off-screen —
/// parked on hide, or drifted by the app — so it never fights a placement the
/// user set while the workspace was visible. Centers as a fallback when no
/// position was captured.
///
/// Fullscreen floating windows are the exception: they own the whole content
/// frame, so they are placed regardless of where they currently sit. `content`
/// is the display frame inset by the outer gaps, matching what retileDisplay
/// hands tiled fullscreen windows.
fn restoreFloatingWindows(ws: *workspace_mod.Space, display: shim.bw_frame, content: window_mod.Window.Frame) void {
    const display_id = ws.ref.display_id;
    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();

    for (ws.windows.items) |leader_wid| {
        const leader = g_store.get(leader_wid) orelse continue;
        if (leader.mode != .floating) continue;
        if (!leader.space.key.eql(ws.ref.key)) {
            // Mirrors the tiled-path warning in retileDisplay: a floating
            // window whose stored display disagrees with its visible
            // workspace's display is never restored, so a parked one stays
            // parked with no other trace.
            log.warn("restore floating: skipping drifted window wid={d} display {d} (workspace {d} on display {d})", .{
                leader_wid, leader.space.display_id, ws.ref.workspace_id, display_id,
            });
            continue;
        }

        // The leader owns the workspace slot and the mode/fullscreen intent,
        // but the window park moved off-screen is the group's active tab.
        // Reading the leader's bounds here would leave a group whose active
        // tab is not its leader parked forever.
        const wid = g_tab_groups.resolveActive(leader_wid);
        var win = g_store.get(wid) orelse continue;

        // Mirrors the tiled fullscreen path in retileDisplay: gate on the
        // stored frame so our own AX write echoing back as a resize does not
        // re-enter here forever, but write two-pass because macOS clamps
        // fullscreen sizes mid-flight.
        if (leader.is_fullscreen) {
            if (!framesEqual(win.frame, content) or g_geometry.needsRepair(wid, content, nanoTimestamp())) {
                if (applyWindowFrame(win.pid, wid, win.frame, content, true, .floating_restore)) {
                    win.frame = content;
                    g_store.put(win) catch {};
                }
                log.debug("fullscreen floating wid={d} → x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
                    wid, content.x, content.y, content.width, content.height,
                });
            }
            applyFrameToTabGroup(leader_wid, content);
            continue;
        }

        var rect: skylight.CGRect = undefined;
        if (sky.getWindowBounds(conn, wid, &rect) != 0) continue;

        const center_x = rect.origin.x + rect.size.width / 2.0;
        const center_y = rect.origin.y + rect.size.height / 2.0;
        const on_x = center_x >= display.x and center_x <= display.x + display.w;
        const on_y = center_y >= display.y and center_y <= display.y + display.h;
        if (on_x and on_y) continue;

        const target = if (win.float_frame) |f|
            clampFrameToDisplay(f, display)
        else
            centeredFrame(rect.size.width, rect.size.height, display);

        if (!setWindowFrameTracked(win.pid, wid, target, .floating_restore)) {
            log.warn("restore floating: frame write rejected wid={d}", .{wid});
            continue;
        }
        win.frame = target;
        g_store.put(win) catch {};
        applyFrameToTabGroup(leader_wid, target);
        log.debug("restore floating wid={d} → x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
            wid, target.x, target.y, target.width, target.height,
        });
    }
}

/// Push a leader's frame onto every member of its tab group. Members hold no
/// workspace or layout slot, so nothing else ever places them, and a member
/// left at a stale frame surfaces at the wrong geometry the moment the app
/// makes it the active tab. Members already at the frame — normally whichever
/// one the caller just wrote — are skipped. No-op when wid does not lead a
/// group.
fn applyFrameToTabGroup(leader_wid: u32, frame: window_mod.Window.Frame) void {
    const g = g_tab_groups.groupOfMut(leader_wid) orelse return;
    if (g.leader_wid != leader_wid) return;

    g.canonical_frame = frame;
    for (g.members.items) |member_wid| {
        const member = g_store.get(member_wid) orelse continue;
        if (framesEqual(member.frame, frame) and !g_geometry.needsRepair(member_wid, frame, nanoTimestamp())) continue;

        if (applyWindowFrame(member.pid, member_wid, member.frame, frame, false, .tab_sync)) {
            var updated = member;
            updated.frame = frame;
            g_store.put(updated) catch {};
        }
    }
}

fn retileDisplay(display_id: u32) void {
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    const ws = spaceForWorkspace(display_id, ws_id) orelse return;
    const display_slot = displayIndexById(display_id) orelse return;
    const display = g_displays[display_slot].visible;

    ax_mod.beginGeometryBatch();
    defer ax_mod.endGeometryBatch();

    const outer = g_config.gaps.outer;
    const frame = window_mod.Window.Frame{
        .x = display.x + @as(f64, @floatFromInt(outer.left)),
        .y = display.y + @as(f64, @floatFromInt(outer.top)),
        .width = display.w - @as(f64, @floatFromInt(@as(u32, outer.left) + @as(u32, outer.right))),
        .height = display.h - @as(f64, @floatFromInt(@as(u32, outer.top) + @as(u32, outer.bottom))),
    };

    restoreFloatingWindows(ws, display, frame);

    const st = tilingStatePtr(ws.ref.key).* orelse return;

    const window_count = st.windowCount();
    std.debug.assert(window_count > 0);

    g_layout_entries.clearRetainingCapacity();
    g_layout_entries.ensureTotalCapacity(g_allocator, window_count) catch {
        log.err("retile: layout buffer reserve failed display={d} windows={d}", .{ display_id, window_count });
        return;
    };
    st.computeLayout(frame, @floatFromInt(g_config.gaps.inner), &g_layout_entries);
    std.debug.assert(g_layout_entries.items.len == window_count);

    for (g_layout_entries.items) |entry| {
        const win = g_store.get(entry.wid) orelse continue;

        // Stored display/workspace metadata disagreeing with the tiling tree
        // means some transition (topology change, window move) is mid-flight
        // or a bookkeeping bug slipped through. Do not "heal" the store here:
        // rewriting workspace_id/display_id alone would desync it from
        // workspace membership lists, focus history, and tab assignments,
        // which only the full move/reconcile paths update together. Skip and
        // surface it; reconcileDisplayChange re-derives window display ids
        // from workspace homes, which repairs the topology-change case.
        if (!win.space.key.eql(ws.ref.key)) {
            log.warn("retile: skipping drifted window wid={d} display {d} (tree {d}) workspace {d} (tree {d})", .{
                entry.wid, win.space.display_id, display_id, win.space.workspace_id, ws_id,
            });
            continue;
        }

        // The leaf is the tab-group leader, which owns the slot and carries the
        // mode and fullscreen intent, but the pixels belong to the group's
        // active tab — and a leader whose group made another tab active is a
        // background tab, which macOS drops from AXWindows entirely, so a write
        // addressed to it reaches nothing. Place the tab that is showing, as
        // restoreFloatingWindows does; applyFrameToTabGroup carries the frame
        // to the rest of the group afterwards.
        const visible_wid = g_tab_groups.resolveActive(entry.wid);
        var visible = g_store.get(visible_wid) orelse continue;

        // Fullscreen windows fill the outer-gap-inset frame, skipping BSP splits and inner gaps
        const target_frame = if (win.is_fullscreen) frame else entry.frame;

        if (!framesEqual(visible.frame, target_frame) or
            g_geometry.needsRepair(visible_wid, target_frame, nanoTimestamp()))
        {
            // Fullscreen windows are never animated: macOS clamps their size
            // mid-flight and they need the two-pass set below to land on the
            // exact display frame.
            var applied = true;
            if (g_config.animation.enabled and !win.is_fullscreen) {
                applied = g_animator.animate(visible.pid, visible_wid, visible.frame, target_frame);
                if (applied) recordAnimationIntent(visible_wid, target_frame);
                ensureAnimatorTimer();
            } else {
                // The window may have entered fullscreen mid-animation; stop
                // the in-flight animation so it doesn't fight the placement.
                g_animator.cancel(visible_wid);
                applied = applyWindowFrame(visible.pid, visible_wid, visible.frame, target_frame, win.is_fullscreen, .layout);
            }

            // Record the target only when the write was accepted (animation
            // converges on the target on its own). Recording a rejected frame
            // would make the next retile's framesEqual check skip the repair.
            if (applied) {
                visible.frame = target_frame;
                g_store.put(visible) catch {};
            }
        }

        applyFrameToTabGroup(entry.wid, target_frame);
    }
}

fn retileAllDisplays() void {
    for (g_displays[0..g_display_count]) |display| {
        retileDisplay(display.id);
    }
}

fn observeDiscoveredApps() void {
    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                ax_observer.observeApp(win.pid);
            }
        }
    }
}

// Exit recovery — restore all hidden windows to screen center

fn restoreAllWindows() void {
    // Undo any inactive-window dimming so windows are left undimmed.
    dim.resetAll();

    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (spaceVisible(win.space)) continue;
                const display_slot = displayIndexById(win.space.display_id) orelse continue;
                const display = g_displays[display_slot].visible;
                // Place at screen center with stored size (or sensible default)
                const w = if (win.frame.width > 1) win.frame.width else display.w * 0.5;
                const h = if (win.frame.height > 1) win.frame.height else display.h * 0.5;
                const x = display.x + (display.w - w) / 2.0;
                const y = display.y + (display.h - h) / 2.0;
                const target: window_mod.Window.Frame = .{
                    .x = x,
                    .y = y,
                    .width = w,
                    .height = h,
                };
                _ = setWindowFrameTracked(win.pid, wid, target, .exit_restore);
            }
        }
    }
}

// Tab group reconciliation

/// Called on kAXFocusedWindowChangedNotification — detects tab switches and
/// forms/updates tab groups so only the active tab occupies a layout slot.
fn reconcileFocusedWindow(pid: i32, focused_wid: u32) void {
    std.debug.assert(pid > 0);
    std.debug.assert(focused_wid != 0);

    log.debug("reconcile: pid={d} focused_wid={d}", .{ pid, focused_wid });

    if (nativeSwitchPending() and g_store.get(focused_wid) == null) {
        log.debug("reconcile: deferred unknown wid={d} during native switch", .{focused_wid});
        return;
    }

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

    // Case 3: focused wid is unknown — a new tab becoming active, or a new
    // window. Same decision as the creation path, so it runs the same code.
    log.debug("reconcile case 3: unknown wid={d}", .{focused_wid});

    if (tryFormTabGroupOnCreate(pid, focused_wid)) {
        _ = syncFocusStateForWindowId(focused_wid, .ax);
        return;
    }

    addNewWindow(pid, focused_wid);
    retile();
}

/// Called on window_moved / window_resized — detects tab drag-out.
/// When a suppressed tab's bounds diverge from its group's canonical frame,
/// promote it to a standalone tiled window.
fn checkTabDragOut(_: i32, wid: u32) bool {
    const g = g_tab_groups.groupOfMut(wid) orelse return false;
    if (g.active_wid == wid) return false; // only check suppressed members
    const group_id = g.id;

    const frame = liveWindowFrame(wid) orelse return false;
    switch (tabgroup.detect.classifyMember(frame, g.canonical_frame, isVisibleOnScreen(wid))) {
        .keep => return false,
        .promote_to_standalone => {},
    }

    log.info("tab drag-out detected: wid={d} promoted to standalone", .{wid});
    const removal = g_tab_groups.removeMember(wid);
    dissolveWindowTabGroup(wid);
    _ = syncWindowTabGroup(group_id);

    // Update stored frame and add to workspace + layout
    if (g_store.get(wid)) |win| {
        var updated = win;
        updated.frame = frame;
        g_store.put(updated) catch return false;
    }

    const win = g_store.get(wid) orelse return false;
    const ws = spaceForWindow(win) orelse return false;

    // If the dragged-out tab led the group, its existing workspace/layout
    // slot belongs to the surviving group — hand it to the new leader before
    // re-adding wid as a standalone window.
    switch (removal) {
        .leader_changed => |new_leader| transferLeaderSlot(win.space.key, wid, new_leader),
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
        ws.addWindow(wid) catch return false;
        insertIntoTiling(win.space.key, wid);
    }
    recordWorkspaceFocus(ws, wid);

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
                insertIntoTiling(win.space.key, solo_wid);
            }
        },
        .none, .leader_changed => {},
    }

    return true;
}

// Workspace resolution (config-based app → workspace mapping)

/// Return the workspace a window should be placed on, checking
/// config workspace_assignments by bundle ID before falling back
/// to the active workspace for the target display.
fn configuredWorkspace(pid: i32, display_id: u32) ?*workspace_mod.Space {
    if (g_config.hasAppWorkspaceRules()) {
        var id_buf: [256]u8 = undefined;
        if (config_mod.getAppBundleId(pid, &id_buf)) |bundle_id| {
            if (g_config.workspaceForApp(bundle_id)) |ws_id| {
                return spaceForCommand(display_id, ws_id);
            }
        }
    }
    return null;
}

fn resolveWorkspace(pid: i32, display_id: u32) *workspace_mod.Space {
    if (configuredWorkspace(pid, display_id)) |ws| return ws;
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    return spaceForWorkspace(display_id, ws_id) orelse unreachable;
}

fn resolveWorkspaceForWindow(pid: i32, wid: u32, display_id: u32) *workspace_mod.Space {
    if (configuredWorkspace(pid, display_id)) |ws| return ws;
    if (nativeSpacesEnabled()) {
        if (g_sky.?.nativeSpaceIdForWindow(wid, display_id)) |space_id| {
            if (g_workspaces.get(.{ .native = space_id })) |ws| return ws;
        }
    }
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    return spaceForWorkspace(display_id, ws_id) orelse unreachable;
}

// Workspace switching

fn frameCenterOnDisplay(frame: window_mod.Window.Frame, display: shim.bw_frame) bool {
    if (frame.width <= 0 or frame.height <= 0) return false;
    const center_x = frame.x + frame.width / 2.0;
    const center_y = frame.y + frame.height / 2.0;
    return center_x >= display.x and center_x <= display.x + display.w and
        center_y >= display.y and center_y <= display.y + display.h;
}

/// Confirm that every non-minimized incoming window physically covers its
/// assigned target. AX returning success only means the app accepted the
/// request; WindowServer can expose the parked frame for several more
/// milliseconds. An empty workspace is immediately ready because revealing
/// the wallpaper is the requested result.
fn workspaceRevealSettled(ws: *const workspace_mod.Space) bool {
    const display_id = ws.ref.display_id;
    const display_slot = displayIndexById(display_id) orelse return false;
    const display = g_displays[display_slot].visible;
    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return false;

    for (ws.windows.items) |leader_wid| {
        const visible_wid = g_tab_groups.resolveActive(leader_wid);
        const win = g_store.get(visible_wid) orelse return false;
        if (win.is_minimized) continue;
        if (!win.space.key.eql(ws.ref.key) or win.space.display_id != display_id) return false;
        if (!frameCenterOnDisplay(win.frame, display)) return false;

        // CG can retain layer-0 Electron windows (and stale native-tab IDs)
        // with plausible bounds after they stop contributing pixels.
        if (!on_screen.contains(visible_wid)) return false;
        const actual = liveWindowFrame(visible_wid) orelse return false;
        if (!workspace_mod.frameCoversTarget(actual, win.frame)) return false;
    }
    return true;
}

fn waitForWorkspaceReveal(ws: *const workspace_mod.Space) bool {
    var waited_us: u32 = 0;
    while (waited_us < workspace_reveal_wait_max_us) : (waited_us += workspace_reveal_poll_interval_us) {
        if (workspaceRevealSettled(ws)) return true;
        _ = c.usleep(workspace_reveal_poll_interval_us);
    }
    return workspaceRevealSettled(ws);
}

/// Park immediately once the incoming pixels are visible. Slow AX servers use
/// the role-poll path, which leaves the old workspace covering the display
/// instead of exposing the wallpaper while the reveal is still in flight.
fn parkOutgoingWhenRevealed(
    outgoing_ws: *workspace_mod.Space,
    target_ws: *const workspace_mod.Space,
) void {
    const display_id = target_ws.ref.display_id;
    const display_slot = displayIndexById(display_id) orelse return;
    const prior = g_pending_workspace_parks[display_slot];

    if (waitForWorkspaceReveal(target_ws)) {
        g_pending_workspace_parks[display_slot] = null;
        parkOutgoingWorkspace(outgoing_ws, target_ws.ref);
        if (prior) |pending| {
            if (!pending.outgoing.key.eql(outgoing_ws.ref.key) and
                !pending.outgoing.key.eql(target_ws.ref.key))
            {
                if (g_workspaces.get(pending.outgoing.key)) |prior_outgoing| {
                    parkOutgoingWorkspace(prior_outgoing, target_ws.ref);
                }
            }
        }
        refreshRolePolling();
        return;
    }

    // A prior deferred outgoing workspace still covers this display. Keep it
    // as the cover and park the logical current workspace now, otherwise a
    // rapid A → B → C sequence would leak both A and B over C.
    const cover: state_mod.SpaceRef = if (prior) |pending| blk: {
        if (!pending.outgoing.key.eql(target_ws.ref.key) and
            !pending.outgoing.key.eql(outgoing_ws.ref.key))
        {
            parkOutgoingWorkspace(outgoing_ws, target_ws.ref);
            break :blk pending.outgoing;
        }
        break :blk outgoing_ws.ref;
    } else outgoing_ws.ref;

    g_pending_workspace_parks[display_slot] = .{
        .outgoing = cover,
        .target = target_ws.ref,
        .deadline_at_s = c.CFAbsoluteTimeGetCurrent() + workspace_reveal_deferred_timeout_s,
    };
    log.debug("workspace switch deferring outgoing park current_workspace={d} target_workspace={d} display={d}", .{
        cover.workspace_id,
        target_ws.ref.workspace_id,
        display_id,
    });
    refreshRolePolling();
}

fn hasPendingWorkspaceParks() bool {
    for (g_pending_workspace_parks) |pending| {
        if (pending != null) return true;
    }
    return false;
}

fn processPendingWorkspaceParks() void {
    var changed = false;
    for (0..g_display_count) |display_slot| {
        const pending = g_pending_workspace_parks[display_slot] orelse continue;
        const display_id = g_displays[display_slot].id;
        const active_workspace_id = activeWorkspaceIdForDisplay(display_id);
        const active = g_state.spaceForWorkspace(display_id, active_workspace_id) orelse continue;
        if (!active.key.eql(pending.target.key)) {
            g_pending_workspace_parks[display_slot] = null;
            changed = true;
            if (!pending.outgoing.key.eql(active.key)) {
                if (g_workspaces.get(pending.outgoing.key)) |outgoing_ws| {
                    parkOutgoingWorkspace(outgoing_ws, active);
                }
            }
            continue;
        }

        const target_ws = g_workspaces.get(pending.target.key) orelse {
            g_pending_workspace_parks[display_slot] = null;
            changed = true;
            continue;
        };
        const reveal_settled = workspaceRevealSettled(target_ws);
        const timed_out = c.CFAbsoluteTimeGetCurrent() >= pending.deadline_at_s;
        if (!reveal_settled and !timed_out) continue;

        g_pending_workspace_parks[display_slot] = null;
        changed = true;
        if (!reveal_settled) {
            log.warn("workspace switch reveal timed out current_workspace={d} target_workspace={d} display={d}; parking outgoing workspace", .{
                pending.outgoing.workspace_id,
                pending.target.workspace_id,
                pending.target.display_id,
            });
        }
        if (g_workspaces.get(pending.outgoing.key)) |outgoing_ws| {
            parkOutgoingWorkspace(outgoing_ws, pending.target);
        }
    }
    if (changed) refreshRolePolling();
}

fn switchWorkspace(target_id: u8) void {
    if (nativeSpacesEnabled()) {
        const target_ws = spaceForCommand(focusedDisplayId(), target_id) orelse return;
        if (spaceVisible(target_ws.ref)) {
            startWorkspaceTransition(.switch_workspace, target_ws.ref);
            setFocusedDisplay(target_ws.ref.display_id);
            updateStatusBar();
            focusWorkspaceWindow(target_ws);
            return;
        }
        dispatchStateEvent(.{ .request_native_switch = .{
            .target = target_ws.ref,
            .at_ms = nativeStateNowMs(),
        } });
        return;
    }

    const target_ws = spaceForCommand(focusedDisplayId(), target_id) orelse return;

    // If target is already visible on some display, just focus there.
    if (spaceVisible(target_ws.ref)) {
        const target_display = target_ws.ref.display_id;
        log.debug("workspace switch target already visible workspace={d} display={d} windows={d}", .{
            target_id,
            target_display,
            target_ws.windows.items.len,
        });
        startWorkspaceTransition(.switch_workspace, target_ws.ref);
        setFocusedDisplay(target_display);
        updateStatusBar();
        focusWorkspaceWindow(target_ws);
        return;
    }

    // Hidden workspace — show it on its assigned display.
    const target_display = target_ws.ref.display_id;
    if (displayIndexById(target_display) == null) return;
    const current_id = activeWorkspaceIdForDisplay(target_display);
    if (target_id == current_id) return;

    const old_ws = spaceForWorkspace(target_display, current_id) orelse return;
    log.debug("workspace switch preparing current_workspace={d} target_workspace={d} display={d} current_windows={d} target_windows={d}", .{
        current_id,
        target_id,
        target_display,
        old_ws.windows.items.len,
        target_ws.windows.items.len,
    });

    // Activate target; old workspace keeps its display_id (just hidden).
    dispatchStateEvent(.{ .activate_workspace = .{
        .display_id = target_display,
        .workspace_id = target_id,
    } });
    for (target_ws.windows.items) |wid| {
        if (!assignManagedWindowSpace(wid, target_ws.ref)) continue;
        updateTabGroupAssignment(wid, target_ws.ref);
    }
    log.debug("workspace switch activated target workspace={d} display={d} windows={d}", .{
        target_id,
        target_display,
        target_ws.windows.items.len,
    });

    assertDisplayCoverage();

    startWorkspaceTransition(.switch_workspace, target_ws.ref);
    ax_mod.beginGeometryBatch();
    defer ax_mod.endGeometryBatch();

    retile();
    // `retile` normally batches work until the event drain completes. A
    // workspace switch cannot use that latency boundary: parking the outgoing
    // windows before the incoming AX writes land exposes the wallpaper. Flush
    // the reveal now, while the outgoing workspace still covers the display.
    flushRetileRequests();
    setFocusedDisplay(target_display);
    updateStatusBar();

    focusWorkspaceWindow(target_ws);
    parkOutgoingWhenRevealed(old_ws, target_ws);
}

/// Park every window the outgoing workspace has on `display_id`.
///
/// Runs last, after the incoming workspace has been placed and focused, so the
/// outgoing windows keep covering the display until there is something to
/// replace them. Parking first exposes the desktop for as long as the outgoing
/// AX writes take — every one a synchronous round-trip into an app — which is
/// what the switch flash was.
///
/// Safe to defer: the workspace transition stays active until its settle
/// deadline even once focus lands, so the synthetic AX move events these writes
/// generate are still suppressed.
fn parkOutgoingWorkspace(ws: *workspace_mod.Space, target: state_mod.SpaceRef) void {
    const display_id = target.display_id;
    const hctx = HideCtx.init(display_id);

    var hidden_count: usize = 0;
    for (ws.windows.items) |wid| {
        const visible_wid = g_tab_groups.resolveActive(wid);
        const hide_wid = if (g_store.get(visible_wid) != null) visible_wid else wid;
        const win = g_store.get(hide_wid) orelse continue;
        if (!win.space.key.eql(ws.ref.key)) continue;

        if (g_tab_groups.groupOf(wid)) |group| {
            log.debug("workspace switch hiding window workspace={d} layout_wid={d} hide_wid={d} group_leader={d} group_active={d} members={d}", .{
                ws.ref.workspace_id,
                wid,
                hide_wid,
                group.leader_wid,
                group.active_wid,
                group.members.items.len,
            });
        } else {
            log.debug("workspace switch hiding window workspace={d} layout_wid={d} hide_wid={d} group=none", .{
                ws.ref.workspace_id,
                wid,
                hide_wid,
            });
        }

        g_animator.finish(hide_wid);
        hctx.hide(win.pid, hide_wid);
        hidden_count += 1;
    }

    var hidden_pending_count: usize = 0;
    var pending_it = g_pending_role_windows.iterator();
    while (pending_it.next()) |entry| {
        const pending = entry.value_ptr.*;
        if (!pending.space.key.eql(ws.ref.key)) continue;
        g_animator.finish(entry.key_ptr.*);
        hctx.hide(pending.pid, entry.key_ptr.*);
        hidden_pending_count += 1;
    }

    log.debug("workspace switch hid current windows current_workspace={d} target_workspace={d} display={d} hidden={d} hidden_pending={d}", .{
        ws.ref.workspace_id,
        target.workspace_id,
        display_id,
        hidden_count,
        hidden_pending_count,
    });
}

/// Focus the remembered (or first available) window on a workspace.
fn focusWorkspaceWindow(ws: *workspace_mod.Space) void {
    var focus_wid = focusedWorkspaceWindow(ws);
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
                    ws.ref.workspace_id,
                    fwid,
                    actual_wid,
                    group.leader_wid,
                    group.active_wid,
                    group.members.items.len,
                });
            } else {
                log.debug("workspace focus target workspace={d} focused_wid={d} actual_wid={d} group=none", .{
                    ws.ref.workspace_id,
                    fwid,
                    actual_wid,
                });
            }
            _ = bw_ax_focus_window(win.pid, actual_wid);
            recordWorkspaceFocus(ws, fwid);
            observeWindowFocus(win, .keyboard, null);
        }
    }

    if (focus_wid == null) {
        log.debug("workspace focus target workspace={d} focused_wid=0 actual_wid=0 reason=empty", .{ws.ref.workspace_id});
        if (g_state.workspace_transition) |transition| {
            if (transition.target.key.eql(ws.ref.key)) {
                markWorkspaceTransitionComplete(.empty_workspace);
            }
        }
    }

    if (g_state.isWorkspaceTransitionActive()) {
        clearPendingFocusQueue();
    }
}

fn updateTabGroupAssignment(leader_wid: u32, space: state_mod.SpaceRef) void {
    std.debug.assert(leader_wid != 0);
    space.assertValid();

    const group = g_tab_groups.groupOf(leader_wid) orelse return;
    if (group.leader_wid != leader_wid) return;

    for (group.members.items) |member_wid| {
        if (member_wid == leader_wid) continue;
        _ = assignManagedWindowSpace(member_wid, space);
    }
}

fn moveWindowToWorkspace(target_id: u8) void {
    const ctx = actionContext() orelse {
        log.debug("move workspace skipped: no visible AX-focused managed window", .{});
        return;
    };
    const wid = ctx.focused_wid;
    var updated = ctx.focused_win;
    const ws = ctx.workspace;
    if (target_id == ws.ref.workspace_id and
        (!nativeSpacesEnabled() or updated.space.display_id == focusedDisplayId())) return;

    log.debug("move workspace target wid={d} pid={d} source={d} target={d}", .{ wid, updated.pid, ws.ref.workspace_id, target_id });

    const target_ws = spaceForCommand(updated.space.display_id, target_id) orelse return;
    // Prepare the destination completely before removing the source slot.
    // After these fallible steps, the move commits without allocation.
    target_ws.ensureUnusedWindowCapacity(1) catch return;
    if (updated.mode == .tiled) {
        tryInsertIntoTiling(target_ws.ref.key, wid) catch |err| {
            log.err("failed to move wid={d} to workspace {d}: {}", .{ wid, target_id, err });
            return;
        };
    }
    const target_display = target_ws.ref.display_id;
    if (nativeSpacesEnabled() and !moveTabGroupToNativeSpace(wid, target_ws.ref)) {
        if (updated.mode == .tiled) removeFromTiling(target_ws.ref.key, wid);
        log.warn("failed to move wid={d} to native workspace {d} on display {d}", .{ wid, target_id, target_display });
        return;
    }
    if (!assignManagedWindowSpace(wid, target_ws.ref)) {
        if (updated.mode == .tiled) removeFromTiling(target_ws.ref.key, wid);
        return;
    }
    target_ws.addWindowAssumeCapacity(wid);

    ws.removeWindow(wid);
    removeFromTiling(ws.ref.key, wid);
    if (focusedWorkspaceWindow(target_ws) == null) {
        recordWorkspaceFocus(target_ws, wid);
    }

    // Update window metadata. Use the target workspace's display so that
    // retileDisplay (which filters on display_id) will include this window
    // when the target workspace becomes visible. Fall back to the source
    // display for hidden workspaces with no assigned display yet —
    // switchWorkspace will correct it when the workspace is activated.
    updated.space = target_ws.ref;
    updateTabGroupAssignment(wid, updated.space);
    if (nativeSpacesEnabled()) {
        trackPendingNativeWindowMove(wid, ws.ref, target_ws.ref);
    }

    // If target is not visible on the window's new display, hide it.
    if (!nativeSpacesEnabled() and !spaceVisible(updated.space)) {
        const visible_wid = g_tab_groups.resolveActive(wid);
        if (g_store.get(visible_wid)) |win| {
            hideWindow(win.pid, visible_wid);
        }
    }

    retile();
}

/// Update every ownership structure for a cross-display move. The caller owns
/// focus policy and the final retile so pointer drags can first adopt the
/// physical tab's latest frame.
fn reassignManagedWindowToDisplay(wid: u32, target_display_id: u32) bool {
    std.debug.assert(wid != 0);
    std.debug.assert(target_display_id != 0);

    var win = g_store.get(wid) orelse return false;
    if (win.space.display_id == target_display_id) return false;

    const target_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
    std.debug.assert(target_workspace_id > 0 and target_workspace_id <= g_workspaces.workspace_count);

    const source_ws = spaceForWindow(win) orelse return false;
    const target_ws = spaceForWorkspace(target_display_id, target_workspace_id) orelse return false;
    if (!source_ws.ref.key.eql(target_ws.ref.key)) {
        for (target_ws.windows.items) |existing_wid| {
            if (existing_wid == wid) {
                log.warn("refusing display move for wid={d}: already in target workspace {d}", .{ wid, target_workspace_id });
                return false;
            }
        }

        target_ws.ensureUnusedWindowCapacity(1) catch return false;
        if (win.mode == .tiled) {
            tryInsertIntoTiling(target_ws.ref.key, wid) catch |err| {
                log.err("failed to move wid={d} to display {d}: {}", .{ wid, target_display_id, err });
                return false;
            };
        }
        target_ws.addWindowAssumeCapacity(wid);

        if (!assignManagedWindowSpace(wid, target_ws.ref)) {
            if (win.mode == .tiled) removeFromTiling(target_ws.ref.key, wid);
            target_ws.removeWindow(wid);
            return false;
        }
        updateTabGroupAssignment(wid, target_ws.ref);

        removeFromTiling(source_ws.ref.key, wid);
        source_ws.removeWindow(wid);
        recordWorkspaceFocus(target_ws, wid);

        win.space = target_ws.ref;
    } else {
        if (!assignManagedWindowSpace(wid, target_ws.ref)) return false;
        updateTabGroupAssignment(wid, target_ws.ref);
        win.space = target_ws.ref;
    }

    return true;
}

/// Move a managed window to a target display and map it onto the target
/// display's active workspace so it stays visible after the move.
fn moveManagedWindowToDisplay(wid: u32, target_display_id: u32) bool {
    if (!reassignManagedWindowToDisplay(wid, target_display_id)) return false;
    if (g_store.get(wid)) |win| {
        observeWindowFocus(win, .keyboard, null);
    }
    retile();
    return true;
}

/// Moves the currently focused managed window to another display slot.
fn moveWindowToDisplay(target_display_slot: u8) void {
    if (target_display_slot == 0) return;
    const slot: usize = @intCast(target_display_slot - 1);
    if (slot >= g_display_count) return;

    const target_display_id = g_displays[slot].id;
    const ctx = actionContext() orelse return;
    _ = moveManagedWindowToDisplay(ctx.focused_wid, target_display_id);
}

fn moveWorkspaceToDisplay(target_display_slot: usize) void {
    if (target_display_slot >= g_display_count) return;

    const source_display_id = focusedDisplayId();
    const target_display_id = g_displays[target_display_slot].id;
    if (source_display_id == target_display_id) return;

    if (nativeSpacesEnabled()) {
        const moving_workspace_id = activeWorkspaceIdForDisplay(source_display_id);
        const displaced_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
        const source = spaceForWorkspace(source_display_id, moving_workspace_id) orelse return;
        const target = spaceForWorkspace(target_display_id, displaced_workspace_id) orelse return;
        dispatchStateEvent(.{ .request_native_workspace_move = .{
            .source = source.ref,
            .target = target.ref,
            .at_ms = nativeStateNowMs(),
        } });
        return;
    }

    const moving_ws_id = activeWorkspaceIdForDisplay(source_display_id);
    const displaced_ws_id = activeWorkspaceIdForDisplay(target_display_id);
    _ = spaceForWorkspace(source_display_id, moving_ws_id) orelse return;
    const displaced_ws = spaceForWorkspace(target_display_id, displaced_ws_id) orelse return;

    // Hide displaced workspace's windows on target display
    const hctx = HideCtx.init(target_display_id);
    for (displaced_ws.windows.items) |wid| {
        const visible_wid = g_tab_groups.resolveActive(wid);
        const hide_wid = if (g_store.get(visible_wid) != null) visible_wid else wid;
        if (g_store.get(hide_wid)) |win| {
            if (!win.space.key.eql(displaced_ws.ref.key)) continue;
            g_animator.finish(hide_wid);
            hctx.hide(win.pid, hide_wid);
        }
    }

    // Source display needs a new active workspace; pick first hidden one
    // assigned to it, or fall back to the displaced workspace.
    var fallback_id: u8 = displaced_ws_id;
    for (g_workspaces.spaces[0..g_workspaces.space_count]) |space| {
        if (space.ref.workspace_id == moving_ws_id) continue;
        if (space.ref.display_id != source_display_id) continue;
        if (spaceVisible(space.ref)) continue;
        fallback_id = space.ref.workspace_id;
        break;
    }
    var workspace_topology = g_state.workspace_topology;
    std.debug.assert(workspace_topology.setActiveWorkspace(target_display_id, moving_ws_id));
    std.debug.assert(workspace_topology.setActiveWorkspace(source_display_id, fallback_id));
    dispatchStateEvent(.{ .replace_workspace_topology = workspace_topology });

    var catalog = g_state.spaces;
    setVirtualSpaceDisplay(&catalog, moving_ws_id, target_display_id);
    setVirtualSpaceDisplay(&catalog, fallback_id, source_display_id);
    applySpaceCatalog(catalog);
    assertDisplayCoverage();

    startWorkspaceTransition(.move_workspace_to_display, g_state.space(.{ .virtual = moving_ws_id }).?);
    retile();
    setFocusedDisplay(target_display_id);
    updateStatusBar();

    if (g_state.isWorkspaceTransitionActive()) {
        clearPendingFocusQueue();
    }

    if (g_state.isWorkspaceTransitionActive()) {
        if (spaceForWorkspace(target_display_id, moving_ws_id)) |ws| {
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

/// Nearest window on the same display whose center lies in the given
/// direction from `focused`'s center, or null when none exists.
fn windowInDirection(ws: *const workspace_mod.Space, focused: *const window_mod.Window, dir: FocusDir) ?u32 {
    const fc_x = focused.frame.x + focused.frame.width / 2.0;
    const fc_y = focused.frame.y + focused.frame.height / 2.0;

    var best_wid: ?u32 = null;
    var best_dist: f64 = std.math.inf(f64);

    for (ws.windows.items) |wid| {
        if (wid == focused.wid) continue;
        const win = g_store.get(wid) orelse continue;
        if (!win.space.key.eql(focused.space.key)) continue;

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
    return best_wid;
}

/// Swap the focused window with its nearest neighbour in the given
/// direction and retile. No-op when either window is not tiled.
fn swapDirection(dir: FocusDir) void {
    const ctx = actionContext() orelse return;

    const target_wid = windowInDirection(ctx.workspace, &ctx.focused_win, dir) orelse return;

    const sp = tilingStatePtr(ctx.focused_win.space.key);
    if (sp.*) |*st| {
        if (!st.swapWids(ctx.focused_wid, target_wid)) return;
        log.info("swap {s}: wid={d} <-> wid={d}", .{ @tagName(dir), ctx.focused_wid, target_wid });
        retile();
    }
}

fn focusDirection(dir: FocusDir) void {
    const ctx = actionContext() orelse return;

    const best_wid = windowInDirection(ctx.workspace, &ctx.focused_win, dir);

    if (best_wid) |wid| {
        // If target is a tab group leader, focus the active tab instead
        const actual_wid = g_tab_groups.resolveActive(wid);
        if (g_store.get(actual_wid)) |win| {
            _ = bw_ax_focus_window(win.pid, actual_wid);
            recordWorkspaceFocus(ctx.workspace, wid);
            observeWindowFocus(win, .keyboard, null);
            setTilingActive(win.space.key, actual_wid);
        }
        return;
    }

    const sp = tilingStatePtr(ctx.focused_win.space.key);
    const st = sp.* orelse return;
    const stack_forward = switch (dir) {
        .left, .up => false,
        .right, .down => true,
    };
    if (st.cycleFocus(ctx.focused_wid, stack_forward)) |stack_wid| {
        if (g_store.get(stack_wid)) |win| {
            _ = bw_ax_focus_window(win.pid, stack_wid);
            recordWorkspaceFocus(ctx.workspace, stack_wid);
            observeWindowFocus(win, .keyboard, null);
            setTilingActive(win.space.key, stack_wid);
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
        .reload_config => {
            if (!reloadConfig()) {
                ipc.writeResponse(client_fd, "err: config reload failed; current config kept\n");
            }
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
            retileDisplay(ctx.focused_win.space.display_id);
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
            retileDisplay(ctx.focused_win.space.display_id);
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
            retileDisplay(ctx.focused_win.space.display_id);
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
            retileDisplay(ctx.focused_win.space.display_id);
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
            retileDisplay(ctx.focused_win.space.display_id);
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
            retileDisplay(ctx.focused_win.space.display_id);
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
    const ws = activeWorkspace();
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;
    var written: usize = 0;

    switch (format) {
        .text => for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                var id_buf: [256]u8 = undefined;
                const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
                const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                w.print("{d} {d} {s} {d} {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{
                    win.wid,     win.pid,     bundle_id,       win.space.workspace_id, win.space.display_id,
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
                    const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
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

    for (g_workspaces.spaces[0..g_workspaces.space_count]) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                // Deduplicate by PID
                if (std.mem.findScalar(i32, seen_pids[0..seen_count], win.pid) != null) continue;
                if (seen_count >= seen_pids.len) break;
                seen_pids[seen_count] = win.pid;
                seen_count += 1;

                var id_buf: [256]u8 = undefined;
                const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
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
        .text => writeWorkspaceText(w),
        .json => writeWorkspaceJson(w),
    }

    const payload = out.written();
    ipc.writeResponse(fd, payload);
    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] query workspaces rows={} bytes={} elapsed_ms={}", .{ g_workspaces.workspace_count, payload.len, elapsed_ms });
}

fn writeWorkspaceText(writer: *std.Io.Writer) void {
    var workspace_id: u8 = 1;
    while (workspace_id <= g_workspaces.workspace_count) : (workspace_id += 1) {
        const space = g_state.logicalWorkspace(workspace_id) orelse unreachable;
        var window_ids: [state_mod.max_managed_windows]u32 = undefined;
        const windows = g_state.workspaceWindowIds(space.key, &window_ids);
        writer.print("{d} {s} {d} {d}\n", .{
            workspace_id,
            if (spaceVisible(space)) "visible" else "hidden",
            g_state.focusedWorkspaceWindow(workspace_id) orelse 0,
            windows.len,
        }) catch return;
    }
}

fn writeWorkspaceJson(writer: *std.Io.Writer) void {
    var json: std.json.Stringify = .{ .writer = writer };
    json.beginArray() catch return;

    var workspace_id: u8 = 1;
    while (workspace_id <= g_workspaces.workspace_count) : (workspace_id += 1) {
        const space = g_state.logicalWorkspace(workspace_id) orelse unreachable;
        writeWorkspaceJsonEntry(&json, space) catch break;
    }
    json.endArray() catch {};
    writer.writeByte('\n') catch {};
}

fn writeWorkspaceJsonEntry(json: *std.json.Stringify, space: state_mod.SpaceRef) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("workspace_id");
    try json.write(space.workspace_id);
    try json.objectField("visible");
    try json.write(spaceVisible(space));
    try json.objectField("focused_window");
    try json.write(g_state.focusedWorkspaceWindow(space.workspace_id));
    try json.objectField("windows");
    try json.beginArray();

    var window_ids: [state_mod.max_managed_windows]u32 = undefined;
    for (g_state.workspaceWindowIds(space.key, &window_ids)) |wid| {
        var win = g_store.get(wid) orelse continue;
        win.space = space;
        var id_buf: [256]u8 = undefined;
        const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
        const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";
        try writeWindowJson(json, win, bundle_id);
    }
    try json.endArray();
    try json.endObject();
}

fn ipcQueryDisplays(fd: posix.socket_t, format: ipc.IpcCommand.QueryFormat) void {
    var out: std.Io.Writer.Allocating = .init(g_allocator);
    defer out.deinit();
    const w = &out.writer;

    switch (format) {
        .text => for (g_displays[0..g_display_count], 0..) |display, slot| {
            const workspace_id = activeWorkspaceIdForDisplay(g_displays[slot].id);
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
                const workspace_id = activeWorkspaceIdForDisplay(g_displays[slot].id);
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
    try json.write(win.space.workspace_id);
    try json.objectField("display_id");
    try json.write(win.space.display_id);
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
