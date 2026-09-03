//! Deterministic application state and transitions.

const std = @import("std");
const geometry_mod = @import("geometry.zig");
const invariants = @import("state/invariants.zig");
const model_mod = @import("state/model.zig");
const command_reducer = @import("state/reducer/command.zig");
const discovery_reducer = @import("state/reducer/discovery.zig");
const layout_reducer = @import("state/reducer/layout.zig");
const pointer_reducer = @import("state/reducer/pointer.zig");
const window_reducer = @import("state/reducer/window.zig");
const workspace_reducer = @import("state/reducer/workspace.zig");
const tiling_mod = @import("tiling.zig");
const window_mod = @import("window.zig");

pub const max_displays = model_mod.max_displays;
pub const max_managed_windows = model_mod.max_managed_windows;
pub const max_pending_focus_entries = model_mod.max_pending_focus_entries;
pub const max_pending_window_candidates = model_mod.max_pending_window_candidates;
pub const max_process_retries = model_mod.max_process_retries;
pub const max_cleanup_processes = model_mod.max_cleanup_processes;
pub const max_spaces_per_display = model_mod.max_spaces_per_display;
pub const max_workspace_focus_history = model_mod.max_workspace_focus_history;
pub const max_pending_native_window_moves = model_mod.max_pending_native_window_moves;
pub const native_switch_timeout_ms = model_mod.native_switch_timeout_ms;
pub const native_observation_delay_ms = model_mod.native_observation_delay_ms;
pub const native_window_move_attempts_max = model_mod.native_window_move_attempts_max;
pub const native_workspace_move_timeout_ms = model_mod.native_workspace_move_timeout_ms;
pub const workspace_transition_settle_ms = model_mod.workspace_transition_settle_ms;
pub const display_event_debounce_ms = model_mod.display_event_debounce_ms;
pub const DisplayId = model_mod.DisplayId;
pub const NativeSpaceId = model_mod.NativeSpaceId;
pub const WorkspaceId = model_mod.WorkspaceId;
pub const SpaceKey = model_mod.SpaceKey;
pub const SpaceRef = model_mod.SpaceRef;
pub const DisplayWorkspace = model_mod.DisplayWorkspace;
pub const WorkspaceTopology = model_mod.WorkspaceTopology;
pub const SpaceCatalog = model_mod.SpaceCatalog;
pub const Space = model_mod.Space;
pub const DisplayTopology = model_mod.DisplayTopology;
pub const NativeTopology = model_mod.NativeTopology;
pub const NativeTopologyInitialization = model_mod.NativeTopologyInitialization;
pub const NativeDisplayObservation = model_mod.NativeDisplayObservation;
pub const NativeTopologyObservation = model_mod.NativeTopologyObservation;
pub const mapNativeTopology = model_mod.mapNativeTopology;
pub const ManagedWindow = model_mod.ManagedWindow;
pub const WindowTabGroupObservation = model_mod.WindowTabGroupObservation;
pub const WindowTabGroupSnapshot = model_mod.WindowTabGroupSnapshot;
pub const WindowCatalog = model_mod.WindowCatalog;
pub const Epoch = model_mod.Epoch;
pub const TimestampMs = model_mod.TimestampMs;
pub const WindowId = model_mod.WindowId;
pub const FocusEventSource = model_mod.FocusEventSource;
pub const FocusDirection = model_mod.FocusDirection;
pub const DeferredFollowFocus = model_mod.DeferredFollowFocus;
pub const FollowFocusObservation = model_mod.FollowFocusObservation;
pub const WindowFocusObservation = model_mod.WindowFocusObservation;
pub const WorkspaceSummary = model_mod.WorkspaceSummary;
pub const WorkspaceFocus = model_mod.WorkspaceFocus;
pub const SwitchRequest = model_mod.SwitchRequest;
pub const PendingSwitch = model_mod.PendingSwitch;
pub const WorkspaceTransitionKind = model_mod.WorkspaceTransitionKind;
pub const WorkspaceTransitionCompletionReason = model_mod.WorkspaceTransitionCompletionReason;
pub const WorkspaceTransition = model_mod.WorkspaceTransition;
pub const WorkspaceTransitionSettlementReason = model_mod.WorkspaceTransitionSettlementReason;
pub const WorkspaceTransitionSettlement = model_mod.WorkspaceTransitionSettlement;
pub const PendingNativeWindowMove = model_mod.PendingNativeWindowMove;
pub const PendingNativeWindowMoves = model_mod.PendingNativeWindowMoves;
pub const PendingNativeWorkspaceMove = model_mod.PendingNativeWorkspaceMove;
pub const NativeWorkspaceMoveObservation = model_mod.NativeWorkspaceMoveObservation;
pub const NativeWindowMoveRequest = model_mod.NativeWindowMoveRequest;
pub const NativeWindowMoveObservation = model_mod.NativeWindowMoveObservation;
pub const DeferredWindowExpiryReason = model_mod.DeferredWindowExpiryReason;
pub const WorkspaceSwitchEffect = model_mod.WorkspaceSwitchEffect;
pub const FocusWindowEffect = model_mod.FocusWindowEffect;
pub const WindowSwapEffect = model_mod.WindowSwapEffect;
pub const WindowModeEffect = model_mod.WindowModeEffect;
pub const FullscreenEffect = model_mod.FullscreenEffect;
pub const CenterWindowEffect = model_mod.CenterWindowEffect;
pub const WindowMoveRequest = model_mod.WindowMoveRequest;
pub const WindowMoveEffect = model_mod.WindowMoveEffect;
pub const PendingFocus = model_mod.PendingFocus;
pub const PendingFocusQueue = model_mod.PendingFocusQueue;
pub const WindowReadiness = model_mod.WindowReadiness;
pub const WindowCandidate = model_mod.WindowCandidate;
pub const WindowCandidates = model_mod.WindowCandidates;
pub const ProcessRetry = model_mod.ProcessRetry;
pub const ProcessRetries = model_mod.ProcessRetries;
pub const PointerDragState = model_mod.PointerDragState;
pub const DragPreviewState = model_mod.DragPreviewState;
pub const PointerDragCompletion = model_mod.PointerDragCompletion;
pub const RetileRequest = model_mod.RetileRequest;
pub const CleanupRequest = model_mod.CleanupRequest;
pub const LayoutSpaceFrame = model_mod.LayoutSpaceFrame;
pub const LayoutRebuild = model_mod.LayoutRebuild;
pub const ObservationTimer = model_mod.ObservationTimer;
pub const LayoutInsertion = model_mod.LayoutInsertion;
pub const WindowAdoption = model_mod.WindowAdoption;
pub const WindowUpdate = model_mod.WindowUpdate;
pub const WindowSpaceAssignment = model_mod.WindowSpaceAssignment;
pub const WindowTabDetachment = model_mod.WindowTabDetachment;
pub const Model = model_mod.Model;
pub const Event = model_mod.Event;
pub const SwitchFailureReason = model_mod.SwitchFailureReason;
pub const WindowCatalogRejectionReason = model_mod.WindowCatalogRejectionReason;
pub const Effect = model_mod.Effect;
pub const max_effects = model_mod.max_effects;
pub const Transition = model_mod.Transition;

pub fn reduce(model: Model, event: Event) Transition {
    var transition: Transition = .{ .model = model };
    var should_refresh_workspace_focus = false;

    switch (event) {
        .replace_space_catalog => |catalog| {
            transition.model.spaces = catalog;
            workspace_reducer.pruneWindowCandidates(&transition.model.pending_role_windows, &catalog);
            workspace_reducer.pruneWindowCandidates(&transition.model.deferred_window_candidates, &catalog);
            workspace_reducer.refreshWorkspaceTransition(&transition);
            workspace_reducer.refreshPendingNativeWindowMoves(&transition.model);
            should_refresh_workspace_focus = true;
        },
        .adopt_window => |adoption| window_reducer.reduceWindowAdopted(&transition, adoption),
        .update_window => |update| window_reducer.reduceWindowUpdated(&transition, update),
        .remove_window => |window_id| {
            window_reducer.reduceWindowRemoved(&transition, window_id);
            should_refresh_workspace_focus = true;
        },
        .replace_window_id => |replacement| window_reducer.reduceWindowIdReplaced(&transition, replacement),
        .assign_window_space => |assignment| {
            window_reducer.reduceWindowSpaceAssigned(&transition, assignment);
            should_refresh_workspace_focus = true;
        },
        .observe_window_tab_group => |observation| {
            window_reducer.reduceWindowTabGroupObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
        .detach_window_tab => |detachment| {
            window_reducer.reduceWindowTabDetached(&transition, detachment);
            should_refresh_workspace_focus = true;
        },
        .record_workspace_focus => |focus| window_reducer.reduceWorkspaceFocusRecorded(&transition, focus),
        .replace_workspace_topology => |topology| {
            transition.model.workspace_topology = topology;
        },
        .focus_display => |display_id| {
            if (transition.model.workspace_topology.findDisplay(display_id) != null) {
                transition.model.workspace_topology.focused_display_id = display_id;
            }
        },
        .activate_workspace => |activation| {
            _ = transition.model.workspace_topology.setActiveWorkspace(
                activation.display_id,
                activation.workspace_id,
            );
        },
        .initialize_native_topology => |initialization| {
            const workspace_transition = transition.model.workspace_transition;
            transition.model.native_topology = initialization.topology;
            transition.model.pending_switch = null;
            transition.model.queued_switch = null;
            transition.model.observation_timer = null;
            transition.model.pending_native_window_moves.count = 0;
            transition.model.pending_native_workspace_move = null;
            if (workspace_transition) |current| {
                workspace_reducer.finalizeWorkspaceTransition(&transition, current, .topology_reinitialized);
            } else {
                transition.model.pending_focus.clear();
                transition.model.deferred_follow_focus = null;
            }
            workspace_reducer.syncNativeWorkspaceTopology(&transition);
            if (initialization.focused_display_id) |display_id| {
                if (transition.model.workspace_topology.findDisplay(display_id) != null) {
                    transition.model.workspace_topology.focused_display_id = display_id;
                }
            }
            should_refresh_workspace_focus = true;
        },
        .request_workspace_switch => |request| workspace_reducer.reduceWorkspaceSwitchRequest(&transition, request),
        .request_native_switch => |request| workspace_reducer.reduceSwitchRequest(&transition, request),
        .native_space_changed => |at_ms| workspace_reducer.reduceSpaceChanged(&transition, at_ms),
        .observation_timer_fired => |timer| workspace_reducer.reduceObservationTimer(&transition, timer),
        .native_topology_observed => |observation| {
            workspace_reducer.reduceTopologyObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
        .native_topology_unavailable => |unavailable| workspace_reducer.reduceTopologyUnavailable(&transition, unavailable),
        .native_switch_effect_failed => |failure| workspace_reducer.reduceSwitchEffectFailed(&transition, failure),
        .start_workspace_transition => |start| workspace_reducer.reduceWorkspaceTransitionStart(&transition, start),
        .complete_workspace_transition => |completion| workspace_reducer.reduceWorkspaceTransitionCompletion(&transition, completion),
        .workspace_transition_timer_fired => |timer| workspace_reducer.reduceWorkspaceTransitionTimer(&transition, timer),
        .track_native_window_move => |request| workspace_reducer.reduceNativeWindowMoveTracked(&transition, request),
        .cancel_native_window_move => |window_id| {
            _ = transition.model.pending_native_window_moves.remove(window_id);
        },
        .native_window_move_observed => |observation| workspace_reducer.reduceNativeWindowMoveObserved(&transition, observation),
        .native_window_move_rollback_result => |result| workspace_reducer.reduceNativeWindowMoveRollbackResult(&transition, result),
        .request_native_workspace_move => |request| workspace_reducer.reduceNativeWorkspaceMoveRequest(&transition, request),
        .native_workspace_move_started => |result| workspace_reducer.reduceNativeWorkspaceMoveStarted(&transition, result),
        .native_workspace_move_observed => |observation| {
            workspace_reducer.reduceNativeWorkspaceMoveObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
        .native_workspace_move_rollback_result => |result| workspace_reducer.reduceNativeWorkspaceMoveRollbackResult(&transition, result),
        .window_focus_observed => |observation| workspace_reducer.reduceWindowFocusObserved(&transition, observation),
        .request_pending_focus => workspace_reducer.reducePendingFocusRequest(&transition),
        .follow_focus_observed => |observation| workspace_reducer.reduceFollowFocusObserved(&transition, observation),
        .track_pending_role_window => |candidate| discovery_reducer.reducePendingRoleTracked(&transition, candidate),
        .untrack_pending_role_window => |window_id| {
            _ = transition.model.pending_role_windows.remove(window_id);
        },
        .pending_role_observed => |observation| discovery_reducer.reducePendingRoleObserved(&transition, observation),
        .track_deferred_window_candidate => |candidate| discovery_reducer.reduceDeferredWindowTracked(&transition, candidate),
        .untrack_deferred_window_candidate => |window_id| {
            _ = transition.model.deferred_window_candidates.remove(window_id);
        },
        .deferred_window_observed => |observation| discovery_reducer.reduceDeferredWindowObserved(&transition, observation),
        .deferred_window_promotion_failed => |window_id| discovery_reducer.reduceDeferredWindowPromotionFailed(&transition, window_id),
        .untrack_window_candidates_for_process => |process_id| {
            transition.model.pending_role_windows.removeProcess(process_id);
            transition.model.deferred_window_candidates.removeProcess(process_id);
        },
        .track_app_launch_retry => |retry| discovery_reducer.reduceProcessRetryTracked(&transition.model.app_launch_retries, retry),
        .untrack_app_launch_retry => |process_id| {
            _ = transition.model.app_launch_retries.remove(process_id);
        },
        .app_launch_retry_timer_fired => |process_id| discovery_reducer.reduceAppLaunchRetryTimer(&transition, process_id),
        .track_focus_retry => |retry| discovery_reducer.reduceProcessRetryTracked(&transition.model.focus_retries, retry),
        .untrack_focus_retry => |process_id| {
            _ = transition.model.focus_retries.remove(process_id);
        },
        .focus_retry_observed => |observation| discovery_reducer.reduceFocusRetryObserved(&transition, observation),
        .display_changed => |change| {
            transition.model.display_resettle_due_at_ms = change.resettle_at_ms;
            const is_debounced = if (transition.model.last_display_change_at_ms) |previous|
                change.at_ms < previous +| display_event_debounce_ms
            else
                false;
            if (!is_debounced) {
                transition.model.last_display_change_at_ms = change.at_ms;
                transition.addEffect(.reconcile_displays);
            }
        },
        .display_resettle_timer_fired => |at_ms| workspace_reducer.reduceDisplayResettleTimer(&transition, at_ms),
        .configure_layout_interaction => |configuration| {
            transition.model.bsp_split_mode = configuration.split_mode;
            transition.model.bsp_insert_point = configuration.insert_point;
        },
        .toggle_split_mode => transition.model.bsp_split_mode = switch (transition.model.bsp_split_mode) {
            .auto => .horizontal,
            .horizontal => .vertical,
            .vertical => .auto,
        },
        .set_insert_point => |insert_point| transition.model.bsp_insert_point = insert_point,
        .focus_direction => |command| command_reducer.reduceFocusDirection(&transition, command),
        .swap_direction => |command| command_reducer.reduceSwapDirection(&transition, command),
        .set_window_mode => |command| command_reducer.reduceWindowModeCommand(&transition, command),
        .toggle_window_fullscreen => |command| command_reducer.reduceFullscreenCommand(&transition, command),
        .center_floating_window => |command| command_reducer.reduceCenterWindowCommand(&transition, command),
        .window_frame_command_result => |result| command_reducer.reduceWindowFrameCommandResult(&transition, result),
        .request_window_move => |request| command_reducer.reduceWindowMoveRequest(&transition, request),
        .pointer_down => |candidate_window_id| pointer_reducer.reducePointerDown(&transition, candidate_window_id),
        .pointer_dragged => pointer_reducer.reducePointerDragged(&transition),
        .pointer_geometry_reconcile_requested => |window_id| {
            if (transition.model.pointer_drag.active_window_id == window_id) {
                transition.model.pointer_drag.should_reconcile_on_drop = true;
            }
        },
        .drag_preview_observed => |observation| pointer_reducer.reduceDragPreviewObserved(&transition, observation),
        .clear_drag_preview => pointer_reducer.clearDragPreview(&transition),
        .pointer_up => pointer_reducer.reducePointerUp(&transition),
        .request_retile_all_displays => {
            transition.model.retile_request.all_displays = true;
            transition.model.retile_request.display_count = 0;
        },
        .request_retile_display => |display_id| workspace_reducer.reduceRetileDisplayRequested(&transition.model, display_id),
        .flush_retile_requests => {
            const request = transition.model.retile_request;
            if (request.all_displays or request.display_count > 0) {
                transition.model.retile_request = .{};
                transition.addEffect(.{ .retile_requested = request });
            }
        },
        .request_cleanup_process => |process_id| reduceCleanupProcessRequested(&transition, process_id),
        .request_offscreen_cleanup => transition.model.cleanup_request.should_clean_offscreen = true,
        .clear_cleanup_requests => transition.model.cleanup_request = .{},
        .flush_cleanup_requests => {
            const request = transition.model.cleanup_request;
            transition.model.cleanup_request = .{};
            if (!transition.model.isWorkspaceTransitionActive() and
                (request.process_count > 0 or request.should_clean_offscreen))
            {
                transition.addEffect(.{ .cleanup_requested = request });
            }
        },
        .rebuild_layout => |rebuild| layout_reducer.rebuild(&transition, rebuild),
        .layout_command => |command| {
            if (layout_reducer.applyEvent(&transition, command.event)) {
                workspace_reducer.reduceRetileDisplayRequested(&transition.model, command.display_id);
            }
        },
        .geometry => |geometry_event| {
            const geometry_transition = geometry_mod.reduce(transition.model.geometry, geometry_event);
            transition.model.geometry = geometry_transition.state;
            if (geometry_transition.effect) |effect| transition.addEffect(.{ .geometry = effect });
        },
        .layout => |layout_event| {
            _ = layout_reducer.applyEvent(&transition, layout_event);
        },
    }

    if (should_refresh_workspace_focus) workspace_reducer.refreshWorkspaceFocus(&transition.model);
    invariants.assertModel(&transition.model);
    return transition;
}

fn reduceCleanupProcessRequested(transition: *Transition, process_id: i32) void {
    if (process_id <= 0) return;
    for (transition.model.cleanup_request.process_ids[0..transition.model.cleanup_request.process_count]) |existing| {
        if (existing == process_id) return;
    }
    if (transition.model.cleanup_request.process_count == transition.model.cleanup_request.process_ids.len) {
        transition.model.cleanup_request.should_clean_offscreen = true;
        transition.addEffect(.{ .cleanup_request_overflow = process_id });
        return;
    }
    transition.model.cleanup_request.process_ids[transition.model.cleanup_request.process_count] = process_id;
    transition.model.cleanup_request.process_count += 1;
}

fn testTopology(first_observed: NativeSpaceId, second_observed: ?NativeSpaceId) NativeTopology {
    var topology: NativeTopology = .{};
    var first = DisplayTopology.init(1, first_observed);
    first.addSpace(.{ .id = 101, .workspace_id = 1 });
    first.addSpace(.{ .id = 102, .workspace_id = 2 });
    first.addSpace(.{ .id = 103, .workspace_id = 3 });
    topology.addDisplay(first);

    if (second_observed) |observed| {
        var second = DisplayTopology.init(2, observed);
        second.addSpace(.{ .id = 201, .workspace_id = 4 });
        second.addSpace(.{ .id = 202, .workspace_id = 5 });
        second.addSpace(.{ .id = 203, .workspace_id = 6 });
        topology.addDisplay(second);
    }
    return topology;
}

fn initializedModel(topology: NativeTopology) Model {
    return reduce(.{}, .{ .initialize_native_topology = .{ .topology = topology } }).model;
}

fn switchRequest(model: *const Model, display_id: DisplayId, workspace_id: WorkspaceId, at_ms: TimestampMs) Event {
    return .{ .request_native_switch = .{
        .target = model.spaceForWorkspace(display_id, workspace_id).?,
        .at_ms = at_ms,
    } };
}

fn followFocusObservation(model: *const Model, target_key: SpaceKey, is_target_visible: bool) Event {
    return .{ .follow_focus_observed = .{
        .process_id = 10,
        .window_id = 41,
        .leader_window_id = 40,
        .source = .ax,
        .target = model.space(target_key).?,
        .is_target_visible = is_target_visible,
        .at_ms = 100,
    } };
}

fn windowFocusObservation(
    model: *const Model,
    process_id: i32,
    window_id: WindowId,
    source: FocusEventSource,
    target_key: SpaceKey,
    is_target_visible: bool,
    pending_transition_epoch: ?Epoch,
) Event {
    return .{ .window_focus_observed = .{
        .process_id = process_id,
        .window_id = window_id,
        .source = source,
        .target = model.space(target_key).?,
        .is_target_visible = is_target_visible,
        .at_ms = 300,
        .pending_transition_epoch = pending_transition_epoch,
    } };
}

fn trackNativeWindowMove(model: *const Model, window_id: WindowId, source_workspace_id: WorkspaceId, target_workspace_id: WorkspaceId) Event {
    return .{ .track_native_window_move = .{
        .window_id = window_id,
        .source = model.spaceForWorkspace(1, source_workspace_id).?,
        .target = model.spaceForWorkspace(1, target_workspace_id).?,
    } };
}

fn testLayoutInsertion(kind: tiling_mod.LayoutKind) LayoutInsertion {
    return .{
        .kind = kind,
        .options = .{
            .split_mode = .horizontal,
            .child = .second,
        },
    };
}

test "workspace summaries preserve globally unique active workspaces" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 101 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 201 }, .workspace_id = 2, .display_id = 22 });
    catalog.add(.{ .key = .{ .id = 102 }, .workspace_id = 3, .display_id = 11 });

    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    topology.addDisplay(.{ .display_id = 22, .active_workspace_id = 2 });
    topology.focused_display_id = 22;

    var model: Model = .{
        .spaces = catalog,
        .workspace_topology = topology,
    };
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 101 },
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 201,
        .process_id = 2001,
        .space_key = .{ .id = 201 },
    } }).model;
    const summaries = model.workspaceSummaries(3);

    try testing.expectEqual(@as(u32, 1), summaries[0].window_count);
    try testing.expect(summaries[0].is_active);
    try testing.expect(!summaries[0].is_focused);
    try testing.expectEqual(@as(u32, 1), summaries[1].window_count);
    try testing.expect(summaries[1].is_active);
    try testing.expect(summaries[1].is_focused);
}

test "window catalog owns identity and Space membership" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });
    const model: Model = .{ .spaces = catalog };

    const first = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 1 },
        .frame = .{ .x = 10, .y = 20, .width = 800, .height = 600 },
        .mode = .floating,
        .float_frame = .{ .x = 10, .y = 20, .width = 800, .height = 600 },
    } });
    const second = reduce(first.model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1002,
        .space_key = .{ .id = 1 },
    } });

    try testing.expect(model.window(101) == null);
    try testing.expectEqual(@as(u16, 2), second.model.windows.countInSpace(.{ .id = 1 }));
    try testing.expectEqual(@as(i32, 1001), second.model.window(101).?.process_id);
    const initial_snapshot = second.model.windowSnapshot(101).?;
    try testing.expectEqual(window_mod.WindowMode.floating, initial_snapshot.mode);
    try testing.expectEqual(@as(f64, 800), initial_snapshot.frame.width);
    try testing.expect(second.model.geometry.get(101).?.observed.?.approxEqual(
        initial_snapshot.frame,
        window_mod.Window.Frame.tolerance,
    ));

    var updated_window = initial_snapshot;
    updated_window.frame.x = 30;
    updated_window.is_fullscreen = true;
    const updated = reduce(second.model, .{ .update_window = .{ .window = updated_window } });
    try testing.expectEqual(@as(f64, 30), updated.model.window(101).?.frame.x);
    try testing.expect(updated.model.window(101).?.is_fullscreen);

    const assigned = reduce(updated.model, .{ .assign_window_space = .{
        .window_id = 101,
        .space_key = .{ .id = 2 },
    } });
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .id = 1 }));
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .id = 2 }));
    try testing.expect(assigned.model.window(101).?.space_key.eql(.{ .id = 2 }));

    const replaced = reduce(assigned.model, .{ .replace_window_id = .{
        .old_window_id = 102,
        .new_window_id = 202,
    } });
    try testing.expect(replaced.model.window(102) == null);
    try testing.expectEqual(@as(i32, 1002), replaced.model.window(202).?.process_id);
    try testing.expect(replaced.model.geometry.get(102) == null);
    try testing.expect(replaced.model.geometry.get(202) != null);

    const removed = reduce(replaced.model, .{ .remove_window = 202 });
    try testing.expect(removed.model.window(202) == null);
    try testing.expect(removed.model.geometry.get(202) == null);
    try testing.expectEqual(@as(u16, 1), removed.model.windows.count);
}

test "window lifecycle transitions update catalog geometry focus and layout atomically" {
    const testing = std.testing;
    const first_space: SpaceKey = .{ .id = 1 };
    const second_space: SpaceKey = .{ .id = 2 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = first_space, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = second_space, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };

    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = first_space,
        .frame = .{ .x = 10, .y = 20, .width = 800, .height = 600 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    try testing.expect(model.window(101) != null);
    try testing.expect(model.geometry.get(101) != null);
    try testing.expect(model.layout.contains(first_space, 101));

    var window = model.windowSnapshot(101).?;
    window.mode = .floating;
    model = reduce(model, .{ .update_window = .{ .window = window } }).model;
    try testing.expectEqual(window_mod.WindowMode.floating, model.window(101).?.mode);
    try testing.expect(!model.layout.contains(first_space, 101));

    window.mode = .tiled;
    model = reduce(model, .{ .update_window = .{
        .window = window,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 1,
        .window_id = 101,
    } }).model;
    try testing.expectEqual(window_mod.WindowMode.tiled, model.window(101).?.mode);
    try testing.expect(model.layout.contains(first_space, 101));

    model = reduce(model, .{ .assign_window_space = .{
        .window_id = 101,
        .space_key = second_space,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    try testing.expect(model.window(101).?.space_key.eql(second_space));
    try testing.expect(!model.layout.contains(first_space, 101));
    try testing.expect(model.layout.contains(second_space, 101));
    try testing.expectEqual(@as(?WindowId, null), model.focusedWorkspaceWindow(1));

    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 2,
        .window_id = 101,
    } }).model;
    model = reduce(model, .{ .replace_window_id = .{
        .old_window_id = 101,
        .new_window_id = 201,
    } }).model;
    try testing.expect(model.window(101) == null);
    try testing.expect(model.window(201) != null);
    try testing.expect(model.geometry.get(101) == null);
    try testing.expect(model.geometry.get(201) != null);
    try testing.expect(!model.layout.contains(second_space, 101));
    try testing.expect(model.layout.contains(second_space, 201));
    try testing.expectEqual(@as(?WindowId, 201), model.focusedWorkspaceWindow(2));

    model = reduce(model, .{ .remove_window = 201 }).model;
    try testing.expect(model.window(201) == null);
    try testing.expect(model.geometry.get(201) == null);
    try testing.expect(!model.layout.contains(second_space, 201));
    try testing.expectEqual(@as(?WindowId, null), model.focusedWorkspaceWindow(2));
}

test "layout rebuild replaces every Space atomically" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .id = 1 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = space_key, .workspace_id = 1, .display_id = 11 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;

    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = space_key,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1002,
        .space_key = space_key,
        .layout = testLayoutInsertion(.bsp),
    } }).model;

    var rebuild: LayoutRebuild = .{
        .kind = .monocle,
        .split_mode = .horizontal,
        .insert_child = .second,
        .insert_point = .last,
        .inner_gap = 8,
        .split_ratio = 0.5,
    };
    try testing.expect(rebuild.addSpace(space_key, .{ .x = 0, .y = 0, .width = 1000, .height = 800 }));
    var transition = reduce(model, .{ .rebuild_layout = rebuild });

    try testing.expectEqual(tiling_mod.LayoutKind.monocle, transition.model.layout.layoutKind(space_key).?);
    try testing.expect(transition.model.layout.contains(space_key, 101));
    try testing.expect(transition.model.layout.contains(space_key, 102));

    try testing.expect(rebuild.addSpace(.{ .id = 2 }, null));
    transition = reduce(model, .{ .rebuild_layout = rebuild });
    try testing.expectEqual(tiling_mod.LayoutKind.bsp, transition.model.layout.layoutKind(space_key).?);
    try testing.expect(transition.model.layout.contains(space_key, 101));
    try testing.expect(transition.model.layout.contains(space_key, 102));
}

test "layout rejection leaves window adoption unchanged" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .id = 1 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = space_key, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };

    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = space_key,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    const rejected = reduce(model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1002,
        .space_key = space_key,
        .layout = testLayoutInsertion(.monocle),
    } });

    try testing.expectEqual(@as(u8, 1), rejected.effect_count);
    try testing.expectEqual(std.meta.Tag(Effect).layout, std.meta.activeTag(rejected.effects[0]));
    try testing.expect(rejected.model.window(102) == null);
    try testing.expect(rejected.model.geometry.get(102) == null);
    try testing.expect(rejected.model.layout.contains(space_key, 101));
    try testing.expect(!rejected.model.layout.contains(space_key, 102));
    try testing.expectEqual(@as(usize, 1), rejected.model.layout.windowCount(space_key));
}

test "cross-domain validation rejects ownership divergence" {
    const testing = std.testing;
    const first_space: SpaceKey = .{ .id = 1 };
    const second_space: SpaceKey = .{ .id = 2 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = first_space, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = second_space, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = first_space,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1001,
        .space_key = first_space,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    try testing.expect(invariants.crossDomainStateIsValid(&model));

    var invalid = model;
    invalid.geometry.forget(101);
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));

    invalid = model;
    try invalid.geometry.seedObserved(999, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].space_key = second_space;
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].space_key = .{ .id = 99 };
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].mode = .floating;
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));

    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 102,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;
    try testing.expect(invariants.crossDomainStateIsValid(&model));

    invalid = model;
    invalid.layout = tiling_mod.reduce(invalid.layout, .{ .insert = .{
        .space_key = first_space,
        .kind = .bsp,
        .window_id = 102,
        .options = testLayoutInsertion(.bsp).options,
    } }).model;
    try testing.expect(!invariants.crossDomainStateIsValid(&invalid));
}

test "tab transitions transfer layout ownership atomically" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .id = 1 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = space_key, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };

    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = space_key,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 102,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1001,
        .space_key = space_key,
        .tab_group = group,
    } }).model;

    try testing.expectEqual(@as(usize, 1), model.layout.windowCount(space_key));
    try testing.expect(model.layout.contains(space_key, 101));
    try testing.expect(!model.layout.contains(space_key, 102));
    try testing.expectEqual(@as(WindowId, 101), model.windowTabLeader(102));

    model = reduce(model, .{ .detach_window_tab = .{
        .window_id = 102,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    try testing.expectEqual(@as(usize, 2), model.layout.windowCount(space_key));
    try testing.expect(model.layout.contains(space_key, 101));
    try testing.expect(model.layout.contains(space_key, 102));
    try testing.expectEqual(@as(WindowId, 102), model.windowTabLeader(102));

    model = reduce(model, .{ .observe_window_tab_group = group }).model;
    model = reduce(model, .{ .remove_window = 101 }).model;
    try testing.expectEqual(@as(usize, 1), model.layout.windowCount(space_key));
    try testing.expect(!model.layout.contains(space_key, 101));
    try testing.expect(model.layout.contains(space_key, 102));
    try testing.expectEqual(@as(WindowId, 102), model.windowTabLeader(102));
}

test "tab grouping reconciles workspace and layout ownership atomically" {
    const testing = std.testing;
    const first_space: SpaceKey = .{ .id = 1 };
    const second_space: SpaceKey = .{ .id = 2 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = first_space, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = second_space, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = first_space,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1001,
        .space_key = second_space,
        .layout = testLayoutInsertion(.bsp),
    } }).model;

    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 101,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;

    try testing.expect(model.window(102).?.space_key.eql(first_space));
    try testing.expectEqual(@as(WindowId, 101), model.windowTabLeader(102));
    try testing.expect(model.layout.contains(first_space, 101));
    try testing.expect(!model.layout.contains(second_space, 102));
    try testing.expectEqual(@as(usize, 0), model.layout.windowCount(second_space));
}

test "workspace focus memory follows window lifecycle" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };

    for ([_]WindowId{ 101, 102 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .id = 1 },
        } }).model;
        model = reduce(model, .{ .record_workspace_focus = .{
            .workspace_id = 1,
            .window_id = window_id,
        } }).model;
    }

    model = reduce(model, .{ .remove_window = 102 }).model;
    try testing.expectEqual(@as(?WindowId, 101), model.focusedWorkspaceWindow(1));

    model = reduce(model, .{ .replace_window_id = .{
        .old_window_id = 101,
        .new_window_id = 201,
    } }).model;
    try testing.expectEqual(@as(?WindowId, 201), model.focusedWorkspaceWindow(1));

    model = reduce(model, .{ .assign_window_space = .{
        .window_id = 201,
        .space_key = .{ .id = 2 },
    } }).model;
    try testing.expectEqual(@as(?WindowId, null), model.focusedWorkspaceWindow(1));
    try testing.expectEqual(@as(?WindowId, null), model.focusedWorkspaceWindow(2));

    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 2,
        .window_id = 201,
    } }).model;
    try testing.expectEqual(@as(?WindowId, 201), model.focusedWorkspaceWindow(2));
}

test "window catalog rejects invalid lifecycle events" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    const model: Model = .{ .spaces = catalog };

    const invalid = reduce(model, .{ .adopt_window = .{
        .window_id = 0,
        .process_id = 1001,
        .space_key = .{ .id = 1 },
    } });
    try testing.expectEqual(@as(u8, 1), invalid.effect_count);
    try testing.expectEqual(
        WindowCatalogRejectionReason.invalid_window,
        invalid.effects[0].window_catalog_rejected.reason,
    );

    const missing_space = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 2 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.space_missing,
        missing_space.effects[0].window_catalog_rejected.reason,
    );

    const missing_window = reduce(model, .{ .assign_window_space = .{
        .window_id = 101,
        .space_key = .{ .id = 1 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.window_missing,
        missing_window.effects[0].window_catalog_rejected.reason,
    );

    const adopted = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 1 },
    } });
    const duplicate = reduce(adopted.model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 1 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.window_exists,
        duplicate.effects[0].window_catalog_rejected.reason,
    );
}

test "window catalog owns tab identity and group Space assignment" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102, 103 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .id = 1 },
        } }).model;
    }

    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 102,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    try testing.expect(group.addMember(103));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;

    try testing.expectEqual(@as(WindowId, 101), model.window(103).?.tab_leader_window_id);
    try testing.expect(model.window(101).?.is_suppressed);
    try testing.expect(!model.window(102).?.is_suppressed);
    try testing.expect(model.window(103).?.is_suppressed);

    model = reduce(model, .{ .assign_window_space = .{
        .window_id = 103,
        .space_key = .{ .id = 2 },
    } }).model;
    try testing.expectEqual(@as(u16, 3), model.windows.countInSpace(.{ .id = 2 }));

    var window_ids: [max_managed_windows]WindowId = undefined;
    const workspace_windows = model.workspaceWindowIds(.{ .id = 2 }, &window_ids);
    try testing.expectEqual(@as(usize, 1), workspace_windows.len);
    try testing.expectEqual(@as(WindowId, 101), workspace_windows[0]);

    group.active_window_id = 103;
    model = reduce(model, .{ .observe_window_tab_group = group }).model;
    try testing.expect(model.window(102).?.is_suppressed);
    try testing.expect(!model.window(103).?.is_suppressed);

    model = reduce(model, .{ .detach_window_tab = .{ .window_id = 102 } }).model;
    try testing.expectEqual(@as(WindowId, 102), model.windowTabLeader(102));
    try testing.expect(!model.window(102).?.is_suppressed);
    try testing.expectEqual(@as(WindowId, 101), model.windowTabLeader(103));
    try testing.expectEqual(@as(WindowId, 103), model.windowTabActive(101));
}

test "removing a tab leader leaves valid standalone identities" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .id = 1 },
        } }).model;
    }
    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 102,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;

    model = reduce(model, .{ .remove_window = 101 }).model;

    const survivor = model.window(102).?;
    try testing.expectEqual(@as(WindowId, 102), survivor.tab_leader_window_id);
    try testing.expect(!survivor.is_suppressed);
}

test "removing a tab leader preserves a surviving group" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102, 103 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .id = 1 },
        } }).model;
    }
    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 103,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    try testing.expect(group.addMember(103));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;

    model = reduce(model, .{ .remove_window = 101 }).model;

    try testing.expectEqual(@as(WindowId, 102), model.windowTabLeader(103));
    try testing.expectEqual(@as(WindowId, 103), model.windowTabActive(102));
    const snapshot = model.windowTabGroup(102).?;
    try testing.expectEqual(@as(u16, 2), snapshot.member_count);
}

test "switch request preserves observed Space until confirmation" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, null));

    const transition = reduce(model, switchRequest(&model, 1, 2, 100));

    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.desiredWorkspace(1));
    try testing.expect(transition.model.isNativeSwitchPending());
    try testing.expectEqual(transition.model.pending_switch.?.epoch, transition.model.workspace_transition.?.epoch);
    try testing.expectEqual(@as(u8, 2), transition.effect_count);
    try testing.expectEqual(std.meta.Tag(Effect).workspace_transition_started, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(std.meta.Tag(Effect).switch_native_space, std.meta.activeTag(transition.effects[1]));
}

test "observed target completes native switch" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, switchRequest(&model, 1, 2, 100));
    model = transition.model;
    const epoch = model.pending_switch.?.epoch;

    transition = reduce(model, .{ .native_topology_observed = .{
        .topology = testTopology(102, null),
        .epoch = epoch,
        .at_ms = 200,
    } });

    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.activeWorkspace(1));
    try testing.expect(!transition.model.isNativeSwitchPending());
    try testing.expect(transition.model.isWorkspaceTransitionActive());
    try testing.expectEqual(WorkspaceTransitionCompletionReason.native_space_changed, transition.model.workspace_transition.?.completion_reason.?);
    try testing.expectEqual(@as(TimestampMs, 600), transition.model.workspace_transition.?.deadline_at_ms);
    try testing.expectEqual(@as(u8, 1), transition.effect_count);
    try testing.expectEqual(std.meta.Tag(Effect).native_switch_completed, std.meta.activeTag(transition.effects[0]));
}

test "unexpected landing commits observation and fails request" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, switchRequest(&model, 1, 2, 100));
    model = transition.model;
    const pending = model.pending_switch.?;

    transition = reduce(model, .{ .native_topology_observed = .{
        .topology = testTopology(103, null),
        .epoch = pending.epoch,
        .at_ms = pending.deadline_at_ms,
    } });

    try testing.expectEqual(@as(?WorkspaceId, 3), transition.model.observedWorkspace(1));
    try testing.expect(!transition.model.isNativeSwitchPending());
    try testing.expectEqual(std.meta.Tag(Effect).workspace_transition_settled, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(WorkspaceTransitionSettlementReason.native_switch_failed, transition.effects[0].workspace_transition_settled.reason);
    try testing.expectEqual(std.meta.Tag(Effect).native_switch_failed, std.meta.activeTag(transition.effects[1]));
    try testing.expectEqual(SwitchFailureReason.unexpected_space, transition.effects[1].native_switch_failed.reason);
}

test "intermediate Space becomes observed while request remains pending" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, switchRequest(&model, 1, 2, 100));
    model = transition.model;
    const pending = model.pending_switch.?;

    transition = reduce(model, .{ .native_topology_observed = .{
        .topology = testTopology(103, null),
        .epoch = pending.epoch,
        .at_ms = 200,
    } });

    try testing.expectEqual(@as(?WorkspaceId, 3), transition.model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.desiredWorkspace(1));
    try testing.expect(transition.model.isNativeSwitchPending());
    try testing.expect(transition.model.hasScheduledObservation());
}

test "native workspace placement is globally unique across displays" {
    const testing = std.testing;
    const model = initializedModel(testTopology(102, 202));
    const first = model.spaceForWorkspace(1, 2).?;
    const second = model.spaceForWorkspace(2, 5).?;

    try testing.expectEqual(@as(?WorkspaceId, 2), model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 5), model.observedWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 102), model.native_topology.findDisplay(1).?.spaceForWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 202), model.native_topology.findDisplay(2).?.spaceForWorkspace(5));
    try testing.expect(first.key.eql(.{ .id = 102 }));
    try testing.expect(second.key.eql(.{ .id = 202 }));
    try testing.expect(!first.key.eql(second.key));

    const summaries = model.workspaceSummaries(6);
    try testing.expect(summaries[1].is_active);
    try testing.expect(summaries[1].is_focused);
    try testing.expect(summaries[4].is_active);
    try testing.expect(!summaries[4].is_focused);
}

test "native topology preserves uneven per-display Space counts" {
    const testing = std.testing;
    var topology: NativeTopology = .{};
    var primary = DisplayTopology.init(1, 102);
    primary.addSpace(.{ .id = 101, .workspace_id = 1 });
    primary.addSpace(.{ .id = 102, .workspace_id = 2 });
    topology.addDisplay(primary);
    var secondary = DisplayTopology.init(2, 201);
    secondary.addSpace(.{ .id = 201, .workspace_id = 3 });
    topology.addDisplay(secondary);

    const model = initializedModel(topology);

    try testing.expectEqual(@as(u8, 3), model.spaces.space_count);
    try testing.expect(model.spaceForWorkspace(1, 2).?.key.eql(.{ .id = 102 }));
    try testing.expect(model.spaceForWorkspace(2, 3).?.key.eql(.{ .id = 201 }));
    try testing.expect(model.spaceForWorkspace(2, 2) == null);
}

test "native topology mapping assigns one global workspace per physical slot" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 1 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 1 });
    catalog.add(.{ .key = .{ .id = 3 }, .workspace_id = 3, .display_id = 2 });
    var workspace_topology: WorkspaceTopology = .{};
    workspace_topology.addDisplay(.{ .display_id = 1, .active_workspace_id = 1 });
    workspace_topology.addDisplay(.{ .display_id = 2, .active_workspace_id = 3 });

    var observation: NativeTopologyObservation = .{};
    var primary: NativeDisplayObservation = .{
        .display_id = 1,
        .observed_space_id = 102,
        .space_count = 3,
    };
    primary.space_ids[0] = 101;
    primary.space_ids[1] = 102;
    primary.space_ids[2] = 103;
    observation.addDisplay(primary);
    var secondary: NativeDisplayObservation = .{
        .display_id = 2,
        .observed_space_id = 201,
        .space_count = 1,
    };
    secondary.space_ids[0] = 201;
    observation.addDisplay(secondary);

    const previous: NativeTopology = .{};
    const mapped = mapNativeTopology(observation, &previous, &workspace_topology, &catalog, 3, 1).?;

    try testing.expectEqual(@as(?WorkspaceId, 1), mapped.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 3), mapped.observedWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 101), mapped.findDisplay(1).?.spaceForWorkspace(2));
    try testing.expect(mapped.findDisplay(1).?.workspaceForSpace(103) == null);
}

test "native topology mapping ignores an activated extra Space" {
    const testing = std.testing;
    var previous: NativeTopology = .{};
    var primary = DisplayTopology.init(1, 102);
    primary.addSpace(.{ .id = 101, .workspace_id = 1 });
    primary.addSpace(.{ .id = 102, .workspace_id = 2 });
    previous.addDisplay(primary);
    var secondary = DisplayTopology.init(2, 201);
    secondary.addSpace(.{ .id = 201, .workspace_id = 3 });
    previous.addDisplay(secondary);

    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 101 }, .workspace_id = 1, .display_id = 1 });
    catalog.add(.{ .key = .{ .id = 102 }, .workspace_id = 2, .display_id = 1 });
    catalog.add(.{ .key = .{ .id = 201 }, .workspace_id = 3, .display_id = 2 });
    var workspace_topology: WorkspaceTopology = .{};
    workspace_topology.addDisplay(.{ .display_id = 1, .active_workspace_id = 2 });
    workspace_topology.addDisplay(.{ .display_id = 2, .active_workspace_id = 3 });

    var observation: NativeTopologyObservation = .{};
    var observed_primary: NativeDisplayObservation = .{
        .display_id = 1,
        .observed_space_id = 103,
        .space_count = 3,
    };
    observed_primary.space_ids[0] = 101;
    observed_primary.space_ids[1] = 102;
    observed_primary.space_ids[2] = 103;
    observation.addDisplay(observed_primary);
    var observed_secondary: NativeDisplayObservation = .{
        .display_id = 2,
        .observed_space_id = 201,
        .space_count = 1,
    };
    observed_secondary.space_ids[0] = 201;
    observation.addDisplay(observed_secondary);

    const mapped = mapNativeTopology(observation, &previous, &workspace_topology, &catalog, 3, 1).?;

    try testing.expect(mapped.eql(&previous));
    try testing.expect(mapped.findDisplay(1).?.workspaceForSpace(103) == null);
}

test "initial topology mapping binds logical workspaces to physical Spaces" {
    const testing = std.testing;
    var observation: NativeTopologyObservation = .{};
    var secondary: NativeDisplayObservation = .{
        .display_id = 22,
        .observed_space_id = 201,
        .space_count = 2,
    };
    secondary.space_ids[0] = 201;
    secondary.space_ids[1] = 202;
    observation.addDisplay(secondary);

    var primary: NativeDisplayObservation = .{
        .display_id = 11,
        .observed_space_id = 102,
        .space_count = 3,
    };
    primary.space_ids[0] = 101;
    primary.space_ids[1] = 102;
    primary.space_ids[2] = 103;
    observation.addDisplay(primary);

    const previous: NativeTopology = .{};
    const workspace_topology: WorkspaceTopology = .{};
    const catalog: SpaceCatalog = .{};
    const mapped = mapNativeTopology(
        observation,
        &previous,
        &workspace_topology,
        &catalog,
        4,
        11,
    ).?;

    try testing.expectEqual(@as(?WorkspaceId, 2), mapped.observedWorkspace(11));
    try testing.expectEqual(@as(?WorkspaceId, 4), mapped.observedWorkspace(22));
    try testing.expectEqual(@as(?NativeSpaceId, 101), mapped.findDisplay(11).?.spaceForWorkspace(1));
    try testing.expectEqual(@as(?NativeSpaceId, 102), mapped.findDisplay(11).?.spaceForWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 103), mapped.findDisplay(11).?.spaceForWorkspace(3));
    try testing.expectEqual(@as(?NativeSpaceId, 201), mapped.findDisplay(22).?.spaceForWorkspace(4));
    try testing.expect(mapped.findDisplay(22).?.workspaceForSpace(202) == null);

    var alternate_observation = observation;
    alternate_observation.displays[1].observed_space_id = 103;
    const alternate = mapNativeTopology(
        alternate_observation,
        &previous,
        &workspace_topology,
        &catalog,
        4,
        11,
    ).?;
    var workspace_id: WorkspaceId = 1;
    while (workspace_id <= 4) : (workspace_id += 1) {
        try testing.expectEqual(
            mapped.spaceForWorkspace(workspace_id).?.key.id,
            alternate.spaceForWorkspace(workspace_id).?.key.id,
        );
    }
}

test "switch effect preserves target Space identity across displays" {
    const testing = std.testing;
    const model = initializedModel(testTopology(102, 201));
    const transition = reduce(model, switchRequest(&model, 2, 5, 100));
    const effect = transition.effects[1].switch_native_space;

    try testing.expect(effect.request.target.key.eql(.{ .id = 202 }));
    try testing.expectEqual(@as(DisplayId, 2), effect.request.target.display_id);
    try testing.expectEqual(@as(WorkspaceId, 5), effect.request.target.workspace_id);
}

test "native workspace move commits placement and ownership atomically" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, 201));
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .id = 101 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 201,
        .process_id = 2001,
        .space_key = .{ .id = 201 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 1,
        .window_id = 101,
    } }).model;
    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 4,
        .window_id = 201,
    } }).model;

    var transition = reduce(model, .{ .request_native_workspace_move = .{
        .source = model.space(.{ .id = 101 }).?,
        .target = model.space(.{ .id = 201 }).?,
        .at_ms = 100,
    } });
    try testing.expectEqual(@as(u8, 2), transition.effect_count);
    try testing.expectEqual(std.meta.Tag(Effect).move_native_workspace_contents, std.meta.activeTag(transition.effects[1]));
    const epoch = transition.model.pending_native_workspace_move.?.epoch;

    transition = reduce(transition.model, .{ .native_workspace_move_started = .{
        .epoch = epoch,
        .succeeded = true,
        .at_ms = 110,
    } });
    try testing.expect(transition.model.pending_native_workspace_move.?.has_started);

    transition = reduce(transition.model, .{ .native_workspace_move_observed = .{
        .epoch = epoch,
        .observation = .confirmed,
        .at_ms = 200,
    } });

    try testing.expect(transition.model.pending_native_workspace_move == null);
    try testing.expectEqual(@as(?WorkspaceId, 4), transition.model.activeWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.activeWorkspace(2));
    try testing.expectEqual(@as(WorkspaceId, 4), transition.model.space(.{ .id = 101 }).?.workspace_id);
    try testing.expectEqual(@as(WorkspaceId, 1), transition.model.space(.{ .id = 201 }).?.workspace_id);
    try testing.expect(transition.model.window(101).?.space_key.eql(.{ .id = 201 }));
    try testing.expect(transition.model.window(201).?.space_key.eql(.{ .id = 101 }));
    try testing.expect(transition.model.layout.contains(.{ .id = 201 }, 101));
    try testing.expect(transition.model.layout.contains(.{ .id = 101 }, 201));
    try testing.expectEqual(@as(?WindowId, 101), transition.model.focusedWorkspaceWindow(1));
    try testing.expectEqual(@as(?WindowId, 201), transition.model.focusedWorkspaceWindow(4));
    try testing.expectEqual(std.meta.Tag(Effect).native_workspace_move_completed, std.meta.activeTag(transition.effects[0]));
}

test "native workspace move timeout rolls physical contents back" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, 201));
    var transition = reduce(model, .{ .request_native_workspace_move = .{
        .source = model.space(.{ .id = 101 }).?,
        .target = model.space(.{ .id = 201 }).?,
        .at_ms = 100,
    } });
    const pending = transition.model.pending_native_workspace_move.?;
    transition = reduce(transition.model, .{ .native_workspace_move_started = .{
        .epoch = pending.epoch,
        .succeeded = true,
        .at_ms = 110,
    } });
    transition = reduce(transition.model, .{ .native_workspace_move_observed = .{
        .epoch = pending.epoch,
        .observation = .pending,
        .at_ms = pending.deadline_at_ms,
    } });

    try testing.expect(transition.model.pending_native_workspace_move.?.is_rolling_back);
    try testing.expectEqual(std.meta.Tag(Effect).rollback_native_workspace_contents, std.meta.activeTag(transition.effects[0]));

    transition = reduce(transition.model, .{ .native_workspace_move_rollback_result = .{
        .epoch = pending.epoch,
        .succeeded = true,
    } });
    try testing.expect(transition.model.pending_native_workspace_move == null);
    try testing.expectEqual(@as(WorkspaceId, 1), transition.model.space(.{ .id = 101 }).?.workspace_id);
    try testing.expectEqual(@as(WorkspaceId, 4), transition.model.space(.{ .id = 201 }).?.workspace_id);
    try testing.expectEqual(std.meta.Tag(Effect).native_workspace_move_failed, std.meta.activeTag(transition.effects[1]));
}

test "Space catalog preserves physical identity when placement changes" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 22 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    catalog.spaces[1].display_id = 11;
    model = reduce(model, .{ .replace_space_catalog = catalog }).model;

    const moved = model.space(.{ .id = 2 }).?;
    try testing.expectEqual(@as(DisplayId, 11), moved.display_id);
    try testing.expect(moved.key.eql(.{ .id = 2 }));
}

test "workspace and focused display are reducer owned" {
    const testing = std.testing;
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    topology.addDisplay(.{ .display_id = 22, .active_workspace_id = 2 });

    var transition = reduce(.{}, .{ .replace_workspace_topology = topology });
    transition = reduce(transition.model, .{ .activate_workspace = .{
        .display_id = 11,
        .workspace_id = 3,
    } });
    transition = reduce(transition.model, .{ .focus_display = 22 });

    try testing.expectEqual(@as(?WorkspaceId, 3), transition.model.activeWorkspace(11));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.activeWorkspace(22));
    try testing.expectEqual(@as(?DisplayId, 22), transition.model.focusedDisplay());
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
}

test "workspace transition settles from explicit focus and time events" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    var transition = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 100,
    } });
    model = transition.model;
    const epoch = model.workspace_transition.?.epoch;

    try testing.expect(model.workspace_transition.?.target.key.eql(.{ .id = 2 }));
    try testing.expectEqual(@as(TimestampMs, 500), model.workspace_transition.?.deadline_at_ms);
    try testing.expectEqual(std.meta.Tag(Effect).workspace_transition_started, std.meta.activeTag(transition.effects[0]));

    transition = reduce(model, .{ .complete_workspace_transition = .{
        .epoch = epoch,
        .reason = .focus_accepted,
        .at_ms = 250,
    } });
    model = transition.model;
    try testing.expectEqual(WorkspaceTransitionCompletionReason.focus_accepted, model.workspace_transition.?.completion_reason.?);
    try testing.expectEqual(@as(TimestampMs, 650), model.workspace_transition.?.deadline_at_ms);

    transition = reduce(model, .{ .workspace_transition_timer_fired = .{
        .epoch = epoch,
        .at_ms = 649,
    } });
    try testing.expect(transition.model.isWorkspaceTransitionActive());
    try testing.expectEqual(@as(u8, 0), transition.effect_count);

    transition = reduce(transition.model, .{ .workspace_transition_timer_fired = .{
        .epoch = epoch,
        .at_ms = 650,
    } });
    try testing.expect(!transition.model.isWorkspaceTransitionActive());
    try testing.expectEqual(std.meta.Tag(Effect).workspace_transition_settled, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(WorkspaceTransitionSettlementReason.completed, transition.effects[0].workspace_transition_settled.reason);
}

test "display move transition follows stable Space identity" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 22 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .move_workspace_to_display,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 100,
    } }).model;

    catalog.spaces[1].display_id = 11;
    model = reduce(model, .{ .replace_space_catalog = catalog }).model;

    try testing.expect(model.workspace_transition.?.target.key.eql(.{ .id = 2 }));
    try testing.expectEqual(@as(DisplayId, 11), model.workspace_transition.?.target.display_id);
    try testing.expectEqual(WorkspaceTransitionKind.move_workspace_to_display, model.workspace_transition.?.kind);
}

test "stale workspace transition timer cannot settle newer intent" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 1 }).?,
        .at_ms = 100,
    } }).model;
    const stale_epoch = model.workspace_transition.?.epoch;

    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 200,
    } }).model;
    const current_epoch = model.workspace_transition.?.epoch;

    const transition = reduce(model, .{ .workspace_transition_timer_fired = .{
        .epoch = stale_epoch,
        .at_ms = 1000,
    } });

    try testing.expectEqual(current_epoch, transition.model.workspace_transition.?.epoch);
    try testing.expect(transition.model.workspace_transition.?.target.key.eql(.{ .id = 2 }));
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
}

test "pending focus queue replaces by window and applies newest intent" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, switchRequest(&model, 1, 2, 100)).model;
    const epoch = model.workspace_transition.?.epoch;

    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .id = 102 }, false, null)).model;
    model = reduce(model, windowFocusObservation(&model, 20, 42, .drag, .{ .id = 101 }, false, null)).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .drag, .{ .id = 102 }, false, null)).model;

    try testing.expectEqual(@as(u8, 2), model.pendingFocusCount());
    var transition = reduce(model, .request_pending_focus);
    const pending = transition.effects[0].apply_pending_focus;
    try testing.expectEqual(@as(WindowId, 41), pending.window_id);
    try testing.expectEqual(FocusEventSource.drag, pending.source);
    try testing.expectEqual(epoch, pending.transition_epoch);
    try testing.expectEqual(@as(u8, 1), transition.model.pendingFocusCount());

    transition = reduce(
        transition.model,
        windowFocusObservation(&transition.model, 10, 41, .drag, .{ .id = 102 }, true, epoch),
    );
    try testing.expect(!transition.model.hasPendingFocus());
    try testing.expectEqual(std.meta.Tag(Effect).window_focus_accepted, std.meta.activeTag(transition.effects[0]));
}

test "new workspace transition rejects stale pending focus observation" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 1 }).?,
        .at_ms = 100,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .id = 1 }, false, null)).model;
    const stale_epoch = model.workspace_transition.?.epoch;

    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 200,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 20, 42, .ax, .{ .id = 2 }, false, null)).model;

    const current_epoch = model.workspace_transition.?.epoch;
    const transition = reduce(
        model,
        windowFocusObservation(&model, 10, 41, .ax, .{ .id = 1 }, true, stale_epoch),
    );

    try testing.expectEqual(current_epoch, transition.model.workspace_transition.?.epoch);
    try testing.expectEqual(@as(u8, 1), transition.model.pendingFocusCount());
}

test "keyboard focus accepts a visible non-target and clears pending focus" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 100,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .id = 1 }, false, null)).model;

    const transition = reduce(
        model,
        windowFocusObservation(&model, 10, 41, .keyboard, .{ .id = 1 }, true, null),
    );

    try testing.expect(!transition.model.hasPendingFocus());
    try testing.expectEqual(WorkspaceTransitionCompletionReason.focus_accepted, transition.model.workspace_transition.?.completion_reason.?);
    try testing.expectEqual(std.meta.Tag(Effect).window_focus_accepted, std.meta.activeTag(transition.effects[0]));
}

test "deferred follow focus leaves the model with transition settlement" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .id = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .id = 2 }).?,
        .at_ms = 100,
    } }).model;
    const epoch = model.workspace_transition.?.epoch;

    var transition = reduce(model, followFocusObservation(&model, .{ .id = 1 }, false));
    model = transition.model;
    try testing.expect(model.hasDeferredFollowFocus());
    try testing.expectEqual(epoch, model.deferred_follow_focus.?.transition_epoch);
    try testing.expectEqual(std.meta.Tag(Effect).follow_focus_deferred, std.meta.activeTag(transition.effects[0]));

    transition = reduce(model, followFocusObservation(&model, .{ .id = 2 }, true));
    model = transition.model;
    try testing.expect(model.hasDeferredFollowFocus());
    try testing.expectEqual(@as(u8, 0), transition.effect_count);

    transition = reduce(model, .{ .workspace_transition_timer_fired = .{
        .epoch = epoch,
        .at_ms = 500,
    } });
    const settlement = transition.effects[0].workspace_transition_settled;
    try testing.expect(!transition.model.hasDeferredFollowFocus());
    try testing.expectEqual(@as(WindowId, 41), settlement.deferred_follow_focus.?.window_id);
    try testing.expectEqual(epoch, settlement.deferred_follow_focus.?.transition_epoch);
}

test "native switch ignores follow focus until Space observation" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, switchRequest(&model, 1, 2, 100)).model;
    const transition = reduce(model, followFocusObservation(&model, .{ .id = 101 }, false));

    try testing.expect(!transition.model.hasDeferredFollowFocus());
    try testing.expectEqual(std.meta.Tag(Effect).follow_focus_ignored_during_native_switch, std.meta.activeTag(transition.effects[0]));
}

test "hidden focus without a transition requests a workspace switch" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, null));
    const transition = reduce(model, followFocusObservation(&model, .{ .id = 102 }, false));

    try testing.expect(transition.model.pending_switch.?.request.target.key.eql(.{ .id = 102 }));
    try testing.expectEqual(std.meta.Tag(Effect).workspace_transition_started, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(std.meta.Tag(Effect).switch_native_space, std.meta.activeTag(transition.effects[1]));
    try testing.expect(!transition.model.hasDeferredFollowFocus());
}

test "native window move retries then requests rollback" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, trackNativeWindowMove(&model, 42, 1, 2));
    model = transition.model;
    const epoch = model.pendingNativeWindowMove(42).?.epoch;

    try testing.expectEqual(@as(u16, 1), model.pending_native_window_moves.count);
    try testing.expectEqual(@as(u8, native_window_move_attempts_max), model.pendingNativeWindowMove(42).?.attempts_remaining);

    transition = reduce(model, .{ .native_window_move_observed = .{
        .window_id = 42,
        .epoch = epoch,
        .observation = .pending,
    } });
    model = transition.model;
    try testing.expect(model.pendingNativeWindowMove(42).?.has_retried);
    try testing.expectEqual(std.meta.Tag(Effect).retry_native_window_move, std.meta.activeTag(transition.effects[0]));

    var checks_remaining: u8 = native_window_move_attempts_max - 1;
    while (checks_remaining > 0) : (checks_remaining -= 1) {
        transition = reduce(model, .{ .native_window_move_observed = .{
            .window_id = 42,
            .epoch = epoch,
            .observation = .pending,
        } });
        model = transition.model;
        try testing.expectEqual(@as(u8, 0), transition.effect_count);
    }

    transition = reduce(model, .{ .native_window_move_observed = .{
        .window_id = 42,
        .epoch = epoch,
        .observation = .pending,
    } });
    try testing.expectEqual(std.meta.Tag(Effect).rollback_native_window_move, std.meta.activeTag(transition.effects[0]));
}

test "native window move rollback result is epoch checked" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, trackNativeWindowMove(&model, 42, 1, 2)).model;
    const stale_epoch = model.pendingNativeWindowMove(42).?.epoch;
    model = reduce(model, trackNativeWindowMove(&model, 42, 1, 3)).model;
    const current_epoch = model.pendingNativeWindowMove(42).?.epoch;

    var transition = reduce(model, .{ .native_window_move_rollback_result = .{
        .window_id = 42,
        .epoch = stale_epoch,
        .succeeded = true,
    } });
    try testing.expectEqual(current_epoch, transition.model.pendingNativeWindowMove(42).?.epoch);
    try testing.expectEqual(@as(u8, 0), transition.effect_count);

    transition = reduce(transition.model, .{ .native_window_move_rollback_result = .{
        .window_id = 42,
        .epoch = current_epoch,
        .succeeded = false,
    } });
    try testing.expect(transition.model.pendingNativeWindowMove(42) != null);
    try testing.expectEqual(std.meta.Tag(Effect).native_window_move_rollback_deferred, std.meta.activeTag(transition.effects[0]));

    transition = reduce(transition.model, .{ .native_window_move_rollback_result = .{
        .window_id = 42,
        .epoch = current_epoch,
        .succeeded = true,
    } });
    try testing.expect(transition.model.pendingNativeWindowMove(42) == null);
    try testing.expectEqual(std.meta.Tag(Effect).native_window_move_rolled_back, std.meta.activeTag(transition.effects[0]));
}

test "native window move confirmation and ownership change terminate intent" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, trackNativeWindowMove(&model, 42, 1, 2)).model;
    var epoch = model.pendingNativeWindowMove(42).?.epoch;

    var transition = reduce(model, .{ .native_window_move_observed = .{
        .window_id = 42,
        .epoch = epoch,
        .observation = .confirmed,
    } });
    try testing.expect(transition.model.pendingNativeWindowMove(42) == null);
    try testing.expectEqual(std.meta.Tag(Effect).native_window_move_confirmed, std.meta.activeTag(transition.effects[0]));

    model = reduce(transition.model, trackNativeWindowMove(&transition.model, 42, 1, 2)).model;
    epoch = model.pendingNativeWindowMove(42).?.epoch;
    transition = reduce(model, .{ .native_window_move_observed = .{
        .window_id = 42,
        .epoch = epoch,
        .observation = .ownership_changed,
    } });
    try testing.expect(transition.model.pendingNativeWindowMove(42) == null);
    try testing.expectEqual(std.meta.Tag(Effect).native_window_move_cancelled, std.meta.activeTag(transition.effects[0]));
}

test "pending native window move follows Space identity across ordinal changes" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, trackNativeWindowMove(&model, 42, 1, 2)).model;

    var topology: NativeTopology = .{};
    var display = DisplayTopology.init(1, 101);
    display.addSpace(.{ .id = 101, .workspace_id = 1 });
    display.addSpace(.{ .id = 103, .workspace_id = 2 });
    display.addSpace(.{ .id = 102, .workspace_id = 3 });
    topology.addDisplay(display);

    const transition = reduce(model, .{ .native_topology_observed = .{
        .topology = topology,
        .epoch = 99,
        .at_ms = 100,
    } });
    const pending = transition.model.pendingNativeWindowMove(42).?;

    try testing.expect(pending.target.key.eql(.{ .id = 102 }));
    try testing.expectEqual(@as(WorkspaceId, 3), pending.target.workspace_id);
}

test "stale timer cannot observe for newer switch" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, switchRequest(&model, 1, 2, 100));
    model = transition.model;
    const stale_epoch = model.pending_switch.?.epoch;

    transition = reduce(model, .{ .native_switch_effect_failed = .{
        .epoch = stale_epoch,
        .at_ms = 110,
    } });
    model = transition.model;
    transition = reduce(model, switchRequest(&model, 1, 3, 120));
    model = transition.model;

    transition = reduce(model, .{ .observation_timer_fired = .{
        .epoch = stale_epoch,
        .at_ms = 1000,
    } });

    try testing.expectEqual(@as(u8, 0), transition.effect_count);
    try testing.expectEqual(@as(?WorkspaceId, 3), transition.model.desiredWorkspace(1));
}

test "rapid switch requests keep only latest target" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    var transition = reduce(model, switchRequest(&model, 1, 2, 100));
    model = transition.model;
    transition = reduce(model, switchRequest(&model, 1, 3, 110));
    model = transition.model;
    transition = reduce(model, switchRequest(&model, 1, 1, 120));

    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.desiredWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 1), if (transition.model.queued_switch) |queued| queued.target.workspace_id else null);
}

test "window discovery retries are reducer owned" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    const candidate: WindowCandidate = .{
        .process_id = 42,
        .window_id = 100,
        .space_key = .{ .id = 1 },
        .attempts_remaining = 1,
    };

    model = reduce(model, .{ .track_pending_role_window = candidate }).model;
    var transition = reduce(model, .{ .pending_role_observed = .{
        .window_id = candidate.window_id,
        .readiness = .pending,
    } });
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
    try testing.expectEqual(@as(u8, 0), transition.model.pending_role_windows.get(candidate.window_id).?.attempts_remaining);

    transition = reduce(transition.model, .{ .pending_role_observed = .{
        .window_id = candidate.window_id,
        .readiness = .pending,
    } });
    try testing.expectEqual(@as(?WindowCandidate, null), transition.model.pending_role_windows.get(candidate.window_id));
    try testing.expectEqual(std.meta.Tag(Effect).pending_role_expired, std.meta.activeTag(transition.effects[0]));

    model = reduce(transition.model, .{ .track_deferred_window_candidate = candidate }).model;
    transition = reduce(model, .{ .deferred_window_observed = .{
        .window_id = candidate.window_id,
        .readiness = .ready,
        .is_visible = true,
    } });
    try testing.expect(transition.model.hasDeferredWindowCandidate(candidate.window_id));
    try testing.expectEqual(std.meta.Tag(Effect).deferred_window_ready, std.meta.activeTag(transition.effects[0]));

    transition = reduce(transition.model, .{ .deferred_window_promotion_failed = candidate.window_id });
    try testing.expectEqual(@as(u8, 0), transition.model.deferred_window_candidates.get(candidate.window_id).?.attempts_remaining);
    transition = reduce(transition.model, .{ .deferred_window_promotion_failed = candidate.window_id });
    try testing.expect(!transition.model.hasDeferredWindowCandidate(candidate.window_id));
    try testing.expectEqual(DeferredWindowExpiryReason.unsettled_bounds, transition.effects[0].deferred_window_expired.reason);
}

test "process retry outcomes are reducer owned" {
    const testing = std.testing;
    const retry: ProcessRetry = .{ .process_id = 42, .attempts_remaining = 1 };
    var model = reduce(.{}, .{ .track_app_launch_retry = retry }).model;

    var transition = reduce(model, .{ .app_launch_retry_timer_fired = retry.process_id });
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
    transition = reduce(transition.model, .{ .app_launch_retry_timer_fired = retry.process_id });
    try testing.expectEqual(@as(?ProcessRetry, null), transition.model.app_launch_retries.get(retry.process_id));
    try testing.expectEqual(std.meta.Tag(Effect).app_launch_retry_ready, std.meta.activeTag(transition.effects[0]));

    model = reduce(transition.model, .{ .track_focus_retry = retry }).model;
    transition = reduce(model, .{ .focus_retry_observed = .{
        .process_id = retry.process_id,
        .focused_window_id = 100,
    } });
    try testing.expectEqual(@as(?ProcessRetry, null), transition.model.focus_retries.get(retry.process_id));
    try testing.expectEqual(@as(WindowId, 100), transition.effects[0].focus_retry_resolved.window_id);
}

test "display settle timer is reducer owned" {
    const testing = std.testing;
    const model = reduce(.{}, .{ .display_changed = .{
        .at_ms = 100,
        .resettle_at_ms = 500,
    } }).model;
    var transition = reduce(model, .{ .display_resettle_timer_fired = 499 });
    try testing.expect(transition.model.hasDisplayResettleScheduled());
    transition = reduce(transition.model, .{ .display_resettle_timer_fired = 500 });
    try testing.expect(!transition.model.hasDisplayResettleScheduled());
    try testing.expectEqual(std.meta.Tag(Effect).display_resettle_due, std.meta.activeTag(transition.effects[0]));
}

test "pointer drop swaps layout inside the reducer" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .id = 1 }, .workspace_id = 1, .display_id = 11 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 100,
        .process_id = 42,
        .space_key = .{ .id = 1 },
        .frame = .{ .x = 0, .y = 0, .width = 500, .height = 500 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 200,
        .process_id = 43,
        .space_key = .{ .id = 1 },
        .frame = .{ .x = 500, .y = 0, .width = 500, .height = 500 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;

    model = reduce(model, .{ .pointer_down = 100 }).model;
    model = reduce(model, .pointer_dragged).model;
    var transition = reduce(model, .{ .drag_preview_observed = .{
        .source_window_id = 100,
        .target_window_id = 200,
        .target_frame = .{ .x = 500, .y = 0, .width = 500, .height = 500 },
    } });
    try testing.expectEqual(std.meta.Tag(Effect).show_drag_preview, std.meta.activeTag(transition.effects[0]));

    transition = reduce(transition.model, .pointer_up);
    try testing.expectEqual(@as(?WindowId, 200), transition.model.layout.firstWid(.{ .id = 1 }));
    try testing.expect(!transition.model.pointer_drag.is_down);
    try testing.expectEqual(std.meta.Tag(Effect).hide_drag_preview, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(@as(WindowId, 100), transition.effects[1].pointer_drag_completed.swapped_window_ids.?.first);
}

test "directional commands resolve focus and layout in the reducer" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .id = 1 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = space_key, .workspace_id = 1, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 100,
        .process_id = 42,
        .space_key = space_key,
        .frame = .{ .x = 0, .y = 0, .width = 500, .height = 500 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 200,
        .process_id = 43,
        .space_key = space_key,
        .frame = .{ .x = 500, .y = 0, .width = 500, .height = 500 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;

    var transition = reduce(model, .{ .focus_direction = .{
        .window_id = 100,
        .direction = .right,
    } });
    try testing.expectEqual(@as(?WindowId, 200), transition.model.focusedWorkspaceWindow(1));
    try testing.expectEqual(std.meta.Tag(Effect).focus_window, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(@as(WindowId, 200), transition.effects[0].focus_window.window_id);

    transition = reduce(transition.model, .{ .swap_direction = .{
        .window_id = 200,
        .direction = .left,
    } });
    try testing.expectEqual(@as(?WindowId, 200), transition.model.layout.firstWid(space_key));
    try testing.expectEqual(@as(u8, 1), transition.model.retile_request.display_count);
    try testing.expectEqual(std.meta.Tag(Effect).windows_swapped, std.meta.activeTag(transition.effects[0]));
}

test "window presentation commands reduce intent before platform effects" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .id = 1 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = space_key, .workspace_id = 1, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 100,
        .process_id = 42,
        .space_key = space_key,
        .frame = .{ .x = 10, .y = 20, .width = 400, .height = 300 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;

    var transition = reduce(model, .{ .set_window_mode = .{
        .window_id = 100,
        .mode = .floating,
    } });
    try testing.expectEqual(window_mod.WindowMode.floating, transition.model.window(100).?.mode);
    try testing.expect(!transition.model.layout.contains(space_key, 100));
    try testing.expectEqual(std.meta.Tag(Effect).window_mode_changed, std.meta.activeTag(transition.effects[0]));

    transition = reduce(transition.model, .{ .toggle_window_fullscreen = .{
        .window_id = 100,
        .observed_frame = .{ .x = 30, .y = 40, .width = 500, .height = 350 },
    } });
    try testing.expect(transition.model.window(100).?.is_fullscreen);
    try testing.expectEqual(@as(f64, 30), transition.model.window(100).?.float_frame.?.x);

    transition = reduce(transition.model, .{ .toggle_window_fullscreen = .{
        .window_id = 100,
        .observed_frame = null,
    } });
    try testing.expect(!transition.model.window(100).?.is_fullscreen);
    try testing.expectEqual(@as(f64, 30), transition.effects[0].fullscreen_changed.restore_frame.?.x);

    transition = reduce(transition.model, .{ .center_floating_window = .{
        .window_id = 100,
        .observed_frame = .{ .x = 30, .y = 40, .width = 500, .height = 350 },
        .display_frame = .{ .x = 0, .y = 0, .width = 1000, .height = 800 },
    } });
    const center = transition.effects[0].center_window;
    try testing.expectEqual(@as(f64, 250), center.target_frame.x);
    try testing.expectEqual(@as(f64, 225), center.target_frame.y);

    transition = reduce(transition.model, .{ .window_frame_command_result = .{
        .leader_window_id = 100,
        .window_id = 100,
        .target_frame = center.target_frame,
        .should_save_float_frame = true,
        .succeeded = true,
    } });
    try testing.expectEqual(@as(f64, 250), transition.model.window(100).?.frame.x);
    try testing.expectEqual(@as(f64, 250), transition.model.window(100).?.float_frame.?.x);
}

test "window move command commits ownership layout and intent atomically" {
    const testing = std.testing;
    const source_key: SpaceKey = .{ .id = 1 };
    const target_key: SpaceKey = .{ .id = 2 };
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = source_key, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = target_key, .workspace_id = 2, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 100,
        .process_id = 42,
        .space_key = source_key,
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .record_workspace_focus = .{
        .workspace_id = 1,
        .window_id = 100,
    } }).model;

    const transition = reduce(model, .{ .request_window_move = .{
        .window_id = 100,
        .target = catalog.find(target_key).?,
        .layout = testLayoutInsertion(.bsp),
        .should_move_native = false,
    } });
    try testing.expect(transition.model.window(100).?.space_key.eql(target_key));
    try testing.expect(!transition.model.layout.contains(source_key, 100));
    try testing.expect(transition.model.layout.contains(target_key, 100));
    try testing.expectEqual(@as(?WindowId, null), transition.model.focusedWorkspaceWindow(1));
    try testing.expectEqual(@as(?WindowId, 100), transition.model.focusedWorkspaceWindow(2));
    try testing.expect(transition.model.retile_request.all_displays);
    try testing.expectEqual(std.meta.Tag(Effect).window_moved, std.meta.activeTag(transition.effects[0]));
}
