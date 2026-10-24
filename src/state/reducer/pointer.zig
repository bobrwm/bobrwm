//! Pointer-drag state transitions.

const std = @import("std");
const invariants = @import("../invariants.zig");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");
const tiling = @import("../../tiling.zig");
const window_mod = @import("../../window.zig");

const Event = model_mod.Event;
const Transition = model_mod.Transition;
const WindowId = model_mod.WindowId;

pub fn removeWindowFromPointerState(transition: *Transition, window_id: WindowId) void {
    if (transition.model.pointer_drag.candidate_window_id == window_id) {
        transition.model.pointer_drag.candidate_window_id = null;
    }
    if (transition.model.pointer_drag.active_window_id == window_id) {
        transition.model.pointer_drag.active_window_id = null;
        transition.model.pointer_drag.should_reconcile_on_drop = false;
        transition.model.pointer_drag.initial_frame = null;
        transition.model.pointer_drag.kind = .unknown;
    }
    if (transition.model.drag_preview.source_window_id == window_id or
        transition.model.drag_preview.target_window_id == window_id)
    {
        clearDragPreview(transition);
    }
}

pub fn reducePointerDown(transition: *Transition, candidate_window_id: ?WindowId) void {
    clearDragPreview(transition);
    const candidate = if (candidate_window_id) |window_id| transition.model.window(window_id) else null;
    transition.model.pointer_drag = .{
        .is_down = true,
        .candidate_window_id = if (candidate) |window| window.window_id else null,
        .initial_frame = if (candidate) |window| window.frame else null,
    };
}

pub fn reducePointerDragged(transition: *Transition) void {
    if (!transition.model.pointer_drag.is_down) return;
    if (transition.model.pointer_drag.active_window_id != null) return;
    transition.model.pointer_drag.active_window_id = transition.model.pointer_drag.candidate_window_id;
}

pub fn reduceDragPreviewObserved(
    transition: *Transition,
    observation: @FieldType(Event, "drag_preview_observed"),
) void {
    const active = transition.model.pointer_drag.active_window_id orelse return;
    // Pointer drags also include text selection and resizing. Only a real
    // window move, confirmed by geometry, may change the layout on release.
    if (transition.model.pointer_drag.kind != .move or
        transition.model.windowTabLeader(active) != observation.source_window_id)
    {
        clearDragPreview(transition);
        return;
    }
    const source = transition.model.window(observation.source_window_id) orelse {
        clearDragPreview(transition);
        return;
    };
    if (source.mode != .tiled or source.is_fullscreen) {
        clearDragPreview(transition);
        return;
    }

    if (!invariants.frameIsFinite(observation.layout_frame) or
        observation.layout_frame.width <= 0 or observation.layout_frame.height <= 0 or
        !std.math.isFinite(observation.pointer_x) or !std.math.isFinite(observation.pointer_y) or
        !std.math.isFinite(observation.inner_gap) or observation.inner_gap < 0)
    {
        clearDragPreview(transition);
        return;
    }
    transition.model.drag_preview.source_window_id = source.window_id;
    const entry = transition.model.layout.entryAtPoint(source.space_key, observation.layout_frame, observation.inner_gap, observation.pointer_x, observation.pointer_y, source.window_id) orelse {
        hideDragPreview(transition);
        return;
    };
    const target = transition.model.window(entry.wid) orelse {
        hideDragPreview(transition);
        return;
    };
    if (target.mode != .tiled or target.is_fullscreen or !target.space_key.eql(source.space_key)) {
        hideDragPreview(transition);
        return;
    }

    const direction = dropDirection(entry.frame, observation.pointer_x, observation.pointer_y);
    const event = dropLayoutEvent(source.space_key, source.window_id, target.window_id, direction);
    const frame = projectDropFrame(&transition.model.layout, source.space_key, event, observation) orelse {
        hideDragPreview(transition);
        return;
    };
    const previous = transition.model.drag_preview;
    transition.model.drag_preview = .{
        .source_window_id = source.window_id,
        .target_window_id = target.window_id,
        .direction = direction,
        .frame = frame,
        .is_visible = true,
    };
    if (previous.is_visible and previous.target_window_id == target.window_id and
        previous.direction == direction and previous.frame != null and
        previous.frame.?.approxEqual(frame, window_mod.Window.Frame.tolerance)) return;
    transition.addEffect(.{ .show_drag_preview = frame });
}

pub fn reducePointerUp(transition: *Transition) void {
    const pointer_drag = transition.model.pointer_drag;
    const preview = transition.model.drag_preview;
    transition.model.pointer_drag = .{};
    clearDragPreview(transition);

    const source_window_id = preview.source_window_id orelse {
        if (pointer_drag.should_reconcile_on_drop) {
            transition.addEffect(.{ .pointer_drag_completed = .{ .should_retile = true } });
        }
        return;
    };
    const target_window_id = preview.target_window_id orelse {
        transition.addEffect(.{ .pointer_drag_completed = .{ .should_retile = true } });
        return;
    };
    if (source_window_id == target_window_id) return;

    const source = transition.model.window(source_window_id) orelse return;
    const target = transition.model.window(target_window_id) orelse return;
    if (source.mode != .tiled or target.mode != .tiled) return;
    if (source.is_fullscreen or target.is_fullscreen) return;
    if (!source.space_key.eql(target.space_key)) return;
    if (!transition.model.layout.contains(source.space_key, source_window_id)) return;
    if (!transition.model.layout.contains(source.space_key, target_window_id)) return;
    if (!layout_reducer.applyEvent(transition, dropLayoutEvent(source.space_key, source_window_id, target_window_id, preview.direction))) return;
    transition.addEffect(.{ .pointer_drag_completed = .{
        .should_retile = true,
        .swapped_window_ids = if (preview.direction == null) .{ .first = source_window_id, .second = target_window_id } else null,
    } });
}

pub fn clearDragPreview(transition: *Transition) void {
    if (transition.model.drag_preview.is_visible) transition.addEffect(.hide_drag_preview);
    transition.model.drag_preview = .{};
}

fn hideDragPreview(transition: *Transition) void {
    transition.model.drag_preview.target_window_id = null;
    transition.model.drag_preview.direction = null;
    transition.model.drag_preview.frame = null;
    if (!transition.model.drag_preview.is_visible) return;
    transition.model.drag_preview.is_visible = false;
    transition.addEffect(.hide_drag_preview);
}

fn projectDropFrame(layout: *const tiling, space_key: model_mod.SpaceKey, event: tiling.Event, observation: @FieldType(Event, "drag_preview_observed")) ?window_mod.Window.Frame {
    // Removing the source can enlarge its sibling. Project the actual
    // insertion rather than promising half of a tile that will not exist.
    var projected = layout.*;
    if (tiling.reduce(&projected, event) != null) return null;
    return projected.frameForWindow(space_key, observation.layout_frame, observation.inner_gap, observation.source_window_id);
}

fn dropDirection(frame: window_mod.Window.Frame, x: f64, y: f64) ?model_mod.FocusDirection {
    const nx = (x - frame.x) / frame.width;
    const ny = (y - frame.y) / frame.height;
    // The central half in each dimension swaps; outside it, diagonals from
    // the corners divide the remaining area into four directional zones.
    if (nx >= 0.25 and nx < 0.75 and ny >= 0.25 and ny < 0.75) return null;
    const dx = nx - 0.5;
    const dy = ny - 0.5;
    if (dy <= -@abs(dx)) return .up;
    if (dx >= @abs(dy)) return .right;
    if (dy >= @abs(dx)) return .down;
    return .left;
}

fn dropLayoutEvent(space_key: model_mod.SpaceKey, source: WindowId, target: WindowId, direction: ?model_mod.FocusDirection) tiling.Event {
    const side = direction orelse return .{ .swap_window_ids = .{
        .space_key = space_key,
        .first_window_id = source,
        .second_window_id = target,
    } };
    return .{ .reinsert_window = .{
        .space_key = space_key,
        .window_id = source,
        .options = .{
            .anchor_wid = target,
            .split_mode = switch (side) {
                .left, .right => .horizontal,
                .up, .down => .vertical,
            },
            .child = switch (side) {
                .left, .up => .first,
                .right, .down => .second,
            },
            .split_ratio = 0.5,
        },
    } };
}
