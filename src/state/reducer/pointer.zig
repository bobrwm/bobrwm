//! Pointer-drag state transitions.

const invariants = @import("../invariants.zig");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");

const Event = model_mod.Event;
const Model = model_mod.Model;
const Transition = model_mod.Transition;
const WindowId = model_mod.WindowId;

pub fn removeWindowFromPointerState(transition: *Transition, window_id: WindowId) void {
    if (transition.model.pointer_drag.candidate_window_id == window_id) {
        transition.model.pointer_drag.candidate_window_id = null;
    }
    if (transition.model.pointer_drag.active_window_id == window_id) {
        transition.model.pointer_drag.active_window_id = null;
        transition.model.pointer_drag.should_reconcile_on_drop = false;
    }
    if (transition.model.drag_preview.source_window_id == window_id or
        transition.model.drag_preview.target_window_id == window_id)
    {
        clearDragPreview(transition);
    }
}

pub fn replacePointerWindowId(model: *Model, old_window_id: WindowId, new_window_id: WindowId) void {
    if (model.pointer_drag.candidate_window_id == old_window_id) {
        model.pointer_drag.candidate_window_id = new_window_id;
    }
    if (model.pointer_drag.active_window_id == old_window_id) {
        model.pointer_drag.active_window_id = new_window_id;
    }
    if (model.drag_preview.source_window_id == old_window_id) {
        model.drag_preview.source_window_id = new_window_id;
    }
    if (model.drag_preview.target_window_id == old_window_id) {
        model.drag_preview.target_window_id = new_window_id;
    }
}

pub fn reducePointerDown(transition: *Transition, candidate_window_id: ?WindowId) void {
    clearDragPreview(transition);
    transition.model.pointer_drag = .{
        .is_down = true,
        .candidate_window_id = if (candidate_window_id) |window_id|
            if (transition.model.window(window_id) != null) window_id else null
        else
            null,
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
    const source = transition.model.window(observation.source_window_id) orelse {
        clearDragPreview(transition);
        return;
    };
    if (source.mode != .tiled or source.is_fullscreen) {
        clearDragPreview(transition);
        return;
    }

    transition.model.drag_preview.source_window_id = source.window_id;
    const target_window_id = observation.target_window_id orelse {
        hideDragPreview(transition);
        return;
    };
    const target_frame = observation.target_frame orelse {
        hideDragPreview(transition);
        return;
    };
    if (!invariants.frameIsFinite(target_frame) or target_frame.width <= 0 or target_frame.height <= 0) {
        hideDragPreview(transition);
        return;
    }
    const target = transition.model.window(target_window_id) orelse {
        hideDragPreview(transition);
        return;
    };
    if (target.mode != .tiled or target.is_fullscreen or !target.space_key.eql(source.space_key)) {
        hideDragPreview(transition);
        return;
    }

    const target_changed = transition.model.drag_preview.target_window_id != target_window_id;
    transition.model.drag_preview.target_window_id = target_window_id;
    if (transition.model.drag_preview.is_visible and !target_changed) return;
    transition.model.drag_preview.is_visible = true;
    transition.addEffect(.{ .show_drag_preview = target_frame });
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
    if (!layout_reducer.applyEvent(transition, .{ .swap_window_ids = .{
        .space_key = source.space_key,
        .first_window_id = source_window_id,
        .second_window_id = target_window_id,
    } })) return;
    transition.addEffect(.{ .pointer_drag_completed = .{
        .should_retile = true,
        .swapped_window_ids = .{ .first = source_window_id, .second = target_window_id },
    } });
}

pub fn clearDragPreview(transition: *Transition) void {
    if (transition.model.drag_preview.is_visible) transition.addEffect(.hide_drag_preview);
    transition.model.drag_preview = .{};
}

fn hideDragPreview(transition: *Transition) void {
    transition.model.drag_preview.target_window_id = null;
    if (!transition.model.drag_preview.is_visible) return;
    transition.model.drag_preview.is_visible = false;
    transition.addEffect(.hide_drag_preview);
}
