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

        var members: std.ArrayListUnmanaged(WindowId) = .{};
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
        try g.members.append(self.allocator, wid);
        try self.wid_to_group.put(self.allocator, wid, group_id);

        log.debug("added wid={d} to group {d} (now {d} members)", .{
            wid, group_id, g.members.items.len,
        });
    }

    /// Remove a window from its group.
    /// Dissolves the group if fewer than 2 members remain (returns remaining
    /// solo wid so the caller can treat it as standalone again).
    pub fn removeMember(self: *TabGroupManager, wid: WindowId) ?WindowId {
        const group_id = self.wid_to_group.get(wid) orelse return null;
        _ = self.wid_to_group.remove(wid);

        const g = self.groups.getPtr(group_id) orelse return null;

        for (g.members.items, 0..) |m, i| {
            if (m == wid) {
                _ = g.members.swapRemove(i);
                break;
            }
        }

        if (g.leader_wid == wid and g.members.items.len > 0) {
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
            return solo_wid;
        }

        return null;
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
