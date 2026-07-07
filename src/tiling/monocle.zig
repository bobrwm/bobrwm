const std = @import("std");
const WindowId = @import("../window.zig").WindowId;
const Frame = @import("../window.zig").Window.Frame;
const bsp = @import("bsp.zig");
const LayoutEntry = bsp.LayoutEntry;
const InsertOptions = bsp.InsertOptions;

pub const State = struct {
    windows: std.ArrayListUnmanaged(WindowId) = .empty,

    pub fn init() State {
        return .{};
    }

    pub fn deinit(s: *State, allocator: std.mem.Allocator) void {
        s.windows.deinit(allocator);
    }

    // ── Common interface ──────────────────────────────────────────────────────

    pub fn insert(s: *State, wid: WindowId, _: InsertOptions, allocator: std.mem.Allocator) !void {
        for (s.windows.items) |w| if (w == wid) return;
        try s.windows.append(allocator, wid);
    }

    pub fn remove(s: *State, wid: WindowId, _: std.mem.Allocator) void {
        for (s.windows.items, 0..) |w, i| {
            if (w == wid) {
                _ = s.windows.swapRemove(i);
                return;
            }
        }
    }

    pub fn windowCount(s: *const State) usize {
        return s.windows.items.len;
    }

    pub fn firstWid(s: *const State) ?WindowId {
        return if (s.windows.items.len > 0) s.windows.items[0] else null;
    }

    pub fn lastWid(s: *const State) ?WindowId {
        return if (s.windows.items.len > 0) s.windows.items[s.windows.items.len - 1] else null;
    }

    pub fn cycleFocus(s: *const State, wid: WindowId, forward: bool) ?WindowId {
        const items = s.windows.items;
        if (items.len <= 1) return null;
        for (items, 0..) |w, i| {
            if (w != wid) continue;
            const next = if (forward)
                (i + 1) % items.len
            else if (i == 0) items.len - 1 else i - 1;
            return items[next];
        }
        return null;
    }

    pub fn setActive(s: *State, wid: WindowId) void {
        for (s.windows.items, 0..) |w, i| {
            if (w != wid) continue;
            if (i == 0) return;
            std.mem.rotate(WindowId, s.windows.items[0 .. i + 1], i);
            return;
        }
    }

    pub fn replaceWid(s: *State, old: WindowId, new: WindowId) bool {
        for (s.windows.items) |*w| {
            if (w.* == old) {
                w.* = new;
                return true;
            }
        }
        return false;
    }

    pub fn swapWids(s: *State, a: WindowId, b: WindowId) bool {
        if (a == b) return false;
        var ai: ?usize = null;
        var bi: ?usize = null;
        for (s.windows.items, 0..) |w, i| {
            if (w == a) ai = i;
            if (w == b) bi = i;
            if (ai != null and bi != null) break;
        }
        const ia = ai orelse return false;
        const ib = bi orelse return false;
        const tmp = s.windows.items[ia];
        s.windows.items[ia] = s.windows.items[ib];
        s.windows.items[ib] = tmp;
        return true;
    }

    /// Precondition: out must have unused capacity for at least windowCount() entries;
    /// this function appends without allocating.
    pub fn computeLayout(
        s: *const State,
        frame: Frame,
        _: f64,
        out: *std.ArrayList(LayoutEntry),
    ) void {
        std.debug.assert(out.capacity - out.items.len >= s.windows.items.len);
        for (s.windows.items) |wid| {
            out.appendAssumeCapacity(.{ .wid = wid, .frame = frame });
        }
    }
};
