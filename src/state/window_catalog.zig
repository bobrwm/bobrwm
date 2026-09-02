//! Managed window identity, geometry, and native-tab membership.

const space_mod = @import("../space.zig");
const window_mod = @import("../window.zig");

pub const max_managed_windows = 1024;

pub const SpaceKey = space_mod.Key;
pub const WindowId = window_mod.WindowId;

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

    pub fn contains(self: *const WindowTabGroupObservation, window_id: WindowId) bool {
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

    pub fn put(self: *WindowCatalog, entry: ManagedWindow) bool {
        if (self.count == self.entries.len) return false;

        self.entries[self.count] = entry;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *WindowCatalog, window_id: WindowId) bool {
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

    pub fn detachTab(self: *WindowCatalog, window_id: WindowId) bool {
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

    pub fn assignSpace(self: *WindowCatalog, window_id: WindowId, space_key: SpaceKey) bool {
        const index = self.findIndex(window_id) orelse return false;
        const leader_window_id = self.entries[index].tab_leader_window_id;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.tab_leader_window_id == leader_window_id) entry.space_key = space_key;
        }
        return true;
    }

    pub fn update(self: *WindowCatalog, window: window_mod.Window) bool {
        const index = self.findIndex(window.wid) orelse return false;
        const entry = &self.entries[index];
        if (entry.process_id != window.pid) return false;
        entry.frame = window.frame;
        entry.is_fullscreen = window.is_fullscreen;
        entry.mode = window.mode;
        entry.float_frame = window.float_frame;
        return true;
    }

    pub fn swapSpaceKeys(self: *WindowCatalog, source_key: SpaceKey, target_key: SpaceKey) void {
        for (self.entries[0..self.count]) |*entry| {
            if (entry.space_key.eql(source_key)) {
                entry.space_key = target_key;
            } else if (entry.space_key.eql(target_key)) {
                entry.space_key = source_key;
            }
        }
    }

    pub fn replaceId(self: *WindowCatalog, old_window_id: WindowId, new_window_id: WindowId) bool {
        const index = self.findIndex(old_window_id) orelse return false;
        self.entries[index].window_id = new_window_id;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.tab_leader_window_id == old_window_id) entry.tab_leader_window_id = new_window_id;
        }
        return true;
    }

    pub fn observeTabGroup(self: *WindowCatalog, observation: WindowTabGroupObservation) void {
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
