//! Model-based fuzz properties for the monocle tiling algorithm.

const std = @import("std");
const tiling = @import("tiling");
const monocle = tiling.monocle_mod;

const Frame = @FieldType(tiling.LayoutEntry, "frame");
const InsertOptions = tiling.InsertOptions;
const LayoutEntry = tiling.LayoutEntry;
const State = monocle.State;
const WindowId = @FieldType(LayoutEntry, "wid");

const fuzz_window_slots: usize = 16;

const FuzzOperation = enum {
    insert,
    remove,
    set_active,
    replace,
    swap,
};

const FuzzModel = struct {
    items: [fuzz_window_slots]WindowId = undefined,
    len: usize = 0,

    fn slice(model: *const FuzzModel) []const WindowId {
        return model.items[0..model.len];
    }

    fn indexOf(model: *const FuzzModel, wid: WindowId) ?usize {
        for (model.slice(), 0..) |item, index| {
            if (item == wid) return index;
        }
        return null;
    }

    fn insert(model: *FuzzModel, wid: WindowId) void {
        if (model.indexOf(wid) != null) return;
        std.debug.assert(model.len < model.items.len);
        model.items[model.len] = wid;
        model.len += 1;
    }

    fn remove(model: *FuzzModel, wid: WindowId) void {
        const index = model.indexOf(wid) orelse return;
        model.len -= 1;
        model.items[index] = model.items[model.len];
    }

    fn setActive(model: *FuzzModel, wid: WindowId) void {
        const index = model.indexOf(wid) orelse return;
        const active = model.items[index];
        var cursor = index;
        while (cursor > 0) : (cursor -= 1) {
            model.items[cursor] = model.items[cursor - 1];
        }
        model.items[0] = active;
    }

    fn replaceWid(model: *FuzzModel, old_wid: WindowId, new_wid: WindowId) bool {
        const index = model.indexOf(old_wid) orelse return false;
        model.items[index] = new_wid;
        return true;
    }

    fn swapWids(model: *FuzzModel, first_wid: WindowId, second_wid: WindowId) bool {
        if (first_wid == second_wid) return false;
        const first = model.indexOf(first_wid) orelse return false;
        const second = model.indexOf(second_wid) orelse return false;
        std.mem.swap(WindowId, &model.items[first], &model.items[second]);
        return true;
    }
};

test "fuzz mutation sequences match the monocle focus-ring model" {
    try std.testing.fuzz({}, fuzzMutationSequence, .{});
}

fn fuzzMutationSequence(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const options: InsertOptions = .{ .split_mode = .auto, .child = .second };
    const root_frame: Frame = .{ .x = 100, .y = 50, .width = 1920, .height = 1080 };

    var state = State.init();
    defer state.deinit(allocator);
    var model: FuzzModel = .{};

    var step: usize = 0;
    while (step < 64 and !smith.eosWeightedSimple(8, 1)) : (step += 1) {
        switch (smith.value(FuzzOperation)) {
            .insert => {
                const wid = fuzzWindowId(smith);
                try state.insert(wid, options, allocator);
                model.insert(wid);
            },
            .remove => {
                const wid = fuzzWindowId(smith);
                state.remove(wid, allocator);
                model.remove(wid);
            },
            .set_active => {
                const wid = fuzzWindowId(smith);
                state.setActive(wid);
                model.setActive(wid);
            },
            .replace => try fuzzReplace(&state, &model, smith),
            .swap => {
                const first = fuzzWindowId(smith);
                const second = fuzzWindowId(smith);
                try std.testing.expectEqual(
                    model.swapWids(first, second),
                    state.swapWids(first, second),
                );
            },
        }
        try validateFuzzState(&state, &model, root_frame, allocator);
    }
}

fn fuzzReplace(state: *State, model: *FuzzModel, smith: *std.testing.Smith) !void {
    const old_wid = fuzzWindowId(smith);
    const new_wid = fuzzWindowId(smith);

    // Production replacement only supplies an ID that is not already managed.
    if (model.indexOf(new_wid) != null) return;
    try std.testing.expectEqual(
        model.replaceWid(old_wid, new_wid),
        state.replaceWid(old_wid, new_wid),
    );
}

fn fuzzWindowId(smith: *std.testing.Smith) WindowId {
    return smith.valueRangeAtMost(u8, 1, @intCast(fuzz_window_slots));
}

fn validateFuzzState(
    state: *const State,
    model: *const FuzzModel,
    root_frame: Frame,
    allocator: std.mem.Allocator,
) !void {
    try std.testing.expectEqual(model.len, state.windowCount());
    try std.testing.expectEqualSlices(WindowId, model.slice(), state.windows.items);

    if (model.len == 0) {
        try std.testing.expectEqual(@as(?WindowId, null), state.firstWid());
        try std.testing.expectEqual(@as(?WindowId, null), state.lastWid());
    } else {
        try std.testing.expectEqual(@as(?WindowId, model.items[0]), state.firstWid());
        try std.testing.expectEqual(@as(?WindowId, model.items[model.len - 1]), state.lastWid());
    }

    try validateFuzzFocus(state, model);

    var layout: std.ArrayList(LayoutEntry) = .empty;
    defer layout.deinit(allocator);
    try layout.ensureTotalCapacity(allocator, model.len);
    state.computeLayout(root_frame, 32, &layout);
    try std.testing.expectEqual(model.len, layout.items.len);
    for (layout.items, model.slice()) |entry, expected_wid| {
        try std.testing.expectEqual(expected_wid, entry.wid);
        try std.testing.expectEqualDeep(root_frame, entry.frame);
    }
}

fn validateFuzzFocus(state: *const State, model: *const FuzzModel) !void {
    try std.testing.expectEqual(@as(?WindowId, null), state.cycleFocus(0, true));
    for (model.slice(), 0..) |wid, index| {
        const expected_forward: ?WindowId = if (model.len <= 1)
            null
        else
            model.items[(index + 1) % model.len];
        const expected_backward: ?WindowId = if (model.len <= 1)
            null
        else if (index == 0)
            model.items[model.len - 1]
        else
            model.items[index - 1];
        try std.testing.expectEqual(expected_forward, state.cycleFocus(wid, true));
        try std.testing.expectEqual(expected_backward, state.cycleFocus(wid, false));
    }
}
