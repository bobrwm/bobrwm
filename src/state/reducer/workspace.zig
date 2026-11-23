//! Workspace, native Space, and focus transitions.

const std = @import("std");
const native_gesture = @import("../../native_gesture.zig");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");
const pointer_reducer = @import("pointer.zig");
const window_reducer = @import("window.zig");

const native_switch_timeout_ms = model_mod.native_switch_timeout_ms;
const native_observation_delay_ms = model_mod.native_observation_delay_ms;
const native_workspace_move_timeout_ms = model_mod.native_workspace_move_timeout_ms;
const workspace_transition_settle_ms = model_mod.workspace_transition_settle_ms;
const DisplayId = model_mod.DisplayId;
const DisplayTopology = model_mod.DisplayTopology;
const NativeSpaceId = model_mod.NativeSpaceId;
const WorkspaceId = model_mod.WorkspaceId;
const SpaceKey = model_mod.SpaceKey;
const SpaceRef = model_mod.SpaceRef;
const WorkspaceTopology = model_mod.WorkspaceTopology;
const SpaceCatalog = model_mod.SpaceCatalog;
const Epoch = model_mod.Epoch;
const TimestampMs = model_mod.TimestampMs;
const WindowId = model_mod.WindowId;
const FollowFocusObservation = model_mod.FollowFocusObservation;
const WindowFocusObservation = model_mod.WindowFocusObservation;
const SwitchRequest = model_mod.SwitchRequest;
const PendingSwitch = model_mod.PendingSwitch;
const WorkspaceTransitionKind = model_mod.WorkspaceTransitionKind;
const WorkspaceTransitionCompletionReason = model_mod.WorkspaceTransitionCompletionReason;
const WorkspaceTransition = model_mod.WorkspaceTransition;
const WorkspaceTransitionSettlementReason = model_mod.WorkspaceTransitionSettlementReason;
const PendingNativeWindowMove = model_mod.PendingNativeWindowMove;
const PendingNativeWorkspaceMove = model_mod.PendingNativeWorkspaceMove;
const HiddenSpaces = model_mod.HiddenSpaces;
const WindowPlacementObservation = model_mod.WindowPlacementObservation;
const NewWindowAdoption = model_mod.NewWindowAdoption;
const OffscreenCleanup = model_mod.OffscreenCleanup;
const WorkspaceMoveCommand = model_mod.WorkspaceMoveCommand;
const SpaceOperand = model_mod.SpaceOperand;
const NativeTopology = model_mod.NativeTopology;
const NativeWindowMoveRequest = model_mod.NativeWindowMoveRequest;
const PendingFocus = model_mod.PendingFocus;
const WindowCandidate = model_mod.WindowCandidate;
const WindowCandidates = model_mod.WindowCandidates;
const Model = model_mod.Model;
const Event = model_mod.Event;
const SwitchFailureReason = model_mod.SwitchFailureReason;
const Transition = model_mod.Transition;

pub fn reduceWorkspaceSwitchRequest(
    transition: *Transition,
    request: @FieldType(Event, "request_workspace_switch"),
) void {
    const target = transition.model.space(request.target.key) orelse return;
    if (transition.model.pending_native_workspace_move != null) {
        transition.model.queued_switch = .{ .target = target };
        return;
    }
    const active_workspace_id = transition.model.activeWorkspace(target.display_id) orelse return;
    if (transition.model.pending_switch == null and active_workspace_id == target.workspace_id and
        transition.model.native_topology.observedWorkspace(target.display_id) == target.workspace_id)
    {
        startWorkspaceTransition(
            transition,
            .switch_workspace,
            target,
            request.at_ms,
            workspace_transition_settle_ms,
            null,
        );
        transition.model.workspace_topology.focused_display_id = target.display_id;
        pointer_reducer.clearDragPreview(transition);
        transition.addEffect(.{ .workspace_switch_ready = .{ .target = target } });
        return;
    }

    reduceSwitchRequest(transition, .{
        .target = target,
        .at_ms = request.at_ms,
    });
}

pub fn reduceSwitchRequest(
    transition: *Transition,
    event: @FieldType(Event, "request_native_switch"),
) void {
    const target = transition.model.spaces.find(event.target.key) orelse {
        transition.addEffect(.{ .native_switch_rejected = event.target });
        return;
    };
    if (target.display_id != event.target.display_id or target.workspace_id != event.target.workspace_id) {
        transition.addEffect(.{ .native_switch_rejected = event.target });
        return;
    }
    const request: SwitchRequest = .{ .target = target };

    if (transition.model.pending_native_workspace_move != null) {
        transition.model.queued_switch = request;
        return;
    }

    if (transition.model.pending_switch) |pending| {
        transition.model.queued_switch = if (sameRequest(request, pending.request)) null else request;
        return;
    }

    startSwitch(transition, request, event.at_ms);
}

pub fn reduceSpaceChanged(transition: *Transition, at_ms: TimestampMs) void {
    // A workspace move makes displays fall back to other Spaces and observes
    // the topology itself.
    if (transition.model.pending_native_workspace_move != null) return;
    if (transition.model.pending_switch) |pending| {
        transition.model.observation_timer = null;
        transition.addEffect(.{ .observe_native_topology = pending.epoch });
        return;
    }

    const epoch = takeEpoch(transition.model);
    transition.model.observation_timer = .{
        .epoch = epoch,
        .due_at_ms = at_ms +| native_observation_delay_ms,
    };
}

pub fn reduceObservationTimer(
    transition: *Transition,
    event: @FieldType(Event, "observation_timer_fired"),
) void {
    const timer = transition.model.observation_timer orelse return;
    if (timer.epoch != event.epoch) return;
    if (event.at_ms < timer.due_at_ms) return;

    transition.model.observation_timer = null;
    transition.addEffect(.{ .observe_native_topology = timer.epoch });
}

pub fn reduceTopologyObserved(
    transition: *Transition,
    event: @FieldType(Event, "native_topology_observed"),
) void {
    if (transition.model.pending_switch) |pending| {
        if (event.epoch != pending.epoch) return;
    }
    // Mid-move topology is transitional and the move adopts the landed one.
    // Only a lost display is adopted so the sync below can cancel the move.
    if (transition.model.pending_native_workspace_move) |pending| {
        const has_source = event.topology.findDisplay(pending.source.display_id) != null;
        const has_target = event.topology.findDisplay(pending.target.display_id) != null;
        if (has_source and has_target) return;
    }
    const has_changed = !transition.model.native_topology.eql(event.topology);
    transition.model.native_topology = event.topology.*;
    syncNativeWorkspaceTopology(transition);

    const pending = transition.model.pending_switch orelse {
        transition.model.observation_timer = null;
        if (has_changed) transition.addEffect(.native_topology_changed);
        if (transition.model.pending_native_workspace_move == null) resumeQueuedWorkspaceSwitch(transition, event.at_ms);
        return;
    };
    const display = event.topology.findDisplay(pending.request.target.display_id);
    const actual_space_id = if (display) |value| value.observed_space_id else null;
    if (pending.phase == .preparing or pending.phase == .delivering or event.is_animating != false) {
        if (event.at_ms < pending.deadline_at_ms) {
            schedulePendingObservation(transition.model, pending, event.at_ms);
            return;
        }
        finishSwitch(transition, pending, event.at_ms, .{
            .reason = if (event.is_animating == null) .observation_unavailable else .animation_timeout,
            .actual = if (actual_space_id) |space_id| transition.model.space(.{ .id = space_id }) else null,
        });
        return;
    }
    if (actual_space_id == pending.request.target.key.id) {
        finishSwitch(transition, pending, event.at_ms, null);
        return;
    }

    if (pending.phase == .waiting_for_idle) {
        transition.model.pending_switch.?.phase = .preparing;
        transition.addEffect(.{ .switch_native_space = .{ .request = pending.request, .epoch = pending.epoch } });
        return;
    }

    // Something else moved the display, such as macOS following app focus,
    // so the swipe can no longer land. Replan now instead of at the deadline.
    if (display != null and isOffSwitchPath(display.?, pending)) {
        if (recoverUnexpectedLanding(transition, pending, event.at_ms)) return;
    }

    if (event.at_ms < pending.deadline_at_ms) {
        schedulePendingObservation(transition.model, pending, event.at_ms);
        return;
    }

    if (recoverUnexpectedLanding(transition, pending, event.at_ms)) return;

    finishSwitch(transition, pending, event.at_ms, .{
        .reason = .unexpected_space,
        .actual = if (actual_space_id) |space_id| transition.model.space(.{ .id = space_id }) else null,
    });
}

pub fn reduceGesturePrepared(transition: *Transition, event: @FieldType(Event, "native_gesture_prepared")) void {
    var pending = transition.model.pending_switch orelse return;
    if (pending.epoch != event.epoch or pending.phase != .preparing) return;
    if (event.plan.steps == 0) {
        pending.phase = .observing;
        transition.model.pending_switch = pending;
        transition.addEffect(.{ .observe_native_topology = pending.epoch });
        return;
    }

    pending.phase = .delivering;
    pending.plan = event.plan;
    pending.gesture = .{ .plan = event.plan, .steps_remaining = event.plan.steps };
    transition.model.pending_switch = pending;
    postGesturePhase(transition, pending);
}

pub fn reduceGesturePosted(transition: *Transition, event: @FieldType(Event, "native_gesture_posted")) void {
    var pending = transition.model.pending_switch orelse return;
    if (pending.epoch != event.epoch or pending.phase != .delivering) return;
    var gesture = pending.gesture orelse return;
    if (gesture.phase != event.phase or gesture.due_at_ms != null) return;
    if (!event.succeeded) {
        reduceSwitchEffectFailed(transition, .{ .epoch = event.epoch, .at_ms = event.at_ms });
        return;
    }

    if (gesture.phase == .ended) {
        gesture.steps_remaining -= 1;
        if (gesture.steps_remaining == 0) {
            pending.phase = .observing;
            pending.gesture = null;
            transition.model.pending_switch = pending;
            transition.addEffect(.{ .observe_native_topology = pending.epoch });
            return;
        }
    }
    gesture.phase = switch (gesture.phase) {
        .began => .changed,
        .changed => .ended,
        .ended => .began,
    };
    // Pace phases within a swipe; waiting between swipes exposes intermediate Spaces.
    const should_pace = gesture.plan.is_paced and gesture.phase != .began;
    if (should_pace) gesture.due_at_ms = event.at_ms +| native_gesture.phase_delay_ms;
    pending.gesture = gesture;
    transition.model.pending_switch = pending;
    if (should_pace) {
        transition.addEffect(.{ .schedule_native_gesture = pending.epoch });
        return;
    }
    postGesturePhase(transition, pending);
}

pub fn reduceGestureTimer(transition: *Transition, event: @FieldType(Event, "native_gesture_timer_fired")) void {
    var pending = transition.model.pending_switch orelse return;
    if (pending.epoch != event.epoch or pending.phase != .delivering) return;
    const due_at_ms = pending.gesture.?.due_at_ms orelse return;
    if (event.at_ms < due_at_ms) return;
    pending.gesture.?.due_at_ms = null;
    transition.model.pending_switch = pending;
    postGesturePhase(transition, pending);
}

fn postGesturePhase(transition: *Transition, pending: PendingSwitch) void {
    const gesture = pending.gesture.?;
    transition.addEffect(.{ .post_native_gesture = .{
        .epoch = pending.epoch,
        .phase = gesture.phase,
        .direction = gesture.plan.direction,
        .velocity = gesture.plan.velocity,
    } });
}

/// The display settled outside the Spaces between the swipe's start and its
/// target. Right swipes move toward later Spaces.
fn isOffSwitchPath(display: *const DisplayTopology, pending: PendingSwitch) bool {
    const plan = pending.plan orelse return false;
    const target_index = spaceIndex(display, pending.request.target.key.id) orelse return false;
    const actual_index = spaceIndex(display, display.observed_space_id) orelse return false;
    const start_index = switch (plan.direction) {
        .right => target_index -| plan.steps,
        .left => target_index + plan.steps,
    };
    const low = @min(start_index, target_index);
    const high = @max(start_index, target_index);
    return actual_index < low or actual_index > high;
}

fn spaceIndex(display: *const DisplayTopology, space_id: NativeSpaceId) ?usize {
    for (display.spaces[0..display.space_count], 0..) |space, index| {
        if (space.id == space_id) return index;
    }
    return null;
}

fn recoverUnexpectedLanding(transition: *Transition, pending: PendingSwitch, at_ms: TimestampMs) bool {
    const queued = transition.model.queued_switch;
    if (queued == null and pending.has_retried) return false;
    const request = queued orelse pending.request;
    if (transition.model.space(request.target.key) == null) return false;

    // Dock can ignore gestures during an animation. Replan from observed
    // topology after the deadline, giving the latest request precedence.
    transition.model.pending_switch = null;
    transition.model.queued_switch = null;
    transition.model.observation_timer = null;
    transition.model.deferred_follow_focus = null;
    settleWorkspaceTransition(transition, pending.epoch, .superseded);
    startSwitch(transition, request, at_ms);
    if (transition.model.pending_switch) |*next| next.has_retried = queued == null;
    return true;
}

pub fn syncNativeWorkspaceTopology(transition: *Transition) void {
    const previous_catalog = transition.model.spaces;
    const focused_display_id = transition.model.workspace_topology.focused_display_id;
    var topology: WorkspaceTopology = .{};
    var catalog: SpaceCatalog = .{};
    for (transition.model.native_topology.displays[0..transition.model.native_topology.display_count]) |display| {
        for (display.spaces[0..display.space_count]) |space| {
            catalog.add(.{
                .key = .{ .id = space.id },
                .workspace_id = space.workspace_id,
                .display_id = display.display_id,
            });
        }

        // A fullscreen Space is visible but does not own a workspace. Keep the
        // hidden desktop's ownership; startup uses the first mapped desktop.
        const previous_workspace = transition.model.workspace_topology.activeWorkspace(display.display_id);
        const workspace_id = display.workspaceForSpace(display.observed_space_id) orelse blk: {
            if (previous_workspace) |workspace_id| {
                if (display.spaceForWorkspace(workspace_id) != null) break :blk workspace_id;
            }
            if (display.space_count == 0) continue;
            break :blk display.spaces[0].workspace_id;
        };
        topology.addDisplay(.{
            .display_id = display.display_id,
            .active_workspace_id = workspace_id,
        });
    }
    if (focused_display_id) |display_id| {
        if (topology.findDisplay(display_id) != null) topology.focused_display_id = display_id;
    }
    transition.model.spaces = catalog;
    transition.model.workspace_topology = topology;
    for (previous_catalog.spaces[0..previous_catalog.space_count]) |previous_space| {
        if (catalog.find(previous_space.key) != null) continue;
        const target = catalog.findLogicalWorkspace(previous_space.workspace_id) orelse continue;
        if (!layout_reducer.applyEvent(transition, .{ .rekey_layout = .{
            .source_key = previous_space.key,
            .target_key = target.key,
        } })) continue;
        transition.model.windows.swapSpaceKeys(previous_space.key, target.key);
    }
    pruneWindowCandidates(&transition.model.pending_role_windows, &catalog);
    pruneWindowCandidates(&transition.model.deferred_window_candidates, &catalog);
    if (transition.model.pending_native_workspace_move) |pending| {
        if (!nativeWorkspaceMoveIsIntact(&transition.model.native_topology, &catalog, pending)) {
            transition.model.pending_native_workspace_move = null;
            settleWorkspaceTransition(transition, pending.epoch, .target_unavailable);
            transition.addEffect(.{ .native_workspace_move_failed = pending });
        }
    }
    refreshWorkspaceTransition(transition);
    refreshPendingNativeWindowMoves(transition.model);
}

/// Both displays must remain. The move changes which display its Spaces are
/// on, so for them only existence is checked.
fn nativeWorkspaceMoveIsIntact(
    topology: *const NativeTopology,
    catalog: *const SpaceCatalog,
    pending: PendingNativeWorkspaceMove,
) bool {
    if (topology.findDisplay(pending.source.display_id) == null) return false;
    if (topology.findDisplay(pending.target.display_id) == null) return false;
    if (catalog.find(pending.source.key) == null or catalog.find(pending.target.key) == null) return false;
    const backfill = pending.backfill orelse return true;
    return catalog.find(backfill.key) != null;
}

pub fn reduceTopologyUnavailable(
    transition: *Transition,
    event: @FieldType(Event, "native_topology_unavailable"),
) void {
    const pending = transition.model.pending_switch orelse return;
    if (event.epoch != pending.epoch) return;

    if (event.at_ms < pending.deadline_at_ms) {
        schedulePendingObservation(transition.model, pending, event.at_ms);
        return;
    }

    finishSwitch(transition, pending, event.at_ms, .{
        .reason = .observation_unavailable,
        .actual = null,
    });
}

pub fn reduceSwitchEffectFailed(
    transition: *Transition,
    event: @FieldType(Event, "native_switch_effect_failed"),
) void {
    const pending = transition.model.pending_switch orelse return;
    if (event.epoch != pending.epoch) return;

    const display = transition.model.native_topology.findDisplay(pending.request.target.display_id);
    const actual_space_id = if (display) |value| value.observed_space_id else null;
    finishSwitch(transition, pending, event.at_ms, .{
        .reason = .effect_failed,
        .actual = if (actual_space_id) |space_id| transition.model.space(.{ .id = space_id }) else null,
    });
}

pub fn reduceWorkspaceTransitionStart(
    transition: *Transition,
    event: @FieldType(Event, "start_workspace_transition"),
) void {
    const target = transition.model.space(event.target.key) orelse return;
    startWorkspaceTransition(transition, event.kind, target, event.at_ms, workspace_transition_settle_ms, null);
}

pub fn reduceWorkspaceTransitionCompletion(
    transition: *Transition,
    event: @FieldType(Event, "complete_workspace_transition"),
) void {
    const current = transition.model.workspace_transition orelse return;
    if (current.epoch != event.epoch) return;
    if (current.completion_reason != null) return;

    var completed = current;
    completed.completion_reason = event.reason;
    completed.deadline_at_ms = event.at_ms +| workspace_transition_settle_ms;
    transition.model.workspace_transition = completed;
}

pub fn reduceWorkspaceTransitionTimer(
    transition: *Transition,
    event: @FieldType(Event, "workspace_transition_timer_fired"),
) void {
    const current = transition.model.workspace_transition orelse return;
    if (current.epoch != event.epoch) return;
    if (transition.model.pending_switch) |pending| {
        if (pending.epoch == current.epoch) return;
    }
    if (transition.model.pending_native_workspace_move) |pending| {
        if (pending.epoch == current.epoch) return;
    }
    if (event.at_ms < current.deadline_at_ms) return;

    finalizeWorkspaceTransition(
        transition,
        current,
        if (current.completion_reason == null) .deadline_expired else .completed,
    );
}

pub fn reduceNativeWindowMoveTracked(
    transition: *Transition,
    request: NativeWindowMoveRequest,
) void {
    if (request.window_id == 0) {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    }
    const source = transition.model.space(request.source.key) orelse {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    };
    const target = transition.model.space(request.target.key) orelse {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    };
    if (source.key.eql(target.key)) {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    }

    const pending: PendingNativeWindowMove = .{
        .window_id = request.window_id,
        .source = source,
        .target = target,
        .epoch = takeEpoch(transition.model),
    };
    if (!transition.model.pending_native_window_moves.put(pending)) {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    }
    transition.addEffect(.{ .move_native_window = pending });

    const at_ms = request.follow_at_ms orelse return;
    const window = transition.model.window(pending.window_id) orelse return;
    const display = transition.model.native_topology.findDisplay(target.display_id);
    reduceFollowFocusObserved(transition, .{
        .process_id = window.process_id,
        .window_id = transition.model.windowTabActive(window.window_id),
        .leader_window_id = window.window_id,
        .source = .ax,
        .target = target,
        .is_target_visible = if (display) |value| value.observed_space_id == target.key.id else false,
        .at_ms = at_ms,
    });
}

/// The app rule's workspace wins over the window's own Space. The display
/// follows a moved window when its app is active: the user just launched it
/// or switched to it.
pub fn reduceNewWindowAdopted(transition: *Transition, adoption: NewWindowAdoption) void {
    const native_space = transition.model.space(adoption.native_space.key) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = adoption.window_id,
            .reason = .space_missing,
        } });
        return;
    };
    const rule_space = if (adoption.rule_workspace_id) |workspace_id| transition.model.logicalWorkspace(workspace_id) else null;
    const target = rule_space orelse native_space;

    window_reducer.reduceWindowAdopted(transition, .{
        .window_id = adoption.window_id,
        .process_id = adoption.process_id,
        .space_key = target.key,
        .frame = adoption.frame,
        .mode = adoption.mode,
    });
    if (transition.model.window(adoption.window_id) == null) return;
    if (target.key.eql(native_space.key)) return;

    reduceNativeWindowMoveTracked(transition, .{
        .window_id = adoption.window_id,
        .source = native_space,
        .target = target,
        .follow_at_ms = adoption.at_ms,
    });
}

/// A managed window is adopted where the user or macOS put it, unless macOS
/// piled it there after a display change. At startup an unmanaged window out
/// of sight goes to its app rule's Space, so showing that Space finds it in
/// place.
pub fn reduceWindowPlacementObserved(transition: *Transition, observation: WindowPlacementObservation) void {
    const model = transition.model;
    const space_id = observation.space_id orelse return;
    const observed_space = model.space(.{ .id = space_id });

    const window = model.window(observation.window_id) orelse {
        if (observation.reason != .startup) return;
        const source = observed_space orelse return;
        const target = model.logicalWorkspace(observation.rule_workspace_id orelse return) orelse return;
        if (source.key.eql(target.key)) return;
        if (model.native_topology.isSpaceShown(source.key.id)) return;
        transition.addEffect(.{ .place_native_window = .{ .window_id = observation.window_id, .target = target } });
        return;
    };
    if (window.tab_leader_window_id != window.window_id) return;
    if (window.space_key.id == space_id) return;
    if (model.pendingNativeWindowMove(window.window_id) != null) return;

    switch (observation.reason) {
        .startup => {},
        .display_changed => {
            const home = model.space(window.space_key) orelse return;
            if (observed_space) |source| {
                reduceNativeWindowMoveTracked(transition, .{ .window_id = window.window_id, .source = source, .target = home });
                return;
            }
            transition.addEffect(.{ .place_native_window = .{ .window_id = window.window_id, .target = home } });
        },
        .settled, .topology_changed => {
            // Mid-operation placement is transitional; the operation
            // reconciles when it lands.
            if (model.pending_switch != null or model.observation_timer != null) return;
            // A window off screen may report a Space it is merely leaving.
            if (observation.reason == .settled and !observation.is_on_screen) return;
            _ = adoptMovedWindow(transition, window.window_id, space_id);
        },
    }
}

// Returns the window's new workspace, or null when it stays where it is.
fn adoptMovedWindow(transition: *Transition, window_id: WindowId, space_id: ?NativeSpaceId) ?SpaceRef {
    const model = transition.model;
    const window = model.window(model.windowTabLeader(window_id)) orelse return null;
    const target = model.space(.{ .id = space_id orelse return null }) orelse return null;
    if (window.space_key.eql(target.key)) return null;
    if (model.pendingNativeWindowMove(window.window_id) != null) return null;
    if (model.pending_native_workspace_move != null) return null;

    window_reducer.reduceWindowSpaceAssigned(transition, .{ .window_id = window.window_id, .space_key = target.key });
    if (!model.window(window.window_id).?.space_key.eql(target.key)) return null;
    refreshWorkspaceFocus(model);
    if (model.focusedWorkspaceWindow(target.workspace_id) == null) {
        window_reducer.reduceWorkspaceFocusRecorded(transition, .{
            .workspace_id = target.workspace_id,
            .window_id = window.window_id,
        });
    }
    return target;
}

pub fn reduceCleanupRequestsFlushed(transition: *Transition) void {
    const model = transition.model;
    var request = model.cleanup_request;
    model.cleanup_request = .{};
    if (model.isWorkspaceTransitionActive()) return;

    if (request.should_clean_offscreen) {
        for (model.windows.items()) |window| {
            if (!model.isOffscreenCleanupCandidate(window.window_id)) continue;
            const process_ids = request.offscreen_process_ids[0..request.offscreen_process_count];
            if (std.mem.findScalar(i32, process_ids, window.process_id) != null) continue;
            if (request.offscreen_process_count == request.offscreen_process_ids.len) break;
            request.offscreen_process_ids[request.offscreen_process_count] = window.process_id;
            request.offscreen_process_count += 1;
        }
    }
    if (request.process_count == 0 and request.offscreen_process_count == 0) return;
    transition.addEffect(.{ .cleanup_requested = request });
}

/// The answer can arrive after a workspace transition began.
pub fn reduceOffscreenWindowListObserved(transition: *Transition, process_id: i32) void {
    const model = transition.model;
    if (model.isWorkspaceTransitionActive()) return;

    var cleanup: OffscreenCleanup = .{ .process_id = process_id };
    for (model.windows.items()) |window| {
        if (window.process_id != process_id) continue;
        if (!model.isOffscreenCleanupCandidate(window.window_id)) continue;
        if (cleanup.window_count == cleanup.window_ids.len) break;
        cleanup.window_ids[cleanup.window_count] = window.window_id;
        cleanup.window_count += 1;
    }
    if (cleanup.window_count == 0) return;
    transition.addEffect(.{ .clean_offscreen_windows = cleanup });
}

/// The app closed the window to the background without telling anyone, or
/// hid itself. Like a minimized window it gives up its slot until it is back.
pub fn reduceWindowOffscreenObserved(transition: *Transition, window_id: WindowId) void {
    if (!transition.model.isOffscreenCleanupCandidate(window_id)) return;
    window_reducer.reduceWindowRemoved(transition, window_id);
}

pub fn reduceNativeWindowMoveObserved(
    transition: *Transition,
    event: @FieldType(Event, "native_window_move_observed"),
) void {
    var pending = transition.model.pending_native_window_moves.get(event.window_id) orelse return;
    if (pending.epoch != event.epoch) return;

    switch (event.observation) {
        .confirmed => {
            _ = transition.model.pending_native_window_moves.remove(event.window_id);
            transition.addEffect(.{ .native_window_move_confirmed = pending });
            var hidden: HiddenSpaces = .{};
            hidden.addIfHidden(&transition.model.native_topology, pending.target.key.id);
            if (hidden.count > 0) transition.addEffect(.{ .hide_native_spaces = hidden });
        },
        .window_missing, .ownership_changed => {
            _ = transition.model.pending_native_window_moves.remove(event.window_id);
            transition.addEffect(.{ .native_window_move_cancelled = pending });
        },
        .pending => {
            if (!pending.has_retried) {
                pending.has_retried = true;
                std.debug.assert(transition.model.pending_native_window_moves.put(pending));
                transition.addEffect(.{ .retry_native_window_move = pending });
                return;
            }
            if (pending.attempts_remaining > 1) {
                pending.attempts_remaining -= 1;
                std.debug.assert(transition.model.pending_native_window_moves.put(pending));
                return;
            }
            transition.addEffect(.{ .rollback_native_window_move = pending });
        },
    }
}

pub fn reduceNativeWindowMoveRollbackResult(
    transition: *Transition,
    event: @FieldType(Event, "native_window_move_rollback_result"),
) void {
    const pending = transition.model.pending_native_window_moves.get(event.window_id) orelse return;
    if (pending.epoch != event.epoch) return;

    if (event.succeeded) {
        const current = transition.model.window(pending.window_id);
        if (current == null or !current.?.space_key.eql(pending.target.key)) {
            _ = transition.model.pending_native_window_moves.remove(event.window_id);
            transition.addEffect(.{ .native_window_move_rolled_back = pending });
            return;
        }
        window_reducer.reduceWindowSpaceAssigned(transition, .{
            .window_id = pending.window_id,
            .space_key = pending.source.key,
        });
        const restored = transition.model.window(pending.window_id) orelse return;
        if (restored.space_key.eql(pending.source.key)) {
            refreshWorkspaceFocus(transition.model);
            if (transition.model.focusedWorkspaceWindow(pending.source.workspace_id) == null) {
                window_reducer.reduceWorkspaceFocusRecorded(transition, .{
                    .workspace_id = pending.source.workspace_id,
                    .window_id = pending.window_id,
                });
            }
            _ = transition.model.pending_native_window_moves.remove(event.window_id);
            transition.addEffect(.{ .native_window_move_rolled_back = pending });
            return;
        }
    }
    transition.addEffect(.{ .native_window_move_rollback_deferred = pending });
}

pub fn reduceNativeWorkspaceMoveRequest(
    transition: *Transition,
    request: @FieldType(Event, "request_native_workspace_move"),
) void {
    const source_display_id = transition.model.focusedDisplay();
    const plan = if (isWorkspaceMoveBlocked(transition.model))
        null
    else
        planNativeWorkspaceMove(transition.model, request.command, source_display_id);
    var pending = plan orelse {
        transition.addEffect(.{ .native_workspace_move_rejected = .{
            .target = request.command.target,
            .source_display_id = source_display_id,
        } });
        return;
    };

    if (transition.model.workspace_transition) |settling| {
        settleWorkspaceTransition(transition, settling.epoch, .superseded);
    }
    pending.epoch = takeEpoch(transition.model);
    pending.started_at_ms = request.at_ms;
    pending.deadline_at_ms = request.at_ms +| native_workspace_move_timeout_ms;
    transition.model.pending_native_workspace_move = pending;
    // The transition guards the moving workspace. Its Space keeps its key,
    // so the transition follows it to the target display when the topology
    // syncs.
    startWorkspaceTransition(
        transition,
        .move_workspace_to_display,
        pending.source,
        request.at_ms,
        native_workspace_move_timeout_ms,
        pending.epoch,
    );
    transition.addEffect(.{ .move_native_workspace_spaces = pending });
}

/// A move waits for the previous workspace operation to land. A completed
/// transition's settle tail does not block; the move's own transition
/// supersedes it and keeps synthetic AX events suppressed.
fn isWorkspaceMoveBlocked(model: *const Model) bool {
    if (model.pending_native_workspace_move != null) return true;
    if (model.pending_switch != null or model.queued_switch != null) return true;
    if (model.pending_native_window_moves.count != 0) return true;
    const current = model.workspace_transition orelse return false;
    return current.completion_reason == null;
}

fn resolveTargetDisplay(command: WorkspaceMoveCommand, source_display_id: DisplayId) ?DisplayId {
    const display_ids = command.display_order.ids();
    if (display_ids.len < 2) return null;
    const source_index = std.mem.indexOfScalar(DisplayId, display_ids, source_display_id) orelse return null;
    const target_index = switch (command.target) {
        .slot => |slot| slot,
        .next => (source_index + 1) % display_ids.len,
        .previous => (source_index + display_ids.len - 1) % display_ids.len,
    };
    if (target_index >= display_ids.len) return null;
    return display_ids[target_index];
}

/// Plans the move of the source display's visible workspace W onto the
/// target display, which shows X. Null rejects it.
fn planNativeWorkspaceMove(
    model: *const Model,
    command: WorkspaceMoveCommand,
    source_display_id: ?DisplayId,
) ?PendingNativeWorkspaceMove {
    const source_display_value = source_display_id orelse return null;
    const target_display_id = resolveTargetDisplay(command, source_display_value) orelse return null;
    if (source_display_value == target_display_id) return null;
    const source_workspace_id = model.activeWorkspace(source_display_value) orelse return null;
    const source = model.spaceForWorkspace(source_display_value, source_workspace_id) orelse return null;
    const target_workspace_id = model.activeWorkspace(target_display_id) orelse return null;
    const target = model.spaceForWorkspace(target_display_id, target_workspace_id) orelse return null;
    const source_display = model.native_topology.findDisplay(source.display_id) orelse return null;
    const target_display = model.native_topology.findDisplay(target.display_id) orelse return null;
    // The target gains a Space; capture past this many would lose one.
    if (target_display.space_count == target_display.spaces.len) return null;

    const moving: SpaceOperand = .{ .space = source.key.id };
    const displaced: SpaceOperand = .{ .space = target.key.id };
    var pending: PendingNativeWorkspaceMove = .{ .source = source, .target = target };
    if (source_display.space_count > 1) {
        addHandoverSteps(&pending, moving, displaced);
        return pending;
    }

    // W is the source display's only workspace, so the displays trade: the
    // same result every time, whichever workspaces are empty. A temporary
    // Space holds the source display while X crosses over, then steps away
    // so the source falls back to X.
    pending.backfill = target;
    pending.addStep(.{ .create_temporary = source.display_id });
    pending.addStep(.{ .move_before = .{ .space = moving, .anchor = displaced } });
    pending.addStep(.{ .move_to_end = .{ .space = displaced, .display_id = source.display_id } });
    pending.addStep(.{ .move_to_end = .{ .space = .temporary, .display_id = target.display_id } });
    pending.addStep(.destroy_temporary);
    return pending;
}

/// W goes just before X, so when X steps off the target display it falls
/// back to W; X then returns just after W. The source display falls back
/// to its own neighbor when W leaves.
fn addHandoverSteps(pending: *PendingNativeWorkspaceMove, moving: SpaceOperand, displaced: SpaceOperand) void {
    pending.addStep(.{ .move_before = .{ .space = moving, .anchor = displaced } });
    pending.addStep(.{ .move_to_end = .{ .space = displaced, .display_id = pending.source.display_id } });
    pending.addStep(.{ .move_after = .{ .space = displaced, .anchor = moving } });
}

pub fn reduceNativeWorkspaceMoveStarted(
    transition: *Transition,
    result: @FieldType(Event, "native_workspace_move_started"),
) void {
    var pending = transition.model.pending_native_workspace_move orelse return;
    if (pending.epoch != result.epoch or pending.has_started) return;
    if (!result.succeeded) {
        failNativeWorkspaceMove(transition, pending, result.at_ms);
        return;
    }

    // Observed as soon as the shell reads this, still inside the key press.
    pending.has_started = true;
    pending.observe_at_ms = result.at_ms;
    transition.model.pending_native_workspace_move = pending;
}

pub fn reduceNativeWorkspaceMoveObserved(
    transition: *Transition,
    event: @FieldType(Event, "native_workspace_move_observed"),
) void {
    var pending = transition.model.pending_native_workspace_move orelse return;
    if (pending.epoch != event.epoch or !pending.has_started) return;

    const topology = event.topology;
    const has_landed = if (topology) |observed| nativeWorkspaceMoveLanded(pending, observed) else false;
    if (has_landed) {
        transition.model.native_topology = topology.?.*;
        finishNativeWorkspaceMove(transition, pending, event.at_ms);
        return;
    }
    if (event.at_ms >= pending.deadline_at_ms) {
        failNativeWorkspaceMove(transition, pending, event.at_ms);
        return;
    }
    pending.observe_at_ms = nextWorkspaceMoveObservationAt(pending, event.at_ms);
    transition.model.pending_native_workspace_move = pending;
}

fn nextWorkspaceMoveObservationAt(pending: PendingNativeWorkspaceMove, at_ms: TimestampMs) TimestampMs {
    const is_fast = at_ms -| pending.started_at_ms < model_mod.native_workspace_move_fast_window_ms;
    const delay_ms = if (is_fast)
        model_mod.native_workspace_move_fast_observe_ms
    else
        model_mod.native_workspace_move_slow_observe_ms;
    return @min(at_ms +| delay_ms, pending.deadline_at_ms);
}

/// The target display shows W, X sits on the side it should, and the source
/// shows the backfill the move chose. Intermediate states never match: X
/// returns to the target display only in the last step.
fn nativeWorkspaceMoveLanded(pending: PendingNativeWorkspaceMove, topology: *const NativeTopology) bool {
    const target_display = topology.findDisplay(pending.target.display_id) orelse return false;
    if (target_display.observed_space_id != pending.source.key.id) return false;
    if (target_display.workspaceForSpace(pending.source.key.id) != pending.source.workspace_id) return false;

    const source_display = topology.findDisplay(pending.source.display_id) orelse return false;
    if (pending.isExchange()) {
        return source_display.observed_space_id == pending.target.key.id;
    }
    if (target_display.workspaceForSpace(pending.target.key.id) != pending.target.workspace_id) return false;
    const backfill = pending.backfill orelse return source_display.observed_space_id != pending.source.key.id;
    return source_display.observed_space_id == backfill.key.id;
}

fn finishNativeWorkspaceMove(transition: *Transition, pending: PendingNativeWorkspaceMove, at_ms: TimestampMs) void {
    transition.model.pending_native_workspace_move = null;
    syncNativeWorkspaceTopology(transition);
    transition.model.workspace_topology.focused_display_id = pending.target.display_id;
    completeWorkspaceTransition(transition.model, pending.epoch, .native_space_changed, at_ms);
    transition.addEffect(.{ .native_workspace_move_completed = pending });

    // Spaces that moved while current can come back hidden but still drawn.
    var hidden: HiddenSpaces = .{};
    hidden.addIfHidden(&transition.model.native_topology, pending.source.key.id);
    hidden.addIfHidden(&transition.model.native_topology, pending.target.key.id);
    if (pending.backfill) |backfill| hidden.addIfHidden(&transition.model.native_topology, backfill.key.id);
    if (hidden.count > 0) transition.addEffect(.{ .hide_native_spaces = hidden });
    resumeQueuedWorkspaceSwitch(transition, at_ms);
}

fn failNativeWorkspaceMove(transition: *Transition, pending: PendingNativeWorkspaceMove, at_ms: TimestampMs) void {
    transition.model.pending_native_workspace_move = null;
    settleWorkspaceTransition(transition, pending.epoch, .native_switch_failed);
    transition.addEffect(.{ .native_workspace_move_failed = pending });
    resumeQueuedWorkspaceSwitch(transition, at_ms);
}

fn resumeQueuedWorkspaceSwitch(transition: *Transition, at_ms: TimestampMs) void {
    const queued = transition.model.queued_switch orelse return;
    transition.model.queued_switch = null;
    const target = transition.model.logicalWorkspace(queued.target.workspace_id) orelse return;
    reduceWorkspaceSwitchRequest(transition, .{ .target = target, .at_ms = at_ms });
}

pub fn reduceWindowFocusObserved(
    transition: *Transition,
    event: WindowFocusObservation,
) void {
    if (event.process_id <= 0 or event.window_id == 0) return;
    var observation = event;
    observation.target = transition.model.space(event.target.key) orelse return;

    const workspace_transition = transition.model.workspace_transition;
    if (observation.pending_transition_epoch) |epoch| {
        const current = workspace_transition orelse return;
        if (current.epoch != epoch) return;
    }

    const is_accepted = observation.is_target_visible and
        (observation.source == .keyboard or
            workspace_transition == null or
            observation.target.key.eql(workspace_transition.?.target.key));
    if (is_accepted) {
        if (transition.model.workspace_topology.findDisplay(observation.target.display_id) != null) {
            transition.model.workspace_topology.focused_display_id = observation.target.display_id;
        }
        if (workspace_transition) |current| {
            transition.addEffect(.{ .window_focus_accepted = .{
                .observation = observation,
                .transition = current,
            } });
            if (current.completion_reason == null) {
                completeWorkspaceTransition(
                    transition.model,
                    current.epoch,
                    .focus_accepted,
                    observation.at_ms,
                );
            }
            if (observation.source == .keyboard or observation.pending_transition_epoch != null) {
                transition.model.pending_focus.clear();
            }
        }
        return;
    }

    const current = workspace_transition orelse return;
    if (observation.source != .keyboard) {
        const pending: PendingFocus = .{
            .process_id = observation.process_id,
            .window_id = observation.window_id,
            .source = observation.source,
            .space_key = observation.target.key,
            .transition_epoch = current.epoch,
            .sequence = transition.model.pending_focus.takeSequence(),
        };
        transition.model.pending_focus.insertOrReplace(pending);
    }

    transition.addEffect(.{ .window_focus_deferred = .{
        .observation = observation,
        .transition = current,
        .pending_count = transition.model.pending_focus.count,
    } });
}

pub fn reducePendingFocusRequest(transition: *Transition) void {
    const workspace_transition = transition.model.workspace_transition orelse {
        transition.model.pending_focus.clear();
        return;
    };
    const pending = transition.model.pending_focus.takeLatest() orelse return;
    if (pending.transition_epoch != workspace_transition.epoch) return;

    transition.addEffect(.{ .apply_pending_focus = pending });
}

pub fn reduceDisplayResettleTimer(transition: *Transition, at_ms: TimestampMs) void {
    const due_at_ms = transition.model.display_resettle_due_at_ms orelse return;
    if (at_ms < due_at_ms) return;
    transition.model.display_resettle_due_at_ms = null;
    transition.addEffect(.display_resettle_due);
}

pub fn reduceRetileDisplayRequested(model: *Model, display_id: DisplayId) void {
    if (display_id == 0 or model.retile_request.all_displays) return;
    for (model.retile_request.display_ids[0..model.retile_request.display_count]) |existing| {
        if (existing == display_id) return;
    }
    if (model.retile_request.display_count == model.retile_request.display_ids.len) {
        model.retile_request.all_displays = true;
        model.retile_request.display_count = 0;
        return;
    }
    model.retile_request.display_ids[model.retile_request.display_count] = display_id;
    model.retile_request.display_count += 1;
}

pub fn windowCandidateIsValid(model: *const Model, candidate: WindowCandidate) bool {
    return candidate.process_id > 0 and
        candidate.window_id != 0 and
        model.space(candidate.space_key) != null;
}

pub fn pruneWindowCandidates(candidates: *WindowCandidates, spaces: *const SpaceCatalog) void {
    var index: usize = 0;
    while (index < candidates.count) {
        if (spaces.find(candidates.entries[index].space_key) != null) {
            index += 1;
            continue;
        }
        _ = candidates.remove(candidates.entries[index].window_id);
    }
}

pub fn reduceFollowFocusObserved(
    transition: *Transition,
    event: FollowFocusObservation,
) void {
    if (event.process_id <= 0 or event.window_id == 0 or event.leader_window_id == 0) return;
    var observation = event;
    observation.target = transition.model.space(event.target.key) orelse return;

    // Only the active app's focus says where the user is. A background app's
    // focused window changes on its own, and its AX answer can arrive after
    // the user has moved on; following it would pull the display to its Space.
    const is_from_active_app = if (transition.model.active_process_id) |active| active == observation.process_id else false;
    if (observation.source == .ax and !is_from_active_app) {
        transition.addEffect(.{ .follow_focus_ignored_inactive_app = observation });
        return;
    }

    if (transition.model.pending_switch) |pending| {
        transition.addEffect(.{ .follow_focus_ignored_during_native_switch = .{
            .observation = observation,
            .pending_target = pending.request.target,
        } });
        return;
    }

    // The user moved the window: it belongs where it is, and macOS is taking
    // the display there.
    if (adoptMovedWindow(transition, observation.leader_window_id, observation.space_id)) |space| {
        observation.target = space;
        observation.is_target_visible = transition.model.native_topology.isSpaceShown(space.key.id);
    }

    const workspace_transition = transition.model.workspace_transition;
    if (observation.is_target_visible) {
        if (workspace_transition == null) transition.model.deferred_follow_focus = null;
        return;
    }

    const current = workspace_transition orelse {
        transition.model.deferred_follow_focus = null;
        reduceWorkspaceSwitchRequest(transition, .{
            .target = observation.target,
            .at_ms = observation.at_ms,
        });
        if (transition.model.pending_switch) |*pending| {
            if (pending.request.target.key.eql(observation.target.key)) pending.request.follow_window_id = observation.window_id;
        }
        return;
    };

    transition.model.deferred_follow_focus = .{
        .process_id = observation.process_id,
        .window_id = observation.window_id,
        .source = observation.source,
        .transition_epoch = current.epoch,
    };
    transition.addEffect(.{ .follow_focus_deferred = .{
        .observation = observation,
        .transition = current,
    } });
}

const FailedSwitch = struct {
    reason: SwitchFailureReason,
    actual: ?SpaceRef,
};

pub fn finishSwitch(
    transition: *Transition,
    pending: PendingSwitch,
    at_ms: TimestampMs,
    failure: ?FailedSwitch,
) void {
    cancelGesture(transition);
    transition.model.pending_switch = null;
    transition.model.observation_timer = null;

    if (failure == null) {
        transition.model.deferred_follow_focus = null;
        transition.model.pending_focus.clear();
        completeWorkspaceTransition(
            transition.model,
            pending.epoch,
            .native_space_changed,
            at_ms,
        );
    } else {
        settleWorkspaceTransition(transition, pending.epoch, .native_switch_failed);
    }

    if (failure) |failed| {
        transition.addEffect(.{ .native_switch_failed = .{
            .request = pending.request,
            .epoch = pending.epoch,
            .reason = failed.reason,
            .actual = failed.actual,
        } });
    }

    const queued = transition.model.queued_switch orelse {
        if (failure == null) {
            transition.addEffect(.{ .native_switch_completed = .{
                .space = transition.model.space(pending.request.target.key) orelse pending.request.target,
                .epoch = pending.epoch,
            } });
            // macOS focuses whatever app was last active on the Space.
            if (pending.request.follow_window_id) |window_id| followed: {
                const leader = transition.model.window(transition.model.windowTabLeader(window_id)) orelse break :followed;
                if (!leader.space_key.eql(pending.request.target.key)) break :followed;
                window_reducer.reduceWorkspaceFocusRecorded(transition, .{
                    .workspace_id = pending.request.target.workspace_id,
                    .window_id = leader.window_id,
                });
                transition.addEffect(.{ .focus_followed_window = .{
                    .process_id = leader.process_id,
                    .window_id = transition.model.windowTabActive(leader.window_id),
                } });
            }
            if (pending.phase == .waiting_for_idle) {
                transition.addEffect(.{ .workspace_switch_ready = .{ .target = pending.request.target } });
            }
        }
        return;
    };
    transition.model.queued_switch = null;
    startSwitch(transition, queued, at_ms);
}

pub fn cancelGesture(transition: *Transition) void {
    const pending = transition.model.pending_switch orelse return;
    const gesture = pending.gesture orelse return;
    transition.addEffect(.{ .cancel_native_gesture = gesture.plan.direction });
}

pub fn startSwitch(
    transition: *Transition,
    request: SwitchRequest,
    at_ms: TimestampMs,
) void {
    const target = transition.model.space(request.target.key) orelse {
        transition.addEffect(.{ .native_switch_rejected = request.target });
        return;
    };
    var current_request = request;
    current_request.target = target;
    if (transition.model.native_topology.findDisplay(target.display_id) == null) {
        transition.addEffect(.{ .native_switch_rejected = target });
        return;
    }

    transition.model.workspace_topology.focused_display_id = target.display_id;

    const epoch = takeEpoch(transition.model);
    const pending: PendingSwitch = .{
        .request = current_request,
        .epoch = epoch,
        .deadline_at_ms = at_ms +| native_switch_timeout_ms,
    };
    transition.model.pending_switch = pending;
    startWorkspaceTransition(
        transition,
        .switch_workspace,
        target,
        at_ms,
        native_switch_timeout_ms,
        pending.epoch,
    );
    schedulePendingObservation(transition.model, pending, at_ms);
    transition.addEffect(.{ .observe_native_topology = epoch });
}

pub fn startWorkspaceTransition(
    transition: *Transition,
    kind: WorkspaceTransitionKind,
    target: SpaceRef,
    at_ms: TimestampMs,
    timeout_ms: TimestampMs,
    requested_epoch: ?Epoch,
) void {
    target.assertValid();
    std.debug.assert(timeout_ms > 0);

    const transition_epoch = requested_epoch orelse takeEpoch(transition.model);
    const workspace_transition: WorkspaceTransition = .{
        .kind = kind,
        .target = target,
        .epoch = transition_epoch,
        .started_at_ms = at_ms,
        .deadline_at_ms = at_ms +| timeout_ms,
    };
    transition.model.workspace_transition = workspace_transition;
    transition.model.pending_focus.clear();
    transition.model.deferred_follow_focus = null;
    transition.addEffect(.{ .workspace_transition_started = workspace_transition });
}

pub fn completeWorkspaceTransition(
    model: *Model,
    epoch: Epoch,
    reason: WorkspaceTransitionCompletionReason,
    at_ms: TimestampMs,
) void {
    const current = model.workspace_transition orelse return;
    if (current.epoch != epoch) return;

    var completed = current;
    completed.completion_reason = reason;
    completed.deadline_at_ms = at_ms +| workspace_transition_settle_ms;
    model.workspace_transition = completed;
}

pub fn settleWorkspaceTransition(
    transition: *Transition,
    epoch: Epoch,
    reason: WorkspaceTransitionSettlementReason,
) void {
    const current = transition.model.workspace_transition orelse return;
    if (current.epoch != epoch) return;

    finalizeWorkspaceTransition(transition, current, reason);
}

pub fn finalizeWorkspaceTransition(
    transition: *Transition,
    current: WorkspaceTransition,
    reason: WorkspaceTransitionSettlementReason,
) void {
    transition.model.workspace_transition = null;
    transition.model.pending_focus.clear();
    const deferred_follow_focus = transition.model.deferred_follow_focus;
    transition.model.deferred_follow_focus = null;
    transition.addEffect(.{ .workspace_transition_settled = .{
        .transition = current,
        .reason = reason,
        .deferred_follow_focus = deferred_follow_focus,
    } });
}

pub fn refreshWorkspaceTransition(transition: *Transition) void {
    var current = transition.model.workspace_transition orelse return;
    current.target = transition.model.space(current.target.key) orelse {
        finalizeWorkspaceTransition(transition, current, .target_unavailable);
        return;
    };
    transition.model.workspace_transition = current;
}

pub fn refreshPendingNativeWindowMoves(model: *Model) void {
    var write_index: usize = 0;
    for (model.pending_native_window_moves.items()) |pending| {
        var refreshed = pending;
        refreshed.source = model.space(pending.source.key) orelse continue;
        refreshed.target = model.space(pending.target.key) orelse continue;
        model.pending_native_window_moves.entries[write_index] = refreshed;
        write_index += 1;
    }
    model.pending_native_window_moves.count = @intCast(write_index);
}

pub fn schedulePendingObservation(model: *Model, pending: PendingSwitch, at_ms: TimestampMs) void {
    model.observation_timer = .{
        .epoch = pending.epoch,
        .due_at_ms = at_ms +| native_observation_delay_ms,
    };
}

pub fn takeEpoch(model: *Model) Epoch {
    const epoch = model.next_epoch;
    model.next_epoch +%= 1;
    if (model.next_epoch == 0) model.next_epoch = 1;
    return epoch;
}

pub fn sameRequest(left: SwitchRequest, right: SwitchRequest) bool {
    return left.target.key.eql(right.target.key);
}

/// Renumbering a surviving Space must carry its focus history with its windows.
/// Replaced Spaces still inherit the history of their logical workspace.
pub fn remapWorkspaceFocus(model: *Model, previous_catalog: *const SpaceCatalog) void {
    const previous_focus = model.workspace_focus;
    model.workspace_focus = @splat(.{});
    for (model.spaces.spaces[0..model.spaces.space_count]) |space| {
        const previous = previous_catalog.find(space.key) orelse
            previous_catalog.findLogicalWorkspace(space.workspace_id) orelse continue;
        model.workspace_focus[space.workspace_id - 1] = previous_focus[previous.workspace_id - 1];
    }
}

pub fn refreshWorkspaceFocus(model: *Model) void {
    for (&model.workspace_focus, 0..) |*focus, index| {
        const had_focus = focus.focused_window_id != null;
        const history = focus.history;
        const history_count = focus.history_count;
        focus.* = .{};

        const workspace_id: WorkspaceId = @intCast(index + 1);
        const space = model.logicalWorkspace(workspace_id) orelse continue;
        for (history[0..history_count]) |window_id| {
            const window = model.window(window_id) orelse continue;
            const leader = model.window(window.tab_leader_window_id).?;
            if (!leader.space_key.eql(space.key)) continue;
            focus.record(leader.window_id);
        }
        if (focus.focused_window_id == null and had_focus) {
            if (firstWorkspaceWindow(model, space.key)) |window_id| focus.record(window_id);
        }
    }
}

pub fn firstWorkspaceWindow(model: *const Model, space_key: SpaceKey) ?WindowId {
    for (model.windows.items()) |window| {
        if (!window.space_key.eql(space_key)) continue;
        if (window.tab_leader_window_id != window.window_id) continue;
        return window.window_id;
    }
    return null;
}
