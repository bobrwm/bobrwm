//! Deterministic application state and transitions.

const std = @import("std");
const geometry_mod = @import("geometry.zig");
const space_mod = @import("space.zig");
const tiling_mod = @import("tiling.zig");
const window_mod = @import("window.zig");

pub const max_displays = 8;
pub const max_managed_windows = 1024;
pub const max_pending_focus_entries = 16;
pub const max_pending_window_candidates = 256;
pub const max_process_retries = 64;
pub const max_display_memory_entries = 16;
pub const max_cleanup_processes = 16;
pub const max_spaces_per_display = 10;
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

pub const DisplayId = space_mod.DisplayId;
pub const NativeSpaceId = space_mod.NativeSpaceId;
pub const WorkspaceId = space_mod.WorkspaceId;
pub const SpaceKey = space_mod.Key;
pub const SpaceRef = space_mod.Ref;
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

pub const DisplayWorkspace = struct {
    display_id: DisplayId,
    active_workspace_id: WorkspaceId,
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

    fn record(self: *WorkspaceFocus, window_id: WindowId) void {
        self.removeFromHistory(window_id);
        if (self.history_count == self.history.len) self.dropHistoryAt(0);

        self.history[self.history_count] = window_id;
        self.history_count += 1;
        self.focused_window_id = window_id;
    }

    fn replaceWindowId(self: *WorkspaceFocus, old_window_id: WindowId, new_window_id: WindowId) void {
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
        std.debug.assert(self.findLogicalWorkspace(space.workspace_id) == null);

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

    pub fn findLogicalWorkspace(self: *const SpaceCatalog, workspace_id: WorkspaceId) ?SpaceRef {
        for (self.spaces[0..self.space_count]) |space| {
            if (space.workspace_id == workspace_id) return space;
        }
        return null;
    }

    fn setDisplay(self: *SpaceCatalog, key: SpaceKey, display_id: DisplayId) bool {
        for (self.spaces[0..self.space_count]) |*space| {
            if (!space.key.eql(key)) continue;
            space.display_id = display_id;
            return true;
        }
        return false;
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
        for (topology.spaces[0..topology.space_count]) |space| {
            std.debug.assert(self.spaceForWorkspace(space.workspace_id) == null);
        }

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

    pub fn spaceForWorkspace(self: *const NativeTopology, workspace_id: WorkspaceId) ?SpaceRef {
        for (self.displays[0..self.display_count]) |display| {
            const space_id = display.spaceForWorkspace(workspace_id) orelse continue;
            return .{
                .key = .{ .native = space_id },
                .workspace_id = workspace_id,
                .display_id = display.display_id,
            };
        }
        return null;
    }

    fn swapWorkspacePlacements(self: *NativeTopology, source_key: SpaceKey, target_key: SpaceKey) bool {
        const source_id = switch (source_key) {
            .native => |space_id| space_id,
            .virtual => return false,
        };
        const target_id = switch (target_key) {
            .native => |space_id| space_id,
            .virtual => return false,
        };
        var source: ?*Space = null;
        var target: ?*Space = null;
        for (self.displays[0..self.display_count]) |*display| {
            for (display.spaces[0..display.space_count]) |*space| {
                if (space.id == source_id) source = space;
                if (space.id == target_id) target = space;
            }
        }
        if (source == null or target == null) return false;

        const workspace_id = source.?.workspace_id;
        source.?.workspace_id = target.?.workspace_id;
        target.?.workspace_id = workspace_id;
        return true;
    }

    pub fn eql(self: *const NativeTopology, other: *const NativeTopology) bool {
        if (self.display_count != other.display_count) return false;

        for (self.displays[0..self.display_count], other.displays[0..other.display_count]) |*left, *right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

pub const NativeTopologyInitialization = struct {
    topology: NativeTopology,
    focused_display_id: ?DisplayId = null,
};

pub const NativeDisplayObservation = struct {
    display_id: DisplayId,
    observed_space_id: NativeSpaceId,
    space_ids: [max_spaces_per_display]NativeSpaceId = @splat(0),
    space_count: u8 = 0,
};

pub const NativeTopologyObservation = struct {
    displays: [max_displays]NativeDisplayObservation = undefined,
    display_count: u8 = 0,

    pub fn addDisplay(self: *NativeTopologyObservation, display: NativeDisplayObservation) void {
        std.debug.assert(self.display_count < self.displays.len);
        self.displays[self.display_count] = display;
        self.display_count += 1;
    }
};

/// Assign global logical workspaces to an observed physical Space topology.
pub fn mapNativeTopology(
    observation: NativeTopologyObservation,
    previous: *const NativeTopology,
    workspace_topology: *const WorkspaceTopology,
    catalog: *const SpaceCatalog,
    workspace_count: u8,
) ?NativeTopology {
    if (workspace_count == 0 or observation.display_count > workspace_count) return null;

    var assignments: [max_displays][max_spaces_per_display]WorkspaceId = @splat(@splat(0));
    var claimed: [max_spaces_per_display + 1]bool = @splat(false);

    for (observation.displays[0..observation.display_count], 0..) |display, display_index| {
        const observed_index = std.mem.indexOfScalar(
            NativeSpaceId,
            display.space_ids[0..display.space_count],
            display.observed_space_id,
        ) orelse return null;
        var workspace_id = workspaceForNativeSpace(previous, display.observed_space_id) orelse
            workspace_topology.activeWorkspace(display.display_id) orelse 0;
        if (workspace_id == 0 or workspace_id > workspace_count or claimed[workspace_id]) {
            workspace_id = firstUnclaimedWorkspaceId(&claimed, workspace_count) orelse return null;
        }
        assignments[display_index][observed_index] = workspace_id;
        claimed[workspace_id] = true;
    }

    for (observation.displays[0..observation.display_count], 0..) |display, display_index| {
        for (display.space_ids[0..display.space_count], 0..) |space_id, space_index| {
            if (assignments[display_index][space_index] != 0) continue;
            const workspace_id = workspaceForNativeSpace(previous, space_id) orelse continue;
            if (workspace_id > workspace_count or claimed[workspace_id]) continue;
            assignments[display_index][space_index] = workspace_id;
            claimed[workspace_id] = true;
        }
    }

    for (observation.displays[0..observation.display_count], 0..) |display, display_index| {
        for (assignments[display_index][0..display.space_count]) |*workspace_id| {
            if (workspace_id.* != 0) continue;
            workspace_id.* = firstUnclaimedWorkspaceOnDisplayId(
                &claimed,
                workspace_count,
                catalog,
                display.display_id,
            ) orelse continue;
            claimed[workspace_id.*] = true;
        }
    }

    for (observation.displays[0..observation.display_count], 0..) |display, display_index| {
        for (assignments[display_index][0..display.space_count]) |*workspace_id| {
            if (workspace_id.* != 0) continue;
            workspace_id.* = firstUnclaimedWorkspaceId(&claimed, workspace_count) orelse continue;
            claimed[workspace_id.*] = true;
        }
    }

    if (firstUnclaimedWorkspaceId(&claimed, workspace_count) != null) return null;

    var topology: NativeTopology = .{};
    for (observation.displays[0..observation.display_count], 0..) |display, display_index| {
        var mapped = DisplayTopology.init(display.display_id, display.observed_space_id);
        for (display.space_ids[0..display.space_count], assignments[display_index][0..display.space_count]) |space_id, workspace_id| {
            if (workspace_id != 0) mapped.addSpace(.{ .id = space_id, .workspace_id = workspace_id });
        }
        topology.addDisplay(mapped);
    }
    return topology;
}

fn workspaceForNativeSpace(topology: *const NativeTopology, space_id: NativeSpaceId) ?WorkspaceId {
    for (topology.displays[0..topology.display_count]) |display| {
        const workspace_id = display.workspaceForSpace(space_id) orelse continue;
        return workspace_id;
    }
    return null;
}

fn firstUnclaimedWorkspaceId(
    claimed: *const [max_spaces_per_display + 1]bool,
    workspace_count: u8,
) ?WorkspaceId {
    var workspace_id: WorkspaceId = 1;
    while (workspace_id <= workspace_count) : (workspace_id += 1) {
        if (!claimed[workspace_id]) return workspace_id;
    }
    return null;
}

fn firstUnclaimedWorkspaceOnDisplayId(
    claimed: *const [max_spaces_per_display + 1]bool,
    workspace_count: u8,
    catalog: *const SpaceCatalog,
    display_id: DisplayId,
) ?WorkspaceId {
    var workspace_id: WorkspaceId = 1;
    while (workspace_id <= workspace_count) : (workspace_id += 1) {
        if (claimed[workspace_id]) continue;
        const space = catalog.findLogicalWorkspace(workspace_id) orelse continue;
        if (space.display_id == display_id) return workspace_id;
    }
    return null;
}

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

pub const WorkspaceParkEffect = struct {
    outgoing: SpaceRef,
    target: SpaceRef,
    did_time_out: bool = false,
};

pub const WorkspaceSwitchEffect = struct {
    target: SpaceRef,
    outgoing: ?SpaceRef = null,
};

pub const VirtualWorkspaceMoveEffect = struct {
    moving: SpaceRef,
    displaced: SpaceRef,
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
    process_id: i32,
    source: SpaceRef,
    target: SpaceRef,
    should_hide: bool,
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

    fn getPtr(self: *WindowCandidates, window_id: WindowId) ?*WindowCandidate {
        const index = self.findIndex(window_id) orelse return null;
        return &self.entries[index];
    }

    fn track(self: *WindowCandidates, candidate: WindowCandidate, should_reset_attempts: bool) bool {
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

    fn remove(self: *WindowCandidates, window_id: WindowId) ?WindowCandidate {
        const index = self.findIndex(window_id) orelse return null;
        const removed = self.entries[index];
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return removed;
    }

    fn removeProcess(self: *WindowCandidates, process_id: i32) void {
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

    fn getPtr(self: *ProcessRetries, process_id: i32) ?*ProcessRetry {
        const index = self.findIndex(process_id) orelse return null;
        return &self.entries[index];
    }

    fn track(self: *ProcessRetries, retry: ProcessRetry) bool {
        if (self.findIndex(retry.process_id)) |index| {
            self.entries[index] = retry;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = retry;
        self.count += 1;
        return true;
    }

    fn remove(self: *ProcessRetries, process_id: i32) ?ProcessRetry {
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

pub const PendingWorkspacePark = struct {
    outgoing: SpaceRef,
    target: SpaceRef,
    deadline_at_ms: TimestampMs,
};

pub const PendingWorkspaceParks = struct {
    entries: [max_displays]PendingWorkspacePark = undefined,
    count: u8 = 0,

    pub fn items(self: *const PendingWorkspaceParks) []const PendingWorkspacePark {
        return self.entries[0..self.count];
    }

    pub fn get(self: *const PendingWorkspaceParks, display_id: DisplayId) ?PendingWorkspacePark {
        const index = self.findIndex(display_id) orelse return null;
        return self.entries[index];
    }

    fn put(self: *PendingWorkspaceParks, pending: PendingWorkspacePark) bool {
        if (self.findIndex(pending.target.display_id)) |index| {
            self.entries[index] = pending;
            return true;
        }
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = pending;
        self.count += 1;
        return true;
    }

    fn remove(self: *PendingWorkspaceParks, display_id: DisplayId) ?PendingWorkspacePark {
        const index = self.findIndex(display_id) orelse return null;
        const removed = self.entries[index];
        self.count -= 1;
        self.entries[index] = self.entries[self.count];
        return removed;
    }

    fn findIndex(self: *const PendingWorkspaceParks, display_id: DisplayId) ?usize {
        for (self.items(), 0..) |pending, index| {
            if (pending.target.display_id == display_id) return index;
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

pub const DisplayMemoryEntry = struct {
    uuid: [16]u8,
    active_workspace_id: WorkspaceId,
};

pub const DisplayIdentity = struct {
    display_id: DisplayId,
    uuid: ?[16]u8,
};

pub const WorkspaceInitialization = struct {
    display_ids: [max_displays]DisplayId = @splat(0),
    display_count: u8 = 0,
    workspace_count: WorkspaceId,
    primary_display_id: DisplayId,

    pub fn addDisplay(self: *WorkspaceInitialization, display_id: DisplayId) bool {
        if (display_id == 0 or self.display_count == self.display_ids.len) return false;
        for (self.display_ids[0..self.display_count]) |existing| {
            if (existing == display_id) return false;
        }
        self.display_ids[self.display_count] = display_id;
        self.display_count += 1;
        return true;
    }
};

pub const VirtualDisplayObservation = struct {
    displays: [max_displays]DisplayIdentity = undefined,
    display_count: u8 = 0,
    primary_display_id: DisplayId,
    focused_display_id: DisplayId,
    workspace_home_uuids: [max_spaces_per_display]?[16]u8 = @splat(null),

    pub fn addDisplay(self: *VirtualDisplayObservation, display: DisplayIdentity) bool {
        if (display.display_id == 0 or self.display_count == self.displays.len) return false;
        for (self.displays[0..self.display_count]) |existing| {
            if (existing.display_id == display.display_id) return false;
        }
        self.displays[self.display_count] = display;
        self.display_count += 1;
        return true;
    }
};

pub const DisplayMemory = struct {
    entries: [max_display_memory_entries]DisplayMemoryEntry = undefined,
    count: u8 = 0,

    pub fn get(self: *const DisplayMemory, uuid: [16]u8) ?DisplayMemoryEntry {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, &entry.uuid, &uuid)) return entry;
        }
        return null;
    }

    fn remember(self: *DisplayMemory, entry: DisplayMemoryEntry) void {
        for (self.entries[0..self.count]) |*existing| {
            if (!std.mem.eql(u8, &existing.uuid, &entry.uuid)) continue;
            existing.* = entry;
            return;
        }
        if (self.count == self.entries.len) {
            std.mem.copyForwards(
                DisplayMemoryEntry,
                self.entries[0 .. self.entries.len - 1],
                self.entries[1..],
            );
            self.count -= 1;
        }
        self.entries[self.count] = entry;
        self.count += 1;
    }
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

pub const ManagedWindow = struct {
    window_id: WindowId,
    process_id: i32,
    space_key: SpaceKey,
    tab_leader_window_id: WindowId = 0,
    is_suppressed: bool = false,
    frame: window_mod.Window.Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    is_fullscreen: bool = false,
    mode: window_mod.WindowMode = .tiled,
    float_frame: ?window_mod.Window.Frame = null,

    /// Project reducer state into the value consumed by platform adapters.
    pub fn snapshot(self: ManagedWindow) window_mod.Window {
        return .{
            .wid = self.window_id,
            .pid = self.process_id,
            .frame = self.frame,
            .is_fullscreen = self.is_fullscreen,
            .mode = self.mode,
            .float_frame = self.float_frame,
        };
    }
};

pub const WindowTabGroupObservation = struct {
    leader_window_id: WindowId,
    active_window_id: WindowId,
    member_window_ids: [max_managed_windows]WindowId = undefined,
    member_count: u16 = 0,

    pub fn addMember(self: *WindowTabGroupObservation, window_id: WindowId) bool {
        if (window_id == 0 or self.member_count == self.member_window_ids.len) return false;
        for (self.members()) |existing| {
            if (existing == window_id) return false;
        }

        self.member_window_ids[self.member_count] = window_id;
        self.member_count += 1;
        return true;
    }

    pub fn members(self: *const WindowTabGroupObservation) []const WindowId {
        return self.member_window_ids[0..self.member_count];
    }

    fn contains(self: *const WindowTabGroupObservation, window_id: WindowId) bool {
        for (self.members()) |member_window_id| {
            if (member_window_id == window_id) return true;
        }
        return false;
    }
};

pub const WindowTabGroupSnapshot = struct {
    leader_window_id: WindowId,
    active_window_id: WindowId,
    process_id: i32,
    member_window_ids: [max_managed_windows]WindowId = undefined,
    member_count: u16 = 0,

    /// Return the group members in deterministic catalog order.
    pub fn members(self: *const WindowTabGroupSnapshot) []const WindowId {
        return self.member_window_ids[0..self.member_count];
    }
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
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = entry;
        self.count += 1;
        return true;
    }

    fn remove(self: *WindowCatalog, window_id: WindowId) bool {
        _ = self.findIndex(window_id) orelse return false;
        _ = self.detachTab(window_id);

        const index = self.findIndex(window_id).?;
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1) {
            self.entries[cursor] = self.entries[cursor + 1];
        }
        self.count -= 1;

        return true;
    }

    fn detachTab(self: *WindowCatalog, window_id: WindowId) bool {
        const index = self.findIndex(window_id) orelse return false;
        const leader_window_id = self.entries[index].tab_leader_window_id;

        var member_count: u16 = 0;
        for (self.items()) |entry| {
            if (entry.tab_leader_window_id == leader_window_id) member_count += 1;
        }
        if (member_count < 2) return true;

        self.entries[index].tab_leader_window_id = window_id;
        self.entries[index].is_suppressed = false;

        if (member_count == 2) {
            self.dissolveTabGroupByLeader(leader_window_id);
            return true;
        }

        var next_leader_window_id = leader_window_id;
        if (window_id == leader_window_id) {
            for (self.items()) |entry| {
                if (entry.window_id == window_id) continue;
                if (entry.tab_leader_window_id != leader_window_id) continue;
                next_leader_window_id = entry.window_id;
                break;
            }
        }

        var active_window_id: ?WindowId = null;
        for (self.items()) |entry| {
            if (entry.window_id == window_id) continue;
            if (entry.tab_leader_window_id != leader_window_id) continue;
            if (!entry.is_suppressed) active_window_id = entry.window_id;
        }
        if (active_window_id == null) active_window_id = next_leader_window_id;

        for (self.entries[0..self.count]) |*entry| {
            if (entry.window_id == window_id) continue;
            if (entry.tab_leader_window_id != leader_window_id) continue;
            entry.tab_leader_window_id = next_leader_window_id;
            entry.is_suppressed = entry.window_id != active_window_id.?;
        }
        return true;
    }

    fn assignSpace(self: *WindowCatalog, window_id: WindowId, space_key: SpaceKey) bool {
        const index = self.findIndex(window_id) orelse return false;
        const leader_window_id = self.entries[index].tab_leader_window_id;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.tab_leader_window_id == leader_window_id) entry.space_key = space_key;
        }
        return true;
    }

    fn update(self: *WindowCatalog, window: window_mod.Window) bool {
        const index = self.findIndex(window.wid) orelse return false;
        const entry = &self.entries[index];
        if (entry.process_id != window.pid) return false;
        entry.frame = window.frame;
        entry.is_fullscreen = window.is_fullscreen;
        entry.mode = window.mode;
        entry.float_frame = window.float_frame;
        return true;
    }

    fn swapSpaceKeys(self: *WindowCatalog, source_key: SpaceKey, target_key: SpaceKey) void {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.space_key.eql(source_key)) {
                entry.space_key = target_key;
            } else if (entry.space_key.eql(target_key)) {
                entry.space_key = source_key;
            }
        }
    }

    fn replaceId(self: *WindowCatalog, old_window_id: WindowId, new_window_id: WindowId) bool {
        const index = self.findIndex(old_window_id) orelse return false;
        self.entries[index].window_id = new_window_id;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.tab_leader_window_id == old_window_id) entry.tab_leader_window_id = new_window_id;
        }
        return true;
    }

    fn observeTabGroup(self: *WindowCatalog, observation: WindowTabGroupObservation) void {
        self.dissolveTabGroupByLeader(observation.leader_window_id);
        for (observation.members()) |window_id| {
            const index = self.findIndex(window_id).?;
            self.entries[index].tab_leader_window_id = observation.leader_window_id;
            self.entries[index].is_suppressed = window_id != observation.active_window_id;
        }
    }

    fn dissolveTabGroupByLeader(self: *WindowCatalog, leader_window_id: WindowId) void {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.tab_leader_window_id != leader_window_id) continue;
            entry.tab_leader_window_id = entry.window_id;
            entry.is_suppressed = false;
        }
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

    fn managedWindow(self: WindowAdoption) ManagedWindow {
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
    pending_workspace_parks: PendingWorkspaceParks = .{},
    display_resettle_due_at_ms: ?TimestampMs = null,
    bsp_split_mode: tiling_mod.SplitMode = .auto,
    bsp_insert_point: tiling_mod.InsertionPointPolicy = .focused,
    pointer_drag: PointerDragState = .{},
    drag_preview: DragPreviewState = .{},
    display_memory: DisplayMemory = .{},
    retile_request: RetileRequest = .{},
    cleanup_request: CleanupRequest = .{},
    last_display_change_at_ms: ?TimestampMs = null,
    next_epoch: Epoch = 1,

    pub fn rememberedDisplayWorkspace(self: *const Model, uuid: [16]u8) ?WorkspaceId {
        return if (self.display_memory.get(uuid)) |entry| entry.active_workspace_id else null;
    }

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

    pub fn hasPendingWorkspaceParks(self: *const Model) bool {
        return self.pending_workspace_parks.count > 0;
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
    initialize_workspaces: WorkspaceInitialization,
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
    request_virtual_workspace_move: struct {
        source_display_id: DisplayId,
        target_display_id: DisplayId,
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
    workspace_reveal_observed: struct {
        outgoing: SpaceRef,
        target: SpaceRef,
        is_revealed: bool,
        deadline_at_ms: TimestampMs,
    },
    workspace_park_timer_fired: struct {
        display_id: DisplayId,
        is_revealed: bool,
        at_ms: TimestampMs,
    },
    clear_workspace_parks,
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
    remember_display_workspace: DisplayMemoryEntry,
    virtual_displays_observed: VirtualDisplayObservation,
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
    virtual_workspace_move_ready: VirtualWorkspaceMoveEffect,
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
    park_workspace: WorkspaceParkEffect,
    display_resettle_due,
    reconcile_displays,
    virtual_displays_reconciled,
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

    fn addEffect(self: *Transition, effect: Effect) void {
        std.debug.assert(self.effect_count < self.effects.len);
        self.effects[self.effect_count] = effect;
        self.effect_count += 1;
    }
};

pub fn reduce(model: Model, event: Event) Transition {
    var transition: Transition = .{ .model = model };
    var should_refresh_workspace_focus = false;

    switch (event) {
        .initialize_workspaces => |initialization| reduceWorkspaceInitialization(&transition, initialization),
        .replace_space_catalog => |catalog| {
            transition.model.spaces = catalog;
            pruneWindowCandidates(&transition.model.pending_role_windows, &catalog);
            pruneWindowCandidates(&transition.model.deferred_window_candidates, &catalog);
            refreshPendingWorkspaceParks(&transition.model.pending_workspace_parks, &catalog);
            refreshWorkspaceTransition(&transition);
            refreshPendingNativeWindowMoves(&transition.model);
            should_refresh_workspace_focus = true;
        },
        .adopt_window => |adoption| reduceWindowAdopted(&transition, adoption),
        .update_window => |update| reduceWindowUpdated(&transition, update),
        .remove_window => |window_id| {
            reduceWindowRemoved(&transition, window_id);
            should_refresh_workspace_focus = true;
        },
        .replace_window_id => |replacement| reduceWindowIdReplaced(&transition, replacement),
        .assign_window_space => |assignment| {
            reduceWindowSpaceAssigned(&transition, assignment);
            should_refresh_workspace_focus = true;
        },
        .observe_window_tab_group => |observation| {
            reduceWindowTabGroupObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
        .detach_window_tab => |detachment| {
            reduceWindowTabDetached(&transition, detachment);
            should_refresh_workspace_focus = true;
        },
        .record_workspace_focus => |focus| reduceWorkspaceFocusRecorded(&transition, focus),
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
            transition.model.pending_workspace_parks.count = 0;
            if (workspace_transition) |current| {
                finalizeWorkspaceTransition(&transition, current, .topology_reinitialized);
            } else {
                transition.model.pending_focus.clear();
                transition.model.deferred_follow_focus = null;
            }
            syncNativeWorkspaceTopology(&transition);
            if (initialization.focused_display_id) |display_id| {
                if (transition.model.workspace_topology.findDisplay(display_id) != null) {
                    transition.model.workspace_topology.focused_display_id = display_id;
                }
            }
            should_refresh_workspace_focus = true;
        },
        .request_workspace_switch => |request| reduceWorkspaceSwitchRequest(&transition, request),
        .request_virtual_workspace_move => |request| reduceVirtualWorkspaceMoveRequest(&transition, request),
        .request_native_switch => |request| reduceSwitchRequest(&transition, request),
        .native_space_changed => |at_ms| reduceSpaceChanged(&transition, at_ms),
        .observation_timer_fired => |timer| reduceObservationTimer(&transition, timer),
        .native_topology_observed => |observation| {
            reduceTopologyObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
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
        .request_native_workspace_move => |request| reduceNativeWorkspaceMoveRequest(&transition, request),
        .native_workspace_move_started => |result| reduceNativeWorkspaceMoveStarted(&transition, result),
        .native_workspace_move_observed => |observation| {
            reduceNativeWorkspaceMoveObserved(&transition, observation);
            should_refresh_workspace_focus = true;
        },
        .native_workspace_move_rollback_result => |result| reduceNativeWorkspaceMoveRollbackResult(&transition, result),
        .window_focus_observed => |observation| reduceWindowFocusObserved(&transition, observation),
        .request_pending_focus => reducePendingFocusRequest(&transition),
        .follow_focus_observed => |observation| reduceFollowFocusObserved(&transition, observation),
        .track_pending_role_window => |candidate| reducePendingRoleTracked(&transition, candidate),
        .untrack_pending_role_window => |window_id| {
            _ = transition.model.pending_role_windows.remove(window_id);
        },
        .pending_role_observed => |observation| reducePendingRoleObserved(&transition, observation),
        .track_deferred_window_candidate => |candidate| reduceDeferredWindowTracked(&transition, candidate),
        .untrack_deferred_window_candidate => |window_id| {
            _ = transition.model.deferred_window_candidates.remove(window_id);
        },
        .deferred_window_observed => |observation| reduceDeferredWindowObserved(&transition, observation),
        .deferred_window_promotion_failed => |window_id| reduceDeferredWindowPromotionFailed(&transition, window_id),
        .untrack_window_candidates_for_process => |process_id| {
            transition.model.pending_role_windows.removeProcess(process_id);
            transition.model.deferred_window_candidates.removeProcess(process_id);
        },
        .track_app_launch_retry => |retry| reduceProcessRetryTracked(&transition.model.app_launch_retries, retry),
        .untrack_app_launch_retry => |process_id| {
            _ = transition.model.app_launch_retries.remove(process_id);
        },
        .app_launch_retry_timer_fired => |process_id| reduceAppLaunchRetryTimer(&transition, process_id),
        .track_focus_retry => |retry| reduceProcessRetryTracked(&transition.model.focus_retries, retry),
        .untrack_focus_retry => |process_id| {
            _ = transition.model.focus_retries.remove(process_id);
        },
        .focus_retry_observed => |observation| reduceFocusRetryObserved(&transition, observation),
        .workspace_reveal_observed => |observation| reduceWorkspaceRevealObserved(&transition, observation),
        .workspace_park_timer_fired => |timer| reduceWorkspaceParkTimer(&transition, timer),
        .clear_workspace_parks => transition.model.pending_workspace_parks.count = 0,
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
        .display_resettle_timer_fired => |at_ms| reduceDisplayResettleTimer(&transition, at_ms),
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
        .focus_direction => |command| reduceFocusDirection(&transition, command),
        .swap_direction => |command| reduceSwapDirection(&transition, command),
        .set_window_mode => |command| reduceWindowModeCommand(&transition, command),
        .toggle_window_fullscreen => |command| reduceFullscreenCommand(&transition, command),
        .center_floating_window => |command| reduceCenterWindowCommand(&transition, command),
        .window_frame_command_result => |result| reduceWindowFrameCommandResult(&transition, result),
        .request_window_move => |request| reduceWindowMoveRequest(&transition, request),
        .pointer_down => |candidate_window_id| reducePointerDown(&transition, candidate_window_id),
        .pointer_dragged => reducePointerDragged(&transition),
        .pointer_geometry_reconcile_requested => |window_id| {
            if (transition.model.pointer_drag.active_window_id == window_id) {
                transition.model.pointer_drag.should_reconcile_on_drop = true;
            }
        },
        .drag_preview_observed => |observation| reduceDragPreviewObserved(&transition, observation),
        .clear_drag_preview => clearDragPreview(&transition),
        .pointer_up => reducePointerUp(&transition),
        .remember_display_workspace => |entry| {
            if (entry.active_workspace_id != 0) transition.model.display_memory.remember(entry);
        },
        .virtual_displays_observed => |observation| reduceVirtualDisplaysObserved(&transition, observation),
        .request_retile_all_displays => {
            transition.model.retile_request.all_displays = true;
            transition.model.retile_request.display_count = 0;
        },
        .request_retile_display => |display_id| reduceRetileDisplayRequested(&transition.model, display_id),
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
        .rebuild_layout => |rebuild| reduceLayoutRebuild(&transition, rebuild),
        .layout_command => |command| {
            if (applyLayoutEvent(&transition, command.event)) {
                reduceRetileDisplayRequested(&transition.model, command.display_id);
            }
        },
        .geometry => |geometry_event| {
            const geometry_transition = geometry_mod.reduce(transition.model.geometry, geometry_event);
            transition.model.geometry = geometry_transition.state;
            if (geometry_transition.effect) |effect| transition.addEffect(.{ .geometry = effect });
        },
        .layout => |layout_event| {
            _ = applyLayoutEvent(&transition, layout_event);
        },
    }

    if (should_refresh_workspace_focus) refreshWorkspaceFocus(&transition.model);
    assertModel(&transition.model);
    return transition;
}

fn reduceWorkspaceInitialization(transition: *Transition, initialization: WorkspaceInitialization) void {
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

fn reduceWindowAdopted(transition: *Transition, adoption: WindowAdoption) void {
    const original_model = transition.model;
    const window = adoption.managedWindow();
    if (window.window_id == 0 or window.process_id <= 0) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .invalid_window,
        } });
        return;
    }
    if (transition.model.window(window.window_id) != null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .window_exists,
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
    if (transition.model.windows.count == transition.model.windows.entries.len) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .catalog_full,
        } });
        return;
    }
    if (adoption.layout) |layout| {
        if (window.mode != .tiled) {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = window.window_id,
                .reason = .invalid_window,
            } });
            return;
        }
        if (!applyLayoutEvent(transition, .{ .insert = .{
            .space_key = window.space_key,
            .kind = layout.kind,
            .window_id = window.window_id,
            .options = layout.options,
        } })) return;
    }

    var adopted = window;
    adopted.tab_leader_window_id = adopted.window_id;
    adopted.is_suppressed = false;
    std.debug.assert(transition.model.windows.put(adopted));
    transition.model.geometry.seedObserved(adopted.window_id, adopted.frame) catch unreachable;

    if (adoption.tab_group) |observation| {
        const effect_count = transition.effect_count;
        reduceWindowTabGroupObserved(transition, observation);
        if (transition.effect_count != effect_count) {
            transition.model = original_model;
            return;
        }
    }

    _ = transition.model.pending_role_windows.remove(adopted.window_id);
    _ = transition.model.deferred_window_candidates.remove(adopted.window_id);
}

fn reduceWindowUpdated(transition: *Transition, update: WindowUpdate) void {
    const window = update.window;
    const previous = transition.model.window(window.wid) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.wid,
            .reason = .window_missing,
        } });
        return;
    };
    if (previous.process_id != window.pid) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.wid,
            .reason = .invalid_window,
        } });
        return;
    }

    const is_layout_owner = previous.tab_leader_window_id == previous.window_id;
    if (is_layout_owner and previous.mode != window.mode) {
        if (window.mode == .tiled) {
            const layout = update.layout orelse {
                transition.addEffect(.{ .window_catalog_rejected = .{
                    .window_id = window.wid,
                    .reason = .layout_missing,
                } });
                return;
            };
            if (!applyLayoutEvent(transition, .{ .insert = .{
                .space_key = previous.space_key,
                .kind = layout.kind,
                .window_id = window.wid,
                .options = layout.options,
            } })) return;
        } else {
            _ = applyLayoutEvent(transition, .{ .remove = .{
                .space_key = previous.space_key,
                .window_id = window.wid,
            } });
        }
    }

    std.debug.assert(transition.model.windows.update(window));
}

fn reduceWindowRemoved(transition: *Transition, window_id: WindowId) void {
    const window = transition.model.window(window_id) orelse return;
    const group = transition.model.windowTabGroup(window_id);
    const owned_layout = window.tab_leader_window_id == window_id and
        transition.model.layout.contains(window.space_key, window_id);

    removeWindowFromPointerState(transition, window_id);
    _ = transition.model.pending_native_window_moves.remove(window_id);
    std.debug.assert(transition.model.windows.remove(window_id));
    transition.model.geometry.forget(window_id);
    if (!owned_layout) return;

    const successor_window_id: ?WindowId = if (group) |snapshot| blk: {
        for (snapshot.members()) |member_window_id| {
            if (member_window_id == window_id) continue;
            break :blk transition.model.windowTabLeader(member_window_id);
        }
        break :blk null;
    } else null;
    if (successor_window_id) |successor| {
        _ = applyLayoutEvent(transition, .{ .replace_window_id = .{
            .space_key = window.space_key,
            .old_window_id = window_id,
            .new_window_id = successor,
        } });
        return;
    }

    _ = applyLayoutEvent(transition, .{ .remove = .{
        .space_key = window.space_key,
        .window_id = window_id,
    } });
}

fn reduceWindowIdReplaced(
    transition: *Transition,
    replacement: @FieldType(Event, "replace_window_id"),
) void {
    if (replacement.new_window_id == 0) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.new_window_id,
            .reason = .invalid_window,
        } });
        return;
    }
    if (transition.model.window(replacement.new_window_id) != null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.new_window_id,
            .reason = .window_exists,
        } });
        return;
    }
    const previous = transition.model.window(replacement.old_window_id) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.old_window_id,
            .reason = .window_missing,
        } });
        return;
    };
    if (transition.model.layout.contains(previous.space_key, replacement.old_window_id)) {
        _ = applyLayoutEvent(transition, .{ .replace_window_id = .{
            .space_key = previous.space_key,
            .old_window_id = replacement.old_window_id,
            .new_window_id = replacement.new_window_id,
        } });
    }

    std.debug.assert(transition.model.windows.replaceId(replacement.old_window_id, replacement.new_window_id));
    transition.model.geometry.replaceWindowId(replacement.old_window_id, replacement.new_window_id);
    if (transition.model.pending_native_window_moves.remove(replacement.old_window_id)) |pending| {
        var updated = pending;
        updated.window_id = replacement.new_window_id;
        std.debug.assert(transition.model.pending_native_window_moves.put(updated));
    }
    replacePointerWindowId(&transition.model, replacement.old_window_id, replacement.new_window_id);
    _ = transition.model.pending_role_windows.remove(replacement.new_window_id);
    _ = transition.model.deferred_window_candidates.remove(replacement.new_window_id);
    for (&transition.model.workspace_focus) |*focus| {
        focus.replaceWindowId(replacement.old_window_id, replacement.new_window_id);
    }
}

fn removeWindowFromPointerState(transition: *Transition, window_id: WindowId) void {
    if (transition.model.pointer_drag.candidate_window_id == window_id) {
        transition.model.pointer_drag.candidate_window_id = null;
    }
    if (transition.model.pointer_drag.active_window_id == window_id) {
        transition.model.pointer_drag.active_window_id = null;
        transition.model.pointer_drag.should_reconcile_on_drop = false;
    }
    if (transition.model.drag_preview.source_window_id == window_id or
        transition.model.drag_preview.target_window_id == window_id)
    {
        clearDragPreview(transition);
    }
}

fn replacePointerWindowId(model: *Model, old_window_id: WindowId, new_window_id: WindowId) void {
    if (model.pointer_drag.candidate_window_id == old_window_id) {
        model.pointer_drag.candidate_window_id = new_window_id;
    }
    if (model.pointer_drag.active_window_id == old_window_id) {
        model.pointer_drag.active_window_id = new_window_id;
    }
    if (model.drag_preview.source_window_id == old_window_id) {
        model.drag_preview.source_window_id = new_window_id;
    }
    if (model.drag_preview.target_window_id == old_window_id) {
        model.drag_preview.target_window_id = new_window_id;
    }
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
    const window = transition.model.window(assignment.window_id) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = assignment.window_id,
            .reason = .window_missing,
        } });
        return;
    };
    const leader = transition.model.window(window.tab_leader_window_id).?;
    if (leader.space_key.eql(assignment.space_key)) return;

    if (transition.model.layout.contains(leader.space_key, leader.window_id)) {
        const layout = assignment.layout orelse {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = assignment.window_id,
                .reason = .layout_missing,
            } });
            return;
        };
        if (!applyLayoutEvent(transition, .{ .move_window = .{
            .source_key = leader.space_key,
            .target_key = assignment.space_key,
            .kind = layout.kind,
            .window_id = leader.window_id,
            .options = layout.options,
        } })) return;
    }

    std.debug.assert(transition.model.windows.assignSpace(assignment.window_id, assignment.space_key));
}

fn applyLayoutEvent(transition: *Transition, event: tiling_mod.Event) bool {
    const layout_transition = tiling_mod.reduce(transition.model.layout, event);
    transition.model.layout = layout_transition.model;
    if (layout_transition.effect) |effect| {
        transition.addEffect(.{ .layout = effect });
        return false;
    }
    return true;
}

fn reduceWindowTabGroupObserved(
    transition: *Transition,
    observation: WindowTabGroupObservation,
) void {
    if (observation.member_count > observation.member_window_ids.len) {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    }
    const leader = transition.model.window(observation.leader_window_id) orelse {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    };
    if (observation.member_count < 2 or
        !observation.contains(observation.leader_window_id) or
        !observation.contains(observation.active_window_id))
    {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    }
    for (observation.members(), 0..) |window_id, index| {
        for (observation.members()[0..index]) |prior_window_id| {
            if (prior_window_id != window_id) continue;
            rejectWindowTabGroup(transition, window_id);
            return;
        }
        const member = transition.model.window(window_id) orelse {
            rejectWindowTabGroup(transition, window_id);
            return;
        };
        if (member.process_id != leader.process_id or
            (member.tab_leader_window_id != member.window_id and
                member.tab_leader_window_id != observation.leader_window_id))
        {
            rejectWindowTabGroup(transition, window_id);
            return;
        }
    }

    for (observation.members()) |window_id| {
        if (window_id == observation.leader_window_id) continue;
        const member = transition.model.window(window_id).?;
        if (!transition.model.layout.contains(member.space_key, window_id)) continue;
        _ = applyLayoutEvent(transition, .{ .remove = .{
            .space_key = member.space_key,
            .window_id = window_id,
        } });
    }
    for (observation.members()) |window_id| {
        std.debug.assert(transition.model.windows.assignSpace(window_id, leader.space_key));
    }
    transition.model.windows.observeTabGroup(observation);
}

fn reduceWindowTabDetached(transition: *Transition, detachment: WindowTabDetachment) void {
    const window = transition.model.window(detachment.window_id) orelse {
        rejectWindowTabGroup(transition, detachment.window_id);
        return;
    };
    const group = transition.model.windowTabGroup(detachment.window_id) orelse return;
    if (window.mode == .tiled and
        transition.model.layout.contains(window.space_key, group.leader_window_id))
    {
        const layout = detachment.layout orelse {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = detachment.window_id,
                .reason = .layout_missing,
            } });
            return;
        };

        const original_layout = transition.model.layout;
        const is_leader = group.leader_window_id == detachment.window_id;
        const inserted_window_id = if (is_leader and group.member_count == 2)
            firstOtherGroupMember(&group, detachment.window_id).?
        else
            detachment.window_id;
        var options = layout.options;
        if (is_leader and group.member_count > 2) {
            const successor = firstOtherGroupMember(&group, detachment.window_id).?;
            if (options.anchor_wid == detachment.window_id) options.anchor_wid = successor;
            _ = applyLayoutEvent(transition, .{ .replace_window_id = .{
                .space_key = window.space_key,
                .old_window_id = detachment.window_id,
                .new_window_id = successor,
            } });
        }
        if (!applyLayoutEvent(transition, .{ .insert = .{
            .space_key = window.space_key,
            .kind = layout.kind,
            .window_id = inserted_window_id,
            .options = options,
        } })) {
            transition.model.layout = original_layout;
            return;
        }
    }

    std.debug.assert(transition.model.windows.detachTab(detachment.window_id));
}

fn firstOtherGroupMember(group: *const WindowTabGroupSnapshot, window_id: WindowId) ?WindowId {
    for (group.members()) |member_window_id| {
        if (member_window_id != window_id) return member_window_id;
    }
    return null;
}

fn reduceWorkspaceFocusRecorded(
    transition: *Transition,
    focus: @FieldType(Event, "record_workspace_focus"),
) void {
    const space = transition.model.logicalWorkspace(focus.workspace_id) orelse return;
    const window = transition.model.window(focus.window_id) orelse return;
    const leader = transition.model.window(window.tab_leader_window_id).?;
    if (!leader.space_key.eql(space.key)) return;

    transition.model.workspace_focus[focus.workspace_id - 1].record(leader.window_id);
}

fn rejectWindowTabGroup(transition: *Transition, window_id: WindowId) void {
    transition.addEffect(.{ .window_catalog_rejected = .{
        .window_id = window_id,
        .reason = .invalid_tab_group,
    } });
}

fn reduceWorkspaceSwitchRequest(
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
        clearDragPreview(transition);
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
            clearDragPreview(transition);
            transition.addEffect(.{ .workspace_switch_ready = .{
                .target = target,
                .outgoing = outgoing,
            } });
        },
    }
}

fn reduceVirtualWorkspaceMoveRequest(
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
    clearDragPreview(transition);
    transition.addEffect(.{ .virtual_workspace_move_ready = .{
        .moving = moved,
        .displaced = displaced,
    } });
}

fn reduceVirtualDisplaysObserved(transition: *Transition, observation: VirtualDisplayObservation) void {
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

fn firstUnclaimedWorkspace(claimed: []const bool) ?WorkspaceId {
    var workspace_id: WorkspaceId = 1;
    while (workspace_id < claimed.len) : (workspace_id += 1) {
        if (!claimed[workspace_id]) return workspace_id;
    }
    return null;
}

fn displayObservationContains(observation: *const VirtualDisplayObservation, display_id: DisplayId) bool {
    for (observation.displays[0..observation.display_count]) |display| {
        if (display.display_id == display_id) return true;
    }
    return false;
}

fn observedDisplayIdForUuid(observation: *const VirtualDisplayObservation, uuid: ?[16]u8) ?DisplayId {
    const expected = uuid orelse return null;
    for (observation.displays[0..observation.display_count]) |display| {
        const actual = display.uuid orelse continue;
        if (std.mem.eql(u8, &actual, &expected)) return display.display_id;
    }
    return null;
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
        return;
    }
    transition.addEffect(.{ .move_native_window = pending });
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
        const current = transition.model.window(pending.window_id);
        if (current == null or !current.?.space_key.eql(pending.target.key)) {
            _ = transition.model.pending_native_window_moves.remove(event.window_id);
            transition.addEffect(.{ .native_window_move_rolled_back = pending });
            return;
        }
        reduceWindowSpaceAssigned(transition, .{
            .window_id = pending.window_id,
            .space_key = pending.source.key,
            .layout = event.layout,
        });
        const restored = transition.model.window(pending.window_id) orelse return;
        if (restored.space_key.eql(pending.source.key)) {
            if (transition.model.focusedWorkspaceWindow(pending.source.workspace_id) == null) {
                reduceWorkspaceFocusRecorded(transition, .{
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

fn reduceNativeWorkspaceMoveRequest(
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

fn reduceNativeWorkspaceMoveStarted(
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

fn reduceNativeWorkspaceMoveObserved(
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
    if (!applyLayoutEvent(transition, .{ .swap_layouts = .{
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

fn reduceNativeWorkspaceMoveRollbackResult(
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

fn reducePendingRoleTracked(transition: *Transition, candidate: WindowCandidate) void {
    if (!windowCandidateIsValid(&transition.model, candidate) or candidate.attempts_remaining == 0) return;
    if (transition.model.window(candidate.window_id) != null) {
        _ = transition.model.pending_role_windows.remove(candidate.window_id);
        return;
    }
    if (!transition.model.pending_role_windows.track(candidate, true)) {
        @panic("pending role window capacity exceeded");
    }
}

fn reducePendingRoleObserved(
    transition: *Transition,
    observation: @FieldType(Event, "pending_role_observed"),
) void {
    if (transition.model.window(observation.window_id) != null) {
        _ = transition.model.pending_role_windows.remove(observation.window_id);
        return;
    }
    const candidate = transition.model.pending_role_windows.getPtr(observation.window_id) orelse return;

    switch (observation.readiness) {
        .reject => _ = transition.model.pending_role_windows.remove(observation.window_id),
        .ready => {
            const ready = transition.model.pending_role_windows.remove(observation.window_id).?;
            transition.addEffect(.{ .pending_role_ready = ready });
        },
        .pending => {
            if (candidate.attempts_remaining > 0) {
                candidate.attempts_remaining -= 1;
                return;
            }
            const expired = transition.model.pending_role_windows.remove(observation.window_id).?;
            transition.addEffect(.{ .pending_role_expired = expired });
        },
    }
}

fn reduceDeferredWindowTracked(transition: *Transition, candidate: WindowCandidate) void {
    if (!windowCandidateIsValid(&transition.model, candidate) or candidate.attempts_remaining == 0) return;
    if (transition.model.window(candidate.window_id) != null) {
        _ = transition.model.deferred_window_candidates.remove(candidate.window_id);
        return;
    }
    if (!transition.model.deferred_window_candidates.track(candidate, false)) {
        @panic("deferred window candidate capacity exceeded");
    }
}

fn reduceDeferredWindowObserved(
    transition: *Transition,
    observation: @FieldType(Event, "deferred_window_observed"),
) void {
    if (transition.model.window(observation.window_id) != null) {
        _ = transition.model.deferred_window_candidates.remove(observation.window_id);
        return;
    }
    const candidate = transition.model.deferred_window_candidates.getPtr(observation.window_id) orelse return;

    switch (observation.readiness) {
        .reject => _ = transition.model.deferred_window_candidates.remove(observation.window_id),
        .pending => expireOrDecrementDeferredWindow(transition, candidate, .role_pending),
        .ready => {
            if (!observation.is_visible) {
                expireOrDecrementDeferredWindow(transition, candidate, .off_screen);
                return;
            }
            transition.addEffect(.{ .deferred_window_ready = candidate.* });
        },
    }
}

fn reduceDeferredWindowPromotionFailed(transition: *Transition, window_id: WindowId) void {
    const candidate = transition.model.deferred_window_candidates.getPtr(window_id) orelse return;
    expireOrDecrementDeferredWindow(transition, candidate, .unsettled_bounds);
}

fn expireOrDecrementDeferredWindow(
    transition: *Transition,
    candidate: *WindowCandidate,
    reason: DeferredWindowExpiryReason,
) void {
    if (candidate.attempts_remaining > 0) {
        candidate.attempts_remaining -= 1;
        return;
    }
    const expired = transition.model.deferred_window_candidates.remove(candidate.window_id).?;
    transition.addEffect(.{ .deferred_window_expired = .{
        .candidate = expired,
        .reason = reason,
    } });
}

fn reduceProcessRetryTracked(retries: *ProcessRetries, retry: ProcessRetry) void {
    if (retry.process_id <= 0 or retry.attempts_remaining == 0) return;
    if (!retries.track(retry)) @panic("process retry capacity exceeded");
}

fn reduceAppLaunchRetryTimer(transition: *Transition, process_id: i32) void {
    const retry = transition.model.app_launch_retries.getPtr(process_id) orelse return;
    if (retry.attempts_remaining > 0) {
        retry.attempts_remaining -= 1;
        return;
    }
    _ = transition.model.app_launch_retries.remove(process_id);
    transition.addEffect(.{ .app_launch_retry_ready = process_id });
}

fn reduceFocusRetryObserved(
    transition: *Transition,
    observation: @FieldType(Event, "focus_retry_observed"),
) void {
    const retry = transition.model.focus_retries.getPtr(observation.process_id) orelse return;
    if (observation.focused_window_id != 0) {
        _ = transition.model.focus_retries.remove(observation.process_id);
        transition.addEffect(.{ .focus_retry_resolved = .{
            .process_id = observation.process_id,
            .window_id = observation.focused_window_id,
        } });
        return;
    }
    if (retry.attempts_remaining > 0) {
        retry.attempts_remaining -= 1;
        return;
    }
    _ = transition.model.focus_retries.remove(observation.process_id);
    transition.addEffect(.{ .focus_retry_expired = observation.process_id });
}

fn reduceWorkspaceRevealObserved(
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

fn reduceWorkspaceParkTimer(
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

fn reduceDisplayResettleTimer(transition: *Transition, at_ms: TimestampMs) void {
    const due_at_ms = transition.model.display_resettle_due_at_ms orelse return;
    if (at_ms < due_at_ms) return;
    transition.model.display_resettle_due_at_ms = null;
    transition.addEffect(.display_resettle_due);
}

fn reducePointerDown(transition: *Transition, candidate_window_id: ?WindowId) void {
    clearDragPreview(transition);
    transition.model.pointer_drag = .{
        .is_down = true,
        .candidate_window_id = if (candidate_window_id) |window_id|
            if (transition.model.window(window_id) != null) window_id else null
        else
            null,
    };
}

fn reduceRetileDisplayRequested(model: *Model, display_id: DisplayId) void {
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

fn reduceLayoutRebuild(transition: *Transition, rebuild: LayoutRebuild) void {
    if (rebuild.space_count > rebuild.spaces.len) return;
    if (!std.math.isFinite(rebuild.inner_gap) or !std.math.isFinite(rebuild.split_ratio)) return;

    const original_layout = transition.model.layout;
    transition.model.layout = .{};
    for (rebuild.spaces[0..rebuild.space_count]) |layout_space| {
        const space = transition.model.space(layout_space.space_key) orelse {
            transition.model.layout = original_layout;
            return;
        };
        if (layout_space.root_frame) |frame| {
            if (!frameIsFinite(frame) or frame.width <= 0 or frame.height <= 0) {
                transition.model.layout = original_layout;
                return;
            }
        }

        for (transition.model.windows.items()) |window| {
            if (!window.space_key.eql(space.key)) continue;
            if (window.tab_leader_window_id != window.window_id) continue;
            if (window.mode != .tiled) continue;

            const anchor_window_id: ?WindowId = switch (rebuild.insert_point) {
                .focused => blk: {
                    const focused_window_id = transition.model.focusedWorkspaceWindow(space.workspace_id) orelse break :blk null;
                    if (focused_window_id == window.window_id) break :blk null;
                    break :blk focused_window_id;
                },
                .first => transition.model.layout.firstWid(space.key),
                .last => transition.model.layout.lastWid(space.key),
                .min_depth => null,
            };
            if (!applyLayoutEvent(transition, .{ .insert = .{
                .space_key = space.key,
                .kind = rebuild.kind,
                .window_id = window.window_id,
                .options = .{
                    .split_mode = rebuild.split_mode,
                    .child = rebuild.insert_child,
                    .anchor_wid = anchor_window_id,
                    .root_frame = layout_space.root_frame,
                    .inner_gap = rebuild.inner_gap,
                    .split_ratio = rebuild.split_ratio,
                },
            } })) {
                transition.model.layout = original_layout;
                return;
            }
        }
        const focused_window_id = transition.model.focusedWorkspaceWindow(space.workspace_id) orelse continue;
        if (!transition.model.layout.contains(space.key, focused_window_id)) continue;
        _ = applyLayoutEvent(transition, .{ .set_active = .{
            .space_key = space.key,
            .window_id = focused_window_id,
        } });
    }
}

const ActionWindow = struct {
    leader: ManagedWindow,
    space: SpaceRef,
};

fn reduceFocusDirection(
    transition: *Transition,
    command: @FieldType(Event, "focus_direction"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const target_window_id = windowInDirection(&transition.model, action, command.direction) orelse
        transition.model.layout.cycleFocus(
            action.space.key,
            action.leader.window_id,
            command.direction == .right or command.direction == .down,
        ) orelse return;
    const target = transition.model.window(target_window_id) orelse return;
    const leader = transition.model.window(target.tab_leader_window_id) orelse return;
    if (!leader.space_key.eql(action.space.key)) return;
    const active_window_id = transition.model.windowTabActive(leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;

    reduceWorkspaceFocusRecorded(transition, .{
        .workspace_id = action.space.workspace_id,
        .window_id = leader.window_id,
    });
    _ = applyLayoutEvent(transition, .{ .set_active = .{
        .space_key = action.space.key,
        .window_id = leader.window_id,
    } });
    transition.addEffect(.{ .focus_window = .{
        .window_id = active.window_id,
        .process_id = active.process_id,
    } });
}

fn reduceSwapDirection(
    transition: *Transition,
    command: @FieldType(Event, "swap_direction"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const target_window_id = windowInDirection(&transition.model, action, command.direction) orelse return;
    if (!transition.model.layout.contains(action.space.key, action.leader.window_id)) return;
    if (!transition.model.layout.contains(action.space.key, target_window_id)) return;
    if (!applyLayoutEvent(transition, .{ .swap_window_ids = .{
        .space_key = action.space.key,
        .first_window_id = action.leader.window_id,
        .second_window_id = target_window_id,
    } })) return;

    reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .windows_swapped = .{
        .first_window_id = action.leader.window_id,
        .second_window_id = target_window_id,
        .direction = command.direction,
    } });
}

fn reduceWindowModeCommand(
    transition: *Transition,
    command: @FieldType(Event, "set_window_mode"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    if (action.leader.mode == command.mode) return;

    var window = action.leader.snapshot();
    window.mode = command.mode;
    reduceWindowUpdated(transition, .{
        .window = window,
        .layout = command.layout,
    });
    const updated = transition.model.window(action.leader.window_id) orelse return;
    if (updated.mode != command.mode) return;

    reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .window_mode_changed = .{
        .window_id = updated.window_id,
        .previous = action.leader.mode,
        .current = updated.mode,
    } });
}

fn reduceFullscreenCommand(
    transition: *Transition,
    command: @FieldType(Event, "toggle_window_fullscreen"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const active_window_id = transition.model.windowTabActive(action.leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;

    var leader = action.leader.snapshot();
    leader.is_fullscreen = !leader.is_fullscreen;
    const restore_frame: ?window_mod.Window.Frame = blk: {
        if (leader.mode != .floating) break :blk null;
        if (!leader.is_fullscreen) break :blk leader.float_frame;

        const observed = command.observed_frame orelse leader.frame;
        if (!frameIsFinite(observed) or observed.width <= 0 or observed.height <= 0) return;
        leader.float_frame = observed;
        break :blk null;
    };
    reduceWindowUpdated(transition, .{ .window = leader });

    reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .fullscreen_changed = .{
        .leader_window_id = action.leader.window_id,
        .window_id = active.window_id,
        .process_id = active.process_id,
        .is_fullscreen = leader.is_fullscreen,
        .mode = leader.mode,
        .restore_frame = restore_frame,
    } });
}

fn reduceCenterWindowCommand(
    transition: *Transition,
    command: @FieldType(Event, "center_floating_window"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    if (action.leader.mode != .floating or action.leader.is_fullscreen) return;
    if (!frameIsFinite(command.observed_frame) or !frameIsFinite(command.display_frame)) return;
    if (command.observed_frame.width <= 0 or command.observed_frame.height <= 0) return;
    if (command.display_frame.width <= 0 or command.display_frame.height <= 0) return;

    const active_window_id = transition.model.windowTabActive(action.leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;
    const target: window_mod.Window.Frame = .{
        .x = command.display_frame.x + (command.display_frame.width - command.observed_frame.width) / 2.0,
        .y = command.display_frame.y + (command.display_frame.height - command.observed_frame.height) / 2.0,
        .width = command.observed_frame.width,
        .height = command.observed_frame.height,
    };
    transition.addEffect(.{ .center_window = .{
        .leader_window_id = action.leader.window_id,
        .window_id = active.window_id,
        .process_id = active.process_id,
        .current_frame = active.frame,
        .target_frame = target,
    } });
}

fn reduceWindowFrameCommandResult(
    transition: *Transition,
    result: @FieldType(Event, "window_frame_command_result"),
) void {
    if (!result.succeeded) return;
    if (!frameIsFinite(result.target_frame)) return;

    var visible = transition.model.window(result.window_id) orelse return;
    visible.frame = result.target_frame;
    std.debug.assert(transition.model.windows.update(visible.snapshot()));

    if (result.leader_window_id == result.window_id) {
        if (!result.should_save_float_frame) return;
        visible.float_frame = result.target_frame;
        std.debug.assert(transition.model.windows.update(visible.snapshot()));
        return;
    }

    var leader = transition.model.window(result.leader_window_id) orelse return;
    if (leader.tab_leader_window_id != leader.window_id) return;
    leader.frame = result.target_frame;
    if (result.should_save_float_frame) leader.float_frame = result.target_frame;
    std.debug.assert(transition.model.windows.update(leader.snapshot()));
}

fn reduceWindowMoveRequest(transition: *Transition, request: WindowMoveRequest) void {
    const action = resolveActionWindow(&transition.model, request.window_id) orelse return;
    const target = transition.model.space(request.target.key) orelse return;
    if (action.space.key.eql(target.key)) return;
    if (request.should_move_native and (action.space.key != .native or target.key != .native)) return;

    reduceWindowSpaceAssigned(transition, .{
        .window_id = action.leader.window_id,
        .space_key = target.key,
        .layout = request.layout,
    });
    const moved = transition.model.window(action.leader.window_id) orelse return;
    if (!moved.space_key.eql(target.key)) return;

    if (transition.model.focusedWorkspaceWindow(target.workspace_id) == null) {
        reduceWorkspaceFocusRecorded(transition, .{
            .workspace_id = target.workspace_id,
            .window_id = moved.window_id,
        });
    }
    transition.model.retile_request.all_displays = true;
    transition.model.retile_request.display_count = 0;
    if (request.should_move_native) {
        reduceNativeWindowMoveTracked(transition, .{
            .window_id = moved.window_id,
            .source = action.space,
            .target = target,
        });
    }

    const active_window_id = transition.model.windowTabActive(moved.window_id);
    const active = transition.model.window(active_window_id) orelse return;
    transition.addEffect(.{ .window_moved = .{
        .window_id = active.window_id,
        .process_id = active.process_id,
        .source = action.space,
        .target = target,
        .should_hide = !request.should_move_native and
            transition.model.activeWorkspace(target.display_id) != target.workspace_id,
        .should_follow_focus = request.should_follow_focus,
    } });
}

fn resolveActionWindow(model: *const Model, window_id: WindowId) ?ActionWindow {
    const window = model.window(window_id) orelse return null;
    const leader = model.window(window.tab_leader_window_id) orelse return null;
    const space = model.space(leader.space_key) orelse return null;
    if (model.activeWorkspace(space.display_id) != space.workspace_id) return null;
    return .{ .leader = leader, .space = space };
}

fn windowInDirection(model: *const Model, action: ActionWindow, direction: FocusDirection) ?WindowId {
    const focused = action.leader.frame;
    const focused_center_x = focused.x + focused.width / 2.0;
    const focused_center_y = focused.y + focused.height / 2.0;
    var best_window_id: ?WindowId = null;
    var best_distance = std.math.inf(f64);

    for (model.windows.items()) |window| {
        if (!window.space_key.eql(action.space.key)) continue;
        if (window.tab_leader_window_id != window.window_id) continue;
        if (window.window_id == action.leader.window_id) continue;

        const center_x = window.frame.x + window.frame.width / 2.0;
        const center_y = window.frame.y + window.frame.height / 2.0;
        const delta_x = center_x - focused_center_x;
        const delta_y = center_y - focused_center_y;
        const is_in_direction = switch (direction) {
            .left => delta_x < 0,
            .right => delta_x > 0,
            .up => delta_y < 0,
            .down => delta_y > 0,
        };
        if (!is_in_direction) continue;

        const distance = @abs(delta_x) + @abs(delta_y);
        if (distance >= best_distance) continue;
        best_distance = distance;
        best_window_id = window.window_id;
    }
    return best_window_id;
}

fn reducePointerDragged(transition: *Transition) void {
    if (!transition.model.pointer_drag.is_down) return;
    if (transition.model.pointer_drag.active_window_id != null) return;
    transition.model.pointer_drag.active_window_id = transition.model.pointer_drag.candidate_window_id;
}

fn reduceDragPreviewObserved(
    transition: *Transition,
    observation: @FieldType(Event, "drag_preview_observed"),
) void {
    const source = transition.model.window(observation.source_window_id) orelse {
        clearDragPreview(transition);
        return;
    };
    if (source.mode != .tiled or source.is_fullscreen) {
        clearDragPreview(transition);
        return;
    }

    transition.model.drag_preview.source_window_id = source.window_id;
    const target_window_id = observation.target_window_id orelse {
        hideDragPreview(transition);
        return;
    };
    const target_frame = observation.target_frame orelse {
        hideDragPreview(transition);
        return;
    };
    if (!frameIsFinite(target_frame) or target_frame.width <= 0 or target_frame.height <= 0) {
        hideDragPreview(transition);
        return;
    }
    const target = transition.model.window(target_window_id) orelse {
        hideDragPreview(transition);
        return;
    };
    if (target.mode != .tiled or target.is_fullscreen or !target.space_key.eql(source.space_key)) {
        hideDragPreview(transition);
        return;
    }

    const target_changed = transition.model.drag_preview.target_window_id != target_window_id;
    transition.model.drag_preview.target_window_id = target_window_id;
    if (transition.model.drag_preview.is_visible and !target_changed) return;
    transition.model.drag_preview.is_visible = true;
    transition.addEffect(.{ .show_drag_preview = target_frame });
}

fn reducePointerUp(transition: *Transition) void {
    const pointer_drag = transition.model.pointer_drag;
    const preview = transition.model.drag_preview;
    transition.model.pointer_drag = .{};
    clearDragPreview(transition);

    const source_window_id = preview.source_window_id orelse {
        if (pointer_drag.should_reconcile_on_drop) {
            transition.addEffect(.{ .pointer_drag_completed = .{ .should_retile = true } });
        }
        return;
    };
    const target_window_id = preview.target_window_id orelse {
        transition.addEffect(.{ .pointer_drag_completed = .{ .should_retile = true } });
        return;
    };
    if (source_window_id == target_window_id) return;

    const source = transition.model.window(source_window_id) orelse return;
    const target = transition.model.window(target_window_id) orelse return;
    if (source.mode != .tiled or target.mode != .tiled) return;
    if (source.is_fullscreen or target.is_fullscreen) return;
    if (!source.space_key.eql(target.space_key)) return;
    if (!transition.model.layout.contains(source.space_key, source_window_id)) return;
    if (!transition.model.layout.contains(source.space_key, target_window_id)) return;
    if (!applyLayoutEvent(transition, .{ .swap_window_ids = .{
        .space_key = source.space_key,
        .first_window_id = source_window_id,
        .second_window_id = target_window_id,
    } })) return;
    transition.addEffect(.{ .pointer_drag_completed = .{
        .should_retile = true,
        .swapped_window_ids = .{ .first = source_window_id, .second = target_window_id },
    } });
}

fn clearDragPreview(transition: *Transition) void {
    if (transition.model.drag_preview.is_visible) transition.addEffect(.hide_drag_preview);
    transition.model.drag_preview = .{};
}

fn hideDragPreview(transition: *Transition) void {
    transition.model.drag_preview.target_window_id = null;
    if (!transition.model.drag_preview.is_visible) return;
    transition.model.drag_preview.is_visible = false;
    transition.addEffect(.hide_drag_preview);
}

fn windowCandidateIsValid(model: *const Model, candidate: WindowCandidate) bool {
    return candidate.process_id > 0 and
        candidate.window_id != 0 and
        model.space(candidate.space_key) != null;
}

fn pruneWindowCandidates(candidates: *WindowCandidates, spaces: *const SpaceCatalog) void {
    var index: usize = 0;
    while (index < candidates.count) {
        if (spaces.find(candidates.entries[index].space_key) != null) {
            index += 1;
            continue;
        }
        _ = candidates.remove(candidates.entries[index].window_id);
    }
}

fn refreshPendingWorkspaceParks(parks: *PendingWorkspaceParks, spaces: *const SpaceCatalog) void {
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

fn refreshWorkspaceFocus(model: *Model) void {
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

fn firstWorkspaceWindow(model: *const Model, space_key: SpaceKey) ?WindowId {
    for (model.windows.items()) |window| {
        if (!window.space_key.eql(space_key)) continue;
        if (window.tab_leader_window_id != window.window_id) continue;
        return window.window_id;
    }
    return null;
}

fn assertModel(model: *const Model) void {
    std.debug.assert(model.next_epoch != 0);
    model.layout.assertValid();
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
        std.debug.assert(window.tab_leader_window_id != 0);
        std.debug.assert(frameIsFinite(window.frame));
        if (window.float_frame) |frame| std.debug.assert(frameIsFinite(frame));
        for (model.windows.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != window.window_id);
        }

        const leader = model.window(window.tab_leader_window_id).?;
        std.debug.assert(leader.process_id == window.process_id);
        std.debug.assert(leader.space_key.eql(window.space_key));
        std.debug.assert(leader.tab_leader_window_id == leader.window_id);
        if (window.tab_leader_window_id != window.window_id) continue;

        var member_count: u16 = 0;
        var active_count: u16 = 0;
        for (model.windows.items()) |member| {
            if (member.tab_leader_window_id != window.window_id) continue;
            member_count += 1;
            if (!member.is_suppressed) active_count += 1;
        }
        std.debug.assert(member_count > 0);
        std.debug.assert(active_count == 1);
    }
    for (model.workspace_focus, 0..) |focus, index| {
        std.debug.assert(focus.history_count <= focus.history.len);
        const workspace_id: WorkspaceId = @intCast(index + 1);
        const space = model.logicalWorkspace(workspace_id);
        for (focus.history[0..focus.history_count], 0..) |window_id, history_index| {
            const window = model.window(window_id).?;
            std.debug.assert(window.tab_leader_window_id == window.window_id);
            std.debug.assert(space != null and window.space_key.eql(space.?.key));
            for (focus.history[0..history_index]) |prior| {
                std.debug.assert(prior != window_id);
            }
        }
        if (focus.focused_window_id) |window_id| {
            std.debug.assert(focus.history_count > 0);
            std.debug.assert(focus.history[focus.history_count - 1] == window_id);
        } else {
            std.debug.assert(focus.history_count == 0);
        }
    }
    std.debug.assert(model.workspace_topology.display_count <= model.workspace_topology.displays.len);
    for (model.workspace_topology.displays[0..model.workspace_topology.display_count], 0..) |display, index| {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.active_workspace_id != 0);
        for (model.workspace_topology.displays[0..index]) |prior| {
            std.debug.assert(prior.display_id != display.display_id);
            std.debug.assert(prior.active_workspace_id != display.active_workspace_id);
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
    if (model.pending_native_workspace_move) |pending| {
        std.debug.assert(pending.epoch != 0);
        std.debug.assert(nativeSpaceId(pending.source) != null);
        std.debug.assert(nativeSpaceId(pending.target) != null);
        std.debug.assert(!pending.source.key.eql(pending.target.key));
        std.debug.assert(pending.source.display_id != pending.target.display_id);
        std.debug.assert(model.workspace_transition != null);
        std.debug.assert(model.workspace_transition.?.epoch == pending.epoch);
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
    assertWindowCandidates(model, &model.pending_role_windows);
    assertWindowCandidates(model, &model.deferred_window_candidates);
    assertProcessRetries(&model.app_launch_retries);
    assertProcessRetries(&model.focus_retries);
    std.debug.assert(model.pending_workspace_parks.count <= model.pending_workspace_parks.entries.len);
    for (model.pending_workspace_parks.items(), 0..) |pending, index| {
        pending.outgoing.assertValid();
        pending.target.assertValid();
        std.debug.assert(!pending.outgoing.key.eql(pending.target.key));
        std.debug.assert(pending.outgoing.display_id == pending.target.display_id);
        std.debug.assert(model.space(pending.outgoing.key).?.display_id == pending.outgoing.display_id);
        std.debug.assert(model.space(pending.target.key).?.display_id == pending.target.display_id);
        for (model.pending_workspace_parks.items()[0..index]) |prior| {
            std.debug.assert(prior.target.display_id != pending.target.display_id);
        }
    }
    if (!model.pointer_drag.is_down) {
        std.debug.assert(model.pointer_drag.candidate_window_id == null);
        std.debug.assert(model.pointer_drag.active_window_id == null);
        std.debug.assert(!model.pointer_drag.should_reconcile_on_drop);
    }
    if (model.pointer_drag.candidate_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
    }
    if (model.pointer_drag.active_window_id) |window_id| {
        std.debug.assert(model.pointer_drag.is_down);
        std.debug.assert(model.pointer_drag.candidate_window_id == window_id);
    }
    if (model.pointer_drag.should_reconcile_on_drop) {
        std.debug.assert(model.pointer_drag.active_window_id != null);
    }
    if (model.drag_preview.source_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
    }
    if (model.drag_preview.target_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
        std.debug.assert(model.drag_preview.source_window_id != null);
    }
    if (model.drag_preview.is_visible) std.debug.assert(model.drag_preview.target_window_id != null);
    std.debug.assert(model.display_memory.count <= model.display_memory.entries.len);
    for (model.display_memory.entries[0..model.display_memory.count], 0..) |entry, index| {
        std.debug.assert(entry.active_workspace_id != 0);
        for (model.display_memory.entries[0..index]) |prior| {
            std.debug.assert(!std.mem.eql(u8, &prior.uuid, &entry.uuid));
        }
    }
    std.debug.assert(model.retile_request.display_count <= model.retile_request.display_ids.len);
    if (model.retile_request.all_displays) std.debug.assert(model.retile_request.display_count == 0);
    for (model.retile_request.display_ids[0..model.retile_request.display_count], 0..) |display_id, index| {
        std.debug.assert(display_id != 0);
        for (model.retile_request.display_ids[0..index]) |prior| {
            std.debug.assert(prior != display_id);
        }
    }
    std.debug.assert(model.cleanup_request.process_count <= model.cleanup_request.process_ids.len);
    for (model.cleanup_request.process_ids[0..model.cleanup_request.process_count], 0..) |process_id, index| {
        std.debug.assert(process_id > 0);
        for (model.cleanup_request.process_ids[0..index]) |prior| {
            std.debug.assert(prior != process_id);
        }
    }
    std.debug.assert(crossDomainStateIsValid(model));
}

fn assertWindowCandidates(model: *const Model, candidates: *const WindowCandidates) void {
    std.debug.assert(candidates.count <= candidates.entries.len);
    for (candidates.items(), 0..) |candidate, index| {
        std.debug.assert(windowCandidateIsValid(model, candidate));
        std.debug.assert(model.window(candidate.window_id) == null);
        for (candidates.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != candidate.window_id);
        }
    }
}

fn assertProcessRetries(retries: *const ProcessRetries) void {
    std.debug.assert(retries.count <= retries.entries.len);
    for (retries.items(), 0..) |retry, index| {
        std.debug.assert(retry.process_id > 0);
        for (retries.items()[0..index]) |prior| {
            std.debug.assert(prior.process_id != retry.process_id);
        }
    }
}

fn crossDomainStateIsValid(model: *const Model) bool {
    if (model.geometry.windowCount() != model.windows.count) return false;

    var layout_window_count: usize = 0;
    for (model.windows.items()) |window| {
        if (model.space(window.space_key) == null) return false;
        if (model.geometry.get(window.window_id) == null) return false;
        if (!model.layout.contains(window.space_key, window.window_id)) continue;
        if (window.tab_leader_window_id != window.window_id) return false;
        if (window.mode != .tiled) return false;
        layout_window_count += 1;
    }
    return layout_window_count == model.layout.totalWindowCount();
}

fn frameIsFinite(frame: window_mod.Window.Frame) bool {
    return std.math.isFinite(frame.x) and
        std.math.isFinite(frame.y) and
        std.math.isFinite(frame.width) and
        std.math.isFinite(frame.height);
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
    catalog.add(.{ .key = .{ .native = 101 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .native = 201 }, .workspace_id = 2, .display_id = 22 });
    catalog.add(.{ .key = .{ .native = 102 }, .workspace_id = 3, .display_id = 11 });

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
        .space_key = .{ .native = 101 },
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 201,
        .process_id = 2001,
        .space_key = .{ .native = 201 },
    } }).model;
    const summaries = model.workspaceSummaries(3);

    try testing.expectEqual(@as(u32, 1), summaries[0].window_count);
    try testing.expect(summaries[0].is_active);
    try testing.expect(!summaries[0].is_focused);
    try testing.expectEqual(@as(u32, 1), summaries[1].window_count);
    try testing.expect(summaries[1].is_active);
    try testing.expect(summaries[1].is_focused);
}

test "workspace initialization assigns one global workspace per display" {
    const testing = std.testing;
    var initialization: WorkspaceInitialization = .{
        .workspace_count = 7,
        .primary_display_id = 11,
    };
    try testing.expect(initialization.addDisplay(22));
    try testing.expect(initialization.addDisplay(11));
    try testing.expect(initialization.addDisplay(33));

    const transition = reduce(.{}, .{ .initialize_workspaces = initialization });
    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.activeWorkspace(11));
    try testing.expectEqual(@as(?WorkspaceId, 7), transition.model.activeWorkspace(22));
    try testing.expectEqual(@as(?WorkspaceId, 6), transition.model.activeWorkspace(33));
    try testing.expectEqual(@as(?DisplayId, 11), transition.model.focusedDisplay());
    try testing.expectEqual(@as(DisplayId, 11), transition.model.logicalWorkspace(2).?.display_id);
    try testing.expectEqual(@as(DisplayId, 33), transition.model.logicalWorkspace(6).?.display_id);
    try testing.expectEqual(@as(DisplayId, 22), transition.model.logicalWorkspace(7).?.display_id);
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
        .frame = .{ .x = 10, .y = 20, .width = 800, .height = 600 },
        .mode = .floating,
        .float_frame = .{ .x = 10, .y = 20, .width = 800, .height = 600 },
    } });
    const second = reduce(first.model, .{ .adopt_window = .{
        .window_id = 102,
        .process_id = 1002,
        .space_key = .{ .virtual = 1 },
    } });

    try testing.expect(model.window(101) == null);
    try testing.expectEqual(@as(u16, 2), second.model.windows.countInSpace(.{ .virtual = 1 }));
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
        .space_key = .{ .virtual = 2 },
    } });
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .virtual = 1 }));
    try testing.expectEqual(@as(u16, 1), assigned.model.windows.countInSpace(.{ .virtual = 2 }));
    try testing.expect(assigned.model.window(101).?.space_key.eql(.{ .virtual = 2 }));

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
    const first_space: SpaceKey = .{ .virtual = 1 };
    const second_space: SpaceKey = .{ .virtual = 2 };
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
    const space_key: SpaceKey = .{ .virtual = 1 };
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

    try testing.expect(rebuild.addSpace(.{ .virtual = 2 }, null));
    transition = reduce(model, .{ .rebuild_layout = rebuild });
    try testing.expectEqual(tiling_mod.LayoutKind.bsp, transition.model.layout.layoutKind(space_key).?);
    try testing.expect(transition.model.layout.contains(space_key, 101));
    try testing.expect(transition.model.layout.contains(space_key, 102));
}

test "layout rejection leaves window adoption unchanged" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .virtual = 1 };
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
    const first_space: SpaceKey = .{ .virtual = 1 };
    const second_space: SpaceKey = .{ .virtual = 2 };
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
    try testing.expect(crossDomainStateIsValid(&model));

    var invalid = model;
    invalid.geometry.forget(101);
    try testing.expect(!crossDomainStateIsValid(&invalid));

    invalid = model;
    try invalid.geometry.seedObserved(999, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try testing.expect(!crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].space_key = second_space;
    try testing.expect(!crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].space_key = .{ .virtual = 99 };
    try testing.expect(!crossDomainStateIsValid(&invalid));

    invalid = model;
    invalid.windows.entries[0].mode = .floating;
    try testing.expect(!crossDomainStateIsValid(&invalid));

    var group: WindowTabGroupObservation = .{
        .leader_window_id = 101,
        .active_window_id = 102,
    };
    try testing.expect(group.addMember(101));
    try testing.expect(group.addMember(102));
    model = reduce(model, .{ .observe_window_tab_group = group }).model;
    try testing.expect(crossDomainStateIsValid(&model));

    invalid = model;
    invalid.layout = tiling_mod.reduce(invalid.layout, .{ .insert = .{
        .space_key = first_space,
        .kind = .bsp,
        .window_id = 102,
        .options = testLayoutInsertion(.bsp).options,
    } }).model;
    try testing.expect(!crossDomainStateIsValid(&invalid));
}

test "tab transitions transfer layout ownership atomically" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .virtual = 1 };
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
    const first_space: SpaceKey = .{ .virtual = 1 };
    const second_space: SpaceKey = .{ .virtual = 2 };
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
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };

    for ([_]WindowId{ 101, 102 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .virtual = 1 },
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
        .space_key = .{ .virtual = 2 },
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

    const adopted = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .virtual = 1 },
    } });
    const duplicate = reduce(adopted.model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .virtual = 1 },
    } });
    try testing.expectEqual(
        WindowCatalogRejectionReason.window_exists,
        duplicate.effects[0].window_catalog_rejected.reason,
    );
}

test "window catalog owns tab identity and group Space assignment" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102, 103 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .virtual = 1 },
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
        .space_key = .{ .virtual = 2 },
    } }).model;
    try testing.expectEqual(@as(u16, 3), model.windows.countInSpace(.{ .virtual = 2 }));

    var window_ids: [max_managed_windows]WindowId = undefined;
    const workspace_windows = model.workspaceWindowIds(.{ .virtual = 2 }, &window_ids);
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
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .virtual = 1 },
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
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    var model: Model = .{ .spaces = catalog };
    for ([_]WindowId{ 101, 102, 103 }) |window_id| {
        model = reduce(model, .{ .adopt_window = .{
            .window_id = window_id,
            .process_id = 1001,
            .space_key = .{ .virtual = 1 },
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
    try testing.expect(first.key.eql(.{ .native = 102 }));
    try testing.expect(second.key.eql(.{ .native = 202 }));
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
    try testing.expect(model.spaceForWorkspace(1, 2).?.key.eql(.{ .native = 102 }));
    try testing.expect(model.spaceForWorkspace(2, 3).?.key.eql(.{ .native = 201 }));
    try testing.expect(model.spaceForWorkspace(2, 2) == null);
}

test "native topology mapping assigns one global workspace per physical slot" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 1 });
    catalog.add(.{ .key = .{ .virtual = 3 }, .workspace_id = 3, .display_id = 2 });
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
    const mapped = mapNativeTopology(observation, &previous, &workspace_topology, &catalog, 3).?;

    try testing.expectEqual(@as(?WorkspaceId, 1), mapped.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 3), mapped.observedWorkspace(2));
    try testing.expectEqual(@as(?NativeSpaceId, 101), mapped.findDisplay(1).?.spaceForWorkspace(2));
    try testing.expect(mapped.findDisplay(1).?.workspaceForSpace(103) == null);
}

test "switch effect preserves target Space identity across displays" {
    const testing = std.testing;
    const model = initializedModel(testTopology(102, 201));
    const transition = reduce(model, switchRequest(&model, 2, 5, 100));
    const effect = transition.effects[1].switch_native_space;

    try testing.expect(effect.request.target.key.eql(.{ .native = 202 }));
    try testing.expectEqual(@as(DisplayId, 2), effect.request.target.display_id);
    try testing.expectEqual(@as(WorkspaceId, 5), effect.request.target.workspace_id);
}

test "native workspace move commits placement and ownership atomically" {
    const testing = std.testing;
    var model = initializedModel(testTopology(101, 201));
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 101,
        .process_id = 1001,
        .space_key = .{ .native = 101 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 201,
        .process_id = 2001,
        .space_key = .{ .native = 201 },
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
        .source = model.space(.{ .native = 101 }).?,
        .target = model.space(.{ .native = 201 }).?,
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
    try testing.expectEqual(@as(WorkspaceId, 4), transition.model.space(.{ .native = 101 }).?.workspace_id);
    try testing.expectEqual(@as(WorkspaceId, 1), transition.model.space(.{ .native = 201 }).?.workspace_id);
    try testing.expect(transition.model.window(101).?.space_key.eql(.{ .native = 201 }));
    try testing.expect(transition.model.window(201).?.space_key.eql(.{ .native = 101 }));
    try testing.expect(transition.model.layout.contains(.{ .native = 201 }, 101));
    try testing.expect(transition.model.layout.contains(.{ .native = 101 }, 201));
    try testing.expectEqual(@as(?WindowId, 101), transition.model.focusedWorkspaceWindow(1));
    try testing.expectEqual(@as(?WindowId, 201), transition.model.focusedWorkspaceWindow(4));
    try testing.expectEqual(std.meta.Tag(Effect).native_workspace_move_completed, std.meta.activeTag(transition.effects[0]));
}

test "native workspace move timeout rolls physical contents back" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, 201));
    var transition = reduce(model, .{ .request_native_workspace_move = .{
        .source = model.space(.{ .native = 101 }).?,
        .target = model.space(.{ .native = 201 }).?,
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
    try testing.expectEqual(@as(WorkspaceId, 1), transition.model.space(.{ .native = 101 }).?.workspace_id);
    try testing.expectEqual(@as(WorkspaceId, 4), transition.model.space(.{ .native = 201 }).?.workspace_id);
    try testing.expectEqual(std.meta.Tag(Effect).native_workspace_move_failed, std.meta.activeTag(transition.effects[1]));
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

    try testing.expect(transition.model.pending_switch.?.request.target.key.eql(.{ .native = 102 }));
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

test "window discovery retries are reducer owned" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    const candidate: WindowCandidate = .{
        .process_id = 42,
        .window_id = 100,
        .space_key = .{ .virtual = 1 },
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

test "workspace park and display settle timers are reducer owned" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 2 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    var transition = reduce(model, .{ .workspace_reveal_observed = .{
        .outgoing = catalog.find(.{ .virtual = 1 }).?,
        .target = catalog.find(.{ .virtual = 2 }).?,
        .is_revealed = false,
        .deadline_at_ms = 200,
    } });
    try testing.expect(transition.model.hasPendingWorkspaceParks());

    transition = reduce(transition.model, .{ .workspace_park_timer_fired = .{
        .display_id = 11,
        .is_revealed = false,
        .at_ms = 199,
    } });
    try testing.expectEqual(@as(u8, 0), transition.effect_count);
    transition = reduce(transition.model, .{ .workspace_park_timer_fired = .{
        .display_id = 11,
        .is_revealed = false,
        .at_ms = 200,
    } });
    try testing.expect(!transition.model.hasPendingWorkspaceParks());
    try testing.expect(transition.effects[0].park_workspace.did_time_out);

    model = reduce(transition.model, .{ .display_changed = .{
        .at_ms = 100,
        .resettle_at_ms = 500,
    } }).model;
    transition = reduce(model, .{ .display_resettle_timer_fired = 499 });
    try testing.expect(transition.model.hasDisplayResettleScheduled());
    transition = reduce(transition.model, .{ .display_resettle_timer_fired = 500 });
    try testing.expect(!transition.model.hasDisplayResettleScheduled());
    try testing.expectEqual(std.meta.Tag(Effect).display_resettle_due, std.meta.activeTag(transition.effects[0]));
}

test "workspace switch request commits virtual activation before its effect" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    const transition = reduce(model, .{ .request_workspace_switch = .{
        .target = catalog.find(.{ .virtual = 2 }).?,
        .at_ms = 100,
    } });

    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.activeWorkspace(11));
    try testing.expectEqual(@as(?DisplayId, 11), transition.model.focusedDisplay());
    try testing.expect(transition.model.workspace_transition.?.target.key.eql(.{ .virtual = 2 }));
    try testing.expectEqual(std.meta.Tag(Effect).workspace_switch_ready, std.meta.activeTag(transition.effects[1]));
    try testing.expect(transition.effects[1].workspace_switch_ready.outgoing.?.key.eql(.{ .virtual = 1 }));
}

test "virtual workspace display move is one reducer transition" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 22 });
    catalog.add(.{ .key = .{ .virtual = 3 }, .workspace_id = 3, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    topology.addDisplay(.{ .display_id = 22, .active_workspace_id = 2 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    const transition = reduce(model, .{ .request_virtual_workspace_move = .{
        .source_display_id = 11,
        .target_display_id = 22,
        .at_ms = 100,
    } });

    try testing.expectEqual(@as(?WorkspaceId, 3), transition.model.activeWorkspace(11));
    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.activeWorkspace(22));
    try testing.expectEqual(@as(DisplayId, 22), transition.model.space(.{ .virtual = 1 }).?.display_id);
    try testing.expectEqual(@as(DisplayId, 11), transition.model.space(.{ .virtual = 3 }).?.display_id);
    try testing.expectEqual(std.meta.Tag(Effect).virtual_workspace_move_ready, std.meta.activeTag(transition.effects[1]));
}

test "virtual display observation reconciles topology in one transition" {
    const testing = std.testing;
    const first_uuid: [16]u8 = @splat(1);
    const second_uuid: [16]u8 = @splat(2);
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    catalog.add(.{ .key = .{ .virtual = 2 }, .workspace_id = 2, .display_id = 22 });
    catalog.add(.{ .key = .{ .virtual = 3 }, .workspace_id = 3, .display_id = 11 });
    var topology: WorkspaceTopology = .{};
    topology.addDisplay(.{ .display_id = 11, .active_workspace_id = 1 });
    topology.addDisplay(.{ .display_id = 22, .active_workspace_id = 2 });

    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .replace_workspace_topology = topology }).model;
    model = reduce(model, .{ .remember_display_workspace = .{
        .uuid = first_uuid,
        .active_workspace_id = 1,
    } }).model;
    model = reduce(model, .{ .remember_display_workspace = .{
        .uuid = second_uuid,
        .active_workspace_id = 2,
    } }).model;

    var observation: VirtualDisplayObservation = .{
        .primary_display_id = 111,
        .focused_display_id = 222,
    };
    observation.workspace_home_uuids[0] = first_uuid;
    observation.workspace_home_uuids[1] = second_uuid;
    observation.workspace_home_uuids[2] = first_uuid;
    try testing.expect(observation.addDisplay(.{ .display_id = 111, .uuid = first_uuid }));
    try testing.expect(observation.addDisplay(.{ .display_id = 222, .uuid = second_uuid }));

    const transition = reduce(model, .{ .virtual_displays_observed = observation });
    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.activeWorkspace(111));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.activeWorkspace(222));
    try testing.expectEqual(@as(?DisplayId, 222), transition.model.focusedDisplay());
    try testing.expectEqual(@as(DisplayId, 111), transition.model.logicalWorkspace(3).?.display_id);
    try testing.expectEqual(std.meta.Tag(Effect).virtual_displays_reconciled, std.meta.activeTag(transition.effects[0]));
}

test "pointer drop swaps layout inside the reducer" {
    const testing = std.testing;
    var catalog: SpaceCatalog = .{};
    catalog.add(.{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 11 });
    var model = reduce(.{}, .{ .replace_space_catalog = catalog }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 100,
        .process_id = 42,
        .space_key = .{ .virtual = 1 },
        .frame = .{ .x = 0, .y = 0, .width = 500, .height = 500 },
        .layout = testLayoutInsertion(.bsp),
    } }).model;
    model = reduce(model, .{ .adopt_window = .{
        .window_id = 200,
        .process_id = 43,
        .space_key = .{ .virtual = 1 },
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
    try testing.expectEqual(@as(?WindowId, 200), transition.model.layout.firstWid(.{ .virtual = 1 }));
    try testing.expect(!transition.model.pointer_drag.is_down);
    try testing.expectEqual(std.meta.Tag(Effect).hide_drag_preview, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(@as(WindowId, 100), transition.effects[1].pointer_drag_completed.swapped_window_ids.?.first);
}

test "directional commands resolve focus and layout in the reducer" {
    const testing = std.testing;
    const space_key: SpaceKey = .{ .virtual = 1 };
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
    const space_key: SpaceKey = .{ .virtual = 1 };
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
    const source_key: SpaceKey = .{ .virtual = 1 };
    const target_key: SpaceKey = .{ .virtual = 2 };
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

    const transition = reduce(model, .{ .request_window_move = .{
        .window_id = 100,
        .target = catalog.find(target_key).?,
        .layout = testLayoutInsertion(.bsp),
        .should_move_native = false,
    } });
    try testing.expect(transition.model.window(100).?.space_key.eql(target_key));
    try testing.expect(!transition.model.layout.contains(source_key, 100));
    try testing.expect(transition.model.layout.contains(target_key, 100));
    try testing.expectEqual(@as(?WindowId, 100), transition.model.focusedWorkspaceWindow(2));
    try testing.expect(transition.model.retile_request.all_displays);
    try testing.expect(transition.effects[0].window_moved.should_hide);
}
