//! Workspace, native Space, and focus transitions.

const std = @import("std");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");
const pointer_reducer = @import("pointer.zig");
const window_reducer = @import("window.zig");
const tiling_mod = @import("../../tiling.zig");

const max_spaces_per_display = model_mod.max_spaces_per_display;
const native_switch_timeout_ms = model_mod.native_switch_timeout_ms;
const native_observation_delay_ms = model_mod.native_observation_delay_ms;
const native_workspace_move_timeout_ms = model_mod.native_workspace_move_timeout_ms;
const workspace_transition_settle_ms = model_mod.workspace_transition_settle_ms;
const DisplayId = model_mod.DisplayId;
const NativeSpaceId = model_mod.NativeSpaceId;
const WorkspaceId = model_mod.WorkspaceId;
const SpaceKey = model_mod.SpaceKey;
const SpaceRef = model_mod.SpaceRef;
const WorkspaceTopology = model_mod.WorkspaceTopology;
const SpaceCatalog = model_mod.SpaceCatalog;
const Space = model_mod.Space;
const Epoch = model_mod.Epoch;
const TimestampMs = model_mod.TimestampMs;
const WindowId = model_mod.WindowId;
const FollowFocusObservation = model_mod.FollowFocusObservation;
const WindowFocusObservation = model_mod.WindowFocusObservation;
const WorkspaceFocus = model_mod.WorkspaceFocus;
const SwitchRequest = model_mod.SwitchRequest;
const PendingSwitch = model_mod.PendingSwitch;
const WorkspaceTransitionKind = model_mod.WorkspaceTransitionKind;
const WorkspaceTransitionCompletionReason = model_mod.WorkspaceTransitionCompletionReason;
const WorkspaceTransition = model_mod.WorkspaceTransition;
const WorkspaceTransitionSettlementReason = model_mod.WorkspaceTransitionSettlementReason;
const WorkspaceTransitionSettlement = model_mod.WorkspaceTransitionSettlement;
const PendingNativeWindowMove = model_mod.PendingNativeWindowMove;
const PendingNativeWindowMoves = model_mod.PendingNativeWindowMoves;
const PendingNativeWorkspaceMove = model_mod.PendingNativeWorkspaceMove;
const NativeWindowMoveRequest = model_mod.NativeWindowMoveRequest;
const WindowMoveRequest = model_mod.WindowMoveRequest;
const PendingFocus = model_mod.PendingFocus;
const WindowCandidate = model_mod.WindowCandidate;
const WindowCandidates = model_mod.WindowCandidates;
const PendingWorkspacePark = model_mod.PendingWorkspacePark;
const PendingWorkspaceParks = model_mod.PendingWorkspaceParks;
const WorkspaceInitialization = model_mod.WorkspaceInitialization;
const VirtualDisplayObservation = model_mod.VirtualDisplayObservation;
const ObservationTimer = model_mod.ObservationTimer;
const Model = model_mod.Model;
const Event = model_mod.Event;
const SwitchFailureReason = model_mod.SwitchFailureReason;
const Effect = model_mod.Effect;
const Transition = model_mod.Transition;

pub fn reduceWorkspaceInitialization(transition: *Transition, initialization: WorkspaceInitialization) void {
    if (transition.model.windows.count != 0 or transition.model.spaces.space_count != 0) return;
    if (initialization.display_count == 0 or initialization.workspace_count == 0) return;
    if (initialization.display_count > initialization.workspace_count) return;

    var primary_slot: ?usize = null;
    for (initialization.display_ids[0..initialization.display_count], 0..) |display_id, slot| {
        if (display_id == 0) return;
        if (display_id == initialization.primary_display_id) primary_slot = slot;
        for (initialization.display_ids[0..slot]) |prior| {
            if (prior == display_id) return;
        }
    }
    const primary_index = primary_slot orelse return;

    var workspace_displays: [max_spaces_per_display]DisplayId = @splat(initialization.primary_display_id);
    var topology: WorkspaceTopology = .{};
    var extra_display_count: WorkspaceId = 0;
    for (initialization.display_ids[0..initialization.display_count], 0..) |display_id, slot| {
        const workspace_id: WorkspaceId = if (slot == primary_index)
            1
        else
            initialization.workspace_count - extra_display_count;
        topology.addDisplay(.{
            .display_id = display_id,
            .active_workspace_id = workspace_id,
        });
        if (slot == primary_index) continue;

        workspace_displays[workspace_id - 1] = display_id;
        extra_display_count += 1;
    }
    topology.focused_display_id = initialization.primary_display_id;

    var catalog: SpaceCatalog = .{};
    var workspace_id: WorkspaceId = 1;
    while (workspace_id <= initialization.workspace_count) : (workspace_id += 1) {
        catalog.add(.{
            .key = .{ .virtual = workspace_id },
            .workspace_id = workspace_id,
            .display_id = workspace_displays[workspace_id - 1],
        });
    }
    transition.model.spaces = catalog;
    transition.model.workspace_topology = topology;
}

pub fn reduceWorkspaceSwitchRequest(
    transition: *Transition,
    request: @FieldType(Event, "request_workspace_switch"),
) void {
    const target = transition.model.space(request.target.key) orelse return;
    const active_workspace_id = transition.model.activeWorkspace(target.display_id) orelse return;
    if (active_workspace_id == target.workspace_id) {
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

    switch (target.key) {
        .native => reduceSwitchRequest(transition, .{
            .target = target,
            .at_ms = request.at_ms,
        }),
        .virtual => {
            const outgoing = transition.model.spaceForWorkspace(target.display_id, active_workspace_id) orelse return;
            if (!transition.model.workspace_topology.setActiveWorkspace(target.display_id, target.workspace_id)) return;
            transition.model.workspace_topology.focused_display_id = target.display_id;
            startWorkspaceTransition(
                transition,
                .switch_workspace,
                target,
                request.at_ms,
                workspace_transition_settle_ms,
                null,
            );
            pointer_reducer.clearDragPreview(transition);
            transition.addEffect(.{ .workspace_switch_ready = .{
                .target = target,
                .outgoing = outgoing,
            } });
        },
    }
}

pub fn reduceVirtualWorkspaceMoveRequest(
    transition: *Transition,
    request: @FieldType(Event, "request_virtual_workspace_move"),
) void {
    if (request.source_display_id == request.target_display_id) return;
    const moving_workspace_id = transition.model.activeWorkspace(request.source_display_id) orelse return;
    const displaced_workspace_id = transition.model.activeWorkspace(request.target_display_id) orelse return;
    const moving = transition.model.spaceForWorkspace(request.source_display_id, moving_workspace_id) orelse return;
    const displaced = transition.model.spaceForWorkspace(request.target_display_id, displaced_workspace_id) orelse return;
    if (moving.key != .virtual or displaced.key != .virtual) return;

    var fallback = displaced;
    for (transition.model.spaces.spaces[0..transition.model.spaces.space_count]) |space| {
        if (space.workspace_id == moving.workspace_id) continue;
        if (space.display_id != request.source_display_id) continue;
        if (transition.model.activeWorkspace(space.display_id) == space.workspace_id) continue;
        fallback = space;
        break;
    }

    if (!transition.model.workspace_topology.setActiveWorkspace(request.target_display_id, moving.workspace_id)) return;
    if (!transition.model.workspace_topology.setActiveWorkspace(request.source_display_id, fallback.workspace_id)) return;
    if (!transition.model.spaces.setDisplay(moving.key, request.target_display_id)) return;
    if (!transition.model.spaces.setDisplay(fallback.key, request.source_display_id)) return;
    transition.model.workspace_topology.focused_display_id = request.target_display_id;
    transition.model.pending_workspace_parks.count = 0;
    pruneWindowCandidates(&transition.model.pending_role_windows, &transition.model.spaces);
    pruneWindowCandidates(&transition.model.deferred_window_candidates, &transition.model.spaces);

    const moved = transition.model.space(moving.key).?;
    startWorkspaceTransition(
        transition,
        .move_workspace_to_display,
        moved,
        request.at_ms,
        workspace_transition_settle_ms,
        null,
    );
    pointer_reducer.clearDragPreview(transition);
    transition.addEffect(.{ .virtual_workspace_move_ready = .{
        .moving = moved,
        .displaced = displaced,
    } });
}

pub fn reduceVirtualDisplaysObserved(transition: *Transition, observation: VirtualDisplayObservation) void {
    const workspace_count = transition.model.spaces.space_count;
    if (observation.display_count == 0 or observation.display_count > workspace_count) return;
    if (!displayObservationContains(&observation, observation.primary_display_id)) return;
    if (!displayObservationContains(&observation, observation.focused_display_id)) return;

    for (transition.model.spaces.spaces[0..workspace_count]) |space| {
        if (space.key != .virtual) return;
        if (space.workspace_id == 0 or space.workspace_id > workspace_count) return;
    }

    var catalog = transition.model.spaces;
    var topology: WorkspaceTopology = .{};
    var active_workspaces: [max_spaces_per_display + 1]bool = @splat(false);
    for (observation.displays[0..observation.display_count]) |display| {
        var workspace_id: WorkspaceId = 0;
        if (display.uuid) |uuid| {
            if (transition.model.display_memory.get(uuid)) |remembered| {
                if (remembered.active_workspace_id <= workspace_count and
                    !active_workspaces[remembered.active_workspace_id])
                {
                    workspace_id = remembered.active_workspace_id;
                }
            }
        }
        if (workspace_id == 0) {
            workspace_id = firstUnclaimedWorkspace(active_workspaces[0 .. workspace_count + 1]) orelse return;
        }

        active_workspaces[workspace_id] = true;
        topology.addDisplay(.{
            .display_id = display.display_id,
            .active_workspace_id = workspace_id,
        });
        const space = catalog.findLogicalWorkspace(workspace_id) orelse return;
        std.debug.assert(catalog.setDisplay(space.key, display.display_id));
    }
    topology.focused_display_id = observation.focused_display_id;

    for (catalog.spaces[0..catalog.space_count]) |space| {
        if (active_workspaces[space.workspace_id]) continue;
        const home_uuid = observation.workspace_home_uuids[space.workspace_id - 1];
        const display_id = observedDisplayIdForUuid(&observation, home_uuid) orelse observation.primary_display_id;
        std.debug.assert(catalog.setDisplay(space.key, display_id));
    }

    transition.model.spaces = catalog;
    transition.model.workspace_topology = topology;
    transition.model.pending_workspace_parks.count = 0;
    pruneWindowCandidates(&transition.model.pending_role_windows, &catalog);
    pruneWindowCandidates(&transition.model.deferred_window_candidates, &catalog);
    refreshWorkspaceTransition(transition);
    refreshPendingNativeWindowMoves(&transition.model);
    refreshWorkspaceFocus(&transition.model);
    for (observation.displays[0..observation.display_count]) |display| {
        const uuid = display.uuid orelse continue;
        const workspace_id = topology.activeWorkspace(display.display_id).?;
        transition.model.display_memory.remember(.{
            .uuid = uuid,
            .active_workspace_id = workspace_id,
        });
    }
    transition.addEffect(.virtual_displays_reconciled);
}

pub fn firstUnclaimedWorkspace(claimed: []const bool) ?WorkspaceId {
    var workspace_id: WorkspaceId = 1;
    while (workspace_id < claimed.len) : (workspace_id += 1) {
        if (!claimed[workspace_id]) return workspace_id;
    }
    return null;
}

pub fn displayObservationContains(observation: *const VirtualDisplayObservation, display_id: DisplayId) bool {
    for (observation.displays[0..observation.display_count]) |display| {
        if (display.display_id == display_id) return true;
    }
    return false;
}

pub fn observedDisplayIdForUuid(observation: *const VirtualDisplayObservation, uuid: ?[16]u8) ?DisplayId {
    const expected = uuid orelse return null;
    for (observation.displays[0..observation.display_count]) |display| {
        const actual = display.uuid orelse continue;
        if (std.mem.eql(u8, &actual, &expected)) return display.display_id;
    }
    return null;
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
    if (nativeSpaceId(target) == null) {
        transition.addEffect(.{ .native_switch_rejected = event.target });
        return;
    }
    const request: SwitchRequest = .{ .target = target };

    if (transition.model.pending_switch) |pending| {
        transition.model.queued_switch = if (sameRequest(request, pending.request)) null else request;
        return;
    }

    startSwitch(transition, request, event.at_ms, true);
}

pub fn reduceSpaceChanged(transition: *Transition, at_ms: TimestampMs) void {
    if (transition.model.pending_switch) |pending| {
        transition.model.observation_timer = null;
        transition.addEffect(.{ .observe_native_topology = pending.epoch });
        return;
    }

    const epoch = takeEpoch(&transition.model);
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
    const has_changed = !transition.model.native_topology.eql(&event.topology);
    transition.model.native_topology = event.topology;
    syncNativeWorkspaceTopology(transition);

    const pending = transition.model.pending_switch orelse {
        transition.model.observation_timer = null;
        if (has_changed) transition.addEffect(.native_topology_changed);
        return;
    };
    if (event.epoch != pending.epoch) return;

    const display = event.topology.findDisplay(pending.request.target.display_id);
    const actual_space_id = if (display) |value| value.observed_space_id else null;
    if (actual_space_id == nativeSpaceId(pending.request.target)) {
        finishSwitch(transition, pending, event.at_ms, null);
        return;
    }

    if (event.at_ms < pending.deadline_at_ms) {
        schedulePendingObservation(&transition.model, pending, event.at_ms);
        return;
    }

    finishSwitch(transition, pending, event.at_ms, .{
        .reason = .unexpected_space,
        .actual = if (actual_space_id) |space_id| transition.model.space(.{ .native = space_id }) else null,
    });
}

pub fn syncNativeWorkspaceTopology(transition: *Transition) void {
    const focused_display_id = transition.model.workspace_topology.focused_display_id;
    var topology: WorkspaceTopology = .{};
    var catalog: SpaceCatalog = .{};
    for (transition.model.native_topology.displays[0..transition.model.native_topology.display_count]) |display| {
        for (display.spaces[0..display.space_count]) |space| {
            catalog.add(.{
                .key = .{ .native = space.id },
                .workspace_id = space.workspace_id,
                .display_id = display.display_id,
            });
        }

        const workspace_id = display.workspaceForSpace(display.observed_space_id) orelse continue;
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
    refreshWorkspaceTransition(transition);
    refreshPendingNativeWindowMoves(&transition.model);
}

pub fn reduceTopologyUnavailable(
    transition: *Transition,
    event: @FieldType(Event, "native_topology_unavailable"),
) void {
    const pending = transition.model.pending_switch orelse return;
    if (event.epoch != pending.epoch) return;

    if (event.at_ms < pending.deadline_at_ms) {
        schedulePendingObservation(&transition.model, pending, event.at_ms);
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
        .actual = if (actual_space_id) |space_id| transition.model.space(.{ .native = space_id }) else null,
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
    if (nativeSpaceId(source) == null or nativeSpaceId(target) == null or source.key.eql(target.key)) {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    }

    const pending: PendingNativeWindowMove = .{
        .window_id = request.window_id,
        .source = source,
        .target = target,
        .epoch = takeEpoch(&transition.model),
    };
    if (!transition.model.pending_native_window_moves.put(pending)) {
        transition.addEffect(.{ .native_window_move_rejected = request });
        return;
    }
    transition.addEffect(.{ .move_native_window = pending });
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
            .layout = event.layout,
        });
        const restored = transition.model.window(pending.window_id) orelse return;
        if (restored.space_key.eql(pending.source.key)) {
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
    const source = transition.model.space(request.source.key) orelse {
        transition.addEffect(.{ .native_workspace_move_rejected = .{
            .source = request.source,
            .target = request.target,
        } });
        return;
    };
    const target = transition.model.space(request.target.key) orelse {
        transition.addEffect(.{ .native_workspace_move_rejected = .{
            .source = request.source,
            .target = request.target,
        } });
        return;
    };
    const is_invalid = transition.model.pending_native_workspace_move != null or
        transition.model.pending_switch != null or
        transition.model.pending_native_window_moves.count != 0 or
        transition.model.workspace_transition != null or
        nativeSpaceId(source) == null or
        nativeSpaceId(target) == null or
        source.key.eql(target.key) or
        source.display_id == target.display_id;
    if (is_invalid) {
        transition.addEffect(.{ .native_workspace_move_rejected = .{
            .source = source,
            .target = target,
        } });
        return;
    }

    const epoch = takeEpoch(&transition.model);
    const pending: PendingNativeWorkspaceMove = .{
        .source = source,
        .target = target,
        .epoch = epoch,
        .deadline_at_ms = request.at_ms +| native_workspace_move_timeout_ms,
    };
    transition.model.pending_native_workspace_move = pending;
    startWorkspaceTransition(
        transition,
        .move_workspace_to_display,
        target,
        request.at_ms,
        native_workspace_move_timeout_ms,
        epoch,
    );
    transition.addEffect(.{ .move_native_workspace_contents = pending });
}

pub fn reduceNativeWorkspaceMoveStarted(
    transition: *Transition,
    result: @FieldType(Event, "native_workspace_move_started"),
) void {
    var pending = transition.model.pending_native_workspace_move orelse return;
    if (pending.epoch != result.epoch) return;
    if (!result.succeeded) {
        transition.model.pending_native_workspace_move = null;
        settleWorkspaceTransition(transition, pending.epoch, .native_switch_failed);
        transition.addEffect(.{ .native_workspace_move_failed = .{
            .move = pending,
            .rollback_succeeded = true,
        } });
        return;
    }

    pending.has_started = true;
    transition.model.pending_native_workspace_move = pending;
}

pub fn reduceNativeWorkspaceMoveObserved(
    transition: *Transition,
    event: @FieldType(Event, "native_workspace_move_observed"),
) void {
    var pending = transition.model.pending_native_workspace_move orelse return;
    if (pending.epoch != event.epoch or !pending.has_started or pending.is_rolling_back) return;

    if (event.observation == .pending) {
        if (event.at_ms < pending.deadline_at_ms) return;
        pending.is_rolling_back = true;
        transition.model.pending_native_workspace_move = pending;
        transition.addEffect(.{ .rollback_native_workspace_contents = pending });
        return;
    }

    if (!transition.model.native_topology.swapWorkspacePlacements(pending.source.key, pending.target.key)) {
        pending.is_rolling_back = true;
        transition.model.pending_native_workspace_move = pending;
        transition.addEffect(.{ .rollback_native_workspace_contents = pending });
        return;
    }
    if (!layout_reducer.applyEvent(transition, .{ .swap_layouts = .{
        .first_key = pending.source.key,
        .second_key = pending.target.key,
    } })) {
        _ = transition.model.native_topology.swapWorkspacePlacements(pending.source.key, pending.target.key);
        pending.is_rolling_back = true;
        transition.model.pending_native_workspace_move = pending;
        transition.addEffect(.{ .rollback_native_workspace_contents = pending });
        return;
    }
    transition.model.windows.swapSpaceKeys(pending.source.key, pending.target.key);
    transition.model.pending_native_workspace_move = null;
    syncNativeWorkspaceTopology(transition);
    const moved = transition.model.space(pending.target.key).?;
    transition.model.workspace_topology.focused_display_id = moved.display_id;
    completeWorkspaceTransition(&transition.model, pending.epoch, .native_space_changed, event.at_ms);
    transition.addEffect(.{ .native_workspace_move_completed = pending });
}

pub fn reduceNativeWorkspaceMoveRollbackResult(
    transition: *Transition,
    result: @FieldType(Event, "native_workspace_move_rollback_result"),
) void {
    const pending = transition.model.pending_native_workspace_move orelse return;
    if (pending.epoch != result.epoch or !pending.is_rolling_back) return;

    transition.model.pending_native_workspace_move = null;
    settleWorkspaceTransition(transition, pending.epoch, .native_switch_failed);
    transition.addEffect(.{ .native_workspace_move_failed = .{
        .move = pending,
        .rollback_succeeded = result.succeeded,
    } });
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
                    &transition.model,
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

pub fn reduceWorkspaceRevealObserved(
    transition: *Transition,
    observation: @FieldType(Event, "workspace_reveal_observed"),
) void {
    const outgoing = transition.model.space(observation.outgoing.key) orelse return;
    const target = transition.model.space(observation.target.key) orelse return;
    if (outgoing.key.eql(target.key) or outgoing.display_id != target.display_id) return;

    const prior = transition.model.pending_workspace_parks.remove(target.display_id);
    if (observation.is_revealed) {
        transition.addEffect(.{ .park_workspace = .{ .outgoing = outgoing, .target = target } });
        if (prior) |pending| {
            if (!pending.outgoing.key.eql(outgoing.key) and
                !pending.outgoing.key.eql(target.key))
            {
                const prior_outgoing = transition.model.space(pending.outgoing.key) orelse return;
                transition.addEffect(.{ .park_workspace = .{ .outgoing = prior_outgoing, .target = target } });
            }
        }
        return;
    }

    var cover = outgoing;
    if (prior) |pending| {
        if (!pending.outgoing.key.eql(target.key) and
            !pending.outgoing.key.eql(outgoing.key))
        {
            transition.addEffect(.{ .park_workspace = .{ .outgoing = outgoing, .target = target } });
            cover = transition.model.space(pending.outgoing.key) orelse outgoing;
        }
    }
    if (!transition.model.pending_workspace_parks.put(.{
        .outgoing = cover,
        .target = target,
        .deadline_at_ms = observation.deadline_at_ms,
    })) @panic("pending workspace park capacity exceeded");
}

pub fn reduceWorkspaceParkTimer(
    transition: *Transition,
    timer: @FieldType(Event, "workspace_park_timer_fired"),
) void {
    const pending = transition.model.pending_workspace_parks.get(timer.display_id) orelse return;
    const active_workspace_id = transition.model.activeWorkspace(timer.display_id) orelse return;
    const active = transition.model.spaceForWorkspace(timer.display_id, active_workspace_id) orelse return;
    if (!active.key.eql(pending.target.key)) {
        _ = transition.model.pending_workspace_parks.remove(timer.display_id);
        if (!pending.outgoing.key.eql(active.key)) {
            const outgoing = transition.model.space(pending.outgoing.key) orelse return;
            transition.addEffect(.{ .park_workspace = .{ .outgoing = outgoing, .target = active } });
        }
        return;
    }
    if (!timer.is_revealed and timer.at_ms < pending.deadline_at_ms) return;

    _ = transition.model.pending_workspace_parks.remove(timer.display_id);
    const outgoing = transition.model.space(pending.outgoing.key) orelse return;
    const target = transition.model.space(pending.target.key) orelse return;
    transition.addEffect(.{ .park_workspace = .{
        .outgoing = outgoing,
        .target = target,
        .did_time_out = !timer.is_revealed,
    } });
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

pub fn refreshPendingWorkspaceParks(parks: *PendingWorkspaceParks, spaces: *const SpaceCatalog) void {
    var index: usize = 0;
    while (index < parks.count) {
        const outgoing = spaces.find(parks.entries[index].outgoing.key);
        const target = spaces.find(parks.entries[index].target.key);
        if (outgoing == null or target == null or outgoing.?.display_id != target.?.display_id) {
            _ = parks.remove(parks.entries[index].target.display_id);
            continue;
        }
        parks.entries[index].outgoing = outgoing.?;
        parks.entries[index].target = target.?;
        index += 1;
    }
}

pub fn reduceFollowFocusObserved(
    transition: *Transition,
    event: FollowFocusObservation,
) void {
    if (event.process_id <= 0 or event.window_id == 0 or event.leader_window_id == 0) return;
    var observation = event;
    observation.target = transition.model.space(event.target.key) orelse return;

    if (transition.model.pending_switch) |pending| {
        transition.addEffect(.{ .follow_focus_ignored_during_native_switch = .{
            .observation = observation,
            .pending_target = pending.request.target,
        } });
        return;
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
    transition.model.pending_switch = null;
    transition.model.observation_timer = null;

    if (failure == null) {
        transition.model.deferred_follow_focus = null;
        transition.model.pending_focus.clear();
        completeWorkspaceTransition(
            &transition.model,
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
        }
        return;
    };
    transition.model.queued_switch = null;
    startSwitch(transition, queued, at_ms, failure != null);
}

pub fn startSwitch(
    transition: *Transition,
    request: SwitchRequest,
    at_ms: TimestampMs,
    should_focus_if_observed: bool,
) void {
    const target = transition.model.space(request.target.key) orelse {
        transition.addEffect(.{ .native_switch_rejected = request.target });
        return;
    };
    const current_request: SwitchRequest = .{ .target = target };
    const display = transition.model.native_topology.findDisplay(target.display_id) orelse {
        transition.addEffect(.{ .native_switch_rejected = target });
        return;
    };
    if (display.observed_space_id == nativeSpaceId(target).?) {
        if (should_focus_if_observed) {
            transition.model.workspace_topology.focused_display_id = target.display_id;
            transition.addEffect(.{ .workspace_switch_ready = .{ .target = target } });
        } else {
            transition.addEffect(.{ .native_switch_completed = .{
                .space = target,
                .epoch = 0,
            } });
        }
        return;
    }

    transition.model.workspace_topology.focused_display_id = target.display_id;

    const epoch = takeEpoch(&transition.model);
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
    schedulePendingObservation(&transition.model, pending, at_ms);
    transition.addEffect(.{ .switch_native_space = .{
        .request = current_request,
        .epoch = epoch,
    } });
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

    const transition_epoch = requested_epoch orelse takeEpoch(&transition.model);
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

pub fn nativeSpaceId(space: SpaceRef) ?NativeSpaceId {
    return switch (space.key) {
        .native => |space_id| space_id,
        .virtual => null,
    };
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
