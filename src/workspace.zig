const std = @import("std");
const Window = @import("window.zig");

pub const WorkspaceId = u8;
pub const max_workspaces = 10;
pub const max_displays = 8;

/// Bounded so focus bookkeeping never allocates. Entries beyond the cap are
/// the least recently focused windows; losing them only degrades the
/// focus-after-close fallback to the first-window heuristic.
pub const max_focus_history = 32;

pub const Workspace = struct {
    id: WorkspaceId,
    name: []const u8 = "",
    display_id: ?u32 = null,
    windows: std.ArrayList(Window.WindowId),
    focused_wid: ?Window.WindowId,
    /// Most recently focused windows, most recent last. Kept duplicate-free;
    /// `focused_wid` mirrors the top entry after every `recordFocus`.
    focus_history: [max_focus_history]Window.WindowId,
    focus_history_len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: WorkspaceId) Workspace {
        return .{
            .id = id,
            .windows = .empty,
            .focused_wid = null,
            .focus_history = @splat(0),
            .focus_history_len = 0,
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

    /// Replace a window ID in-place, preserving its position in the window
    /// list. Used for tab-group leader succession. Returns true when old_wid
    /// was present and replaced.
    pub fn replaceWindow(self: *Workspace, old_wid: Window.WindowId, new_wid: Window.WindowId) bool {
        std.debug.assert(old_wid != 0 and new_wid != 0);
        if (old_wid == new_wid) return false;

        for (self.windows.items) |*slot| {
            if (slot.* == old_wid) {
                slot.* = new_wid;
                if (self.focused_wid == old_wid) {
                    self.focused_wid = new_wid;
                }
                // Keep the history duplicate-free: if new_wid is already
                // recorded, drop the old entry instead of duplicating it.
                if (self.focusHistoryIndexOf(new_wid) != null) {
                    self.removeFromFocusHistory(old_wid);
                } else if (self.focusHistoryIndexOf(old_wid)) |idx| {
                    self.focus_history[idx] = new_wid;
                }
                return true;
            }
        }
        return false;
    }

    pub fn removeWindow(self: *Workspace, wid: Window.WindowId) void {
        for (self.windows.items, 0..) |existing, i| {
            if (existing == wid) {
                _ = self.windows.orderedRemove(i);
                self.removeFromFocusHistory(wid);
                if (self.focused_wid == wid) {
                    self.focused_wid = self.mostRecentLiveFocus() orelse
                        (if (self.windows.items.len > 0) self.windows.items[0] else null);
                }
                return;
            }
        }
    }

    /// Record wid as the most recently focused window. Moves an existing
    /// history entry to the top; drops the oldest entry when full.
    pub fn recordFocus(self: *Workspace, wid: Window.WindowId) void {
        std.debug.assert(wid != 0);
        std.debug.assert(self.focus_history_len <= max_focus_history);

        self.focused_wid = wid;
        self.removeFromFocusHistory(wid);
        if (self.focus_history_len == max_focus_history) {
            self.dropFocusHistoryAt(0);
        }
        self.focus_history[self.focus_history_len] = wid;
        self.focus_history_len += 1;
    }

    /// Most recent history entry still present in the window list. History is
    /// purged on removal, but membership is re-checked defensively because
    /// recordFocus does not require membership (focus events can race window
    /// adoption).
    fn mostRecentLiveFocus(self: *const Workspace) ?Window.WindowId {
        var i = self.focus_history_len;
        while (i > 0) {
            i -= 1;
            const candidate = self.focus_history[i];
            for (self.windows.items) |member| {
                if (member == candidate) return candidate;
            }
        }
        return null;
    }

    fn focusHistoryIndexOf(self: *const Workspace, wid: Window.WindowId) ?usize {
        for (self.focus_history[0..self.focus_history_len], 0..) |entry, i| {
            if (entry == wid) return i;
        }
        return null;
    }

    fn removeFromFocusHistory(self: *Workspace, wid: Window.WindowId) void {
        if (self.focusHistoryIndexOf(wid)) |idx| {
            self.dropFocusHistoryAt(idx);
        }
    }

    fn dropFocusHistoryAt(self: *Workspace, idx: usize) void {
        std.debug.assert(idx < self.focus_history_len);
        var i = idx;
        while (i + 1 < self.focus_history_len) : (i += 1) {
            self.focus_history[i] = self.focus_history[i + 1];
        }
        self.focus_history_len -= 1;
        self.focus_history[self.focus_history_len] = 0;
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

test "recordFocus tracks most recent and dedupes" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    ws.recordFocus(10);
    ws.recordFocus(20);
    ws.recordFocus(10);

    try t.expectEqual(@as(?Window.WindowId, 10), ws.focused_wid);
    try t.expectEqual(@as(usize, 2), ws.focus_history_len);
    try t.expectEqual(@as(Window.WindowId, 20), ws.focus_history[0]);
    try t.expectEqual(@as(Window.WindowId, 10), ws.focus_history[1]);
}

test "removeWindow falls back to most recently focused remaining window" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    // Windows added in order A, B, C; focused B, then C.
    try ws.addWindow(1);
    try ws.addWindow(2);
    try ws.addWindow(3);
    ws.recordFocus(2);
    ws.recordFocus(3);

    // Closing C must fall back to B (last focused), not A (first added).
    ws.removeWindow(3);
    try t.expectEqual(@as(?Window.WindowId, 2), ws.focused_wid);

    ws.removeWindow(2);
    try t.expectEqual(@as(?Window.WindowId, 1), ws.focused_wid);

    ws.removeWindow(1);
    try t.expectEqual(@as(?Window.WindowId, null), ws.focused_wid);
}

test "removeWindow without focus history falls back to first window" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    try ws.addWindow(1);
    try ws.addWindow(2);
    ws.focused_wid = 2; // simulate legacy state with no history

    ws.removeWindow(2);
    try t.expectEqual(@as(?Window.WindowId, 1), ws.focused_wid);
}

test "removeWindow of unfocused window keeps focus and purges history" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    try ws.addWindow(1);
    try ws.addWindow(2);
    ws.recordFocus(1);
    ws.recordFocus(2);

    ws.removeWindow(1);
    try t.expectEqual(@as(?Window.WindowId, 2), ws.focused_wid);
    try t.expectEqual(@as(usize, 1), ws.focus_history_len);
    try t.expectEqual(@as(Window.WindowId, 2), ws.focus_history[0]);
}

test "replaceWindow rewrites focus history in place" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    try ws.addWindow(1);
    try ws.addWindow(2);
    ws.recordFocus(1);
    ws.recordFocus(2);

    // Tab-group leader succession: 1 replaced by 9.
    try t.expect(ws.replaceWindow(1, 9));
    try t.expectEqual(@as(Window.WindowId, 9), ws.focus_history[0]);

    // Closing the focused window must fall back to the successor.
    ws.removeWindow(2);
    try t.expectEqual(@as(?Window.WindowId, 9), ws.focused_wid);
}

test "recordFocus drops oldest entry when history is full" {
    const t = std.testing;
    var ws = Workspace.init(t.allocator, 1);
    defer ws.deinit();

    var wid: Window.WindowId = 1;
    while (wid <= max_focus_history + 1) : (wid += 1) {
        ws.recordFocus(wid);
    }

    try t.expectEqual(@as(usize, max_focus_history), ws.focus_history_len);
    try t.expectEqual(@as(Window.WindowId, 2), ws.focus_history[0]);
    try t.expectEqual(
        @as(Window.WindowId, max_focus_history + 1),
        ws.focus_history[max_focus_history - 1],
    );
}
