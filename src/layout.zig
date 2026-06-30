const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

pub const Direction = enum {
    horizontal,
    vertical,
};

pub const LayoutKind = enum {
    bsp,
    monocle,
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

pub const InsertMode = enum {
    split,
    stack,
};

pub const InsertionPointPolicy = enum {
    focused,
    first,
    last,
    min_depth,
};

pub const InsertOptions = struct {
    mode: InsertMode = .split,
    split_mode: SplitMode,
    child: InsertChild,
    anchor_wid: ?WindowId = null,
    root_frame: ?Frame = null,
    inner_gap: f64 = 0,
    split_ratio: f64 = 0.5,
};

const min_split_ratio: f64 = 0.1;
const max_split_ratio: f64 = 0.9;

pub const Node = union(enum) {
    leaf: Leaf,
    split: *Split,

    pub const Leaf = struct {
        windows: std.ArrayListUnmanaged(WindowId) = .empty,

        pub fn initSingle(allocator: std.mem.Allocator, wid: WindowId) !Leaf {
            var leaf: Leaf = .{};
            try leaf.windows.append(allocator, wid);
            return leaf;
        }

        pub fn deinit(self: *Leaf, allocator: std.mem.Allocator) void {
            self.windows.deinit(allocator);
            self.* = .{};
        }

        pub fn activeWid(self: *const Leaf) WindowId {
            std.debug.assert(self.windows.items.len > 0);
            return self.windows.items[0];
        }

        pub fn contains(self: *const Leaf, wid: WindowId) bool {
            for (self.windows.items) |existing| {
                if (existing == wid) return true;
            }
            return false;
        }

        pub fn appendOnTop(self: *Leaf, allocator: std.mem.Allocator, wid: WindowId) !void {
            if (self.contains(wid)) return;
            try self.windows.ensureUnusedCapacity(allocator, 1);
            const len = self.windows.items.len;
            self.windows.items.len = len + 1;
            var index = len;
            while (index > 0) : (index -= 1) {
                self.windows.items[index] = self.windows.items[index - 1];
            }
            self.windows.items[0] = wid;
        }

        pub fn removeWid(self: *Leaf, wid: WindowId) bool {
            for (self.windows.items, 0..) |existing, index| {
                if (existing == wid) {
                    _ = self.windows.orderedRemove(index);
                    return true;
                }
            }
            return false;
        }

        pub fn promoteWid(self: *Leaf, wid: WindowId) bool {
            for (self.windows.items, 0..) |existing, index| {
                if (existing != wid) continue;
                if (index == 0) return true;

                const target = self.windows.items[index];
                var shift = index;
                while (shift > 0) : (shift -= 1) {
                    self.windows.items[shift] = self.windows.items[shift - 1];
                }
                self.windows.items[0] = target;
                return true;
            }
            return false;
        }

        pub fn count(self: *const Leaf) usize {
            return self.windows.items.len;
        }
    };
};

pub const Split = struct {
    direction: Direction,
    ratio: f64,
    left: Node,
    right: Node,
};

pub const LayoutEntry = struct {
    wid: WindowId,
    frame: Frame,
};

/// Insert a window into the BSP tree by splitting a selected leaf. If
/// `anchor_wid` is present, that matching leaf is split. Otherwise the
/// shallowest leaf is split (yabai-style minimum-depth insertion).
///
/// `InsertChild.second` keeps existing content as first child and places the
/// new window in second child (right/bottom). `InsertChild.first` does the
/// inverse (left/top).
/// If root is null, returns a new leaf node.
pub fn insertWindow(root: ?Node, wid: WindowId, options: InsertOptions, allocator: std.mem.Allocator) !Node {
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
        if (options.mode == .stack) {
            switch (target_leaf.?.*) {
                .leaf => |*leaf| {
                    try leaf.appendOnTop(allocator, wid);
                    return updated;
                },
                .split => unreachable,
            }
        }

        const split_direction = resolveSplitDirection(updated, target_leaf.?, options);
        const split_ratio = clampedSplitRatio(options.split_ratio);
        try splitLeafNode(target_leaf.?, wid, split_direction, options.child, split_ratio, allocator);
        return updated;
    }
    return .{ .leaf = try Node.Leaf.initSingle(allocator, wid) };
}

fn findLeafNode(node: *Node, target_wid: WindowId) ?*Node {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.contains(target_wid)) return node;
            return null;
        },
        .split => |split| {
            if (findLeafNode(&split.left, target_wid)) |leaf| return leaf;
            return findLeafNode(&split.right, target_wid);
        },
    }
}

fn resolveSplitDirection(root: Node, target_leaf: *Node, options: InsertOptions) Direction {
    const target_wid = switch (target_leaf.*) {
        .leaf => |leaf| leaf.activeWid(),
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

fn findLeafFrameByWindowId(node: Node, frame: Frame, inner_gap: f64, target_wid: WindowId) ?Frame {
    return switch (node) {
        .leaf => |leaf| if (leaf.contains(target_wid)) frame else null,
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

            if (findLeafFrameByWindowId(split.left, left_frame, inner_gap, target_wid)) |found| return found;
            return findLeafFrameByWindowId(split.right, right_frame, inner_gap, target_wid);
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
                    left_child = .{ .leaf = try Node.Leaf.initSingle(allocator, wid) };
                    right_child = .{ .leaf = leaf };
                },
                .second => {
                    left_child = .{ .leaf = leaf };
                    right_child = .{ .leaf = try Node.Leaf.initSingle(allocator, wid) };
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

pub fn firstLeafWid(root: Node) WindowId {
    return switch (root) {
        .leaf => |leaf| leaf.activeWid(),
        .split => |split| firstLeafWid(split.left),
    };
}

pub fn lastLeafWid(root: Node) WindowId {
    return switch (root) {
        .leaf => |leaf| leaf.activeWid(),
        .split => |split| lastLeafWid(split.right),
    };
}

pub fn setLeafActive(root: *Node, wid: WindowId) bool {
    switch (root.*) {
        .leaf => |*leaf| return leaf.promoteWid(wid),
        .split => |split| {
            if (setLeafActive(&split.left, wid)) return true;
            return setLeafActive(&split.right, wid);
        },
    }
}

pub fn stackNeighbor(root: Node, wid: WindowId, forward: bool) ?WindowId {
    return switch (root) {
        .leaf => |leaf| {
            if (!leaf.contains(wid)) return null;
            const count = leaf.count();
            if (count <= 1) return null;
            for (leaf.windows.items, 0..) |existing, index| {
                if (existing != wid) continue;
                const next_index = if (forward)
                    (index + 1) % count
                else if (index == 0) count - 1 else index - 1;
                return leaf.windows.items[next_index];
            }
            return null;
        },
        .split => |split| stackNeighbor(split.left, wid, forward) orelse stackNeighbor(split.right, wid, forward),
    };
}

pub fn adjustParentRatio(root: *Node, wid: WindowId, delta: f64) bool {
    const split = findParentSplit(root, wid) orelse return false;
    split.ratio = clampedSplitRatio(split.ratio + delta);
    return true;
}

pub fn setParentRatio(root: *Node, wid: WindowId, ratio: f64) bool {
    const split = findParentSplit(root, wid) orelse return false;
    split.ratio = clampedSplitRatio(ratio);
    return true;
}

pub fn mirror(root: *Node, axis: Direction) void {
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

pub fn equalize(root: *Node, axis: ?Direction, ratio: f64) void {
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

pub fn balance(root: *Node, axis: ?Direction) usize {
    switch (root.*) {
        .leaf => |leaf| return leaf.count(),
        .split => |split| {
            const left_count = balance(&split.left, axis);
            const right_count = balance(&split.right, axis);
            const total = left_count + right_count;
            if (total > 0 and (axis == null or split.direction == axis.?)) {
                split.ratio = clampedSplitRatio(@as(f64, @floatFromInt(left_count)) / @as(f64, @floatFromInt(total)));
            }
            return total;
        },
    }
}

pub fn rotate(root: *Node, degrees: i32) void {
    switch (root.*) {
        .leaf => {},
        .split => |split| {
            rotate(&split.left, degrees);
            rotate(&split.right, degrees);
            switch (degrees) {
                90 => {
                    // Swap children + invert ratio only for vertical splits.
                    // Horizontal splits just need the axis flip.
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
                    // Swap children + invert ratio only for horizontal splits.
                    // Vertical splits just need the axis flip.
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
            if (nodeContainsWid(split.left, wid)) {
                return findParentSplit(&split.left, wid) orelse split;
            }
            if (nodeContainsWid(split.right, wid)) {
                return findParentSplit(&split.right, wid) orelse split;
            }
            return null;
        },
    }
}

fn nodeContainsWid(node: Node, wid: WindowId) bool {
    return switch (node) {
        .leaf => |leaf| leaf.contains(wid),
        .split => |split| nodeContainsWid(split.left, wid) or nodeContainsWid(split.right, wid),
    };
}

pub fn windowCount(node: Node) usize {
    return switch (node) {
        .leaf => |leaf| leaf.count(),
        .split => |split| windowCount(split.left) + windowCount(split.right),
    };
}

/// Remove a window from the BSP tree. Returns the collapsed tree, or null if the
/// tree becomes empty.
pub fn removeWindow(root: Node, wid: WindowId, allocator: std.mem.Allocator) ?Node {
    return removeFrom(root, wid, allocator);
}

/// Swap two window IDs in-place inside an existing BSP tree.
///
/// Returns true when both windows were present and swapped.
pub fn swapWindowIds(root: *Node, first_wid: WindowId, second_wid: WindowId) bool {
    if (first_wid == second_wid) return false;
    var first_slot: ?LeafSlot = null;
    var second_slot: ?LeafSlot = null;
    findLeafSlot(root, first_wid, &first_slot);
    findLeafSlot(root, second_wid, &second_slot);
    if (first_slot == null or second_slot == null) return false;

    const first = first_slot.?;
    const second = second_slot.?;
    const first_id = first.leaf.windows.items[first.index];
    first.leaf.windows.items[first.index] = second.leaf.windows.items[second.index];
    second.leaf.windows.items[second.index] = first_id;
    return true;
}

/// Replace a window ID in-place inside an existing BSP tree, preserving the
/// leaf position. Used for tab-group leader succession: the new leader must
/// inherit the old leader's layout slot instead of being re-inserted.
///
/// Returns true when old_wid was present and replaced.
pub fn replaceWindowId(root: *Node, old_wid: WindowId, new_wid: WindowId) bool {
    std.debug.assert(old_wid != 0 and new_wid != 0);
    if (old_wid == new_wid) return false;

    var slot: ?LeafSlot = null;
    findLeafSlot(root, old_wid, &slot);
    const found = slot orelse return false;
    found.leaf.windows.items[found.index] = new_wid;
    return true;
}

const LeafSlot = struct {
    leaf: *Node.Leaf,
    index: usize,
};

fn findLeafSlot(node: *Node, wid: WindowId, out: *?LeafSlot) void {
    if (out.* != null) return;
    switch (node.*) {
        .leaf => |*leaf| {
            for (leaf.windows.items, 0..) |existing, index| {
                if (existing == wid) {
                    out.* = .{ .leaf = leaf, .index = index };
                    return;
                }
            }
        },
        .split => |split| {
            findLeafSlot(&split.left, wid, out);
            findLeafSlot(&split.right, wid, out);
        },
    }
}

fn removeFrom(node: Node, wid: WindowId, allocator: std.mem.Allocator) ?Node {
    switch (node) {
        .leaf => |leaf| {
            var updated_leaf = leaf;
            if (!updated_leaf.removeWid(wid)) return node;
            if (updated_leaf.count() == 0) {
                updated_leaf.deinit(allocator);
                return null;
            }
            return .{ .leaf = updated_leaf };
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

/// Walk the BSP tree and compute a frame for each leaf window within the given
/// bounding frame. `inner_gap` is the pixel spacing inserted between adjacent windows.
pub fn applyLayout(kind: LayoutKind, node: Node, frame: Frame, inner_gap: f64, output: *std.ArrayList(LayoutEntry), allocator: std.mem.Allocator) !void {
    std.debug.assert(inner_gap >= 0);
    switch (kind) {
        .bsp => try applyBsp(node, frame, inner_gap, output, allocator),
        .monocle => try applyMonocle(node, frame, output, allocator),
    }
}

fn applyBsp(node: Node, frame: Frame, inner_gap: f64, output: *std.ArrayList(LayoutEntry), allocator: std.mem.Allocator) !void {
    switch (node) {
        .leaf => |leaf| {
            var idx = leaf.windows.items.len;
            while (idx > 0) : (idx -= 1) {
                const wid = leaf.windows.items[idx - 1];
                try output.append(allocator, .{ .wid = wid, .frame = frame });
            }
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

            try applyBsp(split.left, left_frame, inner_gap, output, allocator);
            try applyBsp(split.right, right_frame, inner_gap, output, allocator);
        },
    }
}

fn applyMonocle(node: Node, frame: Frame, output: *std.ArrayList(LayoutEntry), allocator: std.mem.Allocator) !void {
    switch (node) {
        .leaf => |leaf| {
            var idx = leaf.windows.items.len;
            while (idx > 0) : (idx -= 1) {
                const wid = leaf.windows.items[idx - 1];
                try output.append(allocator, .{ .wid = wid, .frame = frame });
            }
        },
        .split => |split| {
            try applyMonocle(split.left, frame, output, allocator);
            try applyMonocle(split.right, frame, output, allocator);
        },
    }
}

/// Recursively free all Split nodes in the tree.
pub fn destroyTree(node: Node, allocator: std.mem.Allocator) void {
    switch (node) {
        .leaf => |leaf| {
            var mutable_leaf = leaf;
            mutable_leaf.deinit(allocator);
        },
        .split => |split| {
            destroyTree(split.left, allocator);
            destroyTree(split.right, allocator);
            allocator.destroy(split);
        },
    }
}

// Tests

test "replaceWindowId swaps a wid in place and preserves the leaf slot" {
    const allocator = std.testing.allocator;
    const options: InsertOptions = .{ .split_mode = .auto, .child = .second };

    var root: Node = try insertWindow(null, 1, options, allocator);
    root = try insertWindow(root, 2, options, allocator);
    defer destroyTree(root, allocator);

    try std.testing.expect(replaceWindowId(&root, 1, 9));
    try std.testing.expectEqual(@as(WindowId, 9), firstLeafWid(root));
    try std.testing.expectEqual(@as(WindowId, 2), lastLeafWid(root));

    // The old wid is gone; replacing it again must fail.
    try std.testing.expect(!replaceWindowId(&root, 1, 10));
}
