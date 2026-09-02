const std = @import("std");
const Window = @import("window.zig");
const space_mod = @import("space.zig");

pub const max_workspaces = 10;
pub const max_displays = 8;
pub const max_spaces = max_workspaces * max_displays;

/// Whether `actual` physically covers the complete region assigned by
/// `target`. Apps may clamp a tile larger than requested, which is safe for a
/// reveal; exact frame equality would unnecessarily hold the outgoing
/// workspace in front of an already covered display.
pub fn frameCoversTarget(actual: Window.Window.Frame, target: Window.Window.Frame) bool {
    const tolerance = Window.Window.Frame.tolerance;
    return actual.x <= target.x + tolerance and
        actual.y <= target.y + tolerance and
        actual.x + actual.width >= target.x + target.width - tolerance and
        actual.y + actual.height >= target.y + target.height - tolerance;
}

pub const Space = struct {
    ref: space_mod.Ref,

    pub fn init(ref: space_mod.Ref) Space {
        ref.assertValid();
        return .{ .ref = ref };
    }
};

pub const WorkspaceManager = struct {
    spaces: [max_spaces]Space,
    space_count: u8,

    pub fn init() WorkspaceManager {
        return .{
            .spaces = undefined,
            .space_count = 0,
        };
    }

    pub fn configure(self: *WorkspaceManager, refs: []const space_mod.Ref) void {
        std.debug.assert(refs.len <= self.spaces.len);
        self.space_count = @intCast(refs.len);
        for (refs, 0..) |ref, index| {
            self.spaces[index] = Space.init(ref);
        }
    }

    pub fn get(self: *WorkspaceManager, key: space_mod.Key) ?*Space {
        const index = self.indexOf(key) orelse return null;
        return &self.spaces[index];
    }

    pub fn indexOf(self: *const WorkspaceManager, key: space_mod.Key) ?usize {
        for (self.spaces[0..self.space_count], 0..) |space, index| {
            if (space.ref.key.eql(key)) return index;
        }
        return null;
    }
};

test "physical reveal accepts exact and clamped-larger frames only" {
    const t = std.testing;
    const target: Window.Window.Frame = .{ .x = 4, .y = 37, .width = 750, .height = 941 };

    try t.expect(frameCoversTarget(target, target));
    try t.expect(frameCoversTarget(.{ .x = 0, .y = 33, .width = 800, .height = 949 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 100, .y = 37, .width = 750, .height = 941 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 4, .y = 37, .width = 600, .height = 941 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 1507, .y = 977, .width = 750, .height = 941 }, target));
}
