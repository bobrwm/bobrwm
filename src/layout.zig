const std = @import("std");
const WindowId = @import("window.zig").WindowId;
const Frame = @import("window.zig").Window.Frame;

pub const Direction = enum {
    horizontal,
    vertical,
};

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

pub const LayoutEntry = struct {
    wid: WindowId,
    frame: Frame,
};

/// Insert a window into the BSP tree by splitting the first matching leaf (or the
/// rightmost leaf if no specific target). The existing leaf becomes the left child
/// of a new split; the new window becomes the right child.
/// If root is null, returns a new leaf node.
pub fn insertWindow(root: ?Node, wid: WindowId, dir: Direction, allocator: std.mem.Allocator) !Node {
    if (root) |r| {
        return insertInto(r, wid, dir, allocator);
    }
    return .{ .leaf = .{ .wid = wid } };
}

fn insertInto(node: Node, wid: WindowId, dir: Direction, allocator: std.mem.Allocator) !Node {
    switch (node) {
        .leaf => |leaf| {
            const split = try allocator.create(Split);
            split.* = .{
                .direction = dir,
                .ratio = 0.5,
                .left = .{ .leaf = leaf },
                .right = .{ .leaf = .{ .wid = wid } },
            };
            return .{ .split = split };
        },
        .split => |split| {
            const next_dir: Direction = switch (split.direction) {
                .horizontal => .vertical,
                .vertical => .horizontal,
            };
            split.right = try insertInto(split.right, wid, next_dir, allocator);
            return node;
        },
    }
}

/// Remove a window from the BSP tree. Returns the collapsed tree, or null if the
/// tree becomes empty.
pub fn removeWindow(root: Node, wid: WindowId, allocator: std.mem.Allocator) ?Node {
    return removeFrom(root, wid, allocator);
}

fn removeFrom(node: Node, wid: WindowId, allocator: std.mem.Allocator) ?Node {
    switch (node) {
        .leaf => |leaf| {
            if (leaf.wid == wid) return null;
            return node;
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
pub fn applyLayout(node: Node, frame: Frame, inner_gap: f64, output: *std.ArrayList(LayoutEntry), allocator: std.mem.Allocator) !void {
    switch (node) {
        .leaf => |leaf| {
            try output.append(allocator, .{ .wid = leaf.wid, .frame = frame });
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

            try applyLayout(split.left, left_frame, inner_gap, output, allocator);
            try applyLayout(split.right, right_frame, inner_gap, output, allocator);
        },
    }
}

/// Replace a window ID in the BSP tree. Used for tab switches where the
/// new active tab inherits the old tab's position in the layout.
pub fn swapWindow(node: *Node, old_wid: WindowId, new_wid: WindowId) void {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.wid == old_wid) leaf.wid = new_wid;
        },
        .split => |split| {
            swapWindow(&split.left, old_wid, new_wid);
            swapWindow(&split.right, old_wid, new_wid);
        },
    }
}

/// Recursively free all Split nodes in the tree.
pub fn destroyTree(node: Node, allocator: std.mem.Allocator) void {
    switch (node) {
        .leaf => {},
        .split => |split| {
            destroyTree(split.left, allocator);
            destroyTree(split.right, allocator);
            allocator.destroy(split);
        },
    }
}
