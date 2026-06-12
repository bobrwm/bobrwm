const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

const log = std.log.scoped(.tabgroup);

pub const GroupId = u32;

pub const TabGroup = struct {
    id: GroupId,
    pid: i32,
    leader_wid: WindowId,
    active_wid: WindowId,
    members: std.ArrayListUnmanaged(WindowId),
    canonical_frame: Frame,
};

pub const TabGroupManager = struct {
    groups: std.AutoHashMapUnmanaged(GroupId, TabGroup),
    wid_to_group: std.AutoHashMapUnmanaged(WindowId, GroupId),
    next_id: GroupId,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TabGroupManager {
        return .{
            .groups = .{},
            .wid_to_group = .{},
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabGroupManager) void {
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.members.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        self.wid_to_group.deinit(self.allocator);
    }

    /// Find a group matching pid + frame within tolerance.
    pub fn findGroupByFrame(self: *const TabGroupManager, pid: i32, frame: Frame) ?GroupId {
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            const g = entry.value_ptr;
            if (g.pid == pid and framesMatch(g.canonical_frame, frame)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    /// Create a new group. First member becomes leader + active.
    pub fn createGroup(self: *TabGroupManager, pid: i32, wid: WindowId, frame: Frame) !GroupId {
        const id = self.next_id;
        self.next_id += 1;

        var members: std.ArrayListUnmanaged(WindowId) = .empty;
        try members.ensureTotalCapacity(self.allocator, 4);
        try members.append(self.allocator, wid);

        try self.groups.put(self.allocator, id, .{
            .id = id,
            .pid = pid,
            .leader_wid = wid,
            .active_wid = wid,
            .members = members,
            .canonical_frame = frame,
        });
        try self.wid_to_group.put(self.allocator, wid, id);

        log.info("created group {d} leader={d} pid={d}", .{ id, wid, pid });
        return id;
    }

    /// Add a window to an existing group.
    pub fn addMember(self: *TabGroupManager, group_id: GroupId, wid: WindowId) !void {
        const g = self.groups.getPtr(group_id) orelse return;
        for (g.members.items) |m| {
            if (m == wid) return;
        }

        if (g.members.items.len == g.members.capacity) {
            const current_capacity = g.members.capacity;
            const next_capacity: usize = if (current_capacity < 4) 4 else current_capacity * 2;
            try g.members.ensureTotalCapacity(self.allocator, next_capacity);
        }

        try g.members.append(self.allocator, wid);
        try self.wid_to_group.put(self.allocator, wid, group_id);

        log.debug("added wid={d} to group {d} (now {d} members)", .{
            wid, group_id, g.members.items.len,
        });
    }

    /// Outcome of removing a window from its tab group. The leader is the
    /// group's only member registered in workspace window lists and the BSP
    /// layout, so callers must act on leadership changes or the surviving
    /// tabs become invisible to tiling.
    pub const RemoveResult = union(enum) {
        /// wid was not in a group, a non-leader member left a surviving
        /// group, or the group dissolved with no member left.
        none,
        /// The removed wid led a group that survives; payload is the new
        /// leader. Callers must hand the old leader's workspace/layout slot
        /// to the new leader.
        leader_changed: WindowId,
        /// The group dissolved leaving a single member; callers should
        /// restore it as a standalone window.
        dissolved_solo: WindowId,
    };

    /// Remove a window from its group.
    /// Dissolves the group if fewer than 2 members remain.
    pub fn removeMember(self: *TabGroupManager, wid: WindowId) RemoveResult {
        const group_id = self.wid_to_group.get(wid) orelse return .none;
        _ = self.wid_to_group.remove(wid);

        const g = self.groups.getPtr(group_id) orelse return .none;

        for (g.members.items, 0..) |m, i| {
            if (m == wid) {
                _ = g.members.swapRemove(i);
                break;
            }
        }

        const was_leader = g.leader_wid == wid;
        if (was_leader and g.members.items.len > 0) {
            g.leader_wid = g.members.items[0];
        }
        if (g.active_wid == wid and g.members.items.len > 0) {
            g.active_wid = g.members.items[0];
        }

        // Dissolve single-member groups — no longer a tab group
        if (g.members.items.len < 2) {
            var solo_wid: ?WindowId = null;
            if (g.members.items.len == 1) {
                solo_wid = g.members.items[0];
                _ = self.wid_to_group.remove(solo_wid.?);
            }
            g.members.deinit(self.allocator);
            _ = self.groups.remove(group_id);
            log.info("dissolved group {d}", .{group_id});
            if (solo_wid) |solo| return .{ .dissolved_solo = solo };
            return .none;
        }

        if (was_leader) {
            log.info("group {d} leader changed from {d} to {d}", .{
                group_id, wid, g.leader_wid,
            });
            return .{ .leader_changed = g.leader_wid };
        }
        return .none;
    }

    /// Get the group a window belongs to (read-only).
    pub fn groupOf(self: *const TabGroupManager, wid: WindowId) ?*const TabGroup {
        const gid = self.wid_to_group.get(wid) orelse return null;
        return self.groups.getPtr(gid);
    }

    /// Get the group a window belongs to (mutable).
    pub fn groupOfMut(self: *TabGroupManager, wid: WindowId) ?*TabGroup {
        const gid = self.wid_to_group.get(wid) orelse return null;
        return self.groups.getPtr(gid);
    }

    /// True if wid is in a group but is not the active (visible) tab.
    pub fn isSuppressed(self: *const TabGroupManager, wid: WindowId) bool {
        const gid = self.wid_to_group.get(wid) orelse return false;
        const g = self.groups.getPtr(gid) orelse return false;
        return g.active_wid != wid;
    }

    /// Set the active (visible) tab for the group containing wid.
    pub fn setActive(self: *TabGroupManager, wid: WindowId) void {
        const gid = self.wid_to_group.get(wid) orelse return;
        const g = self.groups.getPtr(gid) orelse return;
        g.active_wid = wid;
    }

    /// Update canonical frame for the group containing wid.
    pub fn updateFrame(self: *TabGroupManager, wid: WindowId, frame: Frame) void {
        const gid = self.wid_to_group.get(wid) orelse return;
        const g = self.groups.getPtr(gid) orelse return;
        g.canonical_frame = frame;
    }

    /// Resolve wid to the actual focus target.
    /// If wid is a tab group leader, returns the active tab.
    /// Otherwise returns the wid unchanged.
    pub fn resolveActive(self: *const TabGroupManager, wid: WindowId) WindowId {
        const gid = self.wid_to_group.get(wid) orelse return wid;
        const g = self.groups.getPtr(gid) orelse return wid;
        if (g.leader_wid == wid) return g.active_wid;
        return wid;
    }

    /// Resolve wid to its leader. If wid is in a group, returns the leader.
    /// Otherwise returns the wid unchanged.
    pub fn resolveLeader(self: *const TabGroupManager, wid: WindowId) WindowId {
        const gid = self.wid_to_group.get(wid) orelse return wid;
        const g = self.groups.getPtr(gid) orelse return wid;
        return g.leader_wid;
    }

    /// Check if two frames match within ±2px tolerance.
    pub fn framesMatch(a: Frame, b: Frame) bool {
        const tol: f64 = 2.0;
        return @abs(a.x - b.x) <= tol and
            @abs(a.y - b.y) <= tol and
            @abs(a.width - b.width) <= tol and
            @abs(a.height - b.height) <= tol;
    }
};

// Tests

const testing = std.testing;

const test_frame: Frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

test "removeMember hands leadership to a surviving member" {
    var mgr = TabGroupManager.init(testing.allocator);
    defer mgr.deinit();

    const gid = try mgr.createGroup(100, 1, test_frame);
    try mgr.addMember(gid, 2);
    try mgr.addMember(gid, 3);

    switch (mgr.removeMember(1)) {
        .leader_changed => |new_leader| {
            const g = mgr.groupOf(new_leader) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(new_leader, g.leader_wid);
            try testing.expectEqual(@as(usize, 2), g.members.items.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "removeMember dissolves a two-member group to a solo survivor" {
    var mgr = TabGroupManager.init(testing.allocator);
    defer mgr.deinit();

    const gid = try mgr.createGroup(100, 1, test_frame);
    try mgr.addMember(gid, 2);

    switch (mgr.removeMember(1)) {
        .dissolved_solo => |solo| {
            try testing.expectEqual(@as(WindowId, 2), solo);
            try testing.expect(mgr.groupOf(2) == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "removeMember returns none for a non-leader member" {
    var mgr = TabGroupManager.init(testing.allocator);
    defer mgr.deinit();

    const gid = try mgr.createGroup(100, 1, test_frame);
    try mgr.addMember(gid, 2);
    try mgr.addMember(gid, 3);

    switch (mgr.removeMember(2)) {
        .none => {
            const g = mgr.groupOf(1) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(WindowId, 1), g.leader_wid);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "removeMember returns none for an untracked window" {
    var mgr = TabGroupManager.init(testing.allocator);
    defer mgr.deinit();

    switch (mgr.removeMember(42)) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}
