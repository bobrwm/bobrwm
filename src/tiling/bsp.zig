const std = @import("std");
const WindowId = @import("../window.zig").WindowId;
const Frame = @import("../window.zig").Window.Frame;

// ── Shared types ─────────────────────────────────────────────────────────────

pub const Direction = enum {
    horizontal,
    vertical,
};

pub const SplitMode = enum {
    auto,
    horizontal,
    vertical,
};

pub const InsertChild = enum {
    first,
    second,
};

pub const InsertionPointPolicy = enum {
    focused,
    first,
    last,
    min_depth,
};

pub const InsertOptions = struct {
    split_mode: SplitMode,
    child: InsertChild,
    anchor_wid: ?WindowId = null,
    root_frame: ?Frame = null,
    inner_gap: f64 = 0,
    split_ratio: f64 = 0.5,
};

pub const LayoutEntry = struct {
    wid: WindowId,
    frame: Frame,
};

// ── BSP tree types ────────────────────────────────────────────────────────────

const min_split_ratio: f64 = 0.1;
const max_split_ratio: f64 = 0.9;

pub const Node = union(enum) {
    leaf: Leaf,
    split: *Split,

    pub const Leaf = struct {
        wid: WindowId,
    };
};

pub const Split = struct {
    direction: Direction,
    ratio: f64,
    left: Node,
    right: Node,
};

// ── State ─────────────────────────────────────────────────────────────────────

pub const State = struct {
    root: ?Node = null,

    pub fn init() State {
        return .{};
    }

    pub fn deinit(s: *State, allocator: std.mem.Allocator) void {
        if (s.root) |*root| destroyTree(root, allocator);
        s.root = null;
    }

    // ── Common interface ──────────────────────────────────────────────────────

    pub fn insert(s: *State, wid: WindowId, opts: InsertOptions, allocator: std.mem.Allocator) !void {
        s.root = try insertWindow(s.root, wid, opts, allocator);
    }

    pub fn remove(s: *State, wid: WindowId, allocator: std.mem.Allocator) void {
        const root = s.root orelse return;
        s.root = removeFrom(root, wid, allocator);
    }

    pub fn windowCount(s: *const State) usize {
        return if (s.root) |*root| windowCountTree(root) else 0;
    }

    pub fn firstWid(s: *const State) ?WindowId {
        return if (s.root) |*root| firstLeafWid(root) else null;
    }

    pub fn lastWid(s: *const State) ?WindowId {
        return if (s.root) |*root| lastLeafWid(root) else null;
    }

    pub fn cycleFocus(_: *const State, _: WindowId, _: bool) ?WindowId {
        return null;
    }

    pub fn setActive(_: *State, _: WindowId) void {}

    pub fn replaceWid(s: *State, old: WindowId, new: WindowId) bool {
        return if (s.root) |*root| replaceWindowId(root, old, new) else false;
    }

    pub fn swapWids(s: *State, a: WindowId, b: WindowId) bool {
        return if (s.root) |*root| swapWindowIds(root, a, b) else false;
    }

    /// Precondition: out must have unused capacity for at least windowCount() entries;
    /// this function appends without allocating.
    pub fn computeLayout(
        s: *const State,
        frame: Frame,
        inner_gap: f64,
        out: *std.ArrayList(LayoutEntry),
    ) void {
        std.debug.assert(out.capacity - out.items.len >= s.windowCount());
        if (s.root) |*root| applyBsp(root, frame, inner_gap, out);
    }

    // ── BSP-only operations ───────────────────────────────────────────────────

    pub fn adjustParentRatio(s: *State, wid: WindowId, delta: f64) bool {
        return if (s.root) |*root| adjustParentRatioFn(root, wid, delta) else false;
    }

    pub fn setParentRatio(s: *State, wid: WindowId, ratio: f64) bool {
        return if (s.root) |*root| setParentRatioFn(root, wid, ratio) else false;
    }

    pub fn mirrorTree(s: *State, axis: Direction) void {
        if (s.root) |*root| mirror(root, axis);
    }

    pub fn equalizeTree(s: *State, axis: ?Direction, ratio: f64) void {
        if (s.root) |*root| equalize(root, axis, ratio);
    }

    pub fn balanceTree(s: *State, axis: ?Direction) void {
        if (s.root) |*root| _ = balance(root, axis);
    }

    pub fn rotateTree(s: *State, degrees: i32) void {
        if (s.root) |*root| rotate(root, degrees);
    }
};

// ── Tree insertion ────────────────────────────────────────────────────────────

fn insertWindow(root: ?Node, wid: WindowId, options: InsertOptions, allocator: std.mem.Allocator) !Node {
    if (root) |r| {
        var updated = r;
        var target_leaf: ?*Node = null;
        if (options.anchor_wid) |target_wid| {
            target_leaf = findLeafNode(&updated, target_wid);
        }

        if (target_leaf == null) {
            var shallowest_depth: usize = std.math.maxInt(usize);
            findShallowestLeaf(&updated, 0, &target_leaf, &shallowest_depth);
        }
        std.debug.assert(target_leaf != null);

        const split_direction = resolveSplitDirection(&updated, target_leaf.?, options);
        const split_ratio = clampedSplitRatio(options.split_ratio);
        try splitLeafNode(target_leaf.?, wid, split_direction, options.child, split_ratio, allocator);
        return updated;
    }
    return .{ .leaf = .{ .wid = wid } };
}

fn findLeafNode(node: *Node, target_wid: WindowId) ?*Node {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.wid == target_wid) return node;
            return null;
        },
        .split => |split| {
            if (findLeafNode(&split.left, target_wid)) |leaf| return leaf;
            return findLeafNode(&split.right, target_wid);
        },
    }
}

fn resolveSplitDirection(root: *const Node, target_leaf: *Node, options: InsertOptions) Direction {
    const target_wid = switch (target_leaf.*) {
        .leaf => |leaf| leaf.wid,
        .split => unreachable,
    };
    switch (options.split_mode) {
        .horizontal => return .horizontal,
        .vertical => return .vertical,
        .auto => {
            std.debug.assert(options.inner_gap >= 0);
            const root_frame = options.root_frame orelse return .horizontal;
            const target_frame = findLeafFrameByWindowId(root, root_frame, options.inner_gap, target_wid) orelse return .horizontal;
            return if (target_frame.width >= target_frame.height) .horizontal else .vertical;
        },
    }
}

fn findLeafFrameByWindowId(node: *const Node, frame: Frame, inner_gap: f64, target_wid: WindowId) ?Frame {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.wid == target_wid) frame else null,
        .split => |split| {
            const half_gap = inner_gap / 2.0;
            var left_frame = frame;
            var right_frame = frame;

            switch (split.direction) {
                .horizontal => {
                    const left_width = frame.width * split.ratio;
                    left_frame.width = left_width - half_gap;
                    right_frame.x = frame.x + left_width + half_gap;
                    right_frame.width = frame.width - left_width - half_gap;
                },
                .vertical => {
                    const top_height = frame.height * split.ratio;
                    left_frame.height = top_height - half_gap;
                    right_frame.y = frame.y + top_height + half_gap;
                    right_frame.height = frame.height - top_height - half_gap;
                },
            }

            if (findLeafFrameByWindowId(&split.left, left_frame, inner_gap, target_wid)) |found| return found;
            return findLeafFrameByWindowId(&split.right, right_frame, inner_gap, target_wid);
        },
    };
}

fn findShallowestLeaf(node: *Node, depth: usize, out_leaf: *?*Node, out_depth: *usize) void {
    switch (node.*) {
        .leaf => {
            if (depth < out_depth.*) {
                out_leaf.* = node;
                out_depth.* = depth;
            }
        },
        .split => |split| {
            findShallowestLeaf(&split.left, depth + 1, out_leaf, out_depth);
            findShallowestLeaf(&split.right, depth + 1, out_leaf, out_depth);
        },
    }
}

fn splitLeafNode(node: *Node, wid: WindowId, split_direction: Direction, child: InsertChild, split_ratio: f64, allocator: std.mem.Allocator) !void {
    std.debug.assert(split_ratio >= min_split_ratio and split_ratio <= max_split_ratio);
    switch (node.*) {
        .leaf => |leaf| {
            var left_child: Node = undefined;
            var right_child: Node = undefined;
            switch (child) {
                .first => {
                    left_child = .{ .leaf = .{ .wid = wid } };
                    right_child = .{ .leaf = leaf };
                },
                .second => {
                    left_child = .{ .leaf = leaf };
                    right_child = .{ .leaf = .{ .wid = wid } };
                },
            }
            const split = try allocator.create(Split);
            split.* = .{
                .direction = split_direction,
                .ratio = split_ratio,
                .left = left_child,
                .right = right_child,
            };
            node.* = .{ .split = split };
        },
        .split => unreachable,
    }
}

fn clampedSplitRatio(value: f64) f64 {
    return std.math.clamp(value, min_split_ratio, max_split_ratio);
}

// ── Tree queries ──────────────────────────────────────────────────────────────

fn firstLeafWid(root: *const Node) WindowId {
    return switch (root.*) {
        .leaf => |leaf| leaf.wid,
        .split => |split| firstLeafWid(&split.left),
    };
}

fn lastLeafWid(root: *const Node) WindowId {
    return switch (root.*) {
        .leaf => |leaf| leaf.wid,
        .split => |split| lastLeafWid(&split.right),
    };
}

fn adjustParentRatioFn(root: *Node, wid: WindowId, delta: f64) bool {
    const split = findParentSplit(root, wid) orelse return false;
    split.ratio = clampedSplitRatio(split.ratio + delta);
    return true;
}

fn setParentRatioFn(root: *Node, wid: WindowId, ratio: f64) bool {
    const split = findParentSplit(root, wid) orelse return false;
    split.ratio = clampedSplitRatio(ratio);
    return true;
}

fn mirror(root: *Node, axis: Direction) void {
    switch (root.*) {
        .leaf => {},
        .split => |split| {
            mirror(&split.left, axis);
            mirror(&split.right, axis);
            if (split.direction == axis) {
                const tmp = split.left;
                split.left = split.right;
                split.right = tmp;
            }
        },
    }
}

fn equalize(root: *Node, axis: ?Direction, ratio: f64) void {
    const clamped = clampedSplitRatio(ratio);
    switch (root.*) {
        .leaf => {},
        .split => |split| {
            equalize(&split.left, axis, clamped);
            equalize(&split.right, axis, clamped);
            if (axis == null or split.direction == axis.?) {
                split.ratio = clamped;
            }
        },
    }
}

fn balance(root: *Node, axis: ?Direction) usize {
    switch (root.*) {
        .leaf => return 1,
        .split => |split| {
            const left_count = balance(&split.left, axis);
            const right_count = balance(&split.right, axis);
            const total = left_count + right_count;
            if (axis == null or split.direction == axis.?) {
                split.ratio = clampedSplitRatio(@as(f64, @floatFromInt(left_count)) / @as(f64, @floatFromInt(total)));
            }
            return total;
        },
    }
}

fn rotate(root: *Node, degrees: i32) void {
    switch (root.*) {
        .leaf => {},
        .split => |split| {
            rotate(&split.left, degrees);
            rotate(&split.right, degrees);
            switch (degrees) {
                90 => {
                    if (split.direction == .vertical) {
                        const tmp = split.left;
                        split.left = split.right;
                        split.right = tmp;
                        split.ratio = 1.0 - split.ratio;
                    }
                    split.direction = toggleDirection(split.direction);
                },
                180 => {
                    const tmp = split.left;
                    split.left = split.right;
                    split.right = tmp;
                    split.ratio = 1.0 - split.ratio;
                },
                270 => {
                    if (split.direction == .horizontal) {
                        const tmp = split.left;
                        split.left = split.right;
                        split.right = tmp;
                        split.ratio = 1.0 - split.ratio;
                    }
                    split.direction = toggleDirection(split.direction);
                },
                else => {},
            }
        },
    }
}

fn toggleDirection(direction: Direction) Direction {
    return switch (direction) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };
}

fn findParentSplit(node: *Node, wid: WindowId) ?*Split {
    switch (node.*) {
        .leaf => return null,
        .split => |split| {
            if (nodeContainsWid(&split.left, wid)) {
                return findParentSplit(&split.left, wid) orelse split;
            }
            if (nodeContainsWid(&split.right, wid)) {
                return findParentSplit(&split.right, wid) orelse split;
            }
            return null;
        },
    }
}

fn nodeContainsWid(node: *const Node, wid: WindowId) bool {
    return switch (node.*) {
        .leaf => |leaf| leaf.wid == wid,
        .split => |split| nodeContainsWid(&split.left, wid) or nodeContainsWid(&split.right, wid),
    };
}

fn windowCountTree(node: *const Node) usize {
    return switch (node.*) {
        .leaf => 1,
        .split => |split| windowCountTree(&split.left) + windowCountTree(&split.right),
    };
}

fn swapWindowIds(root: *Node, first_wid: WindowId, second_wid: WindowId) bool {
    if (first_wid == second_wid) return false;
    const a = findLeafPtr(root, first_wid) orelse return false;
    const b = findLeafPtr(root, second_wid) orelse return false;
    const tmp = a.wid;
    a.wid = b.wid;
    b.wid = tmp;
    return true;
}

fn replaceWindowId(root: *Node, old_wid: WindowId, new_wid: WindowId) bool {
    std.debug.assert(old_wid != 0 and new_wid != 0);
    if (old_wid == new_wid) return false;
    const leaf = findLeafPtr(root, old_wid) orelse return false;
    leaf.wid = new_wid;
    return true;
}

fn findLeafPtr(node: *Node, wid: WindowId) ?*Node.Leaf {
    switch (node.*) {
        .leaf => |*leaf| return if (leaf.wid == wid) leaf else null,
        .split => |split| {
            if (findLeafPtr(&split.left, wid)) |l| return l;
            return findLeafPtr(&split.right, wid);
        },
    }
}

fn removeFrom(node: Node, wid: WindowId, allocator: std.mem.Allocator) ?Node {
    switch (node) {
        .leaf => |leaf| {
            if (leaf.wid != wid) return node;
            return null;
        },
        .split => |split| {
            const left_result = removeFrom(split.left, wid, allocator);
            const right_result = removeFrom(split.right, wid, allocator);

            if (left_result == null and right_result == null) {
                allocator.destroy(split);
                return null;
            }

            if (left_result == null) {
                const result = right_result.?;
                allocator.destroy(split);
                return result;
            }

            if (right_result == null) {
                const result = left_result.?;
                allocator.destroy(split);
                return result;
            }

            split.left = left_result.?;
            split.right = right_result.?;
            return node;
        },
    }
}

fn applyBsp(node: *const Node, frame: Frame, inner_gap: f64, output: *std.ArrayList(LayoutEntry)) void {
    switch (node.*) {
        .leaf => |leaf| {
            output.appendAssumeCapacity(.{ .wid = leaf.wid, .frame = frame });
        },
        .split => |split| {
            const half_gap = inner_gap / 2.0;
            var left_frame = frame;
            var right_frame = frame;

            switch (split.direction) {
                .horizontal => {
                    const left_width = frame.width * split.ratio;
                    left_frame.width = left_width - half_gap;
                    right_frame.x = frame.x + left_width + half_gap;
                    right_frame.width = frame.width - left_width - half_gap;
                },
                .vertical => {
                    const top_height = frame.height * split.ratio;
                    left_frame.height = top_height - half_gap;
                    right_frame.y = frame.y + top_height + half_gap;
                    right_frame.height = frame.height - top_height - half_gap;
                },
            }

            applyBsp(&split.left, left_frame, inner_gap, output);
            applyBsp(&split.right, right_frame, inner_gap, output);
        },
    }
}

fn destroyTree(node: *const Node, allocator: std.mem.Allocator) void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
            destroyTree(&split.left, allocator);
            destroyTree(&split.right, allocator);
            allocator.destroy(split);
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "replaceWid swaps a wid in place and preserves the leaf slot" {
    const allocator = std.testing.allocator;
    const options: InsertOptions = .{ .split_mode = .auto, .child = .second };

    var s = State.init();
    try s.insert(1, options, allocator);
    try s.insert(2, options, allocator);
    defer s.deinit(allocator);

    try std.testing.expect(s.replaceWid(1, 9));
    try std.testing.expectEqual(@as(WindowId, 9), s.firstWid().?);
    try std.testing.expectEqual(@as(WindowId, 2), s.lastWid().?);

    try std.testing.expect(!s.replaceWid(1, 10));
}
