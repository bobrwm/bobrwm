//! Layout transitions owned by the application reducer.

const std = @import("std");
const invariants = @import("../invariants.zig");
const model_mod = @import("../model.zig");
const tiling_mod = @import("../../tiling.zig");

const LayoutRebuild = model_mod.LayoutRebuild;
const Transition = model_mod.Transition;
const WindowId = model_mod.WindowId;

pub fn applyEvent(transition: *Transition, event: tiling_mod.Event) bool {
    const layout_transition = tiling_mod.reduce(transition.model.layout, event);
    transition.model.layout = layout_transition.model;
    if (layout_transition.effect) |effect| {
        transition.addEffect(.{ .layout = effect });
        return false;
    }
    return true;
}

pub fn rebuild(transition: *Transition, request: LayoutRebuild) void {
    if (request.space_count > request.spaces.len) return;
    if (!std.math.isFinite(request.inner_gap) or !std.math.isFinite(request.split_ratio)) return;

    const original_layout = transition.model.layout;
    transition.model.layout = .{};
    for (request.spaces[0..request.space_count]) |layout_space| {
        const space = transition.model.space(layout_space.space_key) orelse {
            transition.model.layout = original_layout;
            return;
        };
        if (layout_space.root_frame) |frame| {
            if (!invariants.frameIsFinite(frame) or frame.width <= 0 or frame.height <= 0) {
                transition.model.layout = original_layout;
                return;
            }
        }

        for (transition.model.windows.items()) |window| {
            if (!window.space_key.eql(space.key)) continue;
            if (window.tab_leader_window_id != window.window_id) continue;
            if (window.mode != .tiled) continue;

            const anchor_window_id: ?WindowId = switch (request.insert_point) {
                .focused => blk: {
                    const focused_window_id = transition.model.focusedWorkspaceWindow(space.workspace_id) orelse break :blk null;
                    if (focused_window_id == window.window_id) break :blk null;
                    break :blk focused_window_id;
                },
                .first => transition.model.layout.firstWid(space.key),
                .last => transition.model.layout.lastWid(space.key),
                .min_depth => null,
            };
            if (!applyEvent(transition, .{ .insert = .{
                .space_key = space.key,
                .kind = request.kind,
                .window_id = window.window_id,
                .options = .{
                    .split_mode = request.split_mode,
                    .child = request.insert_child,
                    .anchor_wid = anchor_window_id,
                    .root_frame = layout_space.root_frame,
                    .inner_gap = request.inner_gap,
                    .split_ratio = request.split_ratio,
                },
            } })) {
                transition.model.layout = original_layout;
                return;
            }
        }
        const focused_window_id = transition.model.focusedWorkspaceWindow(space.workspace_id) orelse continue;
        if (!transition.model.layout.contains(space.key, focused_window_id)) continue;
        _ = applyEvent(transition, .{ .set_active = .{
            .space_key = space.key,
            .window_id = focused_window_id,
        } });
    }
}
