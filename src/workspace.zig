const std = @import("std");
const Window = @import("window.zig");

pub const WorkspaceId = u8;
pub const max_workspaces = 10;

pub const Workspace = struct {
    id: WorkspaceId,
    name: []const u8 = "",
    windows: std.ArrayList(Window.WindowId),
    focused_wid: ?Window.WindowId,
    is_visible: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: WorkspaceId) Workspace {
        return .{
            .id = id,
            .windows = .{},
            .focused_wid = null,
            .is_visible = id == 1,
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
        try self.windows.append(self.allocator, wid);
    }

    /// Replace a window ID in the window list. Used for tab switches.
    pub fn replaceWindow(self: *Workspace, old_wid: Window.WindowId, new_wid: Window.WindowId) void {
        for (self.windows.items) |*wid| {
            if (wid.* == old_wid) {
                wid.* = new_wid;
                if (self.focused_wid == old_wid) self.focused_wid = new_wid;
                return;
            }
        }
    }

    pub fn removeWindow(self: *Workspace, wid: Window.WindowId) void {
        for (self.windows.items, 0..) |existing, i| {
            if (existing == wid) {
                _ = self.windows.swapRemove(i);
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
    active_id: WorkspaceId,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkspaceManager {
        var wm: WorkspaceManager = .{
            .workspaces = undefined,
            .active_id = 1,
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
        return &self.workspaces[self.active_id - 1];
    }

    pub fn get(self: *WorkspaceManager, id: WorkspaceId) ?*Workspace {
        if (id == 0 or id > max_workspaces) return null;
        return &self.workspaces[id - 1];
    }
};
