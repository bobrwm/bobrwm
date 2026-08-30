//! Tab groups: the window manager's model of a native-tabbed window.
//!
//! Two systems live under this name and are deliberately kept apart:
//!
//!   detect.zig  decides which window ids form one tabbed window and which is
//!               on screen. Pure functions over a snapshot of OS facts.
//!   this file    holds the resulting groups and the vocabulary the rest of the
//!               window manager speaks: who owns the workspace slot (leader),
//!               what is on screen (active), what must be hidden from tiling
//!               and dimming (suppressed), and what a caller has to repair when
//!               a member goes away.
//!
//! Nothing here infers anything. Nothing in detect.zig holds state.

const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

const log = std.log.scoped(.tabgroup);

pub const detect = @import("tabgroup/detect.zig");

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
        return self.createGroupFromMembers(pid, &.{wid}, frame);
    }

    /// Create a new group with a leader and one additional member.
    pub fn createGroupWithMember(
        self: *TabGroupManager,
        pid: i32,
        leader_wid: WindowId,
        member_wid: WindowId,
        frame: Frame,
    ) !GroupId {
        if (leader_wid == member_wid) return error.DuplicateWindow;
        return self.createGroupFromMembers(pid, &.{ leader_wid, member_wid }, frame);
    }

    fn createGroupFromMembers(
        self: *TabGroupManager,
        pid: i32,
        initial_members: []const WindowId,
        frame: Frame,
    ) !GroupId {
        std.debug.assert(pid > 0);
        std.debug.assert(initial_members.len > 0);

        for (initial_members) |wid| {
            if (wid == 0) return error.InvalidWindow;
            if (self.wid_to_group.contains(wid)) return error.WindowAlreadyGrouped;
        }

        const id = self.next_id;
        if (id == std.math.maxInt(GroupId)) return error.GroupIdExhausted;

        var members: std.ArrayListUnmanaged(WindowId) = .empty;
        errdefer members.deinit(self.allocator);
        try members.ensureTotalCapacity(self.allocator, @max(4, initial_members.len));
        try self.groups.ensureUnusedCapacity(self.allocator, 1);
        try self.wid_to_group.ensureUnusedCapacity(self.allocator, @intCast(initial_members.len));

        for (initial_members) |wid| members.appendAssumeCapacity(wid);
        self.groups.putAssumeCapacityNoClobber(id, .{
            .id = id,
            .pid = pid,
            .leader_wid = initial_members[0],
            .active_wid = initial_members[initial_members.len - 1],
            .members = members,
            .canonical_frame = frame,
        });
        for (initial_members) |wid| self.wid_to_group.putAssumeCapacityNoClobber(wid, id);
        self.next_id += 1;

        log.info("created group {d} leader={d} pid={d}", .{ id, initial_members[0], pid });
        return id;
    }

    /// Add a window to an existing group.
    pub fn addMember(self: *TabGroupManager, group_id: GroupId, wid: WindowId) !void {
        if (wid == 0) return error.InvalidWindow;
        if (self.wid_to_group.get(wid)) |existing_group_id| {
            if (existing_group_id == group_id) return;
            return error.WindowAlreadyGrouped;
        }

        const g = self.groups.getPtr(group_id) orelse return error.GroupNotFound;
        for (g.members.items) |m| {
            if (m == wid) return;
        }

        try g.members.ensureUnusedCapacity(self.allocator, 1);
        try self.wid_to_group.ensureUnusedCapacity(self.allocator, 1);
        g.members.appendAssumeCapacity(wid);
        self.wid_to_group.putAssumeCapacityNoClobber(wid, group_id);

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

    /// Frame comparison is a detection concern; kept here as the name the
    /// window manager already calls.
    pub const framesMatch = detect.framesMatch;
};

// Tests

const testing = std.testing;

const test_frame: Frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var mgr = TabGroupManager.init(allocator);
    defer mgr.deinit();

    const gid = mgr.createGroupWithMember(100, 1, 2, test_frame) catch |err| {
        try testing.expectEqual(@as(u32, 0), mgr.groups.count());
        try testing.expectEqual(@as(u32, 0), mgr.wid_to_group.count());
        try testing.expectEqual(@as(GroupId, 1), mgr.next_id);
        return err;
    };

    mgr.addMember(gid, 3) catch |err| {
        const group = mgr.groupOf(1) orelse return error.TestUnexpectedResult;
        try testing.expectEqualSlices(WindowId, &.{ 1, 2 }, group.members.items);
        try testing.expect(mgr.groupOf(3) == null);
        try testing.expectEqual(@as(u32, 2), mgr.wid_to_group.count());
        return err;
    };

    const group = mgr.groupOf(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(WindowId, &.{ 1, 2, 3 }, group.members.items);
    try testing.expectEqual(gid, mgr.wid_to_group.get(3).?);
}

test "group mutations remain consistent across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAllocationFailures, .{});
}

test "a window cannot belong to two groups" {
    var mgr = TabGroupManager.init(testing.allocator);
    defer mgr.deinit();

    const first = try mgr.createGroup(100, 1, test_frame);
    const second = try mgr.createGroup(200, 2, test_frame);

    try testing.expectError(error.WindowAlreadyGrouped, mgr.addMember(second, 1));
    try testing.expectEqual(first, mgr.wid_to_group.get(1).?);
    try testing.expectEqualSlices(WindowId, &.{2}, mgr.groups.getPtr(second).?.members.items);
}

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

// Pull in the detection module so its tests run under this test root
// (`zig build test` compiles tabgroup.zig as the tabgroup-tests module).
test {
    _ = detect;
}
