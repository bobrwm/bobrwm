const std = @import("std");
const Window = @import("window.zig");

pub const WorkspaceId = u8;
pub const max_workspaces = 10;
pub const max_displays = 8;

pub const Workspace = struct {
    id: WorkspaceId,
    name: []const u8 = "",
    display_id: ?u32 = null,
    windows: std.ArrayList(Window.WindowId),
    focused_wid: ?Window.WindowId,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: WorkspaceId) Workspace {
        return .{
            .id = id,
            .windows = .{},
            .focused_wid = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit(self.allocator);
    }

    pub fn addWindow(self: *Workspace, wid: Window.WindowId) !void {
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

    pub fn removeWindow(self: *Workspace, wid: Window.WindowId) void {
        for (self.windows.items, 0..) |existing, i| {
            if (existing == wid) {
                _ = self.windows.orderedRemove(i);
                if (self.focused_wid == wid) {
                    self.focused_wid = if (self.windows.items.len > 0) self.windows.items[0] else null;
                }
                return;
            }
        }
    }
};

pub const WorkspaceManager = struct {
    workspaces: [max_workspaces]Workspace,
    active_ids_by_display: [max_displays]WorkspaceId,
    focused_display_slot: usize,
    workspace_count: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: u8) WorkspaceManager {
        const clamped: u8 = if (count == 0) max_workspaces else @min(count, max_workspaces);
        var wm: WorkspaceManager = .{
            .workspaces = undefined,
            .active_ids_by_display = blk: {
                var ids: [max_displays]WorkspaceId = undefined;
                for (0..max_displays) |i| {
                    ids[i] = @intCast(i + 1);
                }
                break :blk ids;
            },
            .focused_display_slot = 0,
            .workspace_count = clamped,
            .allocator = allocator,
        };
        for (0..max_workspaces) |i| {
            wm.workspaces[i] = Workspace.init(allocator, @intCast(i + 1));
        }
        return wm;
    }

    pub fn deinit(self: *WorkspaceManager) void {
        for (&self.workspaces) |*ws| {
            ws.deinit();
        }
    }

    pub fn active(self: *WorkspaceManager) *Workspace {
        const active_id = self.active_ids_by_display[self.focused_display_slot];
        std.debug.assert(active_id > 0 and active_id <= max_workspaces);
        return &self.workspaces[active_id - 1];
    }

    pub fn activeIdForDisplaySlot(self: *const WorkspaceManager, display_slot: usize) WorkspaceId {
        std.debug.assert(display_slot < max_displays);
        const active_id = self.active_ids_by_display[display_slot];
        std.debug.assert(active_id > 0 and active_id <= self.workspace_count);
        return active_id;
    }

    pub fn setActiveForDisplaySlot(self: *WorkspaceManager, display_slot: usize, workspace_id: WorkspaceId) void {
        std.debug.assert(display_slot < max_displays);
        std.debug.assert(workspace_id > 0 and workspace_id <= self.workspace_count);
        self.active_ids_by_display[display_slot] = workspace_id;
    }

    pub fn get(self: *WorkspaceManager, id: WorkspaceId) ?*Workspace {
        if (id == 0 or id > self.workspace_count) return null;
        return &self.workspaces[id - 1];
    }
};
