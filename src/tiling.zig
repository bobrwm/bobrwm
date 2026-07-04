const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

pub const bsp_mod = @import("tiling/bsp.zig");
pub const monocle_mod = @import("tiling/monocle.zig");

// ── Comptime interface validator ──────────────────────────────────────────────
//
// Adding a new tiling algorithm requires implementing these declarations.
// The comptime block below catches missing exports at compile time.

fn requireAlgoInterface(comptime M: type) void {
    if (!@hasDecl(M, "State"))
        @compileError("tiling algo " ++ @typeName(M) ++ " missing: State");
    const required_methods = [_][]const u8{
        "insert", "remove", "windowCount", "firstWid", "lastWid",
        "cycleFocus", "setActive", "replaceWid", "swapWids", "computeLayout",
    };
    for (required_methods) |name| {
        if (!@hasDecl(M.State, name))
            @compileError("tiling algo " ++ @typeName(M) ++ " State missing method: " ++ name);
    }
}

comptime {
    requireAlgoInterface(bsp_mod);
    requireAlgoInterface(monocle_mod);
}

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

pub const State = union(LayoutKind) {
    bsp: bsp_mod.State,
    monocle: monocle_mod.State,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bsp => |*s| s.deinit(allocator),
            .monocle => |*s| s.deinit(allocator),
        }
    }

    pub fn insert(self: *State, wid: WindowId, opts: InsertOptions, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            .bsp => |*s| try s.insert(wid, opts, allocator),
            .monocle => |*s| try s.insert(wid, allocator),
        }
    }

    pub fn remove(self: *State, wid: WindowId, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bsp => |*s| s.remove(wid, allocator),
            .monocle => |*s| s.remove(wid, allocator),
        }
    }

    pub fn windowCount(self: *const State) usize {
        return switch (self.*) {
            .bsp => |*s| s.windowCount(),
            .monocle => |*s| s.windowCount(),
        };
    }

    pub fn firstWid(self: *const State) ?WindowId {
        return switch (self.*) {
            .bsp => |*s| s.firstWid(),
            .monocle => |*s| s.firstWid(),
        };
    }

    pub fn lastWid(self: *const State) ?WindowId {
        return switch (self.*) {
            .bsp => |*s| s.lastWid(),
            .monocle => |*s| s.lastWid(),
        };
    }

    pub fn cycleFocus(self: *const State, wid: WindowId, forward: bool) ?WindowId {
        return switch (self.*) {
            .bsp => |*s| s.cycleFocus(wid, forward),
            .monocle => |*s| s.cycleFocus(wid, forward),
        };
    }

    pub fn setActive(self: *State, wid: WindowId) void {
        switch (self.*) {
            .bsp => |*s| s.setActive(wid),
            .monocle => |*s| s.setActive(wid),
        }
    }

    pub fn replaceWid(self: *State, old: WindowId, new: WindowId) bool {
        return switch (self.*) {
            .bsp => |*s| s.replaceWid(old, new),
            .monocle => |*s| s.replaceWid(old, new),
        };
    }

    pub fn swapWids(self: *State, a: WindowId, b: WindowId) bool {
        return switch (self.*) {
            .bsp => |*s| s.swapWids(a, b),
            .monocle => |*s| s.swapWids(a, b),
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
            .bsp => |*s| try s.computeLayout(frame, inner_gap, out, allocator),
            .monocle => |*s| try s.computeLayout(frame, inner_gap, out, allocator),
        }
    }
};

pub fn newState(kind: LayoutKind) State {
    return switch (kind) {
        .bsp => .{ .bsp = bsp_mod.State.init() },
        .monocle => .{ .monocle = monocle_mod.State.init() },
    };
}
