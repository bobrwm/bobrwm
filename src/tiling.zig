//! Deterministic workspace layout state and frame projection.

const Self = @This();

const std = @import("std");
const space_mod = @import("space.zig");
const window_mod = @import("window.zig");

const WindowId = window_mod.WindowId;
const Frame = window_mod.Window.Frame;
const SpaceKey = space_mod.Key;
const NodeId = u16;

pub const max_layouts = 80;
pub const max_windows = 1024;
pub const max_nodes = max_windows * 2 - 1;

pub const Direction = enum { horizontal, vertical };
pub const SplitMode = enum { auto, horizontal, vertical };
pub const InsertChild = enum { first, second };
pub const InsertionPointPolicy = enum { focused, first, last, min_depth };

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

pub const LayoutKind = enum { bsp, monocle };

pub const Event = union(enum) {
    clear,
    insert: struct {
        space_key: SpaceKey,
        kind: LayoutKind,
        window_id: WindowId,
        options: InsertOptions,
    },
    remove: struct { space_key: SpaceKey, window_id: WindowId },
    move_window: struct {
        source_key: SpaceKey,
        target_key: SpaceKey,
        kind: LayoutKind,
        window_id: WindowId,
        options: InsertOptions,
    },
    swap_layouts: struct { first_key: SpaceKey, second_key: SpaceKey },
    set_active: struct { space_key: SpaceKey, window_id: WindowId },
    replace_window_id: struct {
        space_key: SpaceKey,
        old_window_id: WindowId,
        new_window_id: WindowId,
    },
    swap_window_ids: struct {
        space_key: SpaceKey,
        first_window_id: WindowId,
        second_window_id: WindowId,
    },
    adjust_parent_ratio: struct { space_key: SpaceKey, window_id: WindowId, delta: f64 },
    set_parent_ratio: struct { space_key: SpaceKey, window_id: WindowId, ratio: f64 },
    mirror: struct { space_key: SpaceKey, axis: Direction },
    equalize: struct { space_key: SpaceKey, ratio: f64 },
    balance: SpaceKey,
    rotate: struct { space_key: SpaceKey, degrees: i32 },
};

pub const RejectionReason = enum {
    layout_catalog_full,
    node_catalog_full,
    layout_kind_mismatch,
    window_already_managed,
    window_missing,
};

pub const Effect = union(enum) {
    rejected: struct {
        space_key: SpaceKey,
        window_id: ?WindowId,
        reason: RejectionReason,
    },
};

pub const Transition = struct {
    model: Self,
    effect: ?Effect = null,
};

const min_split_ratio: f64 = 0.1;
const max_split_ratio: f64 = 0.9;

const Leaf = struct {
    window_id: WindowId,
    previous: ?NodeId = null,
    next: ?NodeId = null,
};

const Split = struct {
    direction: Direction,
    ratio: f64,
    first: NodeId,
    second: NodeId,
};

const Node = union(enum) { leaf: Leaf, split: Split };

const LayoutState = struct {
    kind: LayoutKind,
    root: ?NodeId = null,
    tail: ?NodeId = null,
    window_count: u16 = 0,
};

const LayoutSlot = struct {
    space_key: SpaceKey,
    state: ?LayoutState = null,
};

layouts: [max_layouts]LayoutSlot = undefined,
layout_count: u8 = 0,
nodes: [max_nodes]Node = undefined,
node_occupied: [max_nodes]bool = @splat(false),
node_count: u16 = 0,

pub fn reduce(model: Self, event: Event) Transition {
    var transition: Transition = .{ .model = model };
    switch (event) {
        .clear => transition.model = .{},
        .insert => |insertion| {
            transition.model.insert(insertion.space_key, insertion.kind, insertion.window_id, insertion.options) catch |err| {
                transition.model = model;
                transition.effect = rejectionEffect(insertion.space_key, insertion.window_id, err);
            };
        },
        .remove => |removal| transition.model.remove(removal.space_key, removal.window_id),
        .move_window => |movement| {
            transition.model.moveWindow(
                movement.source_key,
                movement.target_key,
                movement.kind,
                movement.window_id,
                movement.options,
            ) catch |err| {
                transition.model = model;
                transition.effect = rejectionEffect(movement.target_key, movement.window_id, err);
            };
        },
        .swap_layouts => |swap| {
            transition.model.swapLayouts(swap.first_key, swap.second_key) catch |err| {
                transition.model = model;
                transition.effect = rejectionEffect(swap.first_key, null, err);
            };
        },
        .set_active => |active| transition.model.setActive(active.space_key, active.window_id),
        .replace_window_id => |replacement| {
            _ = transition.model.replaceWindowId(replacement.space_key, replacement.old_window_id, replacement.new_window_id);
        },
        .swap_window_ids => |swap| {
            _ = transition.model.swapWindowIds(swap.space_key, swap.first_window_id, swap.second_window_id);
        },
        .adjust_parent_ratio => |adjustment| {
            _ = transition.model.adjustParentRatio(adjustment.space_key, adjustment.window_id, adjustment.delta);
        },
        .set_parent_ratio => |adjustment| {
            _ = transition.model.setParentRatio(adjustment.space_key, adjustment.window_id, adjustment.ratio);
        },
        .mirror => |operation| transition.model.mirror(operation.space_key, operation.axis),
        .equalize => |operation| transition.model.equalize(operation.space_key, operation.ratio),
        .balance => |space_key| transition.model.balance(space_key),
        .rotate => |operation| transition.model.rotate(operation.space_key, operation.degrees),
    }
    transition.model.assertValid();
    return transition;
}

pub fn layoutKind(self: *const Self, space_key: SpaceKey) ?LayoutKind {
    const state = self.layoutState(space_key) orelse return null;
    return state.kind;
}

pub fn contains(self: *const Self, space_key: SpaceKey, window_id: WindowId) bool {
    const state = self.layoutState(space_key) orelse return false;
    return self.findWindowNode(state, window_id) != null;
}

pub fn windowCount(self: *const Self, space_key: SpaceKey) usize {
    const state = self.layoutState(space_key) orelse return 0;
    return state.window_count;
}

pub fn firstWid(self: *const Self, space_key: SpaceKey) ?WindowId {
    const state = self.layoutState(space_key) orelse return null;
    const root = state.root orelse return null;
    const node_id = switch (state.kind) {
        .bsp => self.firstLeaf(root),
        .monocle => root,
    };
    return self.nodes[node_id].leaf.window_id;
}

pub fn lastWid(self: *const Self, space_key: SpaceKey) ?WindowId {
    const state = self.layoutState(space_key) orelse return null;
    const root = state.root orelse return null;
    const node_id = switch (state.kind) {
        .bsp => self.lastLeaf(root),
        .monocle => state.tail orelse root,
    };
    return self.nodes[node_id].leaf.window_id;
}

pub fn cycleFocus(self: *const Self, space_key: SpaceKey, window_id: WindowId, forward: bool) ?WindowId {
    const state = self.layoutState(space_key) orelse return null;
    if (state.kind != .monocle or state.window_count <= 1) return null;
    const node_id = self.findWindowNode(state, window_id) orelse return null;
    const leaf = self.nodes[node_id].leaf;
    const next_id = if (forward) leaf.next orelse state.root.? else leaf.previous orelse state.tail.?;
    return self.nodes[next_id].leaf.window_id;
}

pub fn hasParentSplit(self: *const Self, space_key: SpaceKey, window_id: WindowId) bool {
    const state = self.layoutState(space_key) orelse return false;
    if (state.kind != .bsp) return false;
    const root = state.root orelse return false;
    return self.findParentSplit(root, window_id) != null;
}

pub fn computeLayout(
    self: *const Self,
    space_key: SpaceKey,
    frame: Frame,
    inner_gap: f64,
    output: *std.ArrayList(LayoutEntry),
) void {
    const state = self.layoutState(space_key) orelse return;
    std.debug.assert(output.capacity - output.items.len >= state.window_count);
    const root = state.root orelse return;
    switch (state.kind) {
        .bsp => self.applyBsp(root, frame, inner_gap, output),
        .monocle => {
            var node_id: ?NodeId = root;
            while (node_id) |current| {
                const leaf = self.nodes[current].leaf;
                output.appendAssumeCapacity(.{ .wid = leaf.window_id, .frame = frame });
                node_id = leaf.next;
            }
        },
    }
}

pub fn entryAtPoint(
    self: *const Self,
    space_key: SpaceKey,
    frame: Frame,
    inner_gap: f64,
    point_x: f64,
    point_y: f64,
    excluded_window_id: WindowId,
) ?LayoutEntry {
    const state = self.layoutState(space_key) orelse return null;
    if (state.kind != .bsp) return null;
    const root = state.root orelse return null;
    return self.bspEntryAtPoint(root, frame, inner_gap, point_x, point_y, excluded_window_id);
}

/// Return the number of unique window identities owned by all layouts.
pub fn totalWindowCount(self: *const Self) usize {
    var total: usize = 0;
    for (self.layouts[0..self.layout_count]) |slot| {
        const state = slot.state orelse continue;
        total += state.window_count;
    }
    return total;
}

pub fn assertValid(self: *const Self) void {
    std.debug.assert(self.layout_count <= self.layouts.len);
    std.debug.assert(self.node_count <= self.nodes.len);

    var reachable: [max_nodes]bool = @splat(false);
    var window_ids: [max_windows]WindowId = undefined;
    var window_count: usize = 0;
    var reachable_count: usize = 0;

    for (self.layouts[0..self.layout_count], 0..) |slot, index| {
        for (self.layouts[0..index]) |prior| std.debug.assert(!prior.space_key.eql(slot.space_key));
        const state = slot.state orelse continue;
        std.debug.assert(state.window_count > 0);

        switch (state.kind) {
            .bsp => {
                std.debug.assert(state.tail == null);
                const counts = self.assertBspNode(state.root.?, &reachable, &window_ids, &window_count);
                std.debug.assert(counts.windows == state.window_count);
                std.debug.assert(counts.nodes == state.window_count * 2 - 1);
                reachable_count += counts.nodes;
            },
            .monocle => {
                const count = self.assertMonocle(state, &reachable, &window_ids, &window_count);
                std.debug.assert(count == state.window_count);
                reachable_count += count;
            },
        }
    }

    std.debug.assert(reachable_count == self.node_count);
    for (self.node_occupied, reachable) |occupied, is_reachable| {
        std.debug.assert(occupied == is_reachable);
    }
}

fn insert(self: *Self, space_key: SpaceKey, kind: LayoutKind, window_id: WindowId, options: InsertOptions) !void {
    std.debug.assert(window_id != 0);
    if (self.contains(space_key, window_id)) return;
    if (self.containsWindow(window_id)) return error.WindowAlreadyManaged;

    const slot = try self.ensureLayoutSlot(space_key);
    if (slot.state == null) slot.state = .{ .kind = kind };
    if (slot.state.?.kind != kind) return error.LayoutKindMismatch;

    switch (kind) {
        .bsp => try self.insertBsp(&slot.state.?, window_id, options),
        .monocle => try self.insertMonocle(&slot.state.?, window_id),
    }
    slot.state.?.window_count += 1;
}

fn remove(self: *Self, space_key: SpaceKey, window_id: WindowId) void {
    const slot = self.layoutSlotMut(space_key) orelse return;
    const state = if (slot.state) |*value| value else return;
    const removed = switch (state.kind) {
        .bsp => self.removeBsp(state, window_id),
        .monocle => self.removeMonocle(state, window_id),
    };
    if (!removed) return;
    state.window_count -= 1;
    if (state.window_count == 0) slot.state = null;
}

fn moveWindow(
    self: *Self,
    source_key: SpaceKey,
    target_key: SpaceKey,
    kind: LayoutKind,
    window_id: WindowId,
    options: InsertOptions,
) !void {
    if (source_key.eql(target_key)) return;
    if (!self.contains(source_key, window_id)) return error.WindowMissing;

    self.remove(source_key, window_id);
    try self.insert(target_key, kind, window_id, options);
}

fn swapLayouts(self: *Self, first_key: SpaceKey, second_key: SpaceKey) !void {
    if (first_key.eql(second_key)) return;
    const first_index = try self.ensureLayoutIndex(first_key);
    const second_index = try self.ensureLayoutIndex(second_key);
    const previous = self.layouts[first_index].state;
    self.layouts[first_index].state = self.layouts[second_index].state;
    self.layouts[second_index].state = previous;
}

fn setActive(self: *Self, space_key: SpaceKey, window_id: WindowId) void {
    const state = self.layoutStateMut(space_key) orelse return;
    if (state.kind != .monocle or state.root == null) return;
    const node_id = self.findWindowNode(state, window_id) orelse return;
    if (node_id == state.root.?) return;

    const leaf = self.nodes[node_id].leaf;
    if (leaf.previous) |previous| self.nodes[previous].leaf.next = leaf.next;
    if (leaf.next) |next| self.nodes[next].leaf.previous = leaf.previous else state.tail = leaf.previous;

    const old_root = state.root.?;
    self.nodes[old_root].leaf.previous = node_id;
    self.nodes[node_id].leaf = .{ .window_id = leaf.window_id, .next = old_root };
    state.root = node_id;
}

fn replaceWindowId(self: *Self, space_key: SpaceKey, old_window_id: WindowId, new_window_id: WindowId) bool {
    if (old_window_id == new_window_id) return false;
    const state = self.layoutState(space_key) orelse return false;
    if (self.findWindowNode(state, new_window_id) != null) return false;
    const node_id = self.findWindowNode(state, old_window_id) orelse return false;
    self.nodes[node_id].leaf.window_id = new_window_id;
    return true;
}

fn swapWindowIds(self: *Self, space_key: SpaceKey, first_window_id: WindowId, second_window_id: WindowId) bool {
    if (first_window_id == second_window_id) return false;
    const state = self.layoutState(space_key) orelse return false;
    const first = self.findWindowNode(state, first_window_id) orelse return false;
    const second = self.findWindowNode(state, second_window_id) orelse return false;
    self.nodes[first].leaf.window_id = second_window_id;
    self.nodes[second].leaf.window_id = first_window_id;
    return true;
}

fn adjustParentRatio(self: *Self, space_key: SpaceKey, window_id: WindowId, delta: f64) bool {
    const state = self.layoutState(space_key) orelse return false;
    if (state.kind != .bsp) return false;
    const split_id = self.findParentSplit(state.root orelse return false, window_id) orelse return false;
    self.nodes[split_id].split.ratio = clampedRatio(self.nodes[split_id].split.ratio + delta);
    return true;
}

fn setParentRatio(self: *Self, space_key: SpaceKey, window_id: WindowId, ratio: f64) bool {
    const state = self.layoutState(space_key) orelse return false;
    if (state.kind != .bsp) return false;
    const split_id = self.findParentSplit(state.root orelse return false, window_id) orelse return false;
    self.nodes[split_id].split.ratio = clampedRatio(ratio);
    return true;
}

fn mirror(self: *Self, space_key: SpaceKey, axis: Direction) void {
    const state = self.layoutState(space_key) orelse return;
    if (state.kind != .bsp) return;
    if (state.root) |root| self.mirrorNode(root, axis);
}

fn equalize(self: *Self, space_key: SpaceKey, ratio: f64) void {
    const state = self.layoutState(space_key) orelse return;
    if (state.kind != .bsp) return;
    if (state.root) |root| self.equalizeNode(root, clampedRatio(ratio));
}

fn balance(self: *Self, space_key: SpaceKey) void {
    const state = self.layoutState(space_key) orelse return;
    if (state.kind != .bsp) return;
    if (state.root) |root| _ = self.balanceNode(root);
}

fn rotate(self: *Self, space_key: SpaceKey, degrees: i32) void {
    const state = self.layoutState(space_key) orelse return;
    if (state.kind != .bsp) return;
    if (state.root) |root| self.rotateNode(root, degrees);
}

fn insertBsp(self: *Self, state: *LayoutState, window_id: WindowId, options: InsertOptions) !void {
    const root = state.root orelse {
        state.root = try self.allocateNode(.{ .leaf = .{ .window_id = window_id } });
        return;
    };

    var target = if (options.anchor_wid) |anchor| self.findBspLeaf(root, anchor) else null;
    if (target == null) {
        var shallowest_depth: usize = std.math.maxInt(usize);
        self.findShallowestLeaf(root, 0, &target, &shallowest_depth);
    }
    const target_id = target.?;
    const existing = self.nodes[target_id].leaf;
    const direction = self.resolveSplitDirection(root, target_id, options);
    const existing_id = try self.allocateNode(.{ .leaf = existing });
    errdefer self.releaseNode(existing_id);
    const inserted_id = try self.allocateNode(.{ .leaf = .{ .window_id = window_id } });

    const children = switch (options.child) {
        .first => .{ inserted_id, existing_id },
        .second => .{ existing_id, inserted_id },
    };
    self.nodes[target_id] = .{ .split = .{
        .direction = direction,
        .ratio = clampedRatio(options.split_ratio),
        .first = children[0],
        .second = children[1],
    } };
}

fn insertMonocle(self: *Self, state: *LayoutState, window_id: WindowId) !void {
    const node_id = try self.allocateNode(.{ .leaf = .{ .window_id = window_id, .previous = state.tail } });
    if (state.tail) |tail| self.nodes[tail].leaf.next = node_id else state.root = node_id;
    state.tail = node_id;
}

const RemoveResult = struct { removed: bool, replacement: ?NodeId };

fn removeBsp(self: *Self, state: *LayoutState, window_id: WindowId) bool {
    const root = state.root orelse return false;
    const result = self.removeBspNode(root, window_id);
    if (!result.removed) return false;
    state.root = result.replacement;
    return true;
}

fn removeBspNode(self: *Self, node_id: NodeId, window_id: WindowId) RemoveResult {
    switch (self.nodes[node_id]) {
        .leaf => |leaf| {
            if (leaf.window_id != window_id) return .{ .removed = false, .replacement = node_id };
            self.releaseNode(node_id);
            return .{ .removed = true, .replacement = null };
        },
        .split => |split| {
            const first = self.removeBspNode(split.first, window_id);
            if (first.removed) {
                if (first.replacement) |replacement| {
                    self.nodes[node_id].split.first = replacement;
                    return .{ .removed = true, .replacement = node_id };
                }
                self.releaseNode(node_id);
                return .{ .removed = true, .replacement = split.second };
            }

            const second = self.removeBspNode(split.second, window_id);
            if (!second.removed) return .{ .removed = false, .replacement = node_id };
            if (second.replacement) |replacement| {
                self.nodes[node_id].split.second = replacement;
                return .{ .removed = true, .replacement = node_id };
            }
            self.releaseNode(node_id);
            return .{ .removed = true, .replacement = split.first };
        },
    }
}

fn removeMonocle(self: *Self, state: *LayoutState, window_id: WindowId) bool {
    const node_id = self.findWindowNode(state, window_id) orelse return false;
    const tail_id = state.tail.?;
    if (node_id != tail_id) self.nodes[node_id].leaf.window_id = self.nodes[tail_id].leaf.window_id;

    const tail = self.nodes[tail_id].leaf;
    if (tail.previous) |previous| self.nodes[previous].leaf.next = null else state.root = null;
    state.tail = tail.previous;
    self.releaseNode(tail_id);
    return true;
}

fn findWindowNode(self: *const Self, state: *const LayoutState, window_id: WindowId) ?NodeId {
    const root = state.root orelse return null;
    return switch (state.kind) {
        .bsp => self.findBspLeaf(root, window_id),
        .monocle => blk: {
            var node_id: ?NodeId = root;
            while (node_id) |current| {
                const leaf = self.nodes[current].leaf;
                if (leaf.window_id == window_id) break :blk current;
                node_id = leaf.next;
            }
            break :blk null;
        },
    };
}

fn containsWindow(self: *const Self, window_id: WindowId) bool {
    for (self.layouts[0..self.layout_count]) |*slot| {
        const state = if (slot.state) |*value| value else continue;
        if (self.findWindowNode(state, window_id) != null) return true;
    }
    return false;
}

fn findBspLeaf(self: *const Self, node_id: NodeId, window_id: WindowId) ?NodeId {
    return switch (self.nodes[node_id]) {
        .leaf => |leaf| if (leaf.window_id == window_id) node_id else null,
        .split => |split| self.findBspLeaf(split.first, window_id) orelse self.findBspLeaf(split.second, window_id),
    };
}

fn findShallowestLeaf(self: *const Self, node_id: NodeId, depth: usize, output: *?NodeId, output_depth: *usize) void {
    switch (self.nodes[node_id]) {
        .leaf => {
            if (depth >= output_depth.*) return;
            output.* = node_id;
            output_depth.* = depth;
        },
        .split => |split| {
            self.findShallowestLeaf(split.first, depth + 1, output, output_depth);
            self.findShallowestLeaf(split.second, depth + 1, output, output_depth);
        },
    }
}

fn resolveSplitDirection(self: *const Self, root: NodeId, target: NodeId, options: InsertOptions) Direction {
    return switch (options.split_mode) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .auto => blk: {
            const frame = options.root_frame orelse break :blk .horizontal;
            const target_window_id = self.nodes[target].leaf.window_id;
            const target_frame = self.findLeafFrame(root, frame, options.inner_gap, target_window_id) orelse break :blk .horizontal;
            break :blk if (target_frame.width >= target_frame.height) .horizontal else .vertical;
        },
    };
}

fn findLeafFrame(self: *const Self, node_id: NodeId, frame: Frame, inner_gap: f64, window_id: WindowId) ?Frame {
    return switch (self.nodes[node_id]) {
        .leaf => |leaf| if (leaf.window_id == window_id) frame else null,
        .split => |split| blk: {
            const frames = splitFrames(frame, split, inner_gap);
            break :blk self.findLeafFrame(split.first, frames[0], inner_gap, window_id) orelse
                self.findLeafFrame(split.second, frames[1], inner_gap, window_id);
        },
    };
}

fn firstLeaf(self: *const Self, node_id: NodeId) NodeId {
    return switch (self.nodes[node_id]) {
        .leaf => node_id,
        .split => |split| self.firstLeaf(split.first),
    };
}

fn lastLeaf(self: *const Self, node_id: NodeId) NodeId {
    return switch (self.nodes[node_id]) {
        .leaf => node_id,
        .split => |split| self.lastLeaf(split.second),
    };
}

fn findParentSplit(self: *const Self, node_id: NodeId, window_id: WindowId) ?NodeId {
    return switch (self.nodes[node_id]) {
        .leaf => null,
        .split => |split| blk: {
            if (self.findBspLeaf(split.first, window_id) != null) {
                break :blk self.findParentSplit(split.first, window_id) orelse node_id;
            }
            if (self.findBspLeaf(split.second, window_id) != null) {
                break :blk self.findParentSplit(split.second, window_id) orelse node_id;
            }
            break :blk null;
        },
    };
}

fn mirrorNode(self: *Self, node_id: NodeId, axis: Direction) void {
    const split = switch (self.nodes[node_id]) {
        .leaf => return,
        .split => |value| value,
    };
    self.mirrorNode(split.first, axis);
    self.mirrorNode(split.second, axis);
    if (split.direction != axis) return;
    self.nodes[node_id].split.first = split.second;
    self.nodes[node_id].split.second = split.first;
}

fn equalizeNode(self: *Self, node_id: NodeId, ratio: f64) void {
    const split = switch (self.nodes[node_id]) {
        .leaf => return,
        .split => |value| value,
    };
    self.equalizeNode(split.first, ratio);
    self.equalizeNode(split.second, ratio);
    self.nodes[node_id].split.ratio = ratio;
}

fn balanceNode(self: *Self, node_id: NodeId) usize {
    const split = switch (self.nodes[node_id]) {
        .leaf => return 1,
        .split => |value| value,
    };
    const first_count = self.balanceNode(split.first);
    const second_count = self.balanceNode(split.second);
    const total = first_count + second_count;
    self.nodes[node_id].split.ratio = clampedRatio(@as(f64, @floatFromInt(first_count)) / @as(f64, @floatFromInt(total)));
    return total;
}

fn rotateNode(self: *Self, node_id: NodeId, degrees: i32) void {
    const split = switch (self.nodes[node_id]) {
        .leaf => return,
        .split => |value| value,
    };
    self.rotateNode(split.first, degrees);
    self.rotateNode(split.second, degrees);
    switch (degrees) {
        90 => {
            if (split.direction == .vertical) self.swapSplitChildren(node_id);
            self.nodes[node_id].split.direction = toggleDirection(split.direction);
        },
        180 => self.swapSplitChildren(node_id),
        270 => {
            if (split.direction == .horizontal) self.swapSplitChildren(node_id);
            self.nodes[node_id].split.direction = toggleDirection(split.direction);
        },
        else => {},
    }
}

fn swapSplitChildren(self: *Self, node_id: NodeId) void {
    const split = self.nodes[node_id].split;
    self.nodes[node_id].split.first = split.second;
    self.nodes[node_id].split.second = split.first;
    self.nodes[node_id].split.ratio = 1.0 - split.ratio;
}

fn applyBsp(self: *const Self, node_id: NodeId, frame: Frame, inner_gap: f64, output: *std.ArrayList(LayoutEntry)) void {
    switch (self.nodes[node_id]) {
        .leaf => |leaf| output.appendAssumeCapacity(.{ .wid = leaf.window_id, .frame = frame }),
        .split => |split| {
            const frames = splitFrames(frame, split, inner_gap);
            self.applyBsp(split.first, frames[0], inner_gap, output);
            self.applyBsp(split.second, frames[1], inner_gap, output);
        },
    }
}

fn bspEntryAtPoint(
    self: *const Self,
    node_id: NodeId,
    frame: Frame,
    inner_gap: f64,
    point_x: f64,
    point_y: f64,
    excluded_window_id: WindowId,
) ?LayoutEntry {
    switch (self.nodes[node_id]) {
        .leaf => |leaf| {
            if (leaf.window_id == excluded_window_id or !frameContainsPoint(frame, point_x, point_y)) return null;
            return .{ .wid = leaf.window_id, .frame = frame };
        },
        .split => |split| {
            const frames = splitFrames(frame, split, inner_gap);
            if (frameContainsPoint(frames[0], point_x, point_y)) {
                if (self.bspEntryAtPoint(split.first, frames[0], inner_gap, point_x, point_y, excluded_window_id)) |entry| return entry;
            }
            if (!frameContainsPoint(frames[1], point_x, point_y)) return null;
            return self.bspEntryAtPoint(split.second, frames[1], inner_gap, point_x, point_y, excluded_window_id);
        },
    }
}

fn splitFrames(frame: Frame, split: Split, inner_gap: f64) [2]Frame {
    const half_gap = inner_gap / 2.0;
    var first = frame;
    var second = frame;
    switch (split.direction) {
        .horizontal => {
            const first_width = frame.width * split.ratio;
            first.width = first_width - half_gap;
            second.x = frame.x + first_width + half_gap;
            second.width = frame.width - first_width - half_gap;
        },
        .vertical => {
            const first_height = frame.height * split.ratio;
            first.height = first_height - half_gap;
            second.y = frame.y + first_height + half_gap;
            second.height = frame.height - first_height - half_gap;
        },
    }
    return .{ first, second };
}

fn frameContainsPoint(frame: Frame, point_x: f64, point_y: f64) bool {
    return point_x >= frame.x and point_x <= frame.x + frame.width and
        point_y >= frame.y and point_y <= frame.y + frame.height;
}

const TreeCounts = struct { nodes: usize, windows: usize };

fn assertBspNode(
    self: *const Self,
    node_id: NodeId,
    reachable: *[max_nodes]bool,
    window_ids: *[max_windows]WindowId,
    window_count: *usize,
) TreeCounts {
    std.debug.assert(node_id < self.nodes.len);
    std.debug.assert(self.node_occupied[node_id]);
    std.debug.assert(!reachable[node_id]);
    reachable[node_id] = true;

    return switch (self.nodes[node_id]) {
        .leaf => |leaf| blk: {
            std.debug.assert(leaf.previous == null and leaf.next == null);
            assertUniqueWindowId(window_ids, window_count, leaf.window_id);
            break :blk .{ .nodes = 1, .windows = 1 };
        },
        .split => |split| blk: {
            std.debug.assert(split.first != split.second);
            std.debug.assert(std.math.isFinite(split.ratio));
            std.debug.assert(split.ratio >= min_split_ratio and split.ratio <= max_split_ratio);
            const first = self.assertBspNode(split.first, reachable, window_ids, window_count);
            const second = self.assertBspNode(split.second, reachable, window_ids, window_count);
            break :blk .{
                .nodes = 1 + first.nodes + second.nodes,
                .windows = first.windows + second.windows,
            };
        },
    };
}

fn assertMonocle(
    self: *const Self,
    state: LayoutState,
    reachable: *[max_nodes]bool,
    window_ids: *[max_windows]WindowId,
    window_count: *usize,
) usize {
    var count: usize = 0;
    var previous: ?NodeId = null;
    var node_id = state.root;
    while (node_id) |current| {
        std.debug.assert(current < self.nodes.len);
        std.debug.assert(self.node_occupied[current]);
        std.debug.assert(!reachable[current]);
        reachable[current] = true;

        const leaf = switch (self.nodes[current]) {
            .leaf => |value| value,
            .split => unreachable,
        };
        std.debug.assert(leaf.previous == previous);
        assertUniqueWindowId(window_ids, window_count, leaf.window_id);
        count += 1;
        previous = current;
        node_id = leaf.next;
    }
    std.debug.assert(previous == state.tail);
    return count;
}

fn assertUniqueWindowId(window_ids: *[max_windows]WindowId, window_count: *usize, window_id: WindowId) void {
    std.debug.assert(window_id != 0);
    std.debug.assert(window_count.* < window_ids.len);
    for (window_ids[0..window_count.*]) |existing| std.debug.assert(existing != window_id);
    window_ids[window_count.*] = window_id;
    window_count.* += 1;
}

fn layoutState(self: *const Self, space_key: SpaceKey) ?*const LayoutState {
    const slot = self.layoutSlot(space_key) orelse return null;
    return if (slot.state) |*state| state else null;
}

fn layoutStateMut(self: *Self, space_key: SpaceKey) ?*LayoutState {
    const slot = self.layoutSlotMut(space_key) orelse return null;
    return if (slot.state) |*state| state else null;
}

fn layoutSlot(self: *const Self, space_key: SpaceKey) ?*const LayoutSlot {
    for (self.layouts[0..self.layout_count]) |*slot| if (slot.space_key.eql(space_key)) return slot;
    return null;
}

fn layoutSlotMut(self: *Self, space_key: SpaceKey) ?*LayoutSlot {
    for (self.layouts[0..self.layout_count]) |*slot| if (slot.space_key.eql(space_key)) return slot;
    return null;
}

fn ensureLayoutIndex(self: *Self, space_key: SpaceKey) !usize {
    for (self.layouts[0..self.layout_count], 0..) |slot, index| {
        if (slot.space_key.eql(space_key)) return index;
    }
    if (self.layout_count == self.layouts.len) return error.LayoutCatalogFull;
    const index = self.layout_count;
    self.layout_count += 1;
    self.layouts[index] = .{ .space_key = space_key };
    return index;
}

fn ensureLayoutSlot(self: *Self, space_key: SpaceKey) !*LayoutSlot {
    return &self.layouts[try self.ensureLayoutIndex(space_key)];
}

fn allocateNode(self: *Self, node: Node) !NodeId {
    for (&self.node_occupied, 0..) |*occupied, index| {
        if (occupied.*) continue;
        occupied.* = true;
        self.node_count += 1;
        self.nodes[index] = node;
        return @intCast(index);
    }
    return error.NodeCatalogFull;
}

fn releaseNode(self: *Self, node_id: NodeId) void {
    std.debug.assert(self.node_occupied[node_id]);
    self.node_occupied[node_id] = false;
    self.node_count -= 1;
}

fn clampedRatio(ratio: f64) f64 {
    return std.math.clamp(ratio, min_split_ratio, max_split_ratio);
}

fn toggleDirection(direction: Direction) Direction {
    return switch (direction) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };
}

fn rejectionEffect(space_key: SpaceKey, window_id: ?WindowId, err: anyerror) Effect {
    const reason: RejectionReason = switch (err) {
        error.LayoutCatalogFull => .layout_catalog_full,
        error.NodeCatalogFull => .node_catalog_full,
        error.LayoutKindMismatch => .layout_kind_mismatch,
        error.WindowAlreadyManaged => .window_already_managed,
        error.WindowMissing => .window_missing,
        else => unreachable,
    };
    return .{ .rejected = .{ .space_key = space_key, .window_id = window_id, .reason = reason } };
}

const testing = std.testing;
const first_space: SpaceKey = .{ .id = 1 };
const second_space: SpaceKey = .{ .id = 2 };
const test_frame: Frame = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };

fn insertEvent(space_key: SpaceKey, kind: LayoutKind, window_id: WindowId) Event {
    return .{ .insert = .{
        .space_key = space_key,
        .kind = kind,
        .window_id = window_id,
        .options = .{ .split_mode = .horizontal, .child = .second, .root_frame = test_frame },
    } };
}

test "bsp reducer projects, swaps, and collapses deterministic slots" {
    var model = reduce(.{}, insertEvent(first_space, .bsp, 1)).model;
    model = reduce(model, insertEvent(first_space, .bsp, 2)).model;
    model = reduce(model, insertEvent(first_space, .bsp, 3)).model;

    var entries: std.ArrayList(LayoutEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try entries.ensureTotalCapacity(testing.allocator, 3);
    model.computeLayout(first_space, test_frame, 0, &entries);
    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqual(@as(WindowId, 1), entries.items[0].wid);
    try testing.expectEqual(@as(WindowId, 3), entries.items[1].wid);
    try testing.expectEqual(@as(WindowId, 2), entries.items[2].wid);

    model = reduce(model, .{ .swap_window_ids = .{
        .space_key = first_space,
        .first_window_id = 1,
        .second_window_id = 2,
    } }).model;
    try testing.expectEqual(@as(?WindowId, 2), model.firstWid(first_space));
    model = reduce(model, .{ .remove = .{ .space_key = first_space, .window_id = 3 } }).model;
    try testing.expectEqual(@as(usize, 2), model.windowCount(first_space));
    try testing.expectEqual(@as(u16, 3), model.node_count);
}

test "monocle reducer maintains focus order" {
    var model = reduce(.{}, insertEvent(first_space, .monocle, 1)).model;
    model = reduce(model, insertEvent(first_space, .monocle, 2)).model;
    model = reduce(model, insertEvent(first_space, .monocle, 3)).model;
    model = reduce(model, .{ .set_active = .{ .space_key = first_space, .window_id = 3 } }).model;
    try testing.expectEqual(@as(?WindowId, 3), model.firstWid(first_space));
    try testing.expectEqual(@as(?WindowId, 1), model.cycleFocus(first_space, 3, true));
    try testing.expectEqual(@as(?WindowId, 2), model.cycleFocus(first_space, 3, false));
}

test "monocle removal preserves swap-remove focus order" {
    var model = reduce(.{}, insertEvent(first_space, .monocle, 1)).model;
    model = reduce(model, insertEvent(first_space, .monocle, 2)).model;
    model = reduce(model, insertEvent(first_space, .monocle, 3)).model;
    model = reduce(model, .{ .remove = .{ .space_key = first_space, .window_id = 1 } }).model;
    try testing.expectEqual(@as(?WindowId, 3), model.firstWid(first_space));
    try testing.expectEqual(@as(?WindowId, 2), model.lastWid(first_space));
}

test "rejected insertion leaves layout unchanged" {
    const model = reduce(.{}, insertEvent(first_space, .bsp, 1)).model;
    const transition = reduce(model, insertEvent(first_space, .monocle, 2));
    try testing.expect(transition.effect != null);
    try testing.expectEqual(LayoutKind.bsp, transition.model.layoutKind(first_space).?);
    try testing.expectEqual(@as(usize, 1), transition.model.windowCount(first_space));
    try testing.expect(!transition.model.contains(first_space, 2));
}

test "window movement is atomic across layouts" {
    var model = reduce(.{}, insertEvent(first_space, .bsp, 1)).model;
    model = reduce(model, insertEvent(second_space, .bsp, 2)).model;
    const transition = reduce(model, .{ .move_window = .{
        .source_key = first_space,
        .target_key = second_space,
        .kind = .bsp,
        .window_id = 1,
        .options = insertEvent(second_space, .bsp, 1).insert.options,
    } });
    try testing.expect(transition.effect == null);
    try testing.expect(!transition.model.contains(first_space, 1));
    try testing.expect(transition.model.contains(second_space, 1));
    try testing.expectEqual(@as(usize, 2), transition.model.windowCount(second_space));
}

test "layout model copies do not share nodes" {
    const original = reduce(.{}, insertEvent(first_space, .bsp, 1)).model;
    var copied = reduce(original, insertEvent(first_space, .bsp, 2)).model;
    copied = reduce(copied, insertEvent(second_space, .monocle, 3)).model;
    try testing.expectEqual(@as(usize, 1), original.windowCount(first_space));
    try testing.expectEqual(@as(usize, 2), copied.windowCount(first_space));
    try testing.expectEqual(@as(usize, 1), copied.windowCount(second_space));
}
