//! Fuzz properties for the BSP tiling algorithm.

const std = @import("std");
const tiling = @import("tiling");
const bsp = tiling.bsp_mod;

const Direction = bsp.Direction;
const Frame = @FieldType(bsp.LayoutEntry, "frame");
const InsertChild = bsp.InsertChild;
const LayoutEntry = bsp.LayoutEntry;
const Node = bsp.Node;
const SplitMode = bsp.SplitMode;
const State = bsp.State;
const WindowId = @FieldType(LayoutEntry, "wid");

const min_split_ratio: f64 = 0.1;
const max_split_ratio: f64 = 0.9;

const fuzz_window_slots: usize = 16;
const FuzzPresence = [fuzz_window_slots + 1]bool;

const FuzzOperation = enum {
    insert,
    remove,
    replace,
    swap,
    set_ratio,
    adjust_ratio,
    mirror,
    equalize,
    balance,
    rotate,
};

const FuzzAxis = enum {
    all,
    horizontal,
    vertical,
};

const FuzzRotation = enum {
    none,
    clockwise,
    reverse,
    counter_clockwise,
};

test "fuzz mutation sequences preserve BSP invariants" {
    try std.testing.fuzz({}, fuzzMutationSequence, .{});
}

fn fuzzMutationSequence(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const root_frame: Frame = .{ .x = 100, .y = 50, .width = 4096, .height = 2160 };

    var state = State.init();
    defer state.deinit(allocator);
    var expected: FuzzPresence = @splat(false);

    var step: usize = 0;
    while (step < 64 and !smith.eosWeightedSimple(8, 1)) : (step += 1) {
        switch (smith.value(FuzzOperation)) {
            .insert => {
                const wid = fuzzWindowId(smith);
                const index: usize = @intCast(wid);
                try state.insert(wid, .{
                    .split_mode = smith.value(SplitMode),
                    .child = smith.value(InsertChild),
                    .anchor_wid = if (smith.value(bool)) fuzzWindowId(smith) else null,
                    .root_frame = root_frame,
                    .inner_gap = 0,
                    .split_ratio = fuzzRatio(smith),
                }, allocator);
                expected[index] = true;
            },
            .remove => {
                const wid = fuzzWindowId(smith);
                state.remove(wid, allocator);
                expected[@intCast(wid)] = false;
            },
            .replace => try fuzzReplace(&state, &expected, smith),
            .swap => {
                const first = fuzzWindowId(smith);
                const second = fuzzWindowId(smith);
                const should_swap = first != second and
                    expected[@intCast(first)] and expected[@intCast(second)];
                if (state.swapWids(first, second) != should_swap) return error.SwapResultMismatch;
            },
            .set_ratio => {
                const wid = fuzzWindowId(smith);
                const should_update = expected[@intCast(wid)] and expectedCount(&expected) > 1;
                if (state.setParentRatio(wid, fuzzRatio(smith)) != should_update) {
                    return error.SetRatioResultMismatch;
                }
            },
            .adjust_ratio => {
                const wid = fuzzWindowId(smith);
                const should_update = expected[@intCast(wid)] and expectedCount(&expected) > 1;
                const raw_delta = smith.valueRangeAtMost(i8, -64, 64);
                const delta = @as(f64, @floatFromInt(raw_delta)) / 32.0;
                if (state.adjustParentRatio(wid, delta) != should_update) {
                    return error.AdjustRatioResultMismatch;
                }
            },
            .mirror => state.mirrorTree(smith.value(Direction)),
            .equalize => state.equalizeTree(fuzzAxis(smith), fuzzRatio(smith)),
            .balance => state.balanceTree(fuzzAxis(smith)),
            .rotate => state.rotateTree(switch (smith.value(FuzzRotation)) {
                .none => 0,
                .clockwise => 90,
                .reverse => 180,
                .counter_clockwise => 270,
            }),
        }
        try validateFuzzState(&state, &expected, root_frame, allocator);
    }
}

fn fuzzReplace(state: *State, expected: *FuzzPresence, smith: *std.testing.Smith) !void {
    const old_wid = fuzzWindowId(smith);
    const new_wid = fuzzWindowId(smith);
    const old_index: usize = @intCast(old_wid);
    const new_index: usize = @intCast(new_wid);

    // Production replacement only supplies an ID that is not already managed.
    if (expected[new_index]) return;

    const should_replace = old_wid != new_wid and expected[old_index];
    if (state.replaceWid(old_wid, new_wid) != should_replace) {
        return error.ReplaceResultMismatch;
    }
    if (should_replace) {
        expected[old_index] = false;
        expected[new_index] = true;
    }
}

fn fuzzWindowId(smith: *std.testing.Smith) WindowId {
    return smith.valueRangeAtMost(u8, 1, @intCast(fuzz_window_slots));
}

fn fuzzRatio(smith: *std.testing.Smith) f64 {
    return @as(f64, @floatFromInt(smith.value(u8))) / std.math.maxInt(u8);
}

fn fuzzAxis(smith: *std.testing.Smith) ?Direction {
    return switch (smith.value(FuzzAxis)) {
        .all => null,
        .horizontal => .horizontal,
        .vertical => .vertical,
    };
}

fn expectedCount(expected: *const FuzzPresence) usize {
    var count: usize = 0;
    for (expected[1..]) |present| {
        if (present) count += 1;
    }
    return count;
}

fn validateFuzzState(
    state: *const State,
    expected: *const FuzzPresence,
    root_frame: Frame,
    allocator: std.mem.Allocator,
) !void {
    var seen: FuzzPresence = @splat(false);
    var tree_count: usize = 0;
    if (state.root) |*root| {
        try validateFuzzNode(root, expected, &seen, &tree_count);
    }

    const count = expectedCount(expected);
    if (tree_count != count) return error.TreeCountMismatch;
    if (state.windowCount() != count) return error.WindowCountMismatch;
    if (!std.mem.eql(bool, expected, &seen)) return error.TreeMembershipMismatch;

    var layout: std.ArrayList(LayoutEntry) = .empty;
    defer layout.deinit(allocator);
    try layout.ensureTotalCapacity(allocator, count);
    state.computeLayout(root_frame, 0, &layout);
    if (layout.items.len != count) return error.LayoutCountMismatch;
    try validateFuzzLayout(state, layout.items, expected, root_frame);
}

fn validateFuzzNode(
    node: *const Node,
    expected: *const FuzzPresence,
    seen: *FuzzPresence,
    count: *usize,
) !void {
    const tolerance = 0.000001;

    switch (node.*) {
        .leaf => |leaf| {
            const index: usize = @intCast(leaf.wid);
            if (index == 0 or index >= expected.len) return error.InvalidLeafWindowId;
            if (!expected[index]) return error.UnexpectedLeafWindow;
            if (seen[index]) return error.DuplicateLeafWindow;
            seen[index] = true;
            count.* += 1;
        },
        .split => |split| {
            if (!std.math.isFinite(split.ratio)) return error.NonFiniteSplitRatio;
            if (split.ratio < min_split_ratio - tolerance) return error.SplitRatioBelowMinimum;
            if (split.ratio > max_split_ratio + tolerance) return error.SplitRatioAboveMaximum;
            try validateFuzzNode(&split.left, expected, seen, count);
            try validateFuzzNode(&split.right, expected, seen, count);
        },
    }
}

fn validateFuzzLayout(
    state: *const State,
    layout: []const LayoutEntry,
    expected: *const FuzzPresence,
    root_frame: Frame,
) !void {
    const tolerance = 0.000001;

    if (layout.len == 0) {
        if (state.firstWid() != null) return error.UnexpectedFirstWindow;
        if (state.lastWid() != null) return error.UnexpectedLastWindow;
        return;
    }

    const first_wid = state.firstWid() orelse return error.MissingFirstWindow;
    const last_wid = state.lastWid() orelse return error.MissingLastWindow;
    if (first_wid != layout[0].wid) return error.FirstWindowMismatch;
    if (last_wid != layout[layout.len - 1].wid) return error.LastWindowMismatch;
    var seen: FuzzPresence = @splat(false);
    for (layout) |entry| {
        const index: usize = @intCast(entry.wid);
        if (index == 0 or index >= expected.len) return error.InvalidLayoutWindowId;
        if (!expected[index]) return error.UnexpectedLayoutWindow;
        if (seen[index]) return error.DuplicateLayoutWindow;
        seen[index] = true;

        const frame = entry.frame;
        if (!std.math.isFinite(frame.x) or !std.math.isFinite(frame.y) or
            !std.math.isFinite(frame.width) or !std.math.isFinite(frame.height))
        {
            return error.NonFiniteLayoutFrame;
        }
        if (frame.width < 0 or frame.height < 0) return error.NegativeLayoutSize;
        if (frame.x < root_frame.x - tolerance) return error.LayoutBeforeRootX;
        if (frame.y < root_frame.y - tolerance) return error.LayoutBeforeRootY;
        if (frame.x + frame.width > root_frame.x + root_frame.width + tolerance) {
            return error.LayoutAfterRootX;
        }
        if (frame.y + frame.height > root_frame.y + root_frame.height + tolerance) {
            return error.LayoutAfterRootY;
        }
    }
    if (!std.mem.eql(bool, expected, &seen)) return error.LayoutMembershipMismatch;
}
