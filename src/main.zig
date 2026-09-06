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
const ipc = @import("ipc.zig");
const ipc_transport = @import("ipc_transport.zig");
const signal_transport = @import("signal_transport.zig");
const tab_detect = @import("tabgroup/detect.zig");
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
const state_effect_queue_capacity = 64;
const StateEffectQueue = spsc_queue.Queue(state_mod.Effect, state_effect_queue_capacity);

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
/// Focus query retry budget. Electron apps (Discord) can report no AX
/// focused window for several hundred milliseconds after activation;
/// 10 attempts at the 100ms role-poll cadence covers that window.
const focus_retry_attempts_max: u8 = 10;
/// Quiet period after the last display notification before the trailing
/// reconcile runs. macOS emits a burst of display_changed events while a
/// hotplug/wake arrangement settles; the leading-edge debounce can land us on
/// an intermediate topology, so a reconcile this long after the final event
/// converges on the settled arrangement.
const display_settle_delay_ms: u64 = 250;
const native_space_capacity_settle_attempts: u8 = 20;
const native_space_capacity_poll_delay_us: c_uint = 25_000;
const native_space_topology_poll_interval_ms: u64 = 1000;
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

const DropTarget = struct {
    wid: u32,
    frame: window_mod.Window.Frame,
};

const WindowRoleState = state_mod.WindowReadiness;

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

const WorkspaceTransitionCompletionReason = state_mod.WorkspaceTransitionCompletionReason;

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

fn displayTopologyComesBefore(left: DisplayInfo, right: DisplayInfo) bool {
    if (left.is_primary != right.is_primary) return left.is_primary;

    if (left.uuid) |left_uuid| {
        const right_uuid = right.uuid orelse return true;
        for (left_uuid, right_uuid) |left_byte, right_byte| {
            if (left_byte == right_byte) continue;
            return left_byte < right_byte;
        }
    } else if (right.uuid != null) {
        return false;
    }

    return left.id < right.id;
}

fn stableDisplayIndices() [workspace_mod.max_displays]usize {
    var indices: [workspace_mod.max_displays]usize = undefined;
    for (0..g_display_count) |index| indices[index] = index;

    var index: usize = 1;
    while (index < g_display_count) : (index += 1) {
        const candidate = indices[index];
        var insertion_index = index;
        while (insertion_index > 0 and displayTopologyComesBefore(
            g_displays[candidate],
            g_displays[indices[insertion_index - 1]],
        )) : (insertion_index -= 1) {
            indices[insertion_index] = indices[insertion_index - 1];
        }
        indices[insertion_index] = candidate;
    }

    return indices;
}

fn activeWorkspaceIdForDisplay(display_id: u32) u8 {
    return g_state.activeWorkspace(display_id) orelse unreachable;
}

fn spaceForWorkspace(display_id: u32, workspace_id: u8) ?state_mod.SpaceRef {
    return g_state.spaceForWorkspace(display_id, workspace_id);
}

fn managedWindowSpace(window_id: u32) ?state_mod.SpaceRef {
    const managed = g_state.window(window_id) orelse return null;
    return g_state.space(managed.space_key);
}

fn managedWindow(window_id: u32) ?window_mod.Window {
    return g_state.windowSnapshot(window_id);
}

fn updateManagedWindow(window: window_mod.Window) bool {
    const managed = g_state.window(window.wid) orelse return false;
    const layout: ?state_mod.LayoutInsertion = if (managed.tab_leader_window_id == window.wid and
        managed.mode != .tiled and window.mode == .tiled)
        layoutInsertion(managed.space_key, window.wid) catch return false
    else
        null;
    dispatchStateEvent(.{ .update_window = .{ .window = window, .layout = layout } });
    const updated = g_state.windowSnapshot(window.wid) orelse return false;
    return std.meta.eql(updated, window);
}

fn spaceForCommand(_: u32, workspace_id: u8) ?state_mod.SpaceRef {
    return g_state.logicalWorkspace(workspace_id);
}

const WorkspaceWindowSnapshot = struct {
    window_ids: [state_mod.max_managed_windows]u32 = undefined,
    count: usize = 0,

    fn items(self: *const WorkspaceWindowSnapshot) []const u32 {
        return self.window_ids[0..self.count];
    }
};

fn workspaceWindows(space: state_mod.SpaceRef) WorkspaceWindowSnapshot {
    var snapshot: WorkspaceWindowSnapshot = .{};
    snapshot.count = g_state.workspaceWindowIds(space.key, &snapshot.window_ids).len;
    return snapshot;
}

fn activeWorkspace() state_mod.SpaceRef {
    const workspace_id = activeWorkspaceIdForDisplay(focusedDisplayId());
    return spaceForWorkspace(focusedDisplayId(), workspace_id) orelse unreachable;
}

fn focusedWorkspaceWindow(space: state_mod.SpaceRef) ?u32 {
    return g_state.focusedWorkspaceWindow(space.workspace_id);
}

fn recordWorkspaceFocus(space: state_mod.SpaceRef, wid: u32) void {
    dispatchStateEvent(.{ .record_workspace_focus = .{
        .workspace_id = space.workspace_id,
        .window_id = wid,
    } });
}

fn nativeStateNowMs() state_mod.TimestampMs {
    const seconds = c.CFAbsoluteTimeGetCurrent();
    if (seconds <= 0) return 0;
    return @intFromFloat(seconds * std.time.ms_per_s);
}

fn nativeSwitchPending() bool {
    return g_state.isNativeSwitchPending();
}

fn workspaceTraversalDirectionFromAction(action: u8) ?WorkspaceTraversalDirection {
    if (action == shim.BW_HK_FOCUS_PREVIOUS_WORKSPACE) return .previous;
    if (action == shim.BW_HK_FOCUS_NEXT_WORKSPACE) return .next;
    return null;
}

fn adjacentWorkspaceId(direction: WorkspaceTraversalDirection) ?u8 {
    const focused_display_id = focusedDisplayId();
    const workspace_count = workspaceCount();
    std.debug.assert(workspace_count > 0);
    std.debug.assert(workspace_count <= workspace_mod.max_workspaces);

    const base_id = g_state.desiredWorkspace(focused_display_id) orelse activeWorkspaceIdForDisplay(focused_display_id);
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
    if (g_state.isWindowTabSuppressed(win.wid)) return false;
    const space = managedWindowSpace(win.wid) orelse return false;
    return spaceVisible(space);
}

/// Dim every visible managed window except the focused one with black overlay
/// panels. Callers must gate on `dim.enabled`. Uses the model's accepted frames
/// directly (no WindowServer round-trip): retile and move/resize events have
/// already synchronized them by the time this runs at the end of the drain.
fn pushDimSnapshot() void {
    // Precondition: callers gate on dim.enabled, so the disabled feature never
    // reaches the window-scan loops below. Assert rather than early-return so
    // the invariant is documented and compiles out in release builds.
    std.debug.assert(dim.enabled);

    // An overlay is placed over the window's accepted frame, so a stale entry
    // that is not on screen — a stale native-tab id, a window an app closed to
    // background — darkens whatever sits underneath it instead. One entry
    // holding a display-sized frame blacks out the display.
    const on_screen = OnScreenWindows.snapshot();

    var entries: [256]dim.Entry = undefined;
    var n: usize = 0;
    for (g_state.windows.items()) |managed_window| {
        const win = managed_window.snapshot();
        if (n >= entries.len) break;
        if (!isVisibleManaged(&win)) continue;
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
        focused[fn_count] = g_state.windowTabActive(wid);
        fn_count += 1;
    }

    dim.apply(focused[0..fn_count], entries[0..n]);
}

fn focusedDisplayId() u32 {
    return g_state.focusedDisplay() orelse unreachable;
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
    const leader_wid = g_state.windowTabLeader(focused_wid);
    const leader = managedWindow(leader_wid) orelse return null;
    if (leader.pid != pid) return null;
    return leader;
}

/// Resolve the frontmost app's AX-focused window to its visible layout owner.
fn reconciledFocusedWindowId() ?u32 {
    const pid = frontmostApplicationPid() orelse return null;
    const focused_wid = focusedWindowIdForPid(pid) orelse return null;

    if (managedLeaderForFocusedWindow(pid, focused_wid)) |win| {
        if (managedWindowSpace(win.wid)) |space| {
            if (spaceVisible(space)) {
                // A known suppressed member can become AX-focused without a
                // notification reaching the main loop first. The leader owns the
                // fullscreen flag, but retile must address this active member.
                if (!g_state.isWorkspaceTransitionActive()) {
                    _ = syncFocusStateForWindowId(focused_wid, .keyboard);
                }
                return win.wid;
            }
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
            const space = managedWindowSpace(win.wid) orelse return null;
            if (spaceVisible(space)) return win.wid;
        }
    }

    return null;
}

const ActionContext = struct {
    focused_wid: u32,
    focused_win: window_mod.Window,
    workspace: state_mod.SpaceRef,
};

fn actionContext() ?ActionContext {
    const focused_wid = reconciledFocusedWindowId() orelse return null;
    const focused_win = managedWindow(focused_wid) orelse return null;
    const workspace = managedWindowSpace(focused_win.wid) orelse return null;
    if (!spaceVisible(workspace)) return null;
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

    const win = managedWindow(entry.window_id) orelse {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=missing-window", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
        });
        return;
    };
    if (win.pid != entry.process_id) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=pid-mismatch managed_pid={d}", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
            win.pid,
        });
        return;
    }
    const space = managedWindowSpace(win.wid) orelse return;
    if (!space.key.eql(entry.space_key)) {
        log.debug("workspace transition pending focus skipped epoch={d} wid={d} pid={d} reason=space-changed workspace={d}", .{
            transition.epoch,
            entry.window_id,
            entry.process_id,
            space.workspace_id,
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

fn observeWindowFocus(win: window_mod.Window, source: FocusEventSource, pending_transition_epoch: ?state_mod.Epoch) void {
    const space = managedWindowSpace(win.wid) orelse return;
    dispatchStateEvent(.{ .window_focus_observed = .{
        .process_id = win.pid,
        .window_id = win.wid,
        .source = source,
        .target = space,
        .is_target_visible = spaceVisible(space),
        .at_ms = nativeStateNowMs(),
        .pending_transition_epoch = pending_transition_epoch,
    } });
}

/// Follow focus into a hidden workspace. `focused_wid` is the window the AX
/// event named; `win` is its group leader, which owns the workspace slot.
///
/// Hidden focus is deferred through the entire transition, including the
/// settle tail: late AX focus from the Space just left can otherwise
/// reverse an accepted switch and create a two-workspace feedback loop. The
/// deferred replay validates the frontmost app once synthetic events settle,
/// preserving a genuine fast Cmd+Tab without following stale AX fallout.
fn switchToWindowWorkspaceIfHidden(win: window_mod.Window, focused_wid: u32, source: FocusEventSource) void {
    std.debug.assert(win.wid != 0);
    std.debug.assert(focused_wid != 0);
    const space = managedWindowSpace(win.wid) orelse return;

    dispatchStateEvent(.{ .follow_focus_observed = .{
        .process_id = win.pid,
        .window_id = focused_wid,
        .leader_window_id = win.wid,
        .source = source,
        .target = space,
        .is_target_visible = spaceVisible(space),
        .at_ms = nativeStateNowMs(),
    } });
}

/// Replay a follow-focus intent that a mid-flight transition deferred. Called
/// the moment the transition clears. Bails when the window is gone, already
/// visible, or no longer owns app focus — by then the intent is stale.
fn applyDeferredFollowFocus(deferred: ?state_mod.DeferredFollowFocus) void {
    std.debug.assert(!g_state.isWorkspaceTransitionActive());

    const focus = deferred orelse return;

    const leader = managedWindow(g_state.windowTabLeader(focus.window_id)) orelse return;
    if (leader.pid != focus.process_id) return;
    const space = managedWindowSpace(leader.wid) orelse return;
    if (spaceVisible(space)) return;

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
        space.workspace_id,
        space.display_id,
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
    const space = managedWindowSpace(win.wid) orelse return false;
    return space.key.eql(transition.target.key);
}

fn syncFocusStateForWindowId(focused_wid: u32, source: FocusEventSource) bool {
    std.debug.assert(focused_wid != 0);

    const leader = g_state.windowTabLeader(focused_wid);
    std.debug.assert(leader != 0);

    const win = managedWindow(leader) orelse return false;
    std.debug.assert(win.wid == leader);

    // Window ID is the canonical identity. PID-only notifications are resolved
    // before this point so same-process windows do not overwrite each other.
    setTabGroupActive(focused_wid);
    observeWindowFocus(win, source, null);
    const space = managedWindowSpace(win.wid) orelse return false;
    if (shouldRecordWorkspaceFocusForWindow(win)) {
        recordWorkspaceFocus(space, leader);
        setTilingActive(space.key, focused_wid);
    } else {
        const transition = g_state.workspace_transition.?;
        const target = transition.target;
        log.debug("workspace transition focus memory skipped epoch={d} wid={d} leader={d} source={s} workspace={d} display={d} target_workspace={d} target_display={d}", .{
            transition.epoch,
            focused_wid,
            leader,
            @tagName(source),
            space.workspace_id,
            space.display_id,
            target.workspace_id,
            target.display_id,
        });
    }
    switchToWindowWorkspaceIfHidden(win, focused_wid, source);

    return true;
}

/// Refresh accepted frames of visible managed windows from WindowServer bounds.
///
/// Move/resize events are suppressed while a workspace transition is active,
/// so a retile whose target is smaller than an app's minimum size (the app
/// clamps the resize) leaves the model holding the intended tile frame while
/// the real window is larger. Nothing re-reads the frame after the transition,
/// so frame consumers such as the dimming overlays stay mismatched until the
/// app happens to emit another move/resize. Called when a transition clears —
/// the moment suppression ends — to converge the model on physical geometry.
fn reconcileVisibleFramesFromWindowServer() void {
    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();

    var window_index: usize = 0;
    while (window_index < g_state.windows.count) : (window_index += 1) {
        var win = g_state.windows.items()[window_index].snapshot();
        if (!isVisibleManaged(&win)) continue;

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
        _ = updateManagedWindow(win);
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
        for (0..g_display_count) |other| {
            if (other == slot) continue;
            std.debug.assert(activeWorkspaceIdForDisplay(g_displays[other].id) != ws_id);
        }
    }
}

fn updateStatusBar() void {
    const workspace_count = workspaceCount();
    const summaries = g_state.workspaceSummaries(workspace_count);
    statusbar.updateState(summaries[0..workspace_count]);
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
    const workspace_count = workspaceCount();
    if (next_count > workspace_count) {
        log.warn("{d} displays but only {d} workspaces; ignoring the excess displays", .{
            next_count,
            workspace_count,
        });
        next_count = workspace_count;
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
    dispatchStateEvent(.{ .geometry = .{ .seed = .{
        .window_id = wid,
        .observed = frame,
    } } });
}

/// Workspace-aware on-screen check.
fn isVisibleOnScreen(wid: u32) bool {
    if (managedWindow(wid)) |win| {
        const space = managedWindowSpace(win.wid) orelse return false;
        if (!spaceVisible(space)) return false;
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
var g_state: state_mod.Model = .{};
var g_state_effect_queue: StateEffectQueue = .{};
var g_state_effect_drain_active = false;
var g_displays: [workspace_mod.max_displays]DisplayInfo = undefined;
var g_display_count: usize = 0;
var g_workspace_observer: ?objc.Object = null;
var g_ipc: ipc.Server = undefined;
var g_config: config_mod.Config = .{};
var g_config_runtime: ?ConfigRuntime = null;
var g_config_path: ?[:0]const u8 = null;
var g_mouse_down_location: c.CGPoint = .{ .x = 0, .y = 0 };
var g_mouse_drag_event_emitted = false;

fn workspaceCount() u8 {
    const count = config_mod.workspaceCount(&g_config);
    std.debug.assert(count > 0 and count <= workspace_mod.max_workspaces);
    return count;
}

fn moveTabGroupToNativeSpace(wid: u32, target: state_mod.SpaceRef) bool {
    const space_id = target.key.id;
    const sky = &g_sky.?;
    if (g_state.windowTabGroup(wid)) |group| {
        return sky.moveWindowsToNativeSpace(group.members(), space_id);
    }
    return sky.moveWindowToNativeSpace(wid, space_id);
}

fn requestNativeWindowMove(wid: u32, source: state_mod.SpaceRef, target: state_mod.SpaceRef) void {
    source.assertValid();
    target.assertValid();
    const leader_wid = g_state.windowTabLeader(wid);
    dispatchStateEvent(.{ .track_native_window_move = .{
        .window_id = leader_wid,
        .source = source,
        .target = target,
    } });
}

fn nativeTabGroupMoveConfirmed(wid: u32, pending: state_mod.PendingNativeWindowMove) ?bool {
    const sky = &g_sky.?;
    const target_space_id = pending.target.key.id;
    const source_space_id = pending.source.key.id;
    if (g_state.windowTabGroup(wid)) |group| {
        var checked_count: usize = 0;
        for (group.members()) |member_wid| {
            if (managedWindow(member_wid) == null) continue;
            checked_count += 1;
            if (!(sky.nativeWindowMoveConfirmed(member_wid, target_space_id, source_space_id) orelse return null)) return false;
        }
        return checked_count > 0;
    }
    if (managedWindow(wid) == null) return false;
    return sky.nativeWindowMoveConfirmed(wid, target_space_id, source_space_id);
}

/// PID of the last window we focused via bw_ax_focus_window. Used to detect
/// same-process focus switches that need a delay for Electron compatibility.
var g_last_focused_pid: i32 = 0;
/// Compiled keybind table referenced (not copied) by the hotkey event tap.
/// The caller of bw_set_keybinds owns the storage and must keep it alive for
/// as long as the event tap can fire; main's KeybindTable guarantees this.
var g_hotkey_bindings: []const shim.bw_keybind = &.{};
var g_waker_source: c.CFRunLoopSourceRef = null;
var g_role_poll_source: c.dispatch_source_t = null;
var g_native_space_topology_poll_source: c.dispatch_source_t = null;
var g_tap_port: c.CFMachPortRef = null;
var g_layout_entries: std.ArrayList(tiling.LayoutEntry) = .empty;
var g_event_drain_active = false;
var g_event_overflow_recovery_pending = false;
var g_on_screen_truncation_logged = false;

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

fn requestCleanupForPid(pid: i32) void {
    std.debug.assert(pid > 0);
    dispatchStateEvent(.{ .request_cleanup_process = pid });
}

fn requestOffscreenCleanup() void {
    dispatchStateEvent(.request_offscreen_cleanup);
}

fn flushCleanupRequests() void {
    dispatchStateEvent(.flush_cleanup_requests);
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
        if (managedWindow(wid) == null) continue;

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

fn windowMayRemainManaged(pid: i32, wid: u32) bool {
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
        if (managedWindow(wid) != null) continue;

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

fn nativeSpaceTopologyPollTimerTick(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    bw_emit_event(shim.BW_EVENT_NATIVE_TOPOLOGY_POLL_TICK, 0, 0);
}

fn rebuildTilingStatesForConfig() void {
    var rebuild: state_mod.LayoutRebuild = .{
        .kind = g_config.layout,
        .split_mode = g_state.bsp_split_mode,
        .insert_child = g_config.new_window_split,
        .insert_point = g_state.bsp_insert_point,
        .inner_gap = @floatFromInt(g_config.gaps.inner),
        .split_ratio = g_config.bsp_split_ratio,
    };
    for (g_state.spaces.spaces[0..g_state.spaces.space_count]) |ws| {
        if (!rebuild.addSpace(ws.key, displayContentFrame(ws.display_id))) {
            log.err("layout rebuild rejected workspace={d}", .{ws.workspace_id});
            return;
        }
    }
    dispatchStateEvent(.{ .rebuild_layout = rebuild });
}

fn applyReloadedConfig(next: ConfigRuntime) void {
    std.debug.assert(config_mod.workspaceCount(&next.config) == workspaceCount());

    var replacement = next;
    replacement.config.applyKeybinds(&replacement.keybind_table);

    var previous = g_config_runtime.?;
    const layout_changed = previous.config.layout != replacement.config.layout;
    g_config_runtime = replacement;
    g_config = replacement.config;
    dispatchStateEvent(.{ .configure_layout_interaction = .{
        .split_mode = g_config.bsp_split,
        .insert_point = g_config.bsp_insert_point,
    } });
    g_animator.finishAll();
    g_animator.init(g_config.animation);
    dim.configure(g_config.dimmed_inactive);
    loginitem.reconcile(g_config.start_at_login);

    // Preserve BSP topology and runtime split edits for ordinary config saves.
    // Only changing the layout algorithm requires reconstructing state.
    if (layout_changed) rebuildTilingStatesForConfig();
    statusbar.updateWorkspaceMenu(workspaceCount(), &g_config);
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
    if (configured_count != workspaceCount()) {
        log.err("config reload cannot change workspace count ({d} running, {d} configured); restart to apply it", .{
            workspaceCount(),
            configured_count,
        });
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

fn setNativeSpaceTopologyPolling(enabled: bool) void {
    if (!enabled) {
        if (g_native_space_topology_poll_source) |source| {
            c.dispatch_source_cancel(source);
            c.dispatch_release(.{ ._ds = source });
            g_native_space_topology_poll_source = null;
        }
        return;
    }

    if (g_native_space_topology_poll_source != null) return;

    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
    ) orelse return;
    const interval_ns = native_space_topology_poll_interval_ms * c.NSEC_PER_MSEC;
    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, @intCast(interval_ns)),
        interval_ns,
        100 * c.NSEC_PER_MSEC,
    );
    c.dispatch_source_set_event_handler_f(source, nativeSpaceTopologyPollTimerTick);
    c.dispatch_resume(.{ ._ds = source });
    g_native_space_topology_poll_source = source;
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
    const mask: c.CGEventMask =
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventKeyDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseDown)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseDragged)) |
        (@as(c.CGEventMask, 1) << @intCast(c.kCGEventLeftMouseUp)) |
        (@as(c.CGEventMask, 1) << 29) |
        (@as(c.CGEventMask, 1) << 30);

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

    dispatchStateEvent(.{ .configure_layout_interaction = .{
        .split_mode = g_config.bsp_split,
        .insert_point = g_config.bsp_insert_point,
    } });
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

    // -- SkyLight --
    g_sky = skylight.SkyLight.init();
    if (g_sky == null or !g_sky.?.supportsNativeSpaces()) {
        log.err("required native Space APIs are unavailable", .{});
        return error.NativeSpacesUnavailable;
    }

    // -- Core state --
    defer {
        setRolePolling(false);
        setNativeSpaceTopologyPolling(false);
        g_layout_entries.deinit(g_allocator);
    }
    refreshDisplays();
    if (!reconcileNativeSpaceCapacity()) {
        log.err("could not reconcile Mission Control Space count", .{});
        return error.NativeSpaceCapacityUnavailable;
    }

    const primary_id = primaryDisplayId();
    // Capture WindowServer topology before discovering windows so native Space
    // membership and the deterministic logical mapping agree from startup.
    const topology = captureNativeTopology() orelse {
        log.err("could not map configured workspaces to Mission Control Spaces", .{});
        return error.NativeSpaceMappingUnavailable;
    };
    for (topology.displays[0..topology.display_count]) |display| {
        if (display.workspaceForSpace(display.observed_space_id) != null) continue;
        log.err("current Space {d} is not a configured ordinary workspace on display {d}", .{
            display.observed_space_id,
            display.display_id,
        });
        return error.NativeSpaceMappingUnavailable;
    }
    dispatchStateEvent(.{ .initialize_native_topology = .{
        .topology = topology,
        .focused_display_id = primary_id,
    } });

    // -- Signal transport (handler writes only; cleanup runs on main) --
    try signal_transport.init(gracefulStopNSApp);
    defer signal_transport.deinit();
    errdefer resetDimming();

    // -- Discover existing windows and tile --
    discoverWindows();
    log.info("discovered {} windows", .{g_state.windows.count});
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
    setNativeSpaceTopologyPolling(true);
    try g_ipc_transport.start(g_ipc.fd, signalWaker);
    defer g_ipc_transport.stop();
    refreshRolePolling();
    observeDiscoveredApps();

    // Status bar (zig-objc) --
    statusbar.init(
        workspaceCount(),
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
    // The defer chain then removes any dimming overlays on the main thread.
    log.info("entering run loop", .{});
    defer resetDimming();
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

    // Flush retile before cleanup so visible windows are at their accepted
    // layout positions when cleanup checks WindowServer state.
    flushRetileRequests();

    flushCleanupRequests();
    flushRetileRequests();

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
/// deferred through workspace transitions while visibility is changing.
fn recoverFromEventOverflow() void {
    if (!g_event_overflow_recovery_pending) return;
    if (g_state.isWorkspaceTransitionActive()) return;

    g_event_overflow_recovery_pending = false;
    log.warn("event overflow: reconciling window, app, focus, and frame state", .{});

    // Mouse-up may be the lost event. Abandon transient drag state rather than
    // leaving every later AX move classified as a user drag indefinitely.
    dispatchStateEvent(.pointer_up);
    dispatchStateEvent(.{ .geometry = .clear_intents });

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
    var due_wids: [state_mod.max_managed_windows]u32 = undefined;
    const due_count = g_state.geometry.dueResamples(now_ns, &due_wids);

    for (due_wids[0..due_count]) |wid| {
        dispatchStateEvent(.{ .geometry = .{ .begin_resample = wid } });
        if (g_state.pointer_drag.active_window_id == wid) {
            dispatchStateEvent(.{ .geometry = .{ .defer_resample = .{
                .window_id = wid,
                .at_ns = now_ns,
            } } });
            continue;
        }

        const observed = liveWindowFrame(wid) orelse {
            if (g_state.geometry.get(wid)) |entry| {
                if (entry.intent) |intent| {
                    if (now_ns <= intent.settle_deadline_ns) {
                        dispatchStateEvent(.{ .geometry = .{ .defer_resample = .{
                            .window_id = wid,
                            .at_ns = now_ns,
                        } } });
                        continue;
                    }
                    if (reconcileDivergedGeometryIntent(wid, intent)) {
                        forgetGeometryIfUnmanaged(wid);
                        continue;
                    }
                }
            }
            forgetGeometryIfUnmanaged(wid);
            continue;
        };
        dispatchStateEvent(.{ .geometry = .{ .settle = .{
            .window_id = wid,
            .observed = observed,
            .at_ns = now_ns,
        } } });
    }
}

/// An accepted AX write can target a native-tab ID that disappeared from the
/// visible AX window set while the application simultaneously surfaced a new
/// focused ID. Reconcile through the existing tab-aware focus path before
/// retrying geometry; blindly reissuing the stale ID would loop forever.
fn reconcileDivergedGeometryIntent(wid: u32, intent: geometry_mod.Intent) bool {
    switch (intent.source) {
        .tab_sync => return false,
        .layout, .floating_restore, .user_command, .animation => {},
    }

    const win = managedWindow(wid) orelse return false;
    const space = managedWindowSpace(win.wid) orelse return false;
    if (!spaceVisible(space)) return false;
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
    requestRetileDisplay(space.display_id);
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
    if (workspace_id == 0 or workspace_id > workspaceCount()) return;
    switchWorkspace(workspace_id);
}

fn statusBarQuit() callconv(.c) void {
    resetDimming();

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

fn tilingInsertOptions(space_key: state_mod.SpaceKey, wid: u32) !tiling.InsertOptions {
    const ws = g_state.space(space_key) orelse return error.InvalidWorkspace;
    const anchor_wid = blk: {
        switch (g_state.bsp_insert_point) {
            .focused => {
                const focused_wid = focusedWorkspaceWindow(ws) orelse break :blk null;
                if (focused_wid == wid) break :blk null;
                break :blk focused_wid;
            },
            .first => break :blk g_state.layout.firstWid(space_key),
            .last => break :blk g_state.layout.lastWid(space_key),
            .min_depth => break :blk null,
        }
    };
    return .{
        .split_mode = g_state.bsp_split_mode,
        .child = g_config.new_window_split,
        .anchor_wid = anchor_wid,
        .root_frame = displayContentFrame(ws.display_id),
        .inner_gap = @floatFromInt(g_config.gaps.inner),
        .split_ratio = g_config.bsp_split_ratio,
    };
}

fn layoutInsertion(space_key: state_mod.SpaceKey, wid: u32) !state_mod.LayoutInsertion {
    return .{
        .kind = g_config.layout,
        .options = try tilingInsertOptions(space_key, wid),
    };
}

fn adoptWindowIdentity(
    win: window_mod.Window,
    space_key: state_mod.SpaceKey,
    layout: ?state_mod.LayoutInsertion,
    tab_group: ?state_mod.WindowTabGroupObservation,
) bool {
    if (g_state.window(win.wid) != null) return false;

    dispatchStateEvent(.{ .adopt_window = .{
        .window_id = win.wid,
        .process_id = win.pid,
        .space_key = space_key,
        .frame = win.frame,
        .is_fullscreen = win.is_fullscreen,
        .mode = win.mode,
        .float_frame = win.float_frame,
        .layout = layout,
        .tab_group = tab_group,
    } });
    const adopted = g_state.window(win.wid) orelse return false;
    return adopted.process_id == win.pid and adopted.space_key.eql(space_key);
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

fn observeWindowTabGroup(observation: state_mod.WindowTabGroupObservation) bool {
    dispatchStateEvent(.{ .observe_window_tab_group = observation });
    for (observation.members()) |member_wid| {
        const member = g_state.window(member_wid) orelse return false;
        if (member.tab_leader_window_id != observation.leader_window_id) return false;
        if (member.is_suppressed != (member_wid != observation.active_window_id)) return false;
    }
    return true;
}

fn attachWindowToTabGroup(sibling_window_id: u32, window_id: u32, active_window_id: u32) bool {
    const observation = tabGroupObservation(sibling_window_id, window_id, active_window_id) orelse return false;
    return observeWindowTabGroup(observation);
}

fn tabGroupObservation(
    sibling_window_id: u32,
    window_id: u32,
    active_window_id: u32,
) ?state_mod.WindowTabGroupObservation {
    var observation: state_mod.WindowTabGroupObservation = .{
        .leader_window_id = g_state.windowTabLeader(sibling_window_id),
        .active_window_id = active_window_id,
    };
    if (g_state.windowTabGroup(sibling_window_id)) |group| {
        for (group.members()) |member_window_id| {
            if (!observation.addMember(member_window_id)) return null;
        }
    } else if (!observation.addMember(sibling_window_id)) {
        return null;
    }
    if (!observation.addMember(window_id)) return null;
    return observation;
}

fn detachWindowTab(window_id: u32) bool {
    const window = g_state.window(window_id) orelse return false;
    const layout: ?state_mod.LayoutInsertion = if (window.mode == .tiled)
        layoutInsertion(window.space_key, window_id) catch return false
    else
        null;
    dispatchStateEvent(.{ .detach_window_tab = .{
        .window_id = window_id,
        .layout = layout,
    } });
    const detached = g_state.window(window_id) orelse return false;
    return detached.tab_leader_window_id == window_id and !detached.is_suppressed;
}

fn setTabGroupActive(wid: u32) void {
    const group = g_state.windowTabGroup(wid) orelse return;
    var observation: state_mod.WindowTabGroupObservation = .{
        .leader_window_id = group.leader_window_id,
        .active_window_id = wid,
    };
    for (group.members()) |member_window_id| {
        if (!observation.addMember(member_window_id)) return;
    }
    _ = observeWindowTabGroup(observation);
}

fn assignManagedWindowSpace(wid: u32, space: state_mod.SpaceRef) bool {
    if (managedWindow(wid) == null) return false;
    const managed = g_state.window(wid) orelse return false;

    if (!managed.space_key.eql(space.key)) {
        const leader_window_id = g_state.windowTabLeader(wid);
        const leader = g_state.window(leader_window_id) orelse return false;
        const layout: ?state_mod.LayoutInsertion = if (g_state.layout.contains(leader.space_key, leader_window_id))
            layoutInsertion(space.key, leader_window_id) catch return false
        else
            null;
        dispatchStateEvent(.{ .assign_window_space = .{
            .window_id = wid,
            .space_key = space.key,
            .layout = layout,
        } });
        const assigned = g_state.window(wid) orelse return false;
        if (!assigned.space_key.eql(space.key)) return false;
    }

    return true;
}

fn adoptWindow(ws: state_mod.SpaceRef, win: window_mod.Window) !void {
    std.debug.assert(managedWindow(win.wid) == null);
    const layout: ?state_mod.LayoutInsertion = if (win.mode == .tiled)
        try layoutInsertion(ws.key, win.wid)
    else
        null;
    if (!adoptWindowIdentity(win, ws.key, layout, null)) return error.WindowCatalogRejected;
}

fn setTilingActive(space_key: state_mod.SpaceKey, wid: u32) void {
    const layout_wid = g_state.windowTabLeader(wid);
    if (!g_state.layout.contains(space_key, layout_wid)) return;
    dispatchStateEvent(.{ .layout = .{ .set_active = .{
        .space_key = space_key,
        .window_id = layout_wid,
    } } });
}

fn replaceManagedWindowId(old_wid: u32, new_wid: u32, frame: window_mod.Window.Frame) bool {
    std.debug.assert(old_wid != 0);
    std.debug.assert(new_wid != 0);
    std.debug.assert(frame.width > 0 and frame.height > 0);
    if (old_wid == new_wid) return false;
    if (managedWindow(new_wid) != null) return false;
    if (g_state.windowTabGroup(old_wid) != null) return false;
    if (g_state.windowTabGroup(new_wid) != null) return false;

    const old = managedWindow(old_wid) orelse return false;
    const space = managedWindowSpace(old.wid) orelse return false;
    const replaced_in_layout = g_state.layout.contains(space.key, old_wid);

    if (old.mode == .tiled and !replaced_in_layout) {
        log.warn("window id replacement failed old={d} new={d} workspace={d} in_layout={}", .{
            old_wid,
            new_wid,
            space.workspace_id,
            replaced_in_layout,
        });
        return false;
    }

    var updated = old;
    updated.wid = new_wid;
    updated.frame = frame;
    if (!replaceWindowIdentity(old_wid, new_wid)) return false;
    _ = updateManagedWindow(updated);
    seedObservedFrame(new_wid, frame);
    ax_mod.invalidateWindow(old_wid);
    log.info("window id replaced old={d} new={d} pid={d} workspace={d} display={d}", .{
        old_wid,
        new_wid,
        updated.pid,
        space.workspace_id,
        space.display_id,
    });
    return true;
}

const FocusedLayoutContext = struct {
    focused_wid: u32,
    focused_win: window_mod.Window,
    workspace: state_mod.SpaceRef,
    layout_kind: tiling.LayoutKind,
};

fn focusedLayoutContext() ?FocusedLayoutContext {
    const ctx = actionContext() orelse return null;
    const layout_kind = g_state.layout.layoutKind(ctx.workspace.key) orelse return null;
    return .{
        .focused_wid = ctx.focused_wid,
        .focused_win = ctx.focused_win,
        .workspace = ctx.workspace,
        .layout_kind = layout_kind,
    };
}

fn clearDragPreview() void {
    dispatchStateEvent(.clear_drag_preview);
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

fn updateWindowMovePreview(wid: u32) void {
    if (g_config.layout != .bsp) {
        clearDragPreview();
        return;
    }

    const win = managedWindow(wid) orelse {
        clearDragPreview();
        return;
    };

    if (win.mode != .tiled or win.is_fullscreen) {
        clearDragPreview();
        return;
    }
    const space = managedWindowSpace(win.wid) orelse {
        clearDragPreview();
        return;
    };
    if (!spaceVisible(space)) {
        clearDragPreview();
        return;
    }

    if (g_state.layout.layoutKind(space.key) != .bsp) {
        clearDragPreview();
        return;
    }
    const display_frame = displayContentFrame(space.display_id) orelse {
        clearDragPreview();
        return;
    };

    const center_x = win.frame.x + win.frame.width / 2.0;
    const center_y = win.frame.y + win.frame.height / 2.0;
    const target_entry = g_state.layout.entryAtPoint(
        space.key,
        display_frame,
        @floatFromInt(g_config.gaps.inner),
        center_x,
        center_y,
        wid,
    );

    if (target_entry) |entry| {
        dispatchStateEvent(.{ .drag_preview_observed = .{
            .source_window_id = wid,
            .target_window_id = entry.wid,
            .target_frame = entry.frame,
        } });
        return;
    }

    dispatchStateEvent(.{ .drag_preview_observed = .{
        .source_window_id = wid,
        .target_window_id = null,
        .target_frame = null,
    } });
}

fn dispatchLayoutCommand(event: tiling.Event, display_id: u32) void {
    dispatchStateEvent(.{ .layout_command = .{
        .event = event,
        .display_id = display_id,
    } });
}

fn requestRetileDisplay(display_id: u32) void {
    std.debug.assert(display_id != 0);
    const display_slot = displayIndexById(display_id) orelse return;
    dispatchStateEvent(.{ .request_retile_display = g_displays[display_slot].id });
}

fn requestRetileAllDisplays() void {
    dispatchStateEvent(.request_retile_all_displays);
}

fn flushRetileRequests() void {
    dispatchStateEvent(.flush_retile_requests);
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

            if (g_state.hasPendingRoleWindow(ev.wid)) {
                log.debug("window created: role check already pending pid={} wid={}", .{ ev.pid, ev.wid });
                return;
            }

            // Electron browsers (Chrome, Edge, Brave) fire kAXWindowCreatedNotification
            // mid-drag during tab tear-out, before the window has settled. Defer these
            // into the existing deferred-candidate pipeline so they are picked up after
            // mouse-up, preventing a layout flash from tiling a half-positioned window.
            if (g_state.pointer_drag.is_down) {
                if (managedWindow(ev.wid) == null) {
                    // Mid-drag bounds may not be settled yet, so the inferred
                    // display can be wrong; fall back to the focused display
                    // and let processDeferredWindowCandidates re-derive on
                    // promotion (it goes through addNewWindowManaged again).
                    const display_id = inferDisplayIdForWindow(ev.wid) orelse focusedDisplayId();
                    const ws = resolveWorkspaceForWindow(ev.pid, ev.wid, display_id) orelse return;
                    trackDeferredWindowCandidate(ev.pid, ev.wid, ws);
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
            const at_ms = nativeStateNowMs();
            dispatchStateEvent(.{ .display_changed = .{
                .at_ms = at_ms,
                .resettle_at_ms = at_ms +| display_settle_delay_ms,
            } });
        },
        .space_changed => {
            log.info("native space changed", .{});
            dispatchStateEvent(.{ .native_space_changed = nativeStateNowMs() });
        },
        .role_poll_tick => {
            reconcileDueGeometryObservations();
            processPendingNativeWindowMoves();
            processPendingNativeWorkspaceMove();
            if (processDueNativeStateObservation()) return;
            if (processDueDisplayResettle()) return;
            if (nativeSwitchPending()) return;
            processPendingRoleWindows();
            processDeferredWindowCandidates();
            processAppLaunchRetries();
            processFocusRetries();
            processPendingFocusQueue();
        },
        .native_topology_poll_tick => reconcileNativeSpaceTopologyIfNeeded(),
        .mouse_down => {
            dispatchStateEvent(.{ .pointer_down = managedWindowAtPoint(g_mouse_down_location) });
        },
        .mouse_dragged => {
            dispatchStateEvent(.pointer_dragged);
            if (g_state.pointer_drag.active_window_id) |wid| {
                log.debug("geometry: pointer drag claimed wid={d}", .{wid});
            }
        },
        .mouse_up => {
            dispatchStateEvent(.pointer_up);

            // Flush windows that were deferred during the drag (tab tear-off guard).
            // Processing them here avoids waiting for the next role_poll_tick.
            processDeferredWindowCandidates();
        },
        .window_moved, .window_resized => {
            // Every animation tick sets the AX frame, which echoes back here
            // as moved/resized notifications (~60/sec per window). Ignore
            // them: reacting would overwrite the stored target frame with a
            // mid-flight position and, for fullscreen windows, trigger a full
            // retile per tick.
            if (g_animator.isAnimatingWindow(ev.wid)) return;

            if (inWorkspaceTransition() and g_state.pointer_drag.active_window_id != ev.wid) {
                if (ev.kind == .window_resized) {
                    clearDragPreview();
                }
                return;
            }

            log.info("window {s} wid={}", .{
                if (ev.kind == .window_moved) "moved" else "resized",
                ev.wid,
            });

            if (managedWindow(ev.wid) == null) return;
            const observed = liveWindowFrame(ev.wid) orelse return;
            dispatchStateEvent(.{ .geometry = .{ .observe = .{
                .process_id = ev.pid,
                .window_id = ev.wid,
                .observed = observed,
                .is_move = ev.kind == .window_moved,
                .at_ns = nanoTimestamp(),
                .dragged_window_id = g_state.pointer_drag.active_window_id,
            } } });
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
            dispatchStateEvent(.toggle_split_mode);
            log.info("split mode: {s}", .{@tagName(g_state.bsp_split_mode)});
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
    const win = managedWindow(wid) orelse return;
    const space = managedWindowSpace(wid) orelse return;
    const layout: ?state_mod.LayoutInsertion = if (win.mode != .tiled and target == .tiled)
        layoutInsertion(space.key, wid) catch return
    else
        null;
    dispatchStateEvent(.{ .set_window_mode = .{
        .window_id = wid,
        .mode = target,
        .layout = layout,
    } });
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
    const visible_wid = g_state.windowTabActive(wid);
    dispatchStateEvent(.{ .toggle_window_fullscreen = .{
        .window_id = wid,
        .observed_frame = liveWindowFrame(visible_wid),
    } });
}

/// Center a floating window on its display and remember the centered position
/// so a later hide/show restores it there. No-op for tiled or fullscreen
/// windows, whose geometry is owned by the layout.
fn centerFloatingWindow(wid: u32) void {
    const space = managedWindowSpace(wid) orelse return;
    const display_slot = displayIndexById(space.display_id) orelse return;
    const display = g_displays[display_slot].visible;
    const visible_wid = g_state.windowTabActive(wid);
    const win = managedWindow(visible_wid) orelse return;
    dispatchStateEvent(.{ .center_floating_window = .{
        .window_id = wid,
        .observed_frame = liveWindowFrame(visible_wid) orelse win.frame,
        .display_frame = .{
            .x = display.x,
            .y = display.y,
            .width = display.w,
            .height = display.h,
        },
    } });
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
    const has_pending = g_state.hasPendingDiscovery() or
        g_state.hasPendingNativeWindowMoves() or
        g_state.pendingNativeWorkspaceMove() != null or
        g_state.hasDeferredFollowFocus() or
        g_state.hasScheduledObservation() or
        g_state.isWorkspaceTransitionActive() or
        g_state.hasDisplayResettleScheduled() or
        g_event_overflow_recovery_pending or
        g_state.geometry.hasPendingResamples();
    setRolePolling(has_pending);
}

fn rollbackNativeWindowMove(wid: u32, pending: state_mod.PendingNativeWindowMove) bool {
    const win = managedWindow(wid) orelse return true;
    const current_space = managedWindowSpace(win.wid) orelse return true;
    if (!current_space.key.eql(pending.target.key)) return true;

    if (g_state.space(pending.source.key) == null) return false;
    if (g_state.space(pending.target.key) == null) return false;
    return moveTabGroupToNativeSpace(wid, pending.source);
}

fn processPendingNativeWindowMoves() void {
    if (!g_state.hasPendingNativeWindowMoves()) return;

    const snapshot = g_state.pending_native_window_moves;
    for (snapshot.items()) |pending| {
        const wid = pending.window_id;
        const win = managedWindow(wid);
        const managed = g_state.window(wid);
        const observation: state_mod.NativeWindowMoveObservation = if (win == null)
            .window_missing
        else if (managed == null or !managed.?.space_key.eql(pending.target.key))
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
    const moved_ref = g_state.space(pending.target.key) orelse return;
    _ = g_state.space(pending.source.key) orelse return;

    assertDisplayCoverage();
    retile();
    updateStatusBar();
    focusWorkspaceWindow(moved_ref);
}

/// Full reconcile after a topology change: rebuild display/workspace state,
/// pick up windows, retile, refresh the bar.
fn reconcileDisplays() void {
    reconcileDisplayChange();
    reconcileNativeWindowAssignmentsFromWindowServer(false);
    discoverWindows();
    retile();
    updateStatusBar();
}

const NativeSpaceCapacity = struct {
    total_count: u16,
    excess_space_id: ?u64,
};

fn nativeSpaceCapacity() ?NativeSpaceCapacity {
    var snapshot = g_sky.?.nativeSpaceTopology() orelse return null;
    defer snapshot.deinit();

    var total: u16 = 0;
    var excess_space_id: ?u64 = null;
    var remaining_required: u16 = workspaceCount();
    const display_indices = stableDisplayIndices();
    for (display_indices[0..g_display_count], 0..) |display_index, order_index| {
        const display = g_displays[display_index];
        const count: u16 = snapshot.ordinarySpaceCount(display.id) orelse return null;
        total = std.math.add(u16, total, count) catch return null;

        const later_display_count: u16 = @intCast(g_display_count - order_index - 1);
        if (remaining_required <= later_display_count) return null;
        const permitted_count = @min(count, remaining_required - later_display_count);
        remaining_required -= permitted_count;
        if (excess_space_id != null or count <= permitted_count) continue;

        excess_space_id = snapshot.ordinarySpaceIdAtOrdinal(display.id, @intCast(count)) orelse return null;
    }
    return .{ .total_count = total, .excess_space_id = excess_space_id };
}

fn reconcileNativeSpaceCapacity() bool {
    const required_count: u16 = workspaceCount();
    var capacity = nativeSpaceCapacity() orelse return false;

    const sky = &g_sky.?;
    const display_id = primaryDisplayId();
    if (capacity.total_count < required_count) {
        log.info("creating missing Mission Control Spaces required={d} available={d} display={d}", .{
            required_count,
            capacity.total_count,
            display_id,
        });
    }

    while (capacity.total_count < required_count) {
        const space_id = sky.createNativeSpace(display_id) orelse {
            log.warn("native Space creation failed display={d}", .{display_id});
            return false;
        };

        var observed_capacity = capacity;
        var attempt: u8 = 0;
        while (attempt < native_space_capacity_settle_attempts) : (attempt += 1) {
            _ = c.usleep(native_space_capacity_poll_delay_us);
            observed_capacity = nativeSpaceCapacity() orelse continue;
            if (observed_capacity.total_count > capacity.total_count) break;
        }
        if (observed_capacity.total_count <= capacity.total_count) {
            log.warn("created native Space did not enter managed topology display={d} space={d}", .{
                display_id,
                space_id,
            });
            return false;
        }

        capacity = observed_capacity;
        log.info("created Mission Control Space display={d} space={d} available={d}", .{
            display_id,
            space_id,
            capacity.total_count,
        });
    }

    if (capacity.total_count > required_count) {
        log.info("removing excess Mission Control Spaces required={d} available={d}", .{
            required_count,
            capacity.total_count,
        });
    }

    while (capacity.total_count > required_count) {
        const space_id = capacity.excess_space_id orelse {
            log.warn("native Space removal found no removable excess Space", .{});
            return false;
        };
        if (!sky.destroyNativeSpace(space_id)) {
            log.warn("native Space removal failed space={d}", .{space_id});
            return false;
        }

        var observed_capacity = capacity;
        var attempt: u8 = 0;
        while (attempt < native_space_capacity_settle_attempts) : (attempt += 1) {
            _ = c.usleep(native_space_capacity_poll_delay_us);
            observed_capacity = nativeSpaceCapacity() orelse continue;
            if (observed_capacity.total_count < capacity.total_count) break;
        }
        if (observed_capacity.total_count >= capacity.total_count) {
            log.warn("destroyed native Space did not leave managed topology space={d}", .{space_id});
            return false;
        }

        capacity = observed_capacity;
        log.info("removed Mission Control Space space={d} available={d}", .{
            space_id,
            capacity.total_count,
        });
    }
    return true;
}

fn reconcileNativeSpaceTopologyIfNeeded() void {
    if (nativeSwitchPending()) return;
    if (g_state.hasPendingNativeWindowMoves()) return;
    if (g_state.pendingNativeWorkspaceMove() != null) return;
    if (g_state.isWorkspaceTransitionActive()) return;
    if (g_state.hasDisplayResettleScheduled()) return;

    const capacity = nativeSpaceCapacity() orelse return;
    if (capacity.total_count != workspaceCount()) {
        log.info("native Space count changed required={d} available={d}", .{
            workspaceCount(),
            capacity.total_count,
        });
        if (!reconcileNativeSpaceCapacity()) {
            log.warn("live native Space capacity reconciliation failed", .{});
            return;
        }
        reconcileDisplays();
        return;
    }

    const topology = captureNativeTopology() orelse return;
    if (g_state.native_topology.eql(&topology)) return;

    log.info("native Space topology changed", .{});
    reconcileDisplays();
}

fn captureNativeTopology() ?state_mod.NativeTopology {
    const sky = &g_sky.?;
    var snapshot = sky.nativeSpaceTopology() orelse {
        log.warn("native topology: WindowServer snapshot unavailable", .{});
        return null;
    };
    defer snapshot.deinit();

    var observation: state_mod.NativeTopologyObservation = .{};
    var captured_space_count: u16 = 0;
    const display_indices = stableDisplayIndices();
    for (display_indices[0..g_display_count]) |display_index| {
        const display = g_displays[display_index];
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
        captured_space_count += captured_count;

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
    if (captured_space_count < workspaceCount()) {
        log.warn("native topology: configured workspaces exceed ordinary Spaces configured={d} available={d}", .{
            workspaceCount(),
            captured_space_count,
        });
        return null;
    }

    return state_mod.mapNativeTopology(
        observation,
        &g_state.native_topology,
        &g_state.workspace_topology,
        &g_state.spaces,
        workspaceCount(),
        primaryDisplayId(),
    );
}

fn dispatchStateEvent(event: state_mod.Event) void {
    const transition = state_mod.reduce(g_state, event);
    g_state = transition.model;

    for (transition.effects[0..transition.effect_count]) |effect| {
        if (!g_state_effect_queue.push(effect)) @panic("state effect queue overflow");
    }

    drainStateEffects();
}

fn drainStateEffects() void {
    if (g_state_effect_drain_active) return;

    g_state_effect_drain_active = true;
    defer g_state_effect_drain_active = false;

    while (g_state_effect_queue.pop()) |effect| {
        executeStateEffect(effect);
    }
    refreshRolePolling();
}

fn executeStateEffect(effect: state_mod.Effect) void {
    switch (effect) {
        .switch_native_space => |value| executeNativeSwitch(value),
        .cancel_native_gesture => |direction| {
            if (!skylight.postDockSwipe(.ended, direction, 0)) log.warn("native gesture cancellation failed", .{});
        },
        .post_native_gesture => |value| executeNativeGesture(value),
        .schedule_native_gesture => |epoch| scheduleNativeGesture(epoch),
        .observe_native_topology => |epoch| observeNativeTopology(epoch),
        .native_switch_completed => |value| completeNativeSwitch(value.space, value.epoch),
        .native_switch_failed => |value| failNativeSwitch(value),
        .native_topology_changed => reconcileObservedNativeTopology(),
        .workspace_switch_ready => |workspace_switch| executeWorkspaceSwitch(workspace_switch),
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
        .move_native_window => |pending| executeNativeWindowMove(pending),
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
        .pending_role_ready => |candidate| executePendingRoleReady(candidate),
        .pending_role_expired => |candidate| log.info("pending-role: gave up pid={d} wid={d} after {d}ms", .{
            candidate.process_id,
            candidate.window_id,
            @as(u64, role_poll_attempts_max) * role_poll_interval_ms,
        }),
        .deferred_window_ready => |candidate| executeDeferredWindowReady(candidate),
        .deferred_window_expired => |expired| log.info("deferred-window: gave up pid={d} wid={d} after {d}ms reason={s}", .{
            expired.candidate.process_id,
            expired.candidate.window_id,
            @as(u64, role_poll_attempts_max) * role_poll_interval_ms,
            @tagName(expired.reason),
        }),
        .app_launch_retry_ready => |process_id| executeAppLaunchRetry(process_id),
        .focus_retry_resolved => |resolved| {
            log.info("focus-retry: resolved pid={d} wid={d}", .{ resolved.process_id, resolved.window_id });
            reconcileFocusedWindow(resolved.process_id, resolved.window_id);
        },
        .focus_retry_expired => |process_id| log.debug("focus-retry: gave up pid={d}", .{process_id}),
        .display_resettle_due => {
            log.info("display resettle", .{});
            reconcileDisplays();
        },
        .reconcile_displays => {
            log.info("display changed", .{});
            reconcileDisplays();
        },
        .focus_window => |focus| {
            _ = bw_ax_focus_window(focus.process_id, focus.window_id);
            const window = managedWindow(focus.window_id) orelse return;
            observeWindowFocus(window, .keyboard, null);
        },
        .windows_swapped => |swap| log.info("swap {s}: wid={d} <-> wid={d}", .{
            @tagName(swap.direction),
            swap.first_window_id,
            swap.second_window_id,
        }),
        .window_mode_changed => |change| log.info("window {d} mode: {s} → {s}", .{
            change.window_id,
            @tagName(change.previous),
            @tagName(change.current),
        }),
        .fullscreen_changed => |fullscreen| executeFullscreenChanged(fullscreen),
        .center_window => |center| executeCenterWindow(center),
        .window_moved => |move| executeWindowMoved(move),
        .show_drag_preview => |frame| tile_preview.show(frame.x, frame.y, frame.width, frame.height),
        .hide_drag_preview => tile_preview.hide(),
        .pointer_drag_completed => |completion| {
            if (completion.swapped_window_ids) |swapped| {
                log.info("window move swap wid={d} target={d}", .{ swapped.first, swapped.second });
            }
            if (completion.should_retile) retile();
        },
        .retile_requested => |request| executeRetileRequest(request),
        .cleanup_requested => |request| executeCleanupRequest(request),
        .cleanup_request_overflow => |process_id| {
            log.warn("cleanup: pid queue saturated, scheduling broad reconciliation pid={d}", .{process_id});
            g_event_overflow_recovery_pending = true;
        },
        .geometry => |geometry_effect| executeGeometryEffect(geometry_effect),
        .layout => |layout_effect| executeLayoutEffect(layout_effect),
    }
}

fn executeFullscreenChanged(fullscreen: state_mod.FullscreenEffect) void {
    if (fullscreen.restore_frame) |target| {
        const visible = managedWindow(fullscreen.window_id) orelse return;
        const succeeded = applyWindowFrame(
            fullscreen.process_id,
            fullscreen.window_id,
            visible.frame,
            target,
            false,
            .floating_restore,
        );
        dispatchStateEvent(.{ .window_frame_command_result = .{
            .leader_window_id = fullscreen.leader_window_id,
            .window_id = fullscreen.window_id,
            .target_frame = target,
            .should_save_float_frame = false,
            .succeeded = succeeded,
        } });
        if (succeeded) applyFrameToTabGroup(fullscreen.leader_window_id, target);
    }
    log.info("fullscreen {s} wid={d} mode={s}", .{
        if (fullscreen.is_fullscreen) "on" else "off",
        fullscreen.leader_window_id,
        @tagName(fullscreen.mode),
    });
}

fn executeCenterWindow(center: state_mod.CenterWindowEffect) void {
    const succeeded = setWindowFrameTracked(center.process_id, center.window_id, center.target_frame, .user_command);
    dispatchStateEvent(.{ .window_frame_command_result = .{
        .leader_window_id = center.leader_window_id,
        .window_id = center.window_id,
        .target_frame = center.target_frame,
        .should_save_float_frame = true,
        .succeeded = succeeded,
    } });
    if (!succeeded) {
        log.warn("center floating: frame write rejected wid={d}", .{center.window_id});
        return;
    }
    applyFrameToTabGroup(center.leader_window_id, center.target_frame);
    log.info("center floating wid={d} → x={d:.0} y={d:.0}", .{
        center.window_id,
        center.target_frame.x,
        center.target_frame.y,
    });
}

fn executeWindowMoved(move: state_mod.WindowMoveEffect) void {
    const current_space = managedWindowSpace(move.window_id) orelse return;
    if (!current_space.key.eql(move.target.key)) return;
    if (move.should_follow_focus) {
        const window = managedWindow(move.window_id) orelse return;
        observeWindowFocus(window, .keyboard, null);
    }
    log.debug("window moved wid={d} source={d} target={d}", .{
        move.window_id,
        move.source.workspace_id,
        move.target.workspace_id,
    });
}

fn executePendingRoleReady(candidate: state_mod.WindowCandidate) void {
    if (!addNewWindowManaged(candidate.process_id, candidate.window_id) and
        managedWindow(candidate.window_id) == null) return;

    retile();
    updateStatusBar();
}

fn executeDeferredWindowReady(candidate: state_mod.WindowCandidate) void {
    if (addNewWindowManaged(candidate.process_id, candidate.window_id) or
        managedWindow(candidate.window_id) != null)
    {
        untrackDeferredWindowCandidate(candidate.window_id);
        retile();
        updateStatusBar();
        return;
    }
    if (!g_state.hasDeferredWindowCandidate(candidate.window_id)) return;
    dispatchStateEvent(.{ .deferred_window_promotion_failed = candidate.window_id });
}

fn executeAppLaunchRetry(process_id: i32) void {
    log.info("app-launch-retry: retrying discovery for pid={d}", .{process_id});
    ax_observer.observeApp(process_id);
    discoverWindows();
    retile();
    updateStatusBar();
}

fn executeRetileRequest(request: state_mod.RetileRequest) void {
    if (request.all_displays) {
        retileAllDisplays();
        return;
    }
    for (request.display_ids[0..request.display_count]) |display_id| {
        retileDisplay(display_id);
    }
}

fn executeCleanupRequest(request: state_mod.CleanupRequest) void {
    var removed_any = false;
    for (request.process_ids[0..request.process_count]) |process_id| {
        if (cleanupWorkspaceWindowsForPid(process_id)) removed_any = true;
    }
    if (request.should_clean_offscreen and cleanupOffscreenManagedWindows()) removed_any = true;
    if (removed_any) requestRetileAllDisplays();
}

fn executeLayoutEffect(effect: tiling.Effect) void {
    switch (effect) {
        .rejected => |rejection| log.warn("layout state rejected wid={d} reason={s}", .{
            rejection.window_id orelse 0,
            @tagName(rejection.reason),
        }),
    }
}

fn executeGeometryEffect(effect: geometry_mod.Effect) void {
    switch (effect) {
        .observed => |observation| executeWindowGeometryObserved(observation),
        .settled => |observation| executeWindowGeometrySettled(observation),
        .rejected => |rejection| log.warn("geometry state rejected wid={d} reason={s}", .{
            rejection.window_id,
            @tagName(rejection.reason),
        }),
    }
}

fn executeWindowGeometryObserved(
    observation: @FieldType(geometry_mod.Effect, "observed"),
) void {
    if (observation.owner == .manager) {
        log.debug("geometry: ignored manager echo wid={d}", .{observation.window_id});
        return;
    }
    if (observation.owner == .external) {
        handleExternalWindowGeometry(observation.window_id, observation.frame);
        return;
    }

    const tab_dragged_out = checkTabDragOut(observation.process_id, observation.window_id);
    const layout_wid = g_state.windowTabLeader(observation.window_id);

    if (updateDraggedWindowGeometry(observation.window_id, observation.frame)) {
        retile();
        return;
    }
    if (tab_dragged_out) {
        if (managedWindow(layout_wid)) |win| {
            observeWindowFocus(win, .drag, null);
        }
        retile();
    }
    if (managedWindow(layout_wid)) |win| {
        if (win.is_fullscreen) {
            retile();
            return;
        }
    }
    if (g_state.pointer_drag.active_window_id == observation.window_id) {
        if (managedWindow(layout_wid)) |win| {
            const space = managedWindowSpace(win.wid) orelse return;
            if (win.mode == .tiled and !win.is_fullscreen and spaceVisible(space)) {
                dispatchStateEvent(.{ .pointer_geometry_reconcile_requested = observation.window_id });
            }
        }
    }
    if (observation.is_move) {
        updateWindowMovePreview(layout_wid);
    } else {
        clearDragPreview();
    }
}

fn executeWindowGeometrySettled(
    observation: @FieldType(geometry_mod.Effect, "settled"),
) void {
    switch (observation.owner) {
        .manager => return,
        .manager_unsettled => {
            const intent = observation.pending_intent orelse return;
            if (reconcileDivergedGeometryIntent(observation.window_id, intent)) return;

            switch (intent.target) {
                .frame => |target| log.warn("geometry: frame intent did not converge wid={d} source={s} target=({d:.0},{d:.0},{d:.0},{d:.0}) observed=({d:.0},{d:.0},{d:.0},{d:.0})", .{
                    observation.window_id,
                    @tagName(intent.source),
                    target.x,
                    target.y,
                    target.width,
                    target.height,
                    observation.frame.x,
                    observation.frame.y,
                    observation.frame.width,
                    observation.frame.height,
                }),
                .position => |target| log.warn("geometry: position intent did not converge wid={d} source={s} target=({d:.0},{d:.0}) observed=({d:.0},{d:.0})", .{
                    observation.window_id,
                    @tagName(intent.source),
                    target.x,
                    target.y,
                    observation.frame.x,
                    observation.frame.y,
                }),
            }
            return;
        },
        .external => handleExternalWindowGeometry(observation.window_id, observation.frame),
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

fn executeNativeWindowMove(pending: state_mod.PendingNativeWindowMove) void {
    if (moveTabGroupToNativeSpace(pending.window_id, pending.target)) return;

    log.warn("native window move: initial write failed wid={d} workspace={d}", .{
        pending.window_id,
        pending.target.workspace_id,
    });
    executeNativeWindowMoveRollback(pending);
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
    const layout: ?state_mod.LayoutInsertion = if (g_state.layout.contains(pending.target.key, pending.window_id))
        layoutInsertion(pending.source.key, pending.window_id) catch null
    else
        null;
    const succeeded = rollbackNativeWindowMove(pending.window_id, pending);
    dispatchStateEvent(.{ .native_window_move_rollback_result = .{
        .window_id = pending.window_id,
        .epoch = pending.epoch,
        .succeeded = succeeded,
        .layout = layout,
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
    const pending = g_state.pending_switch orelse return;
    if (pending.epoch != effect.epoch or pending.phase != .preparing) return;
    const request = effect.request;
    const native_space_id = request.target.key.id;
    const plan = g_sky.?.prepareNativeSpaceSwitch(request.target.display_id, native_space_id) orelse {
        dispatchStateEvent(.{ .native_switch_effect_failed = .{
            .epoch = effect.epoch,
            .at_ms = nativeStateNowMs(),
        } });
        return;
    };

    dispatchStateEvent(.{ .native_gesture_prepared = .{
        .epoch = effect.epoch,
        .plan = plan,
        .at_ms = nativeStateNowMs(),
    } });

    log.debug("native workspace switch requested epoch={d} display={d} workspace={d} space={d}", .{
        effect.epoch,
        request.target.display_id,
        request.target.workspace_id,
        native_space_id,
    });
    updateStatusBar();
}

fn executeNativeGesture(effect: @FieldType(state_mod.Effect, "post_native_gesture")) void {
    const pending = g_state.pending_switch orelse return;
    if (pending.epoch != effect.epoch or pending.phase != .delivering) return;
    const gesture = pending.gesture orelse return;
    if (gesture.phase != effect.phase or gesture.due_at_ms != null) return;

    const succeeded = skylight.postDockSwipe(effect.phase, effect.direction, effect.velocity);
    dispatchStateEvent(.{ .native_gesture_posted = .{
        .epoch = effect.epoch,
        .phase = effect.phase,
        .succeeded = succeeded,
        .at_ms = nativeStateNowMs(),
    } });
}

fn scheduleNativeGesture(epoch: state_mod.Epoch) void {
    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, @import("native_gesture.zig").phase_delay_ms * std.time.ns_per_ms),
        cg_extra.dispatch_get_main_queue(),
        @ptrFromInt(epoch),
        nativeGestureTimerFired,
    );
}

fn nativeGestureTimerFired(context: ?*anyopaque) callconv(.c) void {
    dispatchStateEvent(.{ .native_gesture_timer_fired = .{
        .epoch = @intFromPtr(context),
        .at_ms = nativeStateNowMs(),
    } });
}

fn executeWorkspaceSwitch(workspace_switch: state_mod.WorkspaceSwitchEffect) void {
    updateStatusBar();
    focusWorkspaceWindow(workspace_switch.target);
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
        .is_animating = if (g_state.pending_switch) |pending|
            g_sky.?.nativeDisplayIsAnimating(pending.request.target.display_id)
        else
            null,
    } });
}

fn completeNativeSwitch(space: state_mod.SpaceRef, epoch: state_mod.Epoch) void {
    const started_ns = nanoTimestamp();
    if (g_state.space(space.key) == null) return;

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
        failure.request.target.key.id,
        @tagName(failure.reason),
        if (failure.actual) |actual| actual.key.id else 0,
        if (failure.actual) |actual| actual.workspace_id else 0,
    });
    reconcileObservedNativeTopology();
}

fn reconcileObservedNativeTopology() void {
    const started_ns = nanoTimestamp();
    reconcileNativeWindowAssignmentsFromWindowServer(true);
    discoverWindows();
    retile();
    updateStatusBar();

    const elapsed_ms = @divTrunc(nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] native topology reconcile elapsed_ms={}", .{elapsed_ms});
}

fn reconcileNativeWindowAssignmentsFromWindowServer(should_require_visible: bool) void {
    const sky = &g_sky.?;
    var topology = sky.nativeSpaceTopology() orelse {
        log.warn("native workspace reconcile could not snapshot window assignments", .{});
        return;
    };
    defer topology.deinit();

    const on_screen = if (should_require_visible) OnScreenWindows.snapshot() else OnScreenWindows{};
    if (should_require_visible and on_screen.truncated) return;
    var repairs: [256]struct { wid: u32, target: state_mod.SpaceRef } = undefined;
    var repair_count: usize = 0;

    for (g_state.windows.items()) |managed_window| {
        const win = managed_window.snapshot();
        const managed = g_state.window(win.wid) orelse continue;
        if (g_state.windowTabLeader(win.wid) != win.wid) continue;
        if (g_state.pendingNativeWindowMove(win.wid) != null) continue;
        const visible_wid = g_state.windowTabActive(win.wid);
        if (should_require_visible and !on_screen.contains(visible_wid)) continue;

        const target = nativeWorkspaceForWindowInTopology(&topology, visible_wid) orelse continue;
        if (managed.space_key.eql(target.key)) continue;
        if (repair_count == repairs.len) {
            log.warn("native workspace assignment repair truncated limit={d}", .{repairs.len});
            break;
        }
        repairs[repair_count] = .{ .wid = win.wid, .target = target };
        repair_count += 1;
    }

    for (repairs[0..repair_count]) |repair| {
        reassignManagedWindowToNativeWorkspace(repair.wid, repair.target);
    }
}

fn nativeWorkspaceForWindowInTopology(
    topology: *const skylight.NativeSpaceTopology,
    wid: u32,
) ?state_mod.SpaceRef {
    const sky = &g_sky.?;
    for (g_displays[0..g_display_count]) |display| {
        const space_id = topology.spaceIdForWindow(sky, wid, display.id) orelse continue;
        return g_state.space(.{ .id = space_id });
    }
    return null;
}

fn reassignManagedWindowToNativeWorkspace(wid: u32, target: state_mod.SpaceRef) void {
    const win = managedWindow(wid) orelse return;
    const managed = g_state.window(win.wid) orelse return;
    if (managed.space_key.eql(target.key)) return;

    const target_ws = g_state.space(target.key) orelse return;
    if (!assignManagedWindowSpace(wid, target_ws)) return;

    if (focusedWorkspaceWindow(target_ws) == null) recordWorkspaceFocus(target_ws, wid);

    log.debug("native workspace assignment repaired wid={d} source_space={d} target={d}", .{
        wid,
        managed.space_key.id,
        target.workspace_id,
    });
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

/// On a role-poll tick, run the trailing reconcile once the arrangement has
/// been quiet for the settle delay. Returns true when it fired so the tick
/// skips the rest of its work this round.
fn processDueDisplayResettle() bool {
    const due_at_ms = g_state.display_resettle_due_at_ms orelse return false;
    const at_ms = nativeStateNowMs();
    if (at_ms < due_at_ms) return false;

    dispatchStateEvent(.{ .display_resettle_timer_fired = at_ms });
    return true;
}

/// Track a pid whose AX focused-window query returned nothing. Electron apps
/// (Discord) publish AXFocusedWindow late after activation; without a retry
/// the focus event is dropped and workspace focus state silently desyncs.
fn trackFocusRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    dispatchStateEvent(.{ .track_focus_retry = .{
        .process_id = pid,
        .attempts_remaining = focus_retry_attempts_max,
    } });
}

fn untrackFocusRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    dispatchStateEvent(.{ .untrack_focus_retry = pid });
}

/// Re-query the AX focused window for tracked pids on the role-poll cadence.
/// Resolved pids run the normal focus reconciliation path; exhausted pids are
/// dropped (the next real focus event will try again).
fn processFocusRetries() void {
    const retries = g_state.focus_retries;
    for (retries.items()) |retry| {
        dispatchStateEvent(.{ .focus_retry_observed = .{
            .process_id = retry.process_id,
            .focused_window_id = bw_ax_get_focused_window(retry.process_id),
        } });
    }
}

fn trackAppLaunchRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    dispatchStateEvent(.{ .track_app_launch_retry = .{
        .process_id = pid,
        .attempts_remaining = app_launch_retry_attempts_max,
    } });
}

fn untrackAppLaunchRetry(pid: i32) void {
    std.debug.assert(pid > 0);
    dispatchStateEvent(.{ .untrack_app_launch_retry = pid });
}

fn processAppLaunchRetries() void {
    const retries = g_state.app_launch_retries;
    for (retries.items()) |retry| {
        dispatchStateEvent(.{ .app_launch_retry_timer_fired = retry.process_id });
    }
}

fn trackPendingRoleWindow(pid: i32, wid: u32, space: state_mod.SpaceRef) void {
    std.debug.assert(wid != 0);
    space.assertValid();
    dispatchStateEvent(.{ .track_pending_role_window = .{
        .process_id = pid,
        .window_id = wid,
        .space_key = space.key,
        .attempts_remaining = role_poll_attempts_max,
    } });
}

fn untrackPendingRoleWindow(wid: u32) void {
    std.debug.assert(wid != 0);
    dispatchStateEvent(.{ .untrack_pending_role_window = wid });
}

fn forgetGeometryIfUnmanaged(wid: u32) void {
    if (managedWindow(wid) != null) return;
    if (g_state.hasPendingRoleWindow(wid)) return;
    if (g_state.hasDeferredWindowCandidate(wid)) return;
    dispatchStateEvent(.{ .geometry = .{ .forget = wid } });
}

fn trackDeferredWindowCandidate(pid: i32, wid: u32, space: state_mod.SpaceRef) void {
    std.debug.assert(wid != 0);
    space.assertValid();
    dispatchStateEvent(.{ .track_deferred_window_candidate = .{
        .process_id = pid,
        .window_id = wid,
        .space_key = space.key,
        .attempts_remaining = role_poll_attempts_max,
    } });
}

fn untrackDeferredWindowCandidate(wid: u32) void {
    std.debug.assert(wid != 0);
    dispatchStateEvent(.{ .untrack_deferred_window_candidate = wid });
}

fn untrackWindowCandidatesForPid(pid: i32) void {
    dispatchStateEvent(.{ .untrack_window_candidates_for_process = pid });
}

fn processPendingRoleWindows() void {
    const candidates = g_state.pending_role_windows;
    const started_ns = nanoTimestamp();
    for (candidates.items()) |candidate| {
        if (nanoTimestamp() - started_ns >= role_poll_work_budget_ms * std.time.ns_per_ms) return;
        dispatchStateEvent(.{ .pending_role_observed = .{
            .window_id = candidate.window_id,
            .readiness = windowRoleStateWithMessagingTimeout(candidate.process_id, candidate.window_id),
        } });
    }
}

fn processDeferredWindowCandidates() void {
    const candidates = g_state.deferred_window_candidates;
    for (candidates.items()) |candidate| {
        dispatchStateEvent(.{ .deferred_window_observed = .{
            .window_id = candidate.window_id,
            .readiness = windowRoleState(candidate.process_id, candidate.window_id),
            .is_visible = isVisibleOnScreen(candidate.window_id),
        } });
    }
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

        if (managedWindow(info.wid) != null) continue;

        const frame: window_mod.Window.Frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h };
        const discovered_display = displayIdForFrame(frame);
        const target_ws = resolveWorkspaceForWindow(info.pid, info.wid, discovered_display) orelse {
            log.debug("discover: ignored pid={d} wid={d} on unmanaged native Space", .{ info.pid, info.wid });
            continue;
        };
        // A landing must not wait on an app's AX server. The role poll applies
        // the same gate after the switch path is free to accept more input.
        if (should_refresh_tabs) {
            trackPendingRoleWindow(info.pid, info.wid, target_ws);
            continue;
        }

        switch (windowRoleState(info.pid, info.wid)) {
            .reject => {
                untrackPendingRoleWindow(info.wid);
                continue;
            },
            .pending => {
                trackPendingRoleWindow(info.pid, info.wid, target_ws);
                continue;
            },
            .ready => {
                untrackPendingRoleWindow(info.wid);
                // Degenerate discovery bounds mean the window is still
                // mid-construction. Defer for bounded re-evaluation instead
                // of storing a garbage frame that would be tiled at zero size.
                // Deliberately not untracked first: tracking an
                // existing candidate preserves its remaining retry budget.
                if (frame.width <= 1 or frame.height <= 1) {
                    trackDeferredWindowCandidate(info.pid, info.wid, target_ws);
                    log.info("discover: deferred pid={d} wid={d} unsettled bounds", .{ info.pid, info.wid });
                    continue;
                }
                untrackDeferredWindowCandidate(info.wid);
            },
        }

        const source_ws = nativeWorkspaceForWindow(info.wid, discovered_display) orelse {
            trackDeferredWindowCandidate(info.pid, info.wid, target_ws);
            log.info("discover: deferred pid={d} wid={d} unsettled native Space", .{ info.pid, info.wid });
            continue;
        };

        const win = window_mod.Window{
            .wid = info.wid,
            .pid = info.pid,
            .frame = frame,
            .mode = .tiled,
        };

        adoptWindow(target_ws, win) catch |err| {
            log.err("discover: failed to adopt pid={d} wid={d}: {}", .{ info.pid, info.wid, err });
            continue;
        };
        adopted_count += 1;

        if (!source_ws.key.eql(target_ws.key)) requestNativeWindowMove(info.wid, source_ws, target_ws);
    }

    // Ensure a focused window is set on the active workspace
    const active_ws = activeWorkspace();
    const active_windows = workspaceWindows(active_ws);
    if (focusedWorkspaceWindow(active_ws) == null and active_windows.items().len > 0) {
        recordWorkspaceFocus(active_ws, active_windows.items()[0]);
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

/// Snapshot the managed windows of `pid` used for tab detection.
///
/// Every OS query the heuristics need happens here, so the decisions themselves
/// stay pure. `owns_workspace_slot` is the inverse of suppression: a group's
/// leader holds the slot; its other members are suppressed.
fn tabCandidates(
    pid: i32,
    on_screen: *const OnScreenWindows,
    out: []tab_detect.Candidate,
) BoundedSnapshotResult {
    std.debug.assert(pid > 0);

    var count: usize = 0;
    var truncated = false;
    for (g_state.windows.items()) |managed_window| {
        const win = managed_window.snapshot();
        if (win.pid != pid) continue;
        if (count == out.len) {
            truncated = true;
            break;
        }

        const space = managedWindowSpace(win.wid) orelse continue;
        const on_visible_workspace = spaceVisible(space);
        out[count] = .{
            .wid = win.wid,
            .pid = win.pid,
            .live_frame = liveWindowFrame(win.wid),
            .is_visible_on_screen = on_visible_workspace and on_screen.contains(win.wid),
            .owns_workspace_slot = !g_state.isWindowTabSuppressed(win.wid),
        };
        count += 1;
    }
    return .{ .count = count, .truncated = truncated };
}

/// Snapshot the windows an application exposes in its AX window list.
fn appWindowSnapshot(
    pid: i32,
    on_screen: *const OnScreenWindows,
    out: []tab_detect.AppWindow,
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
            .is_managed = managedWindow(ax_wid) != null,
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
    if (managedWindow(wid) != null) {
        log.debug("addNewWindow: already managed, skipping", .{});
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
    // Proceeding would record garbage geometry. Track before the untrack-defer
    // below so bounded re-evaluation survives this early return.
    if (g_sky != null and (window_frame.width <= 1 or window_frame.height <= 1)) {
        trackDeferredWindowCandidate(pid, wid, assigned_space);
        log.info("addNewWindow: deferred pid={d} wid={d} unsettled bounds", .{ pid, wid });
        return false;
    }

    const source_display_id = inferDisplayIdForWindow(wid) orelse display_id;
    const source_ws = nativeWorkspaceForWindow(wid, source_display_id) orelse {
        trackDeferredWindowCandidate(pid, wid, assigned_space);
        log.info("addNewWindow: deferred pid={d} wid={d} unsettled native Space", .{ pid, wid });
        return false;
    };

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

    const ws = g_state.space(assigned_space.key) orelse return false;
    const mode: window_mod.WindowMode = if (should_float) .floating else .tiled;

    const win = window_mod.Window{
        .wid = wid,
        .pid = pid,
        .frame = window_frame,
        .mode = mode,
    };

    adoptWindow(ws, win) catch |err| {
        log.err("addNewWindow: failed to adopt pid={d} wid={d}: {}", .{ pid, wid, err });
        return false;
    };
    recordWorkspaceFocus(ws, wid);

    if (!source_ws.key.eql(ws.key)) requestNativeWindowMove(wid, source_ws, ws);

    const float_reason = if (mode == .tiled) "tiled" else if (rule_float) "floated (app rule)" else "floated (undersized+non-resizable)";
    log.info("addNewWindow: {s} wid={d} on workspace {d}", .{ float_reason, wid, ws.workspace_id });
    return true;
}

fn addNewWindowManaged(pid: i32, wid: u32) bool {
    // Prefer the window's actual on-screen position over the currently
    // focused display: a torn-off tab dropped on another monitor must land
    // on the workspace that owns the destination monitor, not on whichever
    // display happened to be focused when the window was created.
    const display_id = inferDisplayIdForWindow(wid) orelse focusedDisplayId();
    const ws = resolveWorkspaceForWindow(pid, wid, display_id) orelse {
        log.debug("addNewWindow: ignored pid={d} wid={d} on unmanaged native Space", .{ pid, wid });
        return false;
    };

    // A rule-pinned app's transient launch position is meaningless: place it
    // on the display that currently owns its assigned workspace, not wherever
    // it happened to launch.
    return addNewWindowManagedWithAssignment(pid, wid, ws);
}

fn addNewWindow(pid: i32, wid: u32) void {
    std.debug.assert(wid != 0);
    if (managedWindow(wid) != null) return;

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
            const ws = resolveWorkspaceForWindow(pid, wid, display_id) orelse {
                log.debug("addNewWindow: ignored pending pid={d} wid={d} on unmanaged native Space", .{ pid, wid });
                return;
            };
            trackPendingRoleWindow(pid, wid, ws);
            trackDeferredWindowCandidate(pid, wid, ws);
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
    const on_screen = OnScreenWindows.snapshot();
    refreshTabGroupActiveTabsFromSnapshot(&on_screen);
}

fn refreshTabGroupActiveTabsFromSnapshot(on_screen: *const OnScreenWindows) void {
    if (on_screen.truncated) return;

    var leader_window_ids: [state_mod.max_managed_windows]u32 = undefined;
    const group_leaders = g_state.windowTabGroupLeaderIds(&leader_window_ids);
    if (group_leaders.len == 0) return;

    const Move = struct { leader_window_id: u32, active_window_id: u32, selected_window_id: u32 };
    var moves: [state_mod.max_managed_windows]Move = undefined;
    var move_count: usize = 0;
    for (group_leaders) |leader_window_id| {
        const group = g_state.windowTabGroup(leader_window_id) orelse continue;
        const leader = managedWindow(group.leader_window_id) orelse continue;
        const leader_space = managedWindowSpace(leader.wid) orelse continue;
        // A group on another physical Space is off-screen on purpose.
        if (!spaceVisible(leader_space)) continue;
        if (on_screen.contains(group.active_window_id)) continue;

        var app_windows: [128]tab_detect.AppWindow = undefined;
        const app_snapshot = appWindowSnapshot(group.process_id, on_screen, &app_windows);
        if (app_snapshot.truncated) {
            log.warn("tab refresh skipped: AX window snapshot truncated pid={d} limit={d}", .{ group.process_id, app_windows.len });
            continue;
        }
        const selected = tab_detect.selectedTabWindow(
            app_windows[0..app_snapshot.count],
            leader.frame,
        ) orelse continue;
        if (selected == group.active_window_id) continue;

        moves[move_count] = .{
            .leader_window_id = group.leader_window_id,
            .active_window_id = group.active_window_id,
            .selected_window_id = selected,
        };
        move_count += 1;
    }

    for (moves[0..move_count]) |move| {
        const group = g_state.windowTabGroup(move.leader_window_id) orelse continue;
        const leader = managedWindow(group.leader_window_id) orelse continue;

        // The user can select a tab Bobrwm has never seen: background tabs are
        // absent from AXWindows, so they are only discovered as they surface.
        if (managedWindow(move.selected_window_id) == null) {
            const leader_space = managedWindowSpace(leader.wid) orelse continue;
            const discovered: window_mod.Window = .{
                .wid = move.selected_window_id,
                .pid = group.process_id,
                .frame = leader.frame,
                .mode = leader.mode,
            };
            const observation = tabGroupObservation(
                group.leader_window_id,
                move.selected_window_id,
                move.selected_window_id,
            ) orelse continue;
            if (!adoptWindowIdentity(discovered, leader_space.key, null, observation)) continue;
        }

        if (g_state.windowTabLeader(move.selected_window_id) != group.leader_window_id) continue;
        log.debug("tab group leader={d} active tab {d} → {d} (tab bar)", .{
            group.leader_window_id, move.active_window_id, move.selected_window_id,
        });
        setTabGroupActive(move.selected_window_id);
    }
}

/// Check whether a window that just appeared — created, or focused while
/// unknown — is a native tab of an already-managed window, and if so hand it
/// the group's slot. Returns true when a group absorbed it, meaning the caller
/// must not manage it as its own window.
///
/// Gathers the OS facts, classifies them, and applies the outcome.
fn tryFormTabGroupOnCreate(pid: i32, new_wid: u32) bool {
    const new_frame = liveWindowFrame(new_wid) orelse return false;
    log.debug("tab detect: new wid={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
        new_wid, new_frame.x, new_frame.y, new_frame.width, new_frame.height,
    });

    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return false;
    var candidates: [128]tab_detect.Candidate = undefined;
    const candidate_snapshot = tabCandidates(pid, &on_screen, &candidates);
    if (candidate_snapshot.truncated) {
        log.warn("tab detect skipped: managed candidate snapshot truncated pid={d} limit={d}", .{ pid, candidates.len });
        return false;
    }

    var app_windows: [128]tab_detect.AppWindow = undefined;
    const app_snapshot = appWindowSnapshot(pid, &on_screen, &app_windows);
    if (app_snapshot.truncated) {
        log.warn("tab detect skipped: AX window snapshot truncated pid={d} limit={d}", .{ pid, app_windows.len });
        return false;
    }
    const has_tab_group = tab_detect.appHasTabGroup(app_windows[0..app_snapshot.count]);

    // Collect before removal so the candidate snapshot stays valid.
    var stale_wids: [128]u32 = undefined;
    const stale_count = tab_detect.staleCandidates(pid, candidates[0..candidate_snapshot.count], &stale_wids);

    const formed = switch (tab_detect.classifyNewWindow(pid, new_wid, new_frame, candidates[0..candidate_snapshot.count], has_tab_group)) {
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
    const sibling = managedWindow(sibling_wid) orelse return false;
    const ws = managedWindowSpace(sibling.wid) orelse return false;
    std.debug.assert(managedWindow(new_wid) == null);

    const member: window_mod.Window = .{
        .wid = new_wid,
        .pid = pid,
        .frame = new_frame,
        .mode = sibling.mode,
    };
    const observation = tabGroupObservation(sibling_wid, new_wid, new_wid) orelse return false;
    if (!adoptWindowIdentity(member, ws.key, null, observation)) return false;

    const leader = g_state.windowTabLeader(sibling_wid);
    const member_count = if (g_state.windowTabGroup(leader)) |group| group.member_count else 1;
    recordWorkspaceFocus(ws, leader);
    log.info("tab group formed pid={d} leader={d} active={d} members={d}", .{
        pid,
        leader,
        new_wid,
        member_count,
    });
    return true;
}

fn removeWindow(wid: u32) void {
    const win = managedWindow(wid) orelse return;
    const space = managedWindowSpace(win.wid) orelse return;
    const tab_group = g_state.windowTabGroup(wid);
    g_animator.cancel(wid);
    ax_mod.invalidateWindow(wid);
    removeWindowIdentity(wid);

    if (tab_group) |group| reconcileTabGroupAfterRemoval(&group, wid);

    _ = focusedWorkspaceWindow(space);
}

fn reconcileTabGroupAfterRemoval(
    previous_group: *const state_mod.WindowTabGroupSnapshot,
    removed_window_id: u32,
) void {
    if (previous_group.member_count <= 2) return;

    for (previous_group.members()) |member_window_id| {
        if (member_window_id == removed_window_id) continue;

        reconcileGroupActiveAfterRemoval(member_window_id, previous_group.process_id);
        return;
    }
}

/// Align a surviving tab group's active tab with the window the app actually
/// focused after a member was removed. Best-effort: when the app has not yet
/// focused the adjacent tab (or AX reports nothing), the members[0] guess
/// stands until the next AXFocusedWindowChanged notification corrects it.
fn reconcileGroupActiveAfterRemoval(member_window_id: u32, pid: i32) void {
    std.debug.assert(member_window_id != 0);
    std.debug.assert(pid > 0);

    const group = g_state.windowTabGroup(member_window_id) orelse return;

    const focused_wid = bw_ax_get_focused_window(pid);
    const app_focused: ?u32 = if (focused_wid == 0) null else focused_wid;
    const active = tab_detect.activeAfterRemoval(app_focused, group.members()) orelse return;

    setTabGroupActive(active);
}

fn removeAppWindows(pid: i32) void {
    untrackWindowCandidatesForPid(pid);
    clearDragPreview();
    var total_removed: usize = 0;

    // Iterate in batches because removeWindow mutates the catalog. Rescan until
    // no matching entries remain; the old single 128-entry batch silently
    // leaked every window above the cap after an app termination.
    while (true) {
        var wids: [128]u32 = undefined;
        var count: usize = 0;

        for (g_state.windows.items()) |managed_window| {
            if (managed_window.process_id != pid) continue;
            if (count == wids.len) break;
            wids[count] = managed_window.window_id;
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
/// stopped process at a time so catalog mutation never overlaps iteration.
fn removeStoppedAppWindows() bool {
    var removed_any = false;
    while (true) {
        const stopped_pid: ?i32 = blk: {
            for (g_state.windows.items()) |managed_window| {
                const win = managed_window.snapshot();
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

    for (g_state.spaces.spaces[0..g_state.spaces.space_count]) |ws| {
        // macOS keeps windows on inactive Spaces off-screen. Only validate the
        // visible Space so native visibility is not mistaken for destruction.
        if (!spaceVisible(ws)) continue;

        const windows = workspaceWindows(ws);
        for (windows.items()) |wid| {
            const win = managedWindow(wid) orelse continue;
            if (win.pid != pid) continue;

            var should_remove = false;
            var rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, wid, &rect) != 0) {
                should_remove = true;
                log.info("cleanup: removing wid={d} pid={d} reason=missing-windowserver", .{ wid, pid });
            } else if (!windowMayRemainManaged(pid, wid)) {
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

    for (g_state.spaces.spaces[0..g_state.spaces.space_count]) |ws| {
        // macOS keeps windows on inactive Spaces off-screen.
        if (!spaceVisible(ws)) continue;

        const windows = workspaceWindows(ws);
        for (windows.items()) |wid| {
            const win = managedWindow(wid) orelse continue;

            // Tab-group members can be intentionally off-screen when a sibling
            // tab is active; treating them as ghosts causes layout churn.
            if (g_state.windowTabGroup(wid) != null) continue;

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

    // Mutations are deferred so the snapshots above stay valid.
    var mutated = false;
    for (suspects[0..suspect_count]) |suspect| {
        const win = managedWindow(suspect.wid) orelse continue;

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
fn adoptWindowAsBackgroundTab(win: window_mod.Window) tab_detect.OffscreenOutcomeKind {
    const frame = liveWindowFrame(win.wid);

    const on_screen = OnScreenWindows.snapshot();
    if (on_screen.truncated) return .keep;
    var app_windows: [128]tab_detect.AppWindow = undefined;
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

    var candidates: [128]tab_detect.Candidate = undefined;
    const candidate_snapshot = tabCandidates(win.pid, &on_screen, &candidates);
    if (candidate_snapshot.truncated) {
        log.warn("background-tab adoption skipped: candidate snapshot truncated pid={d} limit={d}", .{ win.pid, candidates.len });
        return .keep;
    }

    const has_tab_group = tab_detect.appHasTabGroup(app_windows[0..app_snapshot.count]);
    const sibling_wid = switch (tab_detect.classifyOffscreenManaged(
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

    if (managedWindow(sibling_wid) == null) return .reap;
    if (!attachWindowToTabGroup(sibling_wid, win.wid, sibling_wid)) return .reap;

    var updated = win;
    if (frame) |f| updated.frame = f;
    _ = updateManagedWindow(updated);

    log.info("cleanup: adopted wid={d} as background tab, leader={d} pid={d}", .{
        win.wid, g_state.windowTabLeader(sibling_wid), win.pid,
    });
    return .adopt;
}

/// Adopt geometry from the exact window claimed by a real pointer drag while
/// mutating ownership and layout through its native-tab group leader.
/// Returns true when display ownership changed and callers should retile.
fn updateDraggedWindowGeometry(dragged_wid: u32, frame: window_mod.Window.Frame) bool {
    if (g_state.pointer_drag.active_window_id != dragged_wid) return false;
    const leader_wid = g_state.windowTabLeader(dragged_wid);
    const leader = managedWindow(leader_wid) orelse return false;
    const leader_space = managedWindowSpace(leader.wid) orelse return false;
    const next_display_id = displayIdForFrame(frame);
    if (next_display_id == leader_space.display_id) {
        adoptDraggedFrame(dragged_wid, leader_wid, frame);
        return false;
    }

    // Only reassign display while its workspace is visible. A notification
    // from a hidden window must not transfer ownership to the visible display.
    if (!spaceVisible(leader_space)) {
        adoptDraggedFrame(dragged_wid, leader_wid, frame);
        return false;
    }

    if (!reassignManagedWindowToDisplay(leader_wid, next_display_id, false)) return false;
    adoptDraggedFrame(dragged_wid, leader_wid, frame);

    if (managedWindow(leader_wid)) |updated| {
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
    if (managedWindow(dragged_wid)) |dragged| {
        var updated = dragged;
        updated.frame = frame;
        if (updated.mode == .floating and !updated.is_fullscreen) updated.float_frame = frame;
        _ = updateManagedWindow(updated);
    }
    if (leader_wid != dragged_wid) {
        if (managedWindow(leader_wid)) |leader| {
            var updated = leader;
            updated.frame = frame;
            if (updated.mode == .floating and !updated.is_fullscreen) updated.float_frame = frame;
            _ = updateManagedWindow(updated);
        }
    }
}

/// Apply ownership policy to geometry changed without an active pointer drag.
/// Layout-owned windows are repaired from their desired frame; floating
/// windows accept same-display application changes as their new restore frame.
fn handleExternalWindowGeometry(wid: u32, frame: window_mod.Window.Frame) void {
    var win = managedWindow(wid) orelse return;
    const space = managedWindowSpace(win.wid) orelse return;

    if (!spaceVisible(space)) {
        // Never let trailing AX events from an inactive physical Space retile
        // the visible workspace or overwrite floating restore state.
        log.debug("geometry: ignored external sample for hidden wid={d}", .{wid});
        return;
    }

    if (win.mode == .tiled or win.is_fullscreen) {
        log.debug("geometry: external layout drift wid={d}; scheduling retile", .{wid});
        requestRetileDisplay(space.display_id);
        return;
    }

    const next_display_id = displayIdForFrame(frame);
    if (next_display_id != space.display_id) {
        // Workspace/display ownership changes only through the pointer-drag or
        // explicit move paths, which update every correlated data structure.
        // Accepting just the frame here would strand the floating window on a
        // display where its workspace is not visible.
        log.debug("geometry: external floating cross-display drift wid={d}; scheduling restore", .{wid});
        requestRetileDisplay(space.display_id);
        return;
    }

    win.frame = frame;
    win.float_frame = frame;
    _ = updateManagedWindow(win);
}

/// Reconciles workspace/display state after monitor topology changes.
///
/// Native Space IDs preserve surviving assignments. New physical Spaces take
/// the remaining logical workspace IDs during topology mapping.
fn reconcileDisplayChange() void {
    const focused_uuid: ?[16]u8 = blk: {
        const slot = displayIndexById(focusedDisplayId()) orelse break :blk null;
        break :blk g_displays[slot].uuid;
    };

    refreshDisplays();

    const restored_focused_display_id = displayIdForUuid(focused_uuid) orelse primaryDisplayId();
    const native_topology = captureNativeTopology() orelse {
        log.warn("display reconcile could not observe native Space topology", .{});
        return;
    };
    dispatchStateEvent(.{ .initialize_native_topology = .{
        .topology = native_topology,
        .focused_display_id = restored_focused_display_id,
    } });
    assertDisplayCoverage();
    refreshRolePolling();
}

/// Apply a target frame to a window, moving without a resize whenever the
/// stored size already matches so no AXSize write (and its flash/reflow)
/// fires. `two_pass` (fullscreen) always writes the full frame and re-issues
/// it once: the stored size records intent, not what macOS actually granted,
/// and clamped fullscreen sizes must be re-asserted even when the model
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
    // target. External resize drift can leave the model already equal to the
    // desired layout while WindowServer has a different size; consulting the
    // model there would issue a move and permanently leave the bad size.
    const physical = if (g_state.geometry.get(wid)) |entry| entry.observed orelse current else current;
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
        dispatchStateEvent(.{ .geometry = .{ .accept_position = .{
            .window_id = wid,
            .x = x,
            .y = y,
            .source = source,
            .at_ns = nanoTimestamp(),
        } } });
    }
    return ok;
}

fn recordFrameIntent(wid: u32, target: window_mod.Window.Frame, source: geometry_mod.IntentSource) void {
    dispatchStateEvent(.{ .geometry = .{ .accept_frame = .{
        .window_id = wid,
        .target = target,
        .source = source,
        .at_ns = nanoTimestamp(),
    } } });
}

fn recordAnimationIntent(wid: u32, target: window_mod.Window.Frame) void {
    const animation_ns = @as(i128, @intCast(g_config.animation.duration_ms)) * std.time.ns_per_ms;
    const settle_ns = animation_ns + geometry_mod.default_settle_interval_ns;
    dispatchStateEvent(.{ .geometry = .{ .accept_frame = .{
        .window_id = wid,
        .target = target,
        .source = .animation,
        .at_ns = nanoTimestamp(),
        .settle_interval_ns = settle_ns,
    } } });
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

/// Restore floating windows of a shown workspace to their remembered position.
/// Only acts when live bounds are off-display, so it never fights a placement
/// the user set while the workspace was visible.
///
/// Fullscreen floating windows are the exception: they own the whole content
/// frame, so they are placed regardless of where they currently sit. `content`
/// is the display frame inset by the outer gaps, matching what retileDisplay
/// hands tiled fullscreen windows.
fn restoreFloatingWindows(ws: state_mod.SpaceRef, display: shim.bw_frame, content: window_mod.Window.Frame) void {
    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();

    const snapshot = workspaceWindows(ws);
    for (snapshot.items()) |leader_wid| {
        const leader = managedWindow(leader_wid) orelse continue;
        if (leader.mode != .floating) continue;

        // The leader owns the workspace slot and mode/fullscreen intent, but
        // the active tab is the window contributing pixels.
        const wid = g_state.windowTabActive(leader_wid);
        var win = managedWindow(wid) orelse continue;

        // Mirrors the tiled fullscreen path in retileDisplay: gate on the
        // accepted frame so our own AX write echoing back as a resize does not
        // re-enter here forever, but write two-pass because macOS clamps
        // fullscreen sizes mid-flight.
        if (leader.is_fullscreen) {
            if (!framesEqual(win.frame, content) or g_state.geometry.needsRepair(wid, content, nanoTimestamp())) {
                if (applyWindowFrame(win.pid, wid, win.frame, content, true, .floating_restore)) {
                    win.frame = content;
                    _ = updateManagedWindow(win);
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
        _ = updateManagedWindow(win);
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
    const group = g_state.windowTabGroup(leader_wid) orelse return;
    if (group.leader_window_id != leader_wid) return;

    for (group.members()) |member_wid| {
        const member = managedWindow(member_wid) orelse continue;
        if (framesEqual(member.frame, frame) and !g_state.geometry.needsRepair(member_wid, frame, nanoTimestamp())) continue;

        if (applyWindowFrame(member.pid, member_wid, member.frame, frame, false, .tab_sync)) {
            var updated = member;
            updated.frame = frame;
            _ = updateManagedWindow(updated);
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

    const window_count = g_state.layout.windowCount(ws.key);
    if (window_count == 0) return;

    g_layout_entries.clearRetainingCapacity();
    g_layout_entries.ensureTotalCapacity(g_allocator, window_count) catch {
        log.err("retile: layout buffer reserve failed display={d} windows={d}", .{ display_id, window_count });
        return;
    };
    g_state.layout.computeLayout(ws.key, frame, @floatFromInt(g_config.gaps.inner), &g_layout_entries);
    std.debug.assert(g_layout_entries.items.len == window_count);

    for (g_layout_entries.items) |entry| {
        const win = managedWindow(entry.wid) orelse continue;
        const window_space = managedWindowSpace(win.wid) orelse continue;

        if (!window_space.key.eql(ws.key)) {
            log.warn("retile: skipping drifted window wid={d} display {d} (tree {d}) workspace {d} (tree {d})", .{
                entry.wid, window_space.display_id, display_id, window_space.workspace_id, ws_id,
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
        const visible_wid = g_state.windowTabActive(entry.wid);
        var visible = managedWindow(visible_wid) orelse continue;

        // Fullscreen windows fill the outer-gap-inset frame, skipping BSP splits and inner gaps
        const target_frame = if (win.is_fullscreen) frame else entry.frame;

        if (!framesEqual(visible.frame, target_frame) or
            g_state.geometry.needsRepair(visible_wid, target_frame, nanoTimestamp()))
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
                _ = updateManagedWindow(visible);
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
    for (g_state.spaces.spaces[0..g_state.spaces.space_count]) |ws| {
        const snapshot = workspaceWindows(ws);
        for (snapshot.items()) |wid| {
            if (managedWindow(wid)) |win| {
                ax_observer.observeApp(win.pid);
            }
        }
    }
}

fn resetDimming() void {
    dim.resetAll();
}

// Tab group reconciliation

/// Called on kAXFocusedWindowChangedNotification — detects tab switches and
/// forms/updates tab groups so only the active tab occupies a layout slot.
fn reconcileFocusedWindow(pid: i32, focused_wid: u32) void {
    std.debug.assert(pid > 0);
    std.debug.assert(focused_wid != 0);

    log.debug("reconcile: pid={d} focused_wid={d}", .{ pid, focused_wid });

    if (nativeSwitchPending() and managedWindow(focused_wid) == null) {
        log.debug("reconcile: deferred unknown wid={d} during native switch", .{focused_wid});
        return;
    }

    const is_managed = managedWindow(focused_wid) != null;
    const suppressed = g_state.isWindowTabSuppressed(focused_wid);
    const in_group = g_state.windowTabGroup(focused_wid) != null;
    log.debug("reconcile: wid={d} managed={} suppressed={} in_group={}", .{
        focused_wid, is_managed, suppressed, in_group,
    });

    if (syncFocusStateForWindowId(focused_wid, .ax)) {
        const leader = g_state.windowTabLeader(focused_wid);
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
    const group = g_state.windowTabGroup(wid) orelse return false;
    if (group.active_window_id == wid) return false;
    const leader = managedWindow(group.leader_window_id) orelse return false;

    const frame = liveWindowFrame(wid) orelse return false;
    switch (tab_detect.classifyMember(frame, leader.frame, isVisibleOnScreen(wid))) {
        .keep => return false,
        .promote_to_standalone => {},
    }

    log.info("tab drag-out detected: wid={d} promoted to standalone", .{wid});
    if (!detachWindowTab(wid)) return false;
    reconcileTabGroupAfterRemoval(&group, wid);

    if (managedWindow(wid)) |win| {
        var updated = win;
        updated.frame = frame;
        if (!updateManagedWindow(updated)) return false;
    }

    const win = managedWindow(wid) orelse return false;
    const ws = managedWindowSpace(win.wid) orelse return false;
    recordWorkspaceFocus(ws, wid);

    return true;
}

// Workspace resolution (config-based app → workspace mapping)

/// Return the workspace a window should be placed on, checking
/// config workspace_assignments by bundle ID before falling back
/// to the active workspace for the target display.
fn configuredWorkspace(pid: i32, display_id: u32) ?state_mod.SpaceRef {
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

fn resolveWorkspaceForWindow(pid: i32, wid: u32, display_id: u32) ?state_mod.SpaceRef {
    const native_space_id = g_sky.?.nativeSpaceIdForWindow(wid, display_id);
    if (native_space_id) |space_id| {
        if (g_state.space(.{ .id = space_id }) == null) return null;
    }

    if (configuredWorkspace(pid, display_id)) |ws| return ws;
    if (native_space_id) |space_id| {
        if (g_state.space(.{ .id = space_id })) |ws| return ws;
    }
    const ws_id = activeWorkspaceIdForDisplay(display_id);
    return spaceForWorkspace(display_id, ws_id) orelse unreachable;
}

fn nativeWorkspaceForWindow(wid: u32, display_id: u32) ?state_mod.SpaceRef {
    const space_id = g_sky.?.nativeSpaceIdForWindow(wid, display_id) orelse return null;
    return g_state.space(.{ .id = space_id });
}

// Workspace switching

fn switchWorkspace(target_id: u8) void {
    const target_ws = spaceForCommand(focusedDisplayId(), target_id) orelse return;
    dispatchStateEvent(.{ .request_workspace_switch = .{
        .target = target_ws,
        .at_ms = nativeStateNowMs(),
    } });
}

/// Focus the remembered (or first available) window on a workspace.
fn focusWorkspaceWindow(ws: state_mod.SpaceRef) void {
    var focus_wid = focusedWorkspaceWindow(ws);
    if (focus_wid) |fwid| {
        if (managedWindow(fwid) == null) focus_wid = null;
    }
    if (focus_wid == null) {
        const snapshot = workspaceWindows(ws);
        for (snapshot.items()) |wid| {
            if (managedWindow(wid) == null) continue;
            focus_wid = wid;
            break;
        }
    }
    if (focus_wid) |fwid| {
        const actual_wid = g_state.windowTabActive(fwid);
        if (managedWindow(actual_wid)) |win| {
            if (g_state.windowTabGroup(fwid)) |group| {
                log.debug("workspace focus target workspace={d} focused_wid={d} actual_wid={d} group_leader={d} group_active={d} members={d}", .{
                    ws.workspace_id,
                    fwid,
                    actual_wid,
                    group.leader_window_id,
                    group.active_window_id,
                    group.member_count,
                });
            } else {
                log.debug("workspace focus target workspace={d} focused_wid={d} actual_wid={d} group=none", .{
                    ws.workspace_id,
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
        log.debug("workspace focus target workspace={d} focused_wid=0 actual_wid=0 reason=empty", .{ws.workspace_id});
        if (g_state.workspace_transition) |transition| {
            if (transition.target.key.eql(ws.key)) {
                markWorkspaceTransitionComplete(.empty_workspace);
            }
        }
    }
}

fn moveWindowToWorkspace(target_id: u8) void {
    const ctx = actionContext() orelse {
        log.debug("move workspace skipped: no visible AX-focused managed window", .{});
        return;
    };
    const wid = ctx.focused_wid;
    const win = ctx.focused_win;
    const ws = ctx.workspace;
    if (target_id == ws.workspace_id and ws.display_id == focusedDisplayId()) return;

    log.debug("move workspace target wid={d} pid={d} source={d} target={d}", .{ wid, win.pid, ws.workspace_id, target_id });

    const target_ws = spaceForCommand(ws.display_id, target_id) orelse return;
    const layout: ?state_mod.LayoutInsertion = if (g_state.layout.contains(ws.key, wid))
        layoutInsertion(target_ws.key, wid) catch return
    else
        null;
    dispatchStateEvent(.{ .request_window_move = .{
        .window_id = wid,
        .target = target_ws,
        .layout = layout,
        .should_move_native = true,
    } });
}

/// Update every ownership structure for a cross-display move. The caller owns
/// focus policy and the final retile so pointer drags can first adopt the
/// physical tab's latest frame.
fn reassignManagedWindowToDisplay(wid: u32, target_display_id: u32, should_follow_focus: bool) bool {
    std.debug.assert(wid != 0);
    std.debug.assert(target_display_id != 0);

    const win = managedWindow(wid) orelse return false;
    const source_ws = managedWindowSpace(win.wid) orelse return false;
    if (source_ws.display_id == target_display_id) return false;

    const target_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
    std.debug.assert(target_workspace_id > 0 and target_workspace_id <= workspaceCount());

    const target_ws = spaceForWorkspace(target_display_id, target_workspace_id) orelse return false;
    const layout: ?state_mod.LayoutInsertion = if (g_state.layout.contains(source_ws.key, wid))
        layoutInsertion(target_ws.key, wid) catch return false
    else
        null;
    dispatchStateEvent(.{ .request_window_move = .{
        .window_id = wid,
        .target = target_ws,
        .layout = layout,
        .should_move_native = false,
        .should_follow_focus = should_follow_focus,
    } });
    return managedWindowSpace(wid).?.key.eql(target_ws.key);
}

/// Move a managed window to a target display and map it onto the target
/// display's active workspace so it stays visible after the move.
fn moveManagedWindowToDisplay(wid: u32, target_display_id: u32) bool {
    return reassignManagedWindowToDisplay(wid, target_display_id, true);
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

    const moving_workspace_id = activeWorkspaceIdForDisplay(source_display_id);
    const displaced_workspace_id = activeWorkspaceIdForDisplay(target_display_id);
    const source = spaceForWorkspace(source_display_id, moving_workspace_id) orelse return;
    const target = spaceForWorkspace(target_display_id, displaced_workspace_id) orelse return;
    dispatchStateEvent(.{ .request_native_workspace_move = .{
        .source = source,
        .target = target,
        .at_ms = nativeStateNowMs(),
    } });
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

fn swapDirection(direction: state_mod.FocusDirection) void {
    const ctx = actionContext() orelse return;
    dispatchStateEvent(.{ .swap_direction = .{
        .window_id = ctx.focused_wid,
        .direction = direction,
    } });
}

fn focusDirection(direction: state_mod.FocusDirection) void {
    const ctx = actionContext() orelse return;
    dispatchStateEvent(.{ .focus_direction = .{
        .window_id = ctx.focused_wid,
        .direction = direction,
    } });
}

fn focusDirectionFromIpc(direction: ipc.IpcCommand.FocusDir) state_mod.FocusDirection {
    return switch (direction) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
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
            dispatchStateEvent(.toggle_split_mode);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .focus => |dir| {
            focusDirection(focusDirectionFromIpc(dir));
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
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            if (!g_state.layout.hasParentSplit(ctx.workspace.key, ctx.focused_wid)) {
                ipc.writeResponse(client_fd, "err: no parent split\n");
                return;
            }
            dispatchLayoutCommand(.{ .adjust_parent_ratio = .{
                .space_key = ctx.workspace.key,
                .window_id = ctx.focused_wid,
                .delta = delta,
            } }, ctx.workspace.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_ratio_abs => |ratio| {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            if (!g_state.layout.hasParentSplit(ctx.workspace.key, ctx.focused_wid)) {
                ipc.writeResponse(client_fd, "err: no parent split\n");
                return;
            }
            dispatchLayoutCommand(.{ .set_parent_ratio = .{
                .space_key = ctx.workspace.key,
                .window_id = ctx.focused_wid,
                .ratio = ratio,
            } }, ctx.workspace.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_insert_point => |point| {
            dispatchStateEvent(.{ .set_insert_point = point });
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_mirror => |axis| {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            dispatchLayoutCommand(.{ .mirror = .{
                .space_key = ctx.workspace.key,
                .axis = axis,
            } }, ctx.workspace.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_equalize => {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            dispatchLayoutCommand(.{ .equalize = .{
                .space_key = ctx.workspace.key,
                .ratio = g_config.bsp_split_ratio,
            } }, ctx.workspace.display_id);
            ipc.writeResponse(client_fd, "ok\n");
        },
        .bsp_balance => {
            const ctx = focusedLayoutContext() orelse {
                ipc.writeResponse(client_fd, "err: no focused managed window\n");
                return;
            };
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            dispatchLayoutCommand(.{ .balance = ctx.workspace.key }, ctx.workspace.display_id);
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
            if (ctx.layout_kind != .bsp) {
                ipc.writeResponse(client_fd, "err: not in bsp mode\n");
                return;
            }
            dispatchLayoutCommand(.{ .rotate = .{
                .space_key = ctx.workspace.key,
                .degrees = degrees,
            } }, ctx.workspace.display_id);
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
    const snapshot = workspaceWindows(ws);

    switch (format) {
        .text => for (snapshot.items()) |wid| {
            if (managedWindow(wid)) |win| {
                var id_buf: [256]u8 = undefined;
                const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
                const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                w.print("{d} {d} {s} {d} {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{
                    win.wid,     win.pid,     bundle_id,       ws.workspace_id,  ws.display_id,
                    win.frame.x, win.frame.y, win.frame.width, win.frame.height,
                }) catch break;
                written += 1;
            }
        },
        .json => {
            var json: std.json.Stringify = .{ .writer = w };
            json.beginArray() catch {};
            for (snapshot.items()) |wid| {
                if (managedWindow(wid)) |win| {
                    var id_buf: [256]u8 = undefined;
                    const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
                    const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                    writeWindowJson(&json, win, ws, bundle_id) catch break;
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

    for (g_state.spaces.spaces[0..g_state.spaces.space_count]) |ws| {
        const snapshot = workspaceWindows(ws);
        for (snapshot.items()) |wid| {
            if (managedWindow(wid)) |win| {
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
    log.debug("[trace] query workspaces rows={} bytes={} elapsed_ms={}", .{ workspaceCount(), payload.len, elapsed_ms });
}

fn writeWorkspaceText(writer: *std.Io.Writer) void {
    var workspace_id: u8 = 1;
    while (workspace_id <= workspaceCount()) : (workspace_id += 1) {
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
    while (workspace_id <= workspaceCount()) : (workspace_id += 1) {
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
        const win = managedWindow(wid) orelse continue;
        var id_buf: [256]u8 = undefined;
        const id_len = if (osutil.appBundleId(win.pid, &id_buf)) |id| id.len else 0;
        const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";
        try writeWindowJson(json, win, space, bundle_id);
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

fn writeWindowJson(
    json: *std.json.Stringify,
    win: window_mod.Window,
    space: state_mod.SpaceRef,
    bundle_id: []const u8,
) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("window_id");
    try json.write(win.wid);
    try json.objectField("process_id");
    try json.write(win.pid);
    try json.objectField("bundle_id");
    try json.write(bundle_id);
    try json.objectField("workspace_id");
    try json.write(space.workspace_id);
    try json.objectField("display_id");
    try json.write(space.display_id);
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
