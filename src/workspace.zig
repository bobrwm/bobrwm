const std = @import("std");
const Window = @import("window.zig");
const space_mod = @import("space.zig");

pub const WorkspaceId = space_mod.WorkspaceId;
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
    name: []const u8 = "",
    windows: std.ArrayList(Window.WindowId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ref: space_mod.Ref) Space {
        ref.assertValid();
        return .{
            .ref = ref,
            .windows = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Space) void {
        self.windows.deinit(self.allocator);
    }

    pub fn addWindow(self: *Space, wid: Window.WindowId) !void {
        for (self.windows.items) |existing| {
            if (existing == wid) return;
        }

        // Keep growth geometric to avoid frequent reallocations when many
        // windows are added in short bursts (app launch / display reconnect).
        if (self.windows.items.len == self.windows.capacity) {
            const current_capacity = self.windows.capacity;
            const next_capacity: usize = if (current_capacity < 8) 8 else current_capacity * 2;
            try self.windows.ensureTotalCapacity(self.allocator, next_capacity);
        }

        try self.windows.append(self.allocator, wid);
    }

    /// Reserve entries before a mutation that must commit across multiple
    /// containers. Capacity changes are harmless if a later reservation fails.
    pub fn ensureUnusedWindowCapacity(self: *Space, additional_count: usize) !void {
        try self.windows.ensureUnusedCapacity(self.allocator, additional_count);
    }

    /// Append after a matching `ensureUnusedWindowCapacity` call.
    pub fn addWindowAssumeCapacity(self: *Space, wid: Window.WindowId) void {
        std.debug.assert(wid != 0);
        for (self.windows.items) |existing| {
            std.debug.assert(existing != wid);
        }
        self.windows.appendAssumeCapacity(wid);
    }

    /// Replace a window ID in-place, preserving its position in the window
    /// list. Used for tab-group leader succession. Returns true when old_wid
    /// was present and replaced.
    pub fn replaceWindow(self: *Space, old_wid: Window.WindowId, new_wid: Window.WindowId) bool {
        std.debug.assert(old_wid != 0 and new_wid != 0);
        if (old_wid == new_wid) return false;

        for (self.windows.items) |*slot| {
            if (slot.* == old_wid) {
                slot.* = new_wid;
                return true;
            }
        }
        return false;
    }

    pub fn removeWindow(self: *Space, wid: Window.WindowId) void {
        for (self.windows.items, 0..) |existing, i| {
            if (existing == wid) {
                _ = self.windows.orderedRemove(i);
                return;
            }
        }
    }
};

pub const WorkspaceManager = struct {
    spaces: [max_spaces]Space,
    space_count: u8,
    workspace_count: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: u8) WorkspaceManager {
        const clamped: u8 = if (count == 0) max_workspaces else @min(count, max_workspaces);
        var wm: WorkspaceManager = .{
            .spaces = undefined,
            .space_count = clamped,
            .workspace_count = clamped,
            .allocator = allocator,
        };
        for (0..clamped) |i| {
            const workspace_id: WorkspaceId = @intCast(i + 1);
            wm.spaces[i] = Space.init(allocator, .{
                .key = .{ .virtual = workspace_id },
                .workspace_id = workspace_id,
                .display_id = 1,
            });
        }
        return wm;
    }

    pub fn deinit(self: *WorkspaceManager) void {
        for (self.spaces[0..self.space_count]) |*space| {
            space.deinit();
        }
    }

    pub fn configure(self: *WorkspaceManager, refs: []const space_mod.Ref) void {
        for (self.spaces[0..self.space_count]) |*space| {
            std.debug.assert(space.windows.items.len == 0);
            space.deinit();
        }

        std.debug.assert(refs.len <= self.spaces.len);
        self.space_count = @intCast(refs.len);
        for (refs, 0..) |ref, index| {
            self.spaces[index] = Space.init(self.allocator, ref);
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

    pub fn find(self: *WorkspaceManager, display_id: u32, workspace_id: WorkspaceId) ?*Space {
        for (self.spaces[0..self.space_count]) |*space| {
            if (space.ref.display_id == display_id and space.ref.workspace_id == workspace_id) return space;
        }
        return null;
    }
};

test "replace and remove preserve workspace window order" {
    const t = std.testing;
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
    defer ws.deinit();

    try ws.addWindow(1);
    try ws.addWindow(2);
    try ws.addWindow(3);
    try t.expect(ws.replaceWindow(2, 9));
    ws.removeWindow(1);

    try t.expectEqualSlices(Window.WindowId, &.{ 9, 3 }, ws.windows.items);
}

test "physical reveal accepts exact and clamped-larger frames only" {
    const t = std.testing;
    const target: Window.Window.Frame = .{ .x = 4, .y = 37, .width = 750, .height = 941 };

    try t.expect(frameCoversTarget(target, target));
    try t.expect(frameCoversTarget(.{ .x = 0, .y = 33, .width = 800, .height = 949 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 100, .y = 37, .width = 750, .height = 941 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 4, .y = 37, .width = 600, .height = 941 }, target));
    try t.expect(!frameCoversTarget(.{ .x = 1507, .y = 977, .width = 750, .height = 941 }, target));
}
