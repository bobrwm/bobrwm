const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

pub const bsp_mod = @import("tiling/bsp.zig");
pub const monocle_mod = @import("tiling/monocle.zig");

// ── Re-exports ────────────────────────────────────────────────────────────────

pub const LayoutEntry = bsp_mod.LayoutEntry;
pub const InsertOptions = bsp_mod.InsertOptions;
pub const InsertionPointPolicy = bsp_mod.InsertionPointPolicy;
pub const SplitMode = bsp_mod.SplitMode;
pub const InsertChild = bsp_mod.InsertChild;
pub const Direction = bsp_mod.Direction;

// ── Layout algorithm selection ────────────────────────────────────────────────

pub const LayoutKind = enum {
    bsp,
    monocle,
};

// ── Dispatch state ────────────────────────────────────────────────────────────
//
// Each method dispatches with `inline else`, which instantiates the call for
// every algorithm at compile time. A new algorithm therefore only needs a new
// union field here; a missing or mis-typed method on its State is a compile
// error at the dispatch site.

pub const State = union(LayoutKind) {
    bsp: bsp_mod.State,
    monocle: monocle_mod.State,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*s| s.deinit(allocator),
        }
    }

    pub fn insert(self: *State, wid: WindowId, opts: InsertOptions, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            inline else => |*s| try s.insert(wid, opts, allocator),
        }
    }

    pub fn remove(self: *State, wid: WindowId, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*s| s.remove(wid, allocator),
        }
    }

    pub fn windowCount(self: *const State) usize {
        return switch (self.*) {
            inline else => |*s| s.windowCount(),
        };
    }

    pub fn firstWid(self: *const State) ?WindowId {
        return switch (self.*) {
            inline else => |*s| s.firstWid(),
        };
    }

    pub fn lastWid(self: *const State) ?WindowId {
        return switch (self.*) {
            inline else => |*s| s.lastWid(),
        };
    }

    pub fn cycleFocus(self: *const State, wid: WindowId, forward: bool) ?WindowId {
        return switch (self.*) {
            inline else => |*s| s.cycleFocus(wid, forward),
        };
    }

    pub fn setActive(self: *State, wid: WindowId) void {
        switch (self.*) {
            inline else => |*s| s.setActive(wid),
        }
    }

    pub fn replaceWid(self: *State, old: WindowId, new: WindowId) bool {
        return switch (self.*) {
            inline else => |*s| s.replaceWid(old, new),
        };
    }

    pub fn swapWids(self: *State, a: WindowId, b: WindowId) bool {
        return switch (self.*) {
            inline else => |*s| s.swapWids(a, b),
        };
    }

    pub fn computeLayout(
        self: *const State,
        frame: Frame,
        inner_gap: f64,
        out: *std.ArrayList(LayoutEntry),
        allocator: std.mem.Allocator,
    ) !void {
        switch (self.*) {
            inline else => |*s| try s.computeLayout(frame, inner_gap, out, allocator),
        }
    }
};

pub fn newState(kind: LayoutKind) State {
    return switch (kind) {
        .bsp => .{ .bsp = bsp_mod.State.init() },
        .monocle => .{ .monocle = monocle_mod.State.init() },
    };
}

// Pull in the algorithm modules so their tests run under this test root
// (`zig build test` compiles tiling.zig as the tiling-tests module).
test {
    _ = bsp_mod;
    _ = monocle_mod;
}
