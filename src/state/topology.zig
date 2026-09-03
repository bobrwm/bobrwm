//! Logical workspace placement and native Space topology.

const std = @import("std");
const space_mod = @import("../space.zig");

pub const max_displays = 8;
pub const max_spaces_per_display = 10;

pub const DisplayId = space_mod.DisplayId;
pub const NativeSpaceId = space_mod.NativeSpaceId;
pub const WorkspaceId = space_mod.WorkspaceId;
pub const SpaceKey = space_mod.Key;
pub const SpaceRef = space_mod.Ref;

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

    pub fn setDisplay(self: *SpaceCatalog, key: SpaceKey, display_id: DisplayId) bool {
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

    pub fn swapWorkspacePlacements(self: *NativeTopology, source_key: SpaceKey, target_key: SpaceKey) bool {
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
    if (preserveStableNativeTopology(&observation, previous, workspace_count)) |topology| return topology;

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

fn preserveStableNativeTopology(
    observation: *const NativeTopologyObservation,
    previous: *const NativeTopology,
    workspace_count: u8,
) ?NativeTopology {
    if (observation.display_count != previous.display_count) return null;
    var topology: NativeTopology = .{};
    var mapped_count: u8 = 0;
    for (observation.displays[0..observation.display_count]) |display| {
        const previous_display = previous.findDisplay(display.display_id) orelse return null;
        const observed_space_id = if (previous_display.workspaceForSpace(display.observed_space_id) != null)
            display.observed_space_id
        else
            previous_display.observed_space_id;
        var mapped = DisplayTopology.init(display.display_id, observed_space_id);
        for (display.space_ids[0..display.space_count]) |space_id| {
            const workspace_id = previous_display.workspaceForSpace(space_id) orelse continue;
            mapped.addSpace(.{ .id = space_id, .workspace_id = workspace_id });
            mapped_count += 1;
        }
        topology.addDisplay(mapped);
    }
    if (mapped_count != workspace_count) return null;
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
