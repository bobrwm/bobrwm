//! State model and transition protocol.

const std = @import("std");
const geometry_mod = @import("../geometry.zig");
const topology_mod = @import("topology.zig");
const window_catalog_mod = @import("window_catalog.zig");
const tiling_mod = @import("../tiling.zig");
const window_mod = @import("../window.zig");

pub const max_displays = topology_mod.max_displays;
pub const max_managed_windows = window_catalog_mod.max_managed_windows;
pub const max_pending_focus_entries = 16;
pub const max_pending_window_candidates = 256;
pub const max_process_retries = 64;
pub const max_cleanup_processes = 16;
pub const max_spaces_per_display = topology_mod.max_spaces_per_display;
pub const max_workspace_focus_history = 32;
pub const max_pending_native_window_moves = 256;
pub const native_switch_timeout_ms: u64 = 3200;
pub const native_observation_delay_ms: u64 = 50;
pub const native_window_move_attempts_max: u8 = 3;
pub const native_workspace_move_timeout_ms: u64 = 3200;
pub const workspace_transition_settle_ms: u64 = 400;
pub const display_event_debounce_ms: u64 = 50;

comptime {
    std.debug.assert(geometry_mod.max_entries >= max_managed_windows);
    std.debug.assert(tiling_mod.max_windows >= max_managed_windows);
    std.debug.assert(tiling_mod.max_layouts >= max_displays * max_spaces_per_display);
}

pub const DisplayId = topology_mod.DisplayId;
pub const NativeSpaceId = topology_mod.NativeSpaceId;
pub const WorkspaceId = topology_mod.WorkspaceId;
pub const SpaceKey = topology_mod.SpaceKey;
pub const SpaceRef = topology_mod.SpaceRef;
pub const DisplayWorkspace = topology_mod.DisplayWorkspace;
pub const WorkspaceTopology = topology_mod.WorkspaceTopology;
pub const SpaceCatalog = topology_mod.SpaceCatalog;
pub const Space = topology_mod.Space;
pub const DisplayTopology = topology_mod.DisplayTopology;
pub const NativeTopology = topology_mod.NativeTopology;
pub const NativeTopologyInitialization = topology_mod.NativeTopologyInitialization;
pub const NativeDisplayObservation = topology_mod.NativeDisplayObservation;
pub const NativeTopologyObservation = topology_mod.NativeTopologyObservation;
pub const mapNativeTopology = topology_mod.mapNativeTopology;
pub const ManagedWindow = window_catalog_mod.ManagedWindow;
pub const WindowTabGroupObservation = window_catalog_mod.WindowTabGroupObservation;
pub const WindowTabGroupSnapshot = window_catalog_mod.WindowTabGroupSnapshot;
pub const WindowCatalog = window_catalog_mod.WindowCatalog;
pub const Epoch = u64;
pub const TimestampMs = u64;
pub const WindowId = window_mod.WindowId;

pub const FocusEventSource = enum {
    keyboard,
    drag,
    ax,
};

pub const FocusDirection = enum {
    left,
    right,
    up,
    down,
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
    at_ms: TimestampMs,
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

/// Logical workspace state derived from its current placement.
pub const WorkspaceSummary = struct {
    workspace_id: WorkspaceId,
    window_count: u32,
    is_active: bool,
    is_focused: bool,
};

/// Reducer-owned focus memory for one logical workspace.
pub const WorkspaceFocus = struct {
    focused_window_id: ?WindowId = null,
    history: [max_workspace_focus_history]WindowId = @splat(0),
    history_count: u8 = 0,

    pub fn record(self: *WorkspaceFocus, window_id: WindowId) void {
        self.removeFromHistory(window_id);
        if (self.history_count == self.history.len) self.dropHistoryAt(0);

        self.history[self.history_count] = window_id;
        self.history_count += 1;
        self.focused_window_id = window_id;
    }

    pub fn replaceWindowId(self: *WorkspaceFocus, old_window_id: WindowId, new_window_id: WindowId) void {
        for (self.history[0..self.history_count]) |*window_id| {
            if (window_id.* == old_window_id) window_id.* = new_window_id;
        }
        if (self.focused_window_id == old_window_id) self.focused_window_id = new_window_id;
    }

    fn removeFromHistory(self: *WorkspaceFocus, window_id: WindowId) void {
        for (self.history[0..self.history_count], 0..) |candidate, index| {
            if (candidate != window_id) continue;
            self.dropHistoryAt(index);
            return;
        }
    }

    fn dropHistoryAt(self: *WorkspaceFocus, index: usize) void {
        std.debug.assert(index < self.history_count);
        var cursor = index;
        while (cursor + 1 < self.history_count) : (cursor += 1) {
            self.history[cursor] = self.history[cursor + 1];
        }
        self.history_count -= 1;
        self.history[self.history_count] = 0;
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

    pub fn put(self: *PendingNativeWindowMoves, pending: PendingNativeWindowMove) bool {
        if (self.findIndex(pending.window_id)) |index| {
            self.entries[index] = pending;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = pending;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *PendingNativeWindowMoves, window_id: WindowId) ?PendingNativeWindowMove {
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

pub const PendingNativeWorkspaceMove = struct {
    source: SpaceRef,
    target: SpaceRef,
    epoch: Epoch,
    deadline_at_ms: TimestampMs,
    has_started: bool = false,
    is_rolling_back: bool = false,
};

pub const NativeWorkspaceMoveObservation = enum {
    confirmed,
    pending,
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

pub const DeferredWindowExpiryReason = enum {
    role_pending,
    off_screen,
    unsettled_bounds,
};

pub const WorkspaceSwitchEffect = struct {
    target: SpaceRef,
};

pub const FocusWindowEffect = struct {
    window_id: WindowId,
    process_id: i32,
};

pub const WindowSwapEffect = struct {
    first_window_id: WindowId,
    second_window_id: WindowId,
    direction: FocusDirection,
};

pub const WindowModeEffect = struct {
    window_id: WindowId,
    previous: window_mod.WindowMode,
    current: window_mod.WindowMode,
};

pub const FullscreenEffect = struct {
    leader_window_id: WindowId,
    window_id: WindowId,
    process_id: i32,
    is_fullscreen: bool,
    mode: window_mod.WindowMode,
    restore_frame: ?window_mod.Window.Frame,
};

pub const CenterWindowEffect = struct {
    leader_window_id: WindowId,
    window_id: WindowId,
    process_id: i32,
    current_frame: window_mod.Window.Frame,
    target_frame: window_mod.Window.Frame,
};

pub const WindowMoveRequest = struct {
    window_id: WindowId,
    target: SpaceRef,
    layout: ?LayoutInsertion = null,
    should_move_native: bool,
    should_follow_focus: bool = false,
};

pub const WindowMoveEffect = struct {
    window_id: WindowId,
    source: SpaceRef,
    target: SpaceRef,
    should_follow_focus: bool,
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

    pub fn clear(self: *PendingFocusQueue) void {
        self.count = 0;
    }

    pub fn insertOrReplace(self: *PendingFocusQueue, entry: PendingFocus) void {
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

    pub fn takeLatest(self: *PendingFocusQueue) ?PendingFocus {
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

    pub fn takeSequence(self: *PendingFocusQueue) u64 {
        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        return sequence;
    }
};

pub const WindowReadiness = enum {
    reject,
    ready,
    pending,
};

pub const WindowCandidate = struct {
    process_id: i32,
    window_id: WindowId,
    space_key: SpaceKey,
    attempts_remaining: u8,
};

pub const WindowCandidates = struct {
    entries: [max_pending_window_candidates]WindowCandidate = undefined,
    count: u16 = 0,

    pub fn items(self: *const WindowCandidates) []const WindowCandidate {
        return self.entries[0..self.count];
    }

    pub fn get(self: *const WindowCandidates, window_id: WindowId) ?WindowCandidate {
        const index = self.findIndex(window_id) orelse return null;
        return self.entries[index];
    }

    pub fn getPtr(self: *WindowCandidates, window_id: WindowId) ?*WindowCandidate {
        const index = self.findIndex(window_id) orelse return null;
        return &self.entries[index];
    }

    pub fn track(self: *WindowCandidates, candidate: WindowCandidate, should_reset_attempts: bool) bool {
        if (self.findIndex(candidate.window_id)) |index| {
            const attempts_remaining = self.entries[index].attempts_remaining;
            self.entries[index] = candidate;
            if (!should_reset_attempts) self.entries[index].attempts_remaining = attempts_remaining;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = candidate;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *WindowCandidates, window_id: WindowId) ?WindowCandidate {
        const index = self.findIndex(window_id) orelse return null;
        const removed = self.entries[index];
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return removed;
    }

    pub fn removeProcess(self: *WindowCandidates, process_id: i32) void {
        var index: usize = 0;
        while (index < self.count) {
            if (self.entries[index].process_id != process_id) {
                index += 1;
                continue;
            }
            _ = self.remove(self.entries[index].window_id);
        }
    }

    fn findIndex(self: *const WindowCandidates, window_id: WindowId) ?usize {
        for (self.items(), 0..) |candidate, index| {
            if (candidate.window_id == window_id) return index;
        }
        return null;
    }
};

pub const ProcessRetry = struct {
    process_id: i32,
    attempts_remaining: u8,
};

pub const ProcessRetries = struct {
    entries: [max_process_retries]ProcessRetry = undefined,
    count: u8 = 0,

    pub fn items(self: *const ProcessRetries) []const ProcessRetry {
        return self.entries[0..self.count];
    }

    pub fn get(self: *const ProcessRetries, process_id: i32) ?ProcessRetry {
        const index = self.findIndex(process_id) orelse return null;
        return self.entries[index];
    }

    pub fn getPtr(self: *ProcessRetries, process_id: i32) ?*ProcessRetry {
        const index = self.findIndex(process_id) orelse return null;
        return &self.entries[index];
    }

    pub fn track(self: *ProcessRetries, retry: ProcessRetry) bool {
        if (self.findIndex(retry.process_id)) |index| {
            self.entries[index] = retry;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = retry;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *ProcessRetries, process_id: i32) ?ProcessRetry {
        const index = self.findIndex(process_id) orelse return null;
        const removed = self.entries[index];
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return removed;
    }

    fn findIndex(self: *const ProcessRetries, process_id: i32) ?usize {
        for (self.items(), 0..) |retry, index| {
            if (retry.process_id == process_id) return index;
        }
        return null;
    }
};

pub const PointerDragState = struct {
    is_down: bool = false,
    candidate_window_id: ?WindowId = null,
    active_window_id: ?WindowId = null,
    should_reconcile_on_drop: bool = false,
};

pub const DragPreviewState = struct {
    source_window_id: ?WindowId = null,
    target_window_id: ?WindowId = null,
    is_visible: bool = false,
};

pub const PointerDragCompletion = struct {
    should_retile: bool,
    swapped_window_ids: ?struct {
        first: WindowId,
        second: WindowId,
    } = null,
};

pub const RetileRequest = struct {
    all_displays: bool = false,
    display_ids: [max_displays]DisplayId = @splat(0),
    display_count: u8 = 0,
};

pub const CleanupRequest = struct {
    process_ids: [max_cleanup_processes]i32 = @splat(0),
    process_count: u8 = 0,
    should_clean_offscreen: bool = false,
};

pub const LayoutSpaceFrame = struct {
    space_key: SpaceKey,
    root_frame: ?window_mod.Window.Frame,
};

pub const LayoutRebuild = struct {
    kind: tiling_mod.LayoutKind,
    split_mode: tiling_mod.SplitMode,
    insert_child: tiling_mod.InsertChild,
    insert_point: tiling_mod.InsertionPointPolicy,
    inner_gap: f64,
    split_ratio: f64,
    spaces: [tiling_mod.max_layouts]LayoutSpaceFrame = undefined,
    space_count: u8 = 0,

    /// Add one configured Space and its current content frame.
    pub fn addSpace(self: *LayoutRebuild, space_key: SpaceKey, root_frame: ?window_mod.Window.Frame) bool {
        if (self.space_count == self.spaces.len) return false;
        for (self.spaces[0..self.space_count]) |space| {
            if (space.space_key.eql(space_key)) return false;
        }
        self.spaces[self.space_count] = .{ .space_key = space_key, .root_frame = root_frame };
        self.space_count += 1;
        return true;
    }
};

pub const ObservationTimer = struct {
    epoch: Epoch,
    due_at_ms: TimestampMs,
};

pub const LayoutInsertion = struct {
    kind: tiling_mod.LayoutKind,
    options: tiling_mod.InsertOptions,
};

pub const WindowAdoption = struct {
    window_id: WindowId,
    process_id: i32,
    space_key: SpaceKey,
    frame: window_mod.Window.Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    is_fullscreen: bool = false,
    mode: window_mod.WindowMode = .tiled,
    float_frame: ?window_mod.Window.Frame = null,
    layout: ?LayoutInsertion = null,
    tab_group: ?WindowTabGroupObservation = null,

    pub fn managedWindow(self: WindowAdoption) ManagedWindow {
        return .{
            .window_id = self.window_id,
            .process_id = self.process_id,
            .space_key = self.space_key,
            .frame = self.frame,
            .is_fullscreen = self.is_fullscreen,
            .mode = self.mode,
            .float_frame = self.float_frame,
        };
    }
};

pub const WindowUpdate = struct {
    window: window_mod.Window,
    layout: ?LayoutInsertion = null,
};

pub const WindowSpaceAssignment = struct {
    window_id: WindowId,
    space_key: SpaceKey,
    layout: ?LayoutInsertion = null,
};

pub const WindowTabDetachment = struct {
    window_id: WindowId,
    layout: ?LayoutInsertion = null,
};

pub const Model = struct {
    spaces: SpaceCatalog = .{},
    windows: WindowCatalog = .{},
    geometry: geometry_mod = .{},
    layout: tiling_mod = .{},
    workspace_focus: [max_spaces_per_display]WorkspaceFocus = @splat(.{}),
    workspace_topology: WorkspaceTopology = .{},
    native_topology: NativeTopology = .{},
    pending_switch: ?PendingSwitch = null,
    queued_switch: ?SwitchRequest = null,
    observation_timer: ?ObservationTimer = null,
    workspace_transition: ?WorkspaceTransition = null,
    pending_native_window_moves: PendingNativeWindowMoves = .{},
    pending_native_workspace_move: ?PendingNativeWorkspaceMove = null,
    pending_focus: PendingFocusQueue = .{},
    deferred_follow_focus: ?DeferredFollowFocus = null,
    pending_role_windows: WindowCandidates = .{},
    deferred_window_candidates: WindowCandidates = .{},
    app_launch_retries: ProcessRetries = .{},
    focus_retries: ProcessRetries = .{},
    display_resettle_due_at_ms: ?TimestampMs = null,
    bsp_split_mode: tiling_mod.SplitMode = .auto,
    bsp_insert_point: tiling_mod.InsertionPointPolicy = .focused,
    pointer_drag: PointerDragState = .{},
    drag_preview: DragPreviewState = .{},
    retile_request: RetileRequest = .{},
    cleanup_request: CleanupRequest = .{},
    last_display_change_at_ms: ?TimestampMs = null,
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

    pub fn pendingNativeWorkspaceMove(self: *const Model) ?PendingNativeWorkspaceMove {
        return self.pending_native_workspace_move;
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

    pub fn hasPendingDiscovery(self: *const Model) bool {
        return self.pending_role_windows.count > 0 or
            self.deferred_window_candidates.count > 0 or
            self.app_launch_retries.count > 0 or
            self.focus_retries.count > 0;
    }

    pub fn hasDisplayResettleScheduled(self: *const Model) bool {
        return self.display_resettle_due_at_ms != null;
    }

    pub fn hasPendingRoleWindow(self: *const Model, window_id: WindowId) bool {
        return self.pending_role_windows.get(window_id) != null;
    }

    pub fn hasDeferredWindowCandidate(self: *const Model, window_id: WindowId) bool {
        return self.deferred_window_candidates.get(window_id) != null;
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

    pub fn logicalWorkspace(self: *const Model, workspace_id: WorkspaceId) ?SpaceRef {
        return self.spaces.findLogicalWorkspace(workspace_id);
    }

    pub fn space(self: *const Model, key: SpaceKey) ?SpaceRef {
        return self.spaces.find(key);
    }

    pub fn window(self: *const Model, window_id: WindowId) ?ManagedWindow {
        return self.windows.get(window_id);
    }

    /// Return an immutable value snapshot for platform and layout code.
    pub fn windowSnapshot(self: *const Model, window_id: WindowId) ?window_mod.Window {
        const managed_window = self.window(window_id) orelse return null;
        return managed_window.snapshot();
    }

    /// Resolve a managed window to the leader that owns its layout slot.
    pub fn windowTabLeader(self: *const Model, window_id: WindowId) WindowId {
        const managed_window = self.window(window_id) orelse return window_id;
        return managed_window.tab_leader_window_id;
    }

    /// Resolve a group member to the tab currently contributing pixels.
    pub fn windowTabActive(self: *const Model, window_id: WindowId) WindowId {
        const leader_window_id = self.windowTabLeader(window_id);
        for (self.windows.items()) |managed_window| {
            if (managed_window.tab_leader_window_id != leader_window_id) continue;
            if (!managed_window.is_suppressed) return managed_window.window_id;
        }
        return window_id;
    }

    /// Return whether a managed tab is hidden behind its active member.
    pub fn isWindowTabSuppressed(self: *const Model, window_id: WindowId) bool {
        const managed_window = self.window(window_id) orelse return false;
        return managed_window.is_suppressed;
    }

    /// Snapshot the reducer-owned group containing a managed window.
    pub fn windowTabGroup(self: *const Model, window_id: WindowId) ?WindowTabGroupSnapshot {
        const managed_window = self.window(window_id) orelse return null;
        var snapshot: WindowTabGroupSnapshot = .{
            .leader_window_id = managed_window.tab_leader_window_id,
            .active_window_id = 0,
            .process_id = managed_window.process_id,
        };
        for (self.windows.items()) |member| {
            if (member.tab_leader_window_id != snapshot.leader_window_id) continue;
            snapshot.member_window_ids[snapshot.member_count] = member.window_id;
            snapshot.member_count += 1;
            if (!member.is_suppressed) snapshot.active_window_id = member.window_id;
        }
        if (snapshot.member_count < 2) return null;
        std.debug.assert(snapshot.active_window_id != 0);
        return snapshot;
    }

    /// Return the leaders of every reducer-owned tab group.
    pub fn windowTabGroupLeaderIds(
        self: *const Model,
        window_ids: *[max_managed_windows]WindowId,
    ) []const WindowId {
        var count: usize = 0;
        for (self.windows.items()) |managed_window| {
            if (managed_window.tab_leader_window_id != managed_window.window_id) continue;
            var has_member = false;
            for (self.windows.items()) |candidate| {
                if (candidate.window_id == managed_window.window_id) continue;
                if (candidate.tab_leader_window_id != managed_window.window_id) continue;
                has_member = true;
                break;
            }
            if (!has_member) continue;
            window_ids[count] = managed_window.window_id;
            count += 1;
        }
        return window_ids[0..count];
    }

    /// Returns the most recently focused layout owner for a logical workspace.
    pub fn focusedWorkspaceWindow(self: *const Model, workspace_id: WorkspaceId) ?WindowId {
        if (workspace_id == 0 or workspace_id > self.workspace_focus.len) return null;
        return self.workspace_focus[workspace_id - 1].focused_window_id;
    }

    /// Returns the tab-group leaders that own workspace and layout slots.
    pub fn workspaceWindowIds(
        self: *const Model,
        space_key: SpaceKey,
        window_ids: *[max_managed_windows]WindowId,
    ) []const WindowId {
        var count: usize = 0;
        for (self.windows.items()) |managed_window| {
            if (!managed_window.space_key.eql(space_key)) continue;
            if (managed_window.tab_leader_window_id != managed_window.window_id) continue;

            window_ids[count] = managed_window.window_id;
            count += 1;
        }
        return window_ids[0..count];
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

    /// Project reducer state into one summary per configured workspace.
    pub fn workspaceSummaries(self: *const Model, workspace_count: u8) [max_spaces_per_display]WorkspaceSummary {
        std.debug.assert(workspace_count > 0 and workspace_count <= max_spaces_per_display);

        var summaries: [max_spaces_per_display]WorkspaceSummary = undefined;
        for (0..workspace_count) |index| {
            summaries[index] = .{
                .workspace_id = @intCast(index + 1),
                .window_count = 0,
                .is_active = false,
                .is_focused = false,
            };
        }

        for (self.windows.items()) |managed_window| {
            if (managed_window.is_suppressed) continue;
            const space_ref = self.space(managed_window.space_key) orelse continue;
            std.debug.assert(space_ref.workspace_id <= workspace_count);
            summaries[space_ref.workspace_id - 1].window_count += 1;
        }

        for (self.workspace_topology.displays[0..self.workspace_topology.display_count]) |display| {
            std.debug.assert(display.active_workspace_id <= workspace_count);
            const summary = &summaries[display.active_workspace_id - 1];
            summary.is_active = true;
            const is_focused_display = if (self.workspace_topology.focused_display_id) |focused_display_id|
                display.display_id == focused_display_id
            else
                false;
            summary.is_focused = summary.is_focused or is_focused_display;
        }
        return summaries;
    }
};

pub const Event = union(enum) {
    replace_space_catalog: SpaceCatalog,
    adopt_window: WindowAdoption,
    update_window: WindowUpdate,
    remove_window: WindowId,
    replace_window_id: struct {
        old_window_id: WindowId,
        new_window_id: WindowId,
    },
    assign_window_space: WindowSpaceAssignment,
    observe_window_tab_group: WindowTabGroupObservation,
    detach_window_tab: WindowTabDetachment,
    record_workspace_focus: struct {
        workspace_id: WorkspaceId,
        window_id: WindowId,
    },
    replace_workspace_topology: WorkspaceTopology,
    focus_display: DisplayId,
    activate_workspace: struct {
        display_id: DisplayId,
        workspace_id: WorkspaceId,
    },
    initialize_native_topology: NativeTopologyInitialization,
    request_native_switch: struct {
        target: SpaceRef,
        at_ms: TimestampMs,
    },
    request_workspace_switch: struct {
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
        layout: ?LayoutInsertion = null,
    },
    request_native_workspace_move: struct {
        source: SpaceRef,
        target: SpaceRef,
        at_ms: TimestampMs,
    },
    native_workspace_move_started: struct {
        epoch: Epoch,
        succeeded: bool,
        at_ms: TimestampMs,
    },
    native_workspace_move_observed: struct {
        epoch: Epoch,
        observation: NativeWorkspaceMoveObservation,
        at_ms: TimestampMs,
    },
    native_workspace_move_rollback_result: struct {
        epoch: Epoch,
        succeeded: bool,
    },
    window_focus_observed: WindowFocusObservation,
    request_pending_focus,
    follow_focus_observed: FollowFocusObservation,
    track_pending_role_window: WindowCandidate,
    untrack_pending_role_window: WindowId,
    pending_role_observed: struct {
        window_id: WindowId,
        readiness: WindowReadiness,
    },
    track_deferred_window_candidate: WindowCandidate,
    untrack_deferred_window_candidate: WindowId,
    deferred_window_observed: struct {
        window_id: WindowId,
        readiness: WindowReadiness,
        is_visible: bool,
    },
    deferred_window_promotion_failed: WindowId,
    untrack_window_candidates_for_process: i32,
    track_app_launch_retry: ProcessRetry,
    untrack_app_launch_retry: i32,
    app_launch_retry_timer_fired: i32,
    track_focus_retry: ProcessRetry,
    untrack_focus_retry: i32,
    focus_retry_observed: struct {
        process_id: i32,
        focused_window_id: WindowId,
    },
    display_changed: struct {
        at_ms: TimestampMs,
        resettle_at_ms: TimestampMs,
    },
    display_resettle_timer_fired: TimestampMs,
    configure_layout_interaction: struct {
        split_mode: tiling_mod.SplitMode,
        insert_point: tiling_mod.InsertionPointPolicy,
    },
    toggle_split_mode,
    set_insert_point: tiling_mod.InsertionPointPolicy,
    focus_direction: struct {
        window_id: WindowId,
        direction: FocusDirection,
    },
    swap_direction: struct {
        window_id: WindowId,
        direction: FocusDirection,
    },
    set_window_mode: struct {
        window_id: WindowId,
        mode: window_mod.WindowMode,
        layout: ?LayoutInsertion = null,
    },
    toggle_window_fullscreen: struct {
        window_id: WindowId,
        observed_frame: ?window_mod.Window.Frame,
    },
    center_floating_window: struct {
        window_id: WindowId,
        observed_frame: window_mod.Window.Frame,
        display_frame: window_mod.Window.Frame,
    },
    window_frame_command_result: struct {
        leader_window_id: WindowId,
        window_id: WindowId,
        target_frame: window_mod.Window.Frame,
        should_save_float_frame: bool,
        succeeded: bool,
    },
    request_window_move: WindowMoveRequest,
    pointer_down: ?WindowId,
    pointer_dragged,
    pointer_geometry_reconcile_requested: WindowId,
    drag_preview_observed: struct {
        source_window_id: WindowId,
        target_window_id: ?WindowId,
        target_frame: ?window_mod.Window.Frame,
    },
    clear_drag_preview,
    pointer_up,
    request_retile_all_displays,
    request_retile_display: DisplayId,
    flush_retile_requests,
    request_cleanup_process: i32,
    request_offscreen_cleanup,
    clear_cleanup_requests,
    flush_cleanup_requests,
    rebuild_layout: LayoutRebuild,
    layout_command: struct {
        event: tiling_mod.Event,
        display_id: DisplayId,
    },
    geometry: geometry_mod.Event,
    layout: tiling_mod.Event,
};

pub const SwitchFailureReason = enum {
    effect_failed,
    observation_unavailable,
    unexpected_space,
};

pub const WindowCatalogRejectionReason = enum {
    catalog_full,
    invalid_tab_group,
    invalid_window,
    window_exists,
    window_missing,
    space_missing,
    layout_missing,
};

pub const Effect = union(enum) {
    switch_native_space: struct {
        request: SwitchRequest,
        epoch: Epoch,
    },
    observe_native_topology: Epoch,
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
    workspace_switch_ready: WorkspaceSwitchEffect,
    window_catalog_rejected: struct {
        window_id: WindowId,
        reason: WindowCatalogRejectionReason,
    },
    workspace_transition_started: WorkspaceTransition,
    workspace_transition_settled: WorkspaceTransitionSettlement,
    move_native_window: PendingNativeWindowMove,
    retry_native_window_move: PendingNativeWindowMove,
    rollback_native_window_move: PendingNativeWindowMove,
    native_window_move_confirmed: PendingNativeWindowMove,
    native_window_move_cancelled: PendingNativeWindowMove,
    native_window_move_rolled_back: PendingNativeWindowMove,
    native_window_move_rollback_deferred: PendingNativeWindowMove,
    native_window_move_rejected: NativeWindowMoveRequest,
    move_native_workspace_contents: PendingNativeWorkspaceMove,
    rollback_native_workspace_contents: PendingNativeWorkspaceMove,
    native_workspace_move_completed: PendingNativeWorkspaceMove,
    native_workspace_move_failed: struct {
        move: PendingNativeWorkspaceMove,
        rollback_succeeded: bool,
    },
    native_workspace_move_rejected: struct {
        source: SpaceRef,
        target: SpaceRef,
    },
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
    pending_role_ready: WindowCandidate,
    pending_role_expired: WindowCandidate,
    deferred_window_ready: WindowCandidate,
    deferred_window_expired: struct {
        candidate: WindowCandidate,
        reason: DeferredWindowExpiryReason,
    },
    app_launch_retry_ready: i32,
    focus_retry_resolved: struct {
        process_id: i32,
        window_id: WindowId,
    },
    focus_retry_expired: i32,
    display_resettle_due,
    reconcile_displays,
    focus_window: FocusWindowEffect,
    windows_swapped: WindowSwapEffect,
    window_mode_changed: WindowModeEffect,
    fullscreen_changed: FullscreenEffect,
    center_window: CenterWindowEffect,
    window_moved: WindowMoveEffect,
    show_drag_preview: window_mod.Window.Frame,
    hide_drag_preview,
    pointer_drag_completed: PointerDragCompletion,
    retile_requested: RetileRequest,
    cleanup_requested: CleanupRequest,
    cleanup_request_overflow: i32,
    geometry: geometry_mod.Effect,
    layout: tiling_mod.Effect,
};

pub const max_effects = 6;

pub const Transition = struct {
    model: Model,
    effects: [max_effects]Effect = undefined,
    effect_count: u8 = 0,

    pub fn addEffect(self: *Transition, effect: Effect) void {
        std.debug.assert(self.effect_count < self.effects.len);
        self.effects[self.effect_count] = effect;
        self.effect_count += 1;
    }
};
