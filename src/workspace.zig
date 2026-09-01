const std = @import("std");
const Window = @import("window.zig");
const space_mod = @import("space.zig");

pub const WorkspaceId = space_mod.WorkspaceId;
pub const max_workspaces = 10;
pub const max_displays = 8;
pub const max_spaces = max_workspaces * max_displays;

pub const FollowFocusAction = enum {
    ignore,
    defer_until_settled,
    switch_workspace,
};

/// Decide how a focus event should affect workspace visibility.
///
/// A transition remains active during its settle tail, after target focus has
/// already been accepted. Hidden-window AX events in that interval can still
/// be synthetic fallout from parking the old workspace, so they must wait for
/// frontmost-app validation rather than immediately reversing the transition.
pub fn followFocusAction(workspace_visible: bool, transition_active: bool) FollowFocusAction {
    if (workspace_visible) return .ignore;
    if (transition_active) return .defer_until_settled;
    return .switch_workspace;
}

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

/// Bounded so focus bookkeeping never allocates. Entries beyond the cap are
/// the least recently focused windows; losing them only degrades the
/// focus-after-close fallback to the first-window heuristic.
pub const max_focus_history = 32;

pub const Space = struct {
    ref: space_mod.Ref,
    name: []const u8 = "",
    windows: std.ArrayList(Window.WindowId),
    focused_wid: ?Window.WindowId,
    /// Most recently focused windows, most recent last. Kept duplicate-free;
    /// `focused_wid` mirrors the top entry after every `recordFocus`.
    focus_history: [max_focus_history]Window.WindowId,
    focus_history_len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ref: space_mod.Ref) Space {
        ref.assertValid();
        return .{
            .ref = ref,
            .windows = .empty,
            .focused_wid = null,
            .focus_history = @splat(0),
            .focus_history_len = 0,
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

    pub fn removeWindow(self: *Space, wid: Window.WindowId) void {
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
    pub fn recordFocus(self: *Space, wid: Window.WindowId) void {
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
    fn mostRecentLiveFocus(self: *const Space) ?Window.WindowId {
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

    fn focusHistoryIndexOf(self: *const Space, wid: Window.WindowId) ?usize {
        for (self.focus_history[0..self.focus_history_len], 0..) |entry, i| {
            if (entry == wid) return i;
        }
        return null;
    }

    fn removeFromFocusHistory(self: *Space, wid: Window.WindowId) void {
        if (self.focusHistoryIndexOf(wid)) |idx| {
            self.dropFocusHistoryAt(idx);
        }
    }

    fn dropFocusHistoryAt(self: *Space, idx: usize) void {
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

test "recordFocus tracks most recent and dedupes" {
    const t = std.testing;
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
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
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
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
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
    defer ws.deinit();

    try ws.addWindow(1);
    try ws.addWindow(2);
    ws.focused_wid = 2; // simulate legacy state with no history

    ws.removeWindow(2);
    try t.expectEqual(@as(?Window.WindowId, 1), ws.focused_wid);
}

test "removeWindow of unfocused window keeps focus and purges history" {
    const t = std.testing;
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
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
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
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
    var ws = Space.init(t.allocator, .{ .key = .{ .virtual = 1 }, .workspace_id = 1, .display_id = 1 });
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

test "follow focus defers hidden windows through the transition settle tail" {
    const t = std.testing;

    try t.expectEqual(FollowFocusAction.ignore, followFocusAction(true, true));
    try t.expectEqual(FollowFocusAction.defer_until_settled, followFocusAction(false, true));
    try t.expectEqual(FollowFocusAction.switch_workspace, followFocusAction(false, false));
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
