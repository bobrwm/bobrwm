//! Deterministic application state and transitions.

const std = @import("std");
const space_mod = @import("space.zig");

pub const max_displays = 8;
pub const max_spaces_per_display = 10;
pub const native_switch_timeout_ms: u64 = 3200;
pub const native_observation_delay_ms: u64 = 50;

pub const DisplayId = space_mod.DisplayId;
pub const NativeSpaceId = space_mod.NativeSpaceId;
pub const WorkspaceId = space_mod.WorkspaceId;
pub const SpaceKey = space_mod.Key;
pub const SpaceRef = space_mod.Ref;
pub const Epoch = u64;
pub const TimestampMs = u64;

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

pub const ObservationTimer = struct {
    epoch: Epoch,
    due_at_ms: TimestampMs,
};

pub const Model = struct {
    spaces: SpaceCatalog = .{},
    workspace_topology: WorkspaceTopology = .{},
    native_topology: NativeTopology = .{},
    pending_switch: ?PendingSwitch = null,
    queued_switch: ?SwitchRequest = null,
    observation_timer: ?ObservationTimer = null,
    next_epoch: Epoch = 1,

    pub fn isNativeSwitchPending(self: *const Model) bool {
        return self.pending_switch != null;
    }

    pub fn hasScheduledObservation(self: *const Model) bool {
        return self.observation_timer != null;
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
};

pub const SwitchFailureReason = enum {
    effect_failed,
    observation_unavailable,
    unexpected_space,
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
        },
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
            transition.model.native_topology = topology;
            syncNativeWorkspaceTopology(&transition.model);
            transition.model.pending_switch = null;
            transition.model.queued_switch = null;
            transition.model.observation_timer = null;
        },
        .request_native_switch => |request| reduceSwitchRequest(&transition, request),
        .native_space_changed => |at_ms| reduceSpaceChanged(&transition, at_ms),
        .observation_timer_fired => |timer| reduceObservationTimer(&transition, timer),
        .native_topology_observed => |observation| reduceTopologyObserved(&transition, observation),
        .native_topology_unavailable => |unavailable| reduceTopologyUnavailable(&transition, unavailable),
        .native_switch_effect_failed => |failure| reduceSwitchEffectFailed(&transition, failure),
    }

    assertModel(&transition.model);
    return transition;
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
    syncNativeWorkspaceTopology(&transition.model);

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

fn syncNativeWorkspaceTopology(model: *Model) void {
    const focused_display_id = model.workspace_topology.focused_display_id;
    var topology: WorkspaceTopology = .{};
    var catalog: SpaceCatalog = .{};
    for (model.native_topology.displays[0..model.native_topology.display_count]) |display| {
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
    model.spaces = catalog;
    model.workspace_topology = topology;
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
    schedulePendingObservation(&transition.model, pending, at_ms);
    transition.addEffect(.{ .switch_native_space = .{
        .request = current_request,
        .epoch = epoch,
    } });
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

test "switch request preserves observed Space until confirmation" {
    const testing = std.testing;
    const model = initializedModel(testTopology(101, null));

    const transition = reduce(model, switchRequest(&model, 1, 2, 100));

    try testing.expectEqual(@as(?WorkspaceId, 1), transition.model.observedWorkspace(1));
    try testing.expectEqual(@as(?WorkspaceId, 2), transition.model.desiredWorkspace(1));
    try testing.expect(transition.model.isNativeSwitchPending());
    try testing.expectEqual(@as(u8, 1), transition.effect_count);
    try testing.expectEqual(std.meta.Tag(Effect).switch_native_space, std.meta.activeTag(transition.effects[0]));
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
    try testing.expectEqual(std.meta.Tag(Effect).native_switch_failed, std.meta.activeTag(transition.effects[0]));
    try testing.expectEqual(SwitchFailureReason.unexpected_space, transition.effects[0].native_switch_failed.reason);
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
    const effect = transition.effects[0].switch_native_space;

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
