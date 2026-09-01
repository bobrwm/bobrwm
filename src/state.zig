//! Deterministic application state and transitions.

const std = @import("std");
const space_mod = @import("space.zig");

pub const max_displays = 8;
pub const max_managed_windows = 1024;
pub const max_pending_focus_entries = 16;
pub const max_spaces_per_display = 10;
pub const max_pending_native_window_moves = 256;
pub const native_switch_timeout_ms: u64 = 3200;
pub const native_observation_delay_ms: u64 = 50;
pub const native_window_move_attempts_max: u8 = 3;
pub const workspace_transition_settle_ms: u64 = 400;

pub const DisplayId = space_mod.DisplayId;
pub const NativeSpaceId = space_mod.NativeSpaceId;
pub const WorkspaceId = space_mod.WorkspaceId;
pub const SpaceKey = space_mod.Key;
pub const SpaceRef = space_mod.Ref;
pub const Epoch = u64;
pub const TimestampMs = u64;
pub const WindowId = u32;

pub const FocusEventSource = enum {
    keyboard,
    drag,
    ax,
};

pub const DeferredFollowFocus = struct {
    process_id: i32,
    window_id: WindowId,
    source: FocusEventSource,
    transition_epoch: Epoch,
};

pub const FollowFocusObservation = struct {
    process_id: i32,
    window_id: WindowId,
    leader_window_id: WindowId,
    source: FocusEventSource,
    target: SpaceRef,
    is_target_visible: bool,
};

pub const WindowFocusObservation = struct {
    process_id: i32,
    window_id: WindowId,
    source: FocusEventSource,
    target: SpaceRef,
    is_target_visible: bool,
    at_ms: TimestampMs,
    pending_transition_epoch: ?Epoch = null,
};

pub const DisplayWorkspace = struct {
    display_id: DisplayId,
    active_workspace_id: WorkspaceId,
};

pub const WorkspaceTopology = struct {
    displays: [max_displays]DisplayWorkspace = undefined,
    display_count: u8 = 0,
    focused_display_id: ?DisplayId = null,

    pub fn addDisplay(self: *WorkspaceTopology, display: DisplayWorkspace) void {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.active_workspace_id != 0);
        std.debug.assert(self.display_count < self.displays.len);
        std.debug.assert(self.findDisplay(display.display_id) == null);

        self.displays[self.display_count] = display;
        self.display_count += 1;
        if (self.focused_display_id == null) self.focused_display_id = display.display_id;
    }

    pub fn findDisplay(self: *const WorkspaceTopology, display_id: DisplayId) ?*const DisplayWorkspace {
        for (self.displays[0..self.display_count]) |*display| {
            if (display.display_id == display_id) return display;
        }
        return null;
    }

    pub fn activeWorkspace(self: *const WorkspaceTopology, display_id: DisplayId) ?WorkspaceId {
        const display = self.findDisplay(display_id) orelse return null;
        return display.active_workspace_id;
    }

    pub fn setActiveWorkspace(self: *WorkspaceTopology, display_id: DisplayId, workspace_id: WorkspaceId) bool {
        for (self.displays[0..self.display_count]) |*display| {
            if (display.display_id != display_id) continue;
            display.active_workspace_id = workspace_id;
            return true;
        }
        return false;
    }
};

pub const SpaceCatalog = struct {
    spaces: [max_displays * max_spaces_per_display]SpaceRef = undefined,
    space_count: u8 = 0,

    pub fn add(self: *SpaceCatalog, space: SpaceRef) void {
        space.assertValid();
        std.debug.assert(self.space_count < self.spaces.len);
        std.debug.assert(self.find(space.key) == null);
        std.debug.assert(self.findWorkspace(space.display_id, space.workspace_id) == null);

        self.spaces[self.space_count] = space;
        self.space_count += 1;
    }

    pub fn find(self: *const SpaceCatalog, key: SpaceKey) ?SpaceRef {
        for (self.spaces[0..self.space_count]) |space| {
            if (space.key.eql(key)) return space;
        }
        return null;
    }

    pub fn findWorkspace(self: *const SpaceCatalog, display_id: DisplayId, workspace_id: WorkspaceId) ?SpaceRef {
        for (self.spaces[0..self.space_count]) |space| {
            if (space.display_id == display_id and space.workspace_id == workspace_id) return space;
        }
        return null;
    }
};

pub const Space = struct {
    id: NativeSpaceId,
    workspace_id: WorkspaceId,
};

pub const DisplayTopology = struct {
    display_id: DisplayId,
    observed_space_id: NativeSpaceId,
    spaces: [max_spaces_per_display]Space = undefined,
    space_count: u8 = 0,

    pub fn init(display_id: DisplayId, observed_space_id: NativeSpaceId) DisplayTopology {
        std.debug.assert(display_id != 0);
        std.debug.assert(observed_space_id != 0);
        return .{
            .display_id = display_id,
            .observed_space_id = observed_space_id,
        };
    }

    pub fn addSpace(self: *DisplayTopology, space: Space) void {
        std.debug.assert(space.id != 0);
        std.debug.assert(space.workspace_id != 0);
        std.debug.assert(self.space_count < self.spaces.len);
        std.debug.assert(self.spaceForWorkspace(space.workspace_id) == null);
        std.debug.assert(self.workspaceForSpace(space.id) == null);

        self.spaces[self.space_count] = space;
        self.space_count += 1;
    }

    pub fn spaceForWorkspace(self: *const DisplayTopology, workspace_id: WorkspaceId) ?NativeSpaceId {
        for (self.spaces[0..self.space_count]) |space| {
            if (space.workspace_id == workspace_id) return space.id;
        }
        return null;
    }

    pub fn workspaceForSpace(self: *const DisplayTopology, space_id: NativeSpaceId) ?WorkspaceId {
        for (self.spaces[0..self.space_count]) |space| {
            if (space.id == space_id) return space.workspace_id;
        }
        return null;
    }

    fn eql(self: *const DisplayTopology, other: *const DisplayTopology) bool {
        if (self.display_id != other.display_id) return false;
        if (self.observed_space_id != other.observed_space_id) return false;
        if (self.space_count != other.space_count) return false;

        for (self.spaces[0..self.space_count], other.spaces[0..other.space_count]) |left, right| {
            if (left.id != right.id or left.workspace_id != right.workspace_id) return false;
        }
        return true;
    }
};

pub const NativeTopology = struct {
    displays: [max_displays]DisplayTopology = undefined,
    display_count: u8 = 0,

    pub fn addDisplay(self: *NativeTopology, topology: DisplayTopology) void {
        std.debug.assert(self.display_count < self.displays.len);
        std.debug.assert(self.findDisplay(topology.display_id) == null);

        self.displays[self.display_count] = topology;
        self.display_count += 1;
    }

    pub fn findDisplay(self: *const NativeTopology, display_id: DisplayId) ?*const DisplayTopology {
        for (self.displays[0..self.display_count]) |*topology| {
            if (topology.display_id == display_id) return topology;
        }
        return null;
    }

    pub fn observedWorkspace(self: *const NativeTopology, display_id: DisplayId) ?WorkspaceId {
        const topology = self.findDisplay(display_id) orelse return null;
        return topology.workspaceForSpace(topology.observed_space_id);
    }

    pub fn eql(self: *const NativeTopology, other: *const NativeTopology) bool {
        if (self.display_count != other.display_count) return false;

        for (self.displays[0..self.display_count], other.displays[0..other.display_count]) |*left, *right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

pub const SwitchRequest = struct {
    target: SpaceRef,
};

pub const PendingSwitch = struct {
    request: SwitchRequest,
    epoch: Epoch,
    deadline_at_ms: TimestampMs,
};

pub const WorkspaceTransitionKind = enum {
    switch_workspace,
    move_workspace_to_display,
};

pub const WorkspaceTransitionCompletionReason = enum {
    focus_accepted,
    empty_workspace,
    native_space_changed,
};

pub const WorkspaceTransition = struct {
    kind: WorkspaceTransitionKind,
    target: SpaceRef,
    epoch: Epoch,
    started_at_ms: TimestampMs,
    deadline_at_ms: TimestampMs,
    completion_reason: ?WorkspaceTransitionCompletionReason = null,
};

pub const WorkspaceTransitionSettlementReason = enum {
    completed,
    deadline_expired,
    native_switch_failed,
    target_unavailable,
    topology_reinitialized,
};

pub const WorkspaceTransitionSettlement = struct {
    transition: WorkspaceTransition,
    reason: WorkspaceTransitionSettlementReason,
    deferred_follow_focus: ?DeferredFollowFocus,
};

pub const PendingNativeWindowMove = struct {
    window_id: WindowId,
    source: SpaceRef,
    target: SpaceRef,
    epoch: Epoch,
    attempts_remaining: u8 = native_window_move_attempts_max,
    has_retried: bool = false,
};

pub const PendingNativeWindowMoves = struct {
    entries: [max_pending_native_window_moves]PendingNativeWindowMove = undefined,
    count: u16 = 0,

    pub fn items(self: *const PendingNativeWindowMoves) []const PendingNativeWindowMove {
        return self.entries[0..self.count];
    }

    pub fn get(self: *const PendingNativeWindowMoves, window_id: WindowId) ?PendingNativeWindowMove {
        const index = self.findIndex(window_id) orelse return null;
        return self.entries[index];
    }

    fn put(self: *PendingNativeWindowMoves, pending: PendingNativeWindowMove) bool {
        if (self.findIndex(pending.window_id)) |index| {
            self.entries[index] = pending;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = pending;
        self.count += 1;
        return true;
    }

    fn remove(self: *PendingNativeWindowMoves, window_id: WindowId) ?PendingNativeWindowMove {
        const index = self.findIndex(window_id) orelse return null;
        const removed = self.entries[index];
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return removed;
    }

    fn findIndex(self: *const PendingNativeWindowMoves, window_id: WindowId) ?usize {
        for (self.items(), 0..) |pending, index| {
            if (pending.window_id == window_id) return index;
        }
        return null;
    }
};

pub const NativeWindowMoveRequest = struct {
    window_id: WindowId,
    source: SpaceRef,
    target: SpaceRef,
};

pub const NativeWindowMoveObservation = enum {
    confirmed,
    pending,
    window_missing,
    ownership_changed,
};

pub const PendingFocus = struct {
    process_id: i32,
    window_id: WindowId,
    source: FocusEventSource,
    space_key: SpaceKey,
    transition_epoch: Epoch,
    sequence: u64,
};

pub const PendingFocusQueue = struct {
    entries: [max_pending_focus_entries]PendingFocus = undefined,
    count: u8 = 0,
    next_sequence: u64 = 1,

    pub fn hasEntries(self: *const PendingFocusQueue) bool {
        return self.count > 0;
    }

    fn clear(self: *PendingFocusQueue) void {
        self.count = 0;
    }

    fn insertOrReplace(self: *PendingFocusQueue, entry: PendingFocus) void {
        var oldest_index: usize = 0;
        var oldest_sequence: u64 = std.math.maxInt(u64);
        for (self.entries[0..self.count], 0..) |existing, index| {
            if (existing.window_id == entry.window_id) {
                self.entries[index] = entry;
                return;
            }
            if (existing.sequence < oldest_sequence) {
                oldest_sequence = existing.sequence;
                oldest_index = index;
            }
        }

        if (self.count < self.entries.len) {
            self.entries[self.count] = entry;
            self.count += 1;
            return;
        }
        self.entries[oldest_index] = entry;
    }

    fn takeLatest(self: *PendingFocusQueue) ?PendingFocus {
        if (self.count == 0) return null;

        var latest_index: usize = 0;
        for (self.entries[1..self.count], 1..) |entry, index| {
            if (entry.sequence > self.entries[latest_index].sequence) latest_index = index;
        }

        const entry = self.entries[latest_index];
        self.count -= 1;
        self.entries[latest_index] = self.entries[self.count];
        return entry;
    }

    fn takeSequence(self: *PendingFocusQueue) u64 {
        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        return sequence;
    }
};

pub const ManagedWindow = struct {
    window_id: WindowId,
    process_id: i32,
    space_key: SpaceKey,
};

pub const WindowCatalog = struct {
    entries: [max_managed_windows]ManagedWindow = undefined,
    count: u16 = 0,

    pub fn items(self: *const WindowCatalog) []const ManagedWindow {
        return self.entries[0..self.count];
    }

    pub fn get(self: *const WindowCatalog, window_id: WindowId) ?ManagedWindow {
        const index = self.findIndex(window_id) orelse return null;
        return self.entries[index];
    }

    pub fn countInSpace(self: *const WindowCatalog, space_key: SpaceKey) u16 {
        var count: u16 = 0;
        for (self.items()) |entry| {
            if (entry.space_key.eql(space_key)) count += 1;
        }
        return count;
    }

    fn put(self: *WindowCatalog, entry: ManagedWindow) bool {
        if (self.findIndex(entry.window_id)) |index| {
            self.entries[index] = entry;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = entry;
        self.count += 1;
        return true;
    }

    fn remove(self: *WindowCatalog, window_id: WindowId) bool {
        const index = self.findIndex(window_id) orelse return false;
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return true;
    }

    fn assignSpace(self: *WindowCatalog, window_id: WindowId, space_key: SpaceKey) bool {
        const index = self.findIndex(window_id) orelse return false;
        self.entries[index].space_key = space_key;
        return true;
    }

    fn findIndex(self: *const WindowCatalog, window_id: WindowId) ?usize {
        for (self.items(), 0..) |entry, index| {
            if (entry.window_id == window_id) return index;
        }
        return null;
    }
};

pub const ObservationTimer = struct {
    epoch: Epoch,
    due_at_ms: TimestampMs,
};

pub const Model = struct {
    spaces: SpaceCatalog = .{},
    windows: WindowCatalog = .{},
    workspace_topology: WorkspaceTopology = .{},
    native_topology: NativeTopology = .{},
    pending_switch: ?PendingSwitch = null,
    queued_switch: ?SwitchRequest = null,
    observation_timer: ?ObservationTimer = null,
    workspace_transition: ?WorkspaceTransition = null,
    pending_native_window_moves: PendingNativeWindowMoves = .{},
    pending_focus: PendingFocusQueue = .{},
    deferred_follow_focus: ?DeferredFollowFocus = null,
    next_epoch: Epoch = 1,

    pub fn isNativeSwitchPending(self: *const Model) bool {
        return self.pending_switch != null;
    }

    pub fn hasScheduledObservation(self: *const Model) bool {
        return self.observation_timer != null;
    }

    pub fn isWorkspaceTransitionActive(self: *const Model) bool {
        return self.workspace_transition != null;
    }

    pub fn hasPendingNativeWindowMoves(self: *const Model) bool {
        return self.pending_native_window_moves.count > 0;
    }

    pub fn pendingNativeWindowMove(self: *const Model, window_id: WindowId) ?PendingNativeWindowMove {
        return self.pending_native_window_moves.get(window_id);
    }

    pub fn hasPendingFocus(self: *const Model) bool {
        return self.pending_focus.hasEntries();
    }

    pub fn pendingFocusCount(self: *const Model) u8 {
        return self.pending_focus.count;
    }

    pub fn hasDeferredFollowFocus(self: *const Model) bool {
        return self.deferred_follow_focus != null;
    }

    pub fn dueObservation(self: *const Model, at_ms: TimestampMs) ?ObservationTimer {
        const timer = self.observation_timer orelse return null;
        if (at_ms < timer.due_at_ms) return null;
        return timer;
    }

    pub fn observedWorkspace(self: *const Model, display_id: DisplayId) ?WorkspaceId {
        return self.native_topology.observedWorkspace(display_id);
    }

    pub fn activeWorkspace(self: *const Model, display_id: DisplayId) ?WorkspaceId {
        return self.workspace_topology.activeWorkspace(display_id);
    }

    pub fn focusedDisplay(self: *const Model) ?DisplayId {
        return self.workspace_topology.focused_display_id;
    }

    pub fn spaceForWorkspace(self: *const Model, display_id: DisplayId, workspace_id: WorkspaceId) ?SpaceRef {
        return self.spaces.findWorkspace(display_id, workspace_id);
    }

    pub fn space(self: *const Model, key: SpaceKey) ?SpaceRef {
        return self.spaces.find(key);
    }

    pub fn window(self: *const Model, window_id: WindowId) ?ManagedWindow {
        return self.windows.get(window_id);
    }

    pub fn desiredWorkspace(self: *const Model, display_id: DisplayId) ?WorkspaceId {
        if (self.queued_switch) |queued| {
            if (queued.target.display_id == display_id) return queued.target.workspace_id;
        }
        if (self.pending_switch) |pending| {
            if (pending.request.target.display_id == display_id) return pending.request.target.workspace_id;
        }
        return self.activeWorkspace(display_id);
    }
};

pub const Event = union(enum) {
    replace_space_catalog: SpaceCatalog,
    adopt_window: ManagedWindow,
    remove_window: WindowId,
    assign_window_space: struct {
        window_id: WindowId,
        space_key: SpaceKey,
    },
    replace_workspace_topology: WorkspaceTopology,
    focus_display: DisplayId,
    activate_workspace: struct {
        display_id: DisplayId,
        workspace_id: WorkspaceId,
    },
    initialize_native_topology: NativeTopology,
    request_native_switch: struct {
        target: SpaceRef,
        at_ms: TimestampMs,
    },
    native_space_changed: TimestampMs,
    observation_timer_fired: struct {
        epoch: Epoch,
        at_ms: TimestampMs,
    },
    native_topology_observed: struct {
        topology: NativeTopology,
        epoch: Epoch,
        at_ms: TimestampMs,
    },
    native_topology_unavailable: struct {
        epoch: Epoch,
        at_ms: TimestampMs,
    },
    native_switch_effect_failed: struct {
        epoch: Epoch,
        at_ms: TimestampMs,
    },
    start_workspace_transition: struct {
        kind: WorkspaceTransitionKind,
        target: SpaceRef,
        at_ms: TimestampMs,
    },
    complete_workspace_transition: struct {
        epoch: Epoch,
        reason: WorkspaceTransitionCompletionReason,
        at_ms: TimestampMs,
    },
    workspace_transition_timer_fired: struct {
        epoch: Epoch,
        at_ms: TimestampMs,
    },
    track_native_window_move: NativeWindowMoveRequest,
    cancel_native_window_move: WindowId,
    native_window_move_observed: struct {
        window_id: WindowId,
        epoch: Epoch,
        observation: NativeWindowMoveObservation,
    },
    native_window_move_rollback_result: struct {
        window_id: WindowId,
        epoch: Epoch,
        succeeded: bool,
    },
    window_focus_observed: WindowFocusObservation,
    request_pending_focus,
    clear_pending_focus,
    follow_focus_observed: FollowFocusObservation,
};

pub const SwitchFailureReason = enum {
    effect_failed,
    observation_unavailable,
    unexpected_space,
};

pub const WindowCatalogRejectionReason = enum {
    catalog_full,
    invalid_window,
    window_missing,
    space_missing,
};

pub const Effect = union(enum) {
    switch_native_space: struct {
        request: SwitchRequest,
        epoch: Epoch,
    },
    observe_native_topology: Epoch,
    focus_observed_space: SpaceRef,
    native_switch_completed: struct {
        space: SpaceRef,
        epoch: Epoch,
    },
    native_switch_failed: struct {
        request: SwitchRequest,
        epoch: Epoch,
        reason: SwitchFailureReason,
        actual: ?SpaceRef,
    },
    native_topology_changed,
    native_switch_rejected: SpaceRef,
    window_catalog_rejected: struct {
        window_id: WindowId,
        reason: WindowCatalogRejectionReason,
    },
    workspace_transition_started: WorkspaceTransition,
    workspace_transition_settled: WorkspaceTransitionSettlement,
    retry_native_window_move: PendingNativeWindowMove,
    rollback_native_window_move: PendingNativeWindowMove,
    native_window_move_confirmed: PendingNativeWindowMove,
    native_window_move_cancelled: PendingNativeWindowMove,
    native_window_move_rolled_back: PendingNativeWindowMove,
    native_window_move_rollback_deferred: PendingNativeWindowMove,
    native_window_move_rejected: NativeWindowMoveRequest,
    apply_pending_focus: PendingFocus,
    window_focus_deferred: struct {
        observation: WindowFocusObservation,
        transition: WorkspaceTransition,
        pending_count: u8,
    },
    window_focus_accepted: struct {
        observation: WindowFocusObservation,
        transition: WorkspaceTransition,
    },
    follow_focus_ignored_during_native_switch: struct {
        observation: FollowFocusObservation,
        pending_target: SpaceRef,
    },
    follow_focus_deferred: struct {
        observation: FollowFocusObservation,
        transition: WorkspaceTransition,
    },
    follow_focus_workspace: FollowFocusObservation,
};

pub const max_effects = 6;

pub const Transition = struct {
    model: Model,
    effects: [max_effects]Effect = undefined,
    effect_count: u8 = 0,

    fn addEffect(self: *Transition, effect: Effect) void {
        std.debug.assert(self.effect_count < self.effects.len);
        self.effects[self.effect_count] = effect;
        self.effect_count += 1;
    }
};

pub fn reduce(model: Model, event: Event) Transition {
    var transition: Transition = .{ .model = model };

    switch (event) {
        .replace_space_catalog => |catalog| {
            transition.model.spaces = catalog;
            refreshWorkspaceTransition(&transition);
            refreshPendingNativeWindowMoves(&transition.model);
        },
        .adopt_window => |window| reduceWindowAdopted(&transition, window),
        .remove_window => |window_id| {
            _ = transition.model.windows.remove(window_id);
        },
        .assign_window_space => |assignment| reduceWindowSpaceAssigned(&transition, assignment),
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
        .initialize_native_topology => |topology| {
            const workspace_transition = transition.model.workspace_transition;
            transition.model.native_topology = topology;
            transition.model.pending_switch = null;
            transition.model.queued_switch = null;
            transition.model.observation_timer = null;
            transition.model.pending_native_window_moves.count = 0;
            if (workspace_transition) |current| {
                finalizeWorkspaceTransition(&transition, current, .topology_reinitialized);
            } else {
                transition.model.pending_focus.clear();
                transition.model.deferred_follow_focus = null;
            }
            syncNativeWorkspaceTopology(&transition);
        },
        .request_native_switch => |request| reduceSwitchRequest(&transition, request),
        .native_space_changed => |at_ms| reduceSpaceChanged(&transition, at_ms),
        .observation_timer_fired => |timer| reduceObservationTimer(&transition, timer),
        .native_topology_observed => |observation| reduceTopologyObserved(&transition, observation),
        .native_topology_unavailable => |unavailable| reduceTopologyUnavailable(&transition, unavailable),
        .native_switch_effect_failed => |failure| reduceSwitchEffectFailed(&transition, failure),
        .start_workspace_transition => |start| reduceWorkspaceTransitionStart(&transition, start),
        .complete_workspace_transition => |completion| reduceWorkspaceTransitionCompletion(&transition, completion),
        .workspace_transition_timer_fired => |timer| reduceWorkspaceTransitionTimer(&transition, timer),
        .track_native_window_move => |request| reduceNativeWindowMoveTracked(&transition, request),
        .cancel_native_window_move => |window_id| {
            _ = transition.model.pending_native_window_moves.remove(window_id);
        },
        .native_window_move_observed => |observation| reduceNativeWindowMoveObserved(&transition, observation),
        .native_window_move_rollback_result => |result| reduceNativeWindowMoveRollbackResult(&transition, result),
        .window_focus_observed => |observation| reduceWindowFocusObserved(&transition, observation),
        .request_pending_focus => reducePendingFocusRequest(&transition),
        .clear_pending_focus => transition.model.pending_focus.clear(),
        .follow_focus_observed => |observation| reduceFollowFocusObserved(&transition, observation),
    }

    assertModel(&transition.model);
    return transition;
}

fn reduceWindowAdopted(transition: *Transition, window: ManagedWindow) void {
    if (window.window_id == 0 or window.process_id <= 0) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .invalid_window,
        } });
        return;
    }
    if (transition.model.space(window.space_key) == null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .space_missing,
        } });
        return;
    }
    if (transition.model.windows.put(window)) return;

    transition.addEffect(.{ .window_catalog_rejected = .{
        .window_id = window.window_id,
        .reason = .catalog_full,
    } });
}

fn reduceWindowSpaceAssigned(
    transition: *Transition,
    assignment: @FieldType(Event, "assign_window_space"),
) void {
    if (transition.model.space(assignment.space_key) == null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = assignment.window_id,
            .reason = .space_missing,
        } });
        return;
    }
    if (transition.model.windows.assignSpace(assignment.window_id, assignment.space_key)) return;

    transition.addEffect(.{ .window_catalog_rejected = .{
        .window_id = assignment.window_id,
        .reason = .window_missing,
    } });
}

fn reduceSwitchRequest(
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

fn reduceSpaceChanged(transition: *Transition, at_ms: TimestampMs) void {
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

fn reduceObservationTimer(
    transition: *Transition,
    event: @FieldType(Event, "observation_timer_fired"),
) void {
    const timer = transition.model.observation_timer orelse return;
    if (timer.epoch != event.epoch) return;
    if (event.at_ms < timer.due_at_ms) return;

    transition.model.observation_timer = null;
    transition.addEffect(.{ .observe_native_topology = timer.epoch });
}

fn reduceTopologyObserved(
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

fn syncNativeWorkspaceTopology(transition: *Transition) void {
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

fn reduceTopologyUnavailable(
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

fn reduceSwitchEffectFailed(
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

fn reduceWorkspaceTransitionStart(
    transition: *Transition,
    event: @FieldType(Event, "start_workspace_transition"),
) void {
    const target = transition.model.space(event.target.key) orelse return;
    startWorkspaceTransition(transition, event.kind, target, event.at_ms, workspace_transition_settle_ms, null);
}

fn reduceWorkspaceTransitionCompletion(
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

fn reduceWorkspaceTransitionTimer(
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

fn reduceNativeWindowMoveTracked(
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
    }
}

fn reduceNativeWindowMoveObserved(
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

fn reduceNativeWindowMoveRollbackResult(
    transition: *Transition,
    event: @FieldType(Event, "native_window_move_rollback_result"),
) void {
    const pending = transition.model.pending_native_window_moves.get(event.window_id) orelse return;
    if (pending.epoch != event.epoch) return;

    if (event.succeeded) {
        _ = transition.model.pending_native_window_moves.remove(event.window_id);
        transition.addEffect(.{ .native_window_move_rolled_back = pending });
        return;
    }
    transition.addEffect(.{ .native_window_move_rollback_deferred = pending });
}

fn reduceWindowFocusObserved(
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

fn reducePendingFocusRequest(transition: *Transition) void {
    const workspace_transition = transition.model.workspace_transition orelse {
        transition.model.pending_focus.clear();
        return;
    };
    const pending = transition.model.pending_focus.takeLatest() orelse return;
    if (pending.transition_epoch != workspace_transition.epoch) return;

    transition.addEffect(.{ .apply_pending_focus = pending });
}

fn reduceFollowFocusObserved(
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
        transition.addEffect(.{ .follow_focus_workspace = observation });
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

fn finishSwitch(
    transition: *Transition,
    pending: PendingSwitch,
    at_ms: TimestampMs,
    failure: ?FailedSwitch,
) void {
    transition.model.pending_switch = null;
    transition.model.observation_timer = null;

    if (failure == null) {
        transition.model.deferred_follow_focus = null;
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

fn startSwitch(
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
            transition.addEffect(.{ .focus_observed_space = target });
        } else {
            transition.addEffect(.{ .native_switch_completed = .{
                .space = target,
                .epoch = 0,
            } });
        }
        return;
    }

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

fn startWorkspaceTransition(
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

fn completeWorkspaceTransition(
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

fn settleWorkspaceTransition(
    transition: *Transition,
    epoch: Epoch,
    reason: WorkspaceTransitionSettlementReason,
) void {
    const current = transition.model.workspace_transition orelse return;
    if (current.epoch != epoch) return;

    finalizeWorkspaceTransition(transition, current, reason);
}

fn finalizeWorkspaceTransition(
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

fn refreshWorkspaceTransition(transition: *Transition) void {
    var current = transition.model.workspace_transition orelse return;
    current.target = transition.model.space(current.target.key) orelse {
        finalizeWorkspaceTransition(transition, current, .target_unavailable);
        return;
    };
    transition.model.workspace_transition = current;
}

fn refreshPendingNativeWindowMoves(model: *Model) void {
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

fn schedulePendingObservation(model: *Model, pending: PendingSwitch, at_ms: TimestampMs) void {
    model.observation_timer = .{
        .epoch = pending.epoch,
        .due_at_ms = at_ms +| native_observation_delay_ms,
    };
}

fn takeEpoch(model: *Model) Epoch {
    const epoch = model.next_epoch;
    model.next_epoch +%= 1;
    if (model.next_epoch == 0) model.next_epoch = 1;
    return epoch;
}

fn sameRequest(left: SwitchRequest, right: SwitchRequest) bool {
    return left.target.key.eql(right.target.key);
}

fn nativeSpaceId(space: SpaceRef) ?NativeSpaceId {
    return switch (space.key) {
        .native => |space_id| space_id,
        .virtual => null,
    };
}

fn assertModel(model: *const Model) void {
    std.debug.assert(model.next_epoch != 0);
    std.debug.assert(model.spaces.space_count <= model.spaces.spaces.len);
    for (model.spaces.spaces[0..model.spaces.space_count], 0..) |space, index| {
        space.assertValid();
        for (model.spaces.spaces[0..index]) |prior| {
            std.debug.assert(!prior.key.eql(space.key));
            std.debug.assert(prior.display_id != space.display_id or prior.workspace_id != space.workspace_id);
        }
    }
    std.debug.assert(model.windows.count <= model.windows.entries.len);
    for (model.windows.items(), 0..) |window, index| {
        std.debug.assert(window.window_id != 0);
        std.debug.assert(window.process_id > 0);
        for (model.windows.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != window.window_id);
        }
    }
    std.debug.assert(model.workspace_topology.display_count <= model.workspace_topology.displays.len);
    for (model.workspace_topology.displays[0..model.workspace_topology.display_count], 0..) |display, index| {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.active_workspace_id != 0);
        for (model.workspace_topology.displays[0..index]) |prior| {
            std.debug.assert(prior.display_id != display.display_id);
        }
    }
    if (model.workspace_topology.focused_display_id) |display_id| {
        std.debug.assert(model.workspace_topology.findDisplay(display_id) != null);
    }
    std.debug.assert(model.native_topology.display_count <= model.native_topology.displays.len);
    for (model.native_topology.displays[0..model.native_topology.display_count], 0..) |display, index| {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.observed_space_id != 0);
        std.debug.assert(display.space_count <= display.spaces.len);
        for (model.native_topology.displays[0..index]) |prior| {
            std.debug.assert(prior.display_id != display.display_id);
        }
        for (display.spaces[0..display.space_count], 0..) |space, space_index| {
            std.debug.assert(space.id != 0);
            std.debug.assert(space.workspace_id != 0);
            for (display.spaces[0..space_index]) |prior| {
                std.debug.assert(prior.id != space.id);
                std.debug.assert(prior.workspace_id != space.workspace_id);
            }
        }
    }
    if (model.pending_switch) |pending| {
        std.debug.assert(pending.epoch != 0);
        pending.request.target.assertValid();
        std.debug.assert(nativeSpaceId(pending.request.target) != null);
        if (model.observation_timer) |timer| std.debug.assert(timer.epoch == pending.epoch);
    }
    if (model.queued_switch) |queued| {
        queued.target.assertValid();
        std.debug.assert(nativeSpaceId(queued.target) != null);
    }
    if (model.workspace_transition) |workspace_transition| {
        std.debug.assert(workspace_transition.epoch != 0);
        workspace_transition.target.assertValid();
        const target = model.space(workspace_transition.target.key).?;
        std.debug.assert(target.display_id == workspace_transition.target.display_id);
        std.debug.assert(target.workspace_id == workspace_transition.target.workspace_id);
        std.debug.assert(workspace_transition.deadline_at_ms >= workspace_transition.started_at_ms);
    }
    std.debug.assert(model.pending_native_window_moves.count <= model.pending_native_window_moves.entries.len);
    for (model.pending_native_window_moves.items(), 0..) |pending, index| {
        std.debug.assert(pending.window_id != 0);
        std.debug.assert(pending.epoch != 0);
        std.debug.assert(pending.attempts_remaining > 0);
        std.debug.assert(nativeSpaceId(pending.source) != null);
        std.debug.assert(nativeSpaceId(pending.target) != null);
        std.debug.assert(!pending.source.key.eql(pending.target.key));
        std.debug.assert(model.space(pending.source.key) != null);
        std.debug.assert(model.space(pending.target.key) != null);
        for (model.pending_native_window_moves.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != pending.window_id);
        }
    }
    std.debug.assert(model.pending_focus.count <= model.pending_focus.entries.len);
    std.debug.assert(model.pending_focus.next_sequence != 0);
    if (model.workspace_transition == null) std.debug.assert(!model.pending_focus.hasEntries());
    for (model.pending_focus.entries[0..model.pending_focus.count], 0..) |pending, index| {
        std.debug.assert(pending.process_id > 0);
        std.debug.assert(pending.window_id != 0);
        std.debug.assert(pending.source != .keyboard);
        std.debug.assert(pending.sequence != 0);
        std.debug.assert(pending.transition_epoch == model.workspace_transition.?.epoch);
        for (model.pending_focus.entries[0..index]) |prior| {
            std.debug.assert(prior.window_id != pending.window_id);
        }
    }
    if (model.workspace_transition == null) std.debug.assert(model.deferred_follow_focus == null);
    if (model.deferred_follow_focus) |deferred| {
        std.debug.assert(deferred.process_id > 0);
        std.debug.assert(deferred.window_id != 0);
        std.debug.assert(deferred.transition_epoch == model.workspace_transition.?.epoch);
    }
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
        second.addSpace(.{ .id = 201, .workspace_id = 1 });
        second.addSpace(.{ .id = 202, .workspace_id = 2 });
        second.addSpace(.{ .id = 203, .workspace_id = 3 });
        topology.addDisplay(second);
    }
    return topology;
}

fn initializedModel(topology: NativeTopology) Model {
    return reduce(.{}, .{ .initialize_native_topology = topology }).model;
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

test "window catalog owns identity and Space membership" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });
    const model: Model = .{ .spaces = catalog };

    const first = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .virtual = 1 },
    } });
    const second = reduce(first.model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1002,
        .space_key = .{ .virtual = 1 },
    } });

    try testing.expect(model.window(101) == null);
    try testing.expectEqual(@as(u16, 2), second.model.windows.countInSpace(.{ .virtual = 1 }));
    try testing.expectEqual(@as(i32, 1001), second.model.window(101).?.process_id);

    const assigned = reduce(second.model, .{ .assign_window_space = .{
        .window_id = 101,
        .space_key = .{ .virtual = 2 },
    } });
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .virtual = 1 }));
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .virtual = 2 }));
    try testing.expect(assigned.model.window(101).?.space_key.eql(.{ .virtual = 2 }));

    const removed = reduce(assigned.model, .{ .remove_window = 102 });
    try testing.expect(removed.model.window(102) == null);
    try testing.expectEqual(@as(u16, 1), removed.model.windows.count);
}

test "window catalog rejects invalid lifecycle events" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    const model: Model = .{ .spaces = catalog };

    const invalid = reduce(model, .{ .adopt_window = .{
        .window_id = 0,
        .process_id = 1001,
        .space_key = .{ .virtual = 1 },
    } });
    try testing.expectEqual(@as(u8, 1), invalid.effect_count);
    try testing.expectEqual(
        WindowCatalogRejectionReason.invalid_window,
        invalid.effects[0].window_catalog_rejected.reason,
    );

    const missing_space = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .virtual = 2 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.space_missing,
        missing_space.effects[0].window_catalog_rejected.reason,
    );

    const missing_window = reduce(model, .{ .assign_window_space = .{
        .window_id = 101,
        .space_key = .{ .virtual = 1 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.window_missing,
        missing_window.effects[0].window_catalog_rejected.reason,
    );
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

test "native ordinal is scoped to display Space identity" {
    const testing = std.testing;
    const model = initializedModel(testTopology(102, 202));
    const first = model.spaceForWorkspace(1, 2).?;
    const second = model.spaceForWorkspace(2, 2).?;

    try testing.expectEqual(@as(?WorkspaceId, 2), model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 2), model.observedWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 102), model.native_topology.findDisplay(1).?.spaceForWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 202), model.native_topology.findDisplay(2).?.spaceForWorkspace(2));
    try testing.expect(first.key.eql(.{ .native = 102 }));
    try testing.expect(second.key.eql(.{ .native = 202 }));
    try testing.expect(!first.key.eql(second.key));
}

test "switch effect preserves target Space identity across displays" {
    const testing = std.testing;
    const model = initializedModel(testTopology(102, 201));
    const transition = reduce(model, switchRequest(&model, 2, 2, 100));
    const effect = transition.effects[1].switch_native_space;

    try testing.expect(effect.request.target.key.eql(.{ .native = 202 }));
    try testing.expectEqual(@as(DisplayId, 2), effect.request.target.display_id);
    try testing.expectEqual(@as(WorkspaceId, 2), effect.request.target.workspace_id);
}

test "virtual catalog preserves identity when placement changes" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 22 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    catalog.spaces[1].display_id = 11;
    model = reduce(model, .{ .replace_space_catalog = catalog }).model;

    const moved = model.space(.{ .virtual = 2 }).?;
    try testing.expectEqual(@as(DisplayId, 11), moved.display_id);
    try testing.expect(moved.key.eql(.{ .virtual = 2 }));
}

test "virtual workspace and focused display are reducer owned" {
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

test "virtual workspace transition settles from explicit focus and time events" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    var transition = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 100,
    } });
    model = transition.model;
    const epoch = model.workspace_transition.?.epoch;

    try testing.expect(model.workspace_transition.?.target.key.eql(.{ .virtual = 2 }));
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

test "virtual display move transition follows stable Space identity" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 22 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .move_workspace_to_display,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 100,
    } }).model;

    catalog.spaces[1].display_id = 11;
    model = reduce(model, .{ .replace_space_catalog = catalog }).model;

    try testing.expect(model.workspace_transition.?.target.key.eql(.{ .virtual = 2 }));
    try testing.expectEqual(@as(DisplayId, 11), model.workspace_transition.?.target.display_id);
    try testing.expectEqual(WorkspaceTransitionKind.move_workspace_to_display, model.workspace_transition.?.kind);
}

test "stale workspace transition timer cannot settle newer intent" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 1 }).?,
        .at_ms = 100,
    } }).model;
    const stale_epoch = model.workspace_transition.?.epoch;

    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 200,
    } }).model;
    const current_epoch = model.workspace_transition.?.epoch;

    const transition = reduce(model, .{ .workspace_transition_timer_fired = .{
        .epoch = stale_epoch,
        .at_ms = 1000,
    } });

    try testing.expectEqual(current_epoch, transition.model.workspace_transition.?.epoch);
    try testing.expect(transition.model.workspace_transition.?.target.key.eql(.{ .virtual = 2 }));
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
}

test "pending focus queue replaces by window and applies newest intent" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, null));
    model = reduce(model, switchRequest(&model, 1, 2, 100)).model;
    const epoch = model.workspace_transition.?.epoch;

    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .native = 102 }, false, null)).model;
    model = reduce(model, windowFocusObservation(&model, 20, 42, .drag, .{ .native = 101 }, false, null)).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .drag, .{ .native = 102 }, false, null)).model;

    try testing.expectEqual(@as(u8, 2), model.pendingFocusCount());
    var transition = reduce(model, .request_pending_focus);
    const pending = transition.effects[0].apply_pending_focus;
    try testing.expectEqual(@as(WindowId, 41), pending.window_id);
    try testing.expectEqual(FocusEventSource.drag, pending.source);
    try testing.expectEqual(epoch, pending.transition_epoch);
    try testing.expectEqual(@as(u8, 1), transition.model.pendingFocusCount());

    transition = reduce(
        transition.model,
        windowFocusObservation(&transition.model, 10, 41, .drag, .{ .native = 102 }, true, epoch),
    );
    try testing.expect(!transition.model.hasPendingFocus());
    try testing.expectEqual(std.meta.Tag(Effect).window_focus_accepted, std.meta.activeTag(transition.effects[0]));
}

test "new workspace transition rejects stale pending focus observation" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 1 }).?,
        .at_ms = 100,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .virtual = 1 }, false, null)).model;
    const stale_epoch = model.workspace_transition.?.epoch;

    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 200,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 20, 42, .ax, .{ .virtual = 2 }, false, null)).model;

    const current_epoch = model.workspace_transition.?.epoch;
    const transition = reduce(
        model,
        windowFocusObservation(&model, 10, 41, .ax, .{ .virtual = 1 }, true, stale_epoch),
    );

    try testing.expectEqual(current_epoch, transition.model.workspace_transition.?.epoch);
    try testing.expectEqual(@as(u8, 1), transition.model.pendingFocusCount());
}

test "keyboard focus accepts a visible non-target and clears pending focus" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 100,
    } }).model;
    model = reduce(model, windowFocusObservation(&model, 10, 41, .ax, .{ .virtual = 1 }, false, null)).model;

    const transition = reduce(
        model,
        windowFocusObservation(&model, 10, 41, .keyboard, .{ .virtual = 1 }, true, null),
    );

    try testing.expect(!transition.model.hasPendingFocus());
    try testing.expectEqual(WorkspaceTransitionCompletionReason.focus_accepted, transition.model.workspace_transition.?.completion_reason.?);
    try testing.expectEqual(std.meta.Tag(Effect).window_focus_accepted, std.meta.activeTag(transition.effects[0]));
}

test "deferred follow focus leaves the model with transition settlement" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .start_workspace_transition = .{
        .kind = .switch_workspace,
        .target = model.space(.{ .virtual = 2 }).?,
        .at_ms = 100,
    } }).model;
    const epoch = model.workspace_transition.?.epoch;

    var transition = reduce(model, followFocusObservation(&model, .{ .virtual = 1 }, false));
    model = transition.model;
    try testing.expect(model.hasDeferredFollowFocus());
    try testing.expectEqual(epoch, model.deferred_follow_focus.?.transition_epoch);
    try testing.expectEqual(std.meta.Tag(Effect).follow_focus_deferred, std.meta.activeTag(transition.effects[0]));

    transition = reduce(model, followFocusObservation(&model, .{ .virtual = 2 }, true));
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
    const transition = reduce(model, followFocusObservation(&model, .{ .native = 101 }, false));

    try testing.expect(!transition.model.hasDeferredFollowFocus());
    try testing.expectEqual(std.meta.Tag(Effect).follow_focus_ignored_during_native_switch, std.meta.activeTag(transition.effects[0]));
}

test "hidden focus without a transition requests a workspace switch" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, null));
    const transition = reduce(model, followFocusObservation(&model, .{ .native = 102 }, false));
    const observation = transition.effects[0].follow_focus_workspace;

    try testing.expectEqual(std.meta.Tag(Effect).follow_focus_workspace, std.meta.activeTag(transition.effects[0]));
    try testing.expect(observation.target.key.eql(.{ .native = 102 }));
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

    try testing.expect(pending.target.key.eql(.{ .native = 102 }));
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
