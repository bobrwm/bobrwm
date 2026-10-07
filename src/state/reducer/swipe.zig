//! Trackpad swipe transitions and workspace intent.

const model_mod = @import("../model.zig");

const Model = model_mod.Model;
const SwipeInput = model_mod.SwipeInput;
const SwipeReduction = model_mod.SwipeReduction;

pub fn reduceInput(model: *const Model, input: SwipeInput) SwipeReduction {
    var state = model.swipe;
    const result = state.process(input.event, input.settings);
    var reduction: SwipeReduction = .{
        .state = state,
        .result = result,
    };
    if (result.direction) |direction| reduction.workspace_target = adjacentWorkspace(model, direction);
    return reduction;
}

fn adjacentWorkspace(model: *const Model, direction: model_mod.swipe.Direction) ?model_mod.SpaceRef {
    const display_id = model.focusedDisplay() orelse return null;
    const workspace_id = model.desiredWorkspace(display_id) orelse return null;
    const target_id = switch (direction) {
        .previous => if (workspace_id > 1) workspace_id - 1 else return null,
        .next => workspace_id +| 1,
    };
    return model.logicalWorkspace(target_id);
}
