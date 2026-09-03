//! User command transitions.

const std = @import("std");
const invariants = @import("../invariants.zig");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");
const window_reducer = @import("window.zig");
const workspace_reducer = @import("workspace.zig");
const window_mod = @import("../../window.zig");

const Event = model_mod.Event;
const FocusDirection = model_mod.FocusDirection;
const ManagedWindow = model_mod.ManagedWindow;
const Model = model_mod.Model;
const SpaceRef = model_mod.SpaceRef;
const Transition = model_mod.Transition;
const WindowId = model_mod.WindowId;
const WindowMoveRequest = model_mod.WindowMoveRequest;

const ActionWindow = struct {
    leader: ManagedWindow,
    space: SpaceRef,
};

pub fn reduceFocusDirection(
    transition: *Transition,
    command: @FieldType(Event, "focus_direction"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const target_window_id = windowInDirection(&transition.model, action, command.direction) orelse
        transition.model.layout.cycleFocus(
            action.space.key,
            action.leader.window_id,
            command.direction == .right or command.direction == .down,
        ) orelse return;
    const target = transition.model.window(target_window_id) orelse return;
    const leader = transition.model.window(target.tab_leader_window_id) orelse return;
    if (!leader.space_key.eql(action.space.key)) return;
    const active_window_id = transition.model.windowTabActive(leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;

    window_reducer.reduceWorkspaceFocusRecorded(transition, .{
        .workspace_id = action.space.workspace_id,
        .window_id = leader.window_id,
    });
    _ = layout_reducer.applyEvent(transition, .{ .set_active = .{
        .space_key = action.space.key,
        .window_id = leader.window_id,
    } });
    transition.addEffect(.{ .focus_window = .{
        .window_id = active.window_id,
        .process_id = active.process_id,
    } });
}

pub fn reduceSwapDirection(
    transition: *Transition,
    command: @FieldType(Event, "swap_direction"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const target_window_id = windowInDirection(&transition.model, action, command.direction) orelse return;
    if (!transition.model.layout.contains(action.space.key, action.leader.window_id)) return;
    if (!transition.model.layout.contains(action.space.key, target_window_id)) return;
    if (!layout_reducer.applyEvent(transition, .{ .swap_window_ids = .{
        .space_key = action.space.key,
        .first_window_id = action.leader.window_id,
        .second_window_id = target_window_id,
    } })) return;

    workspace_reducer.reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .windows_swapped = .{
        .first_window_id = action.leader.window_id,
        .second_window_id = target_window_id,
        .direction = command.direction,
    } });
}

pub fn reduceWindowModeCommand(
    transition: *Transition,
    command: @FieldType(Event, "set_window_mode"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    if (action.leader.mode == command.mode) return;

    var window = action.leader.snapshot();
    window.mode = command.mode;
    window_reducer.reduceWindowUpdated(transition, .{
        .window = window,
        .layout = command.layout,
    });
    const updated = transition.model.window(action.leader.window_id) orelse return;
    if (updated.mode != command.mode) return;

    workspace_reducer.reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .window_mode_changed = .{
        .window_id = updated.window_id,
        .previous = action.leader.mode,
        .current = updated.mode,
    } });
}

pub fn reduceFullscreenCommand(
    transition: *Transition,
    command: @FieldType(Event, "toggle_window_fullscreen"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    const active_window_id = transition.model.windowTabActive(action.leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;

    var leader = action.leader.snapshot();
    leader.is_fullscreen = !leader.is_fullscreen;
    const restore_frame: ?window_mod.Window.Frame = blk: {
        if (leader.mode != .floating) break :blk null;
        if (!leader.is_fullscreen) break :blk leader.float_frame;

        const observed = command.observed_frame orelse leader.frame;
        if (!invariants.frameIsFinite(observed) or observed.width <= 0 or observed.height <= 0) return;
        leader.float_frame = observed;
        break :blk null;
    };
    window_reducer.reduceWindowUpdated(transition, .{ .window = leader });

    workspace_reducer.reduceRetileDisplayRequested(&transition.model, action.space.display_id);
    transition.addEffect(.{ .fullscreen_changed = .{
        .leader_window_id = action.leader.window_id,
        .window_id = active.window_id,
        .process_id = active.process_id,
        .is_fullscreen = leader.is_fullscreen,
        .mode = leader.mode,
        .restore_frame = restore_frame,
    } });
}

pub fn reduceCenterWindowCommand(
    transition: *Transition,
    command: @FieldType(Event, "center_floating_window"),
) void {
    const action = resolveActionWindow(&transition.model, command.window_id) orelse return;
    if (action.leader.mode != .floating or action.leader.is_fullscreen) return;
    if (!invariants.frameIsFinite(command.observed_frame) or !invariants.frameIsFinite(command.display_frame)) return;
    if (command.observed_frame.width <= 0 or command.observed_frame.height <= 0) return;
    if (command.display_frame.width <= 0 or command.display_frame.height <= 0) return;

    const active_window_id = transition.model.windowTabActive(action.leader.window_id);
    const active = transition.model.window(active_window_id) orelse return;
    const target: window_mod.Window.Frame = .{
        .x = command.display_frame.x + (command.display_frame.width - command.observed_frame.width) / 2.0,
        .y = command.display_frame.y + (command.display_frame.height - command.observed_frame.height) / 2.0,
        .width = command.observed_frame.width,
        .height = command.observed_frame.height,
    };
    transition.addEffect(.{ .center_window = .{
        .leader_window_id = action.leader.window_id,
        .window_id = active.window_id,
        .process_id = active.process_id,
        .current_frame = active.frame,
        .target_frame = target,
    } });
}

pub fn reduceWindowFrameCommandResult(
    transition: *Transition,
    result: @FieldType(Event, "window_frame_command_result"),
) void {
    if (!result.succeeded) return;
    if (!invariants.frameIsFinite(result.target_frame)) return;

    var visible = transition.model.window(result.window_id) orelse return;
    visible.frame = result.target_frame;
    std.debug.assert(transition.model.windows.update(visible.snapshot()));

    if (result.leader_window_id == result.window_id) {
        if (!result.should_save_float_frame) return;
        visible.float_frame = result.target_frame;
        std.debug.assert(transition.model.windows.update(visible.snapshot()));
        return;
    }

    var leader = transition.model.window(result.leader_window_id) orelse return;
    if (leader.tab_leader_window_id != leader.window_id) return;
    leader.frame = result.target_frame;
    if (result.should_save_float_frame) leader.float_frame = result.target_frame;
    std.debug.assert(transition.model.windows.update(leader.snapshot()));
}

pub fn reduceWindowMoveRequest(transition: *Transition, request: WindowMoveRequest) void {
    const action = resolveActionWindow(&transition.model, request.window_id) orelse return;
    const target = transition.model.space(request.target.key) orelse return;
    if (action.space.key.eql(target.key)) return;
    if (request.should_move_native and (action.space.key != .native or target.key != .native)) return;

    window_reducer.reduceWindowSpaceAssigned(transition, .{
        .window_id = action.leader.window_id,
        .space_key = target.key,
        .layout = request.layout,
    });
    const moved = transition.model.window(action.leader.window_id) orelse return;
    if (!moved.space_key.eql(target.key)) return;
    workspace_reducer.refreshWorkspaceFocus(&transition.model);

    if (transition.model.focusedWorkspaceWindow(target.workspace_id) == null) {
        window_reducer.reduceWorkspaceFocusRecorded(transition, .{
            .workspace_id = target.workspace_id,
            .window_id = moved.window_id,
        });
    }
    transition.model.retile_request.all_displays = true;
    transition.model.retile_request.display_count = 0;
    if (request.should_move_native) {
        workspace_reducer.reduceNativeWindowMoveTracked(transition, .{
            .window_id = moved.window_id,
            .source = action.space,
            .target = target,
        });
    }

    const active_window_id = transition.model.windowTabActive(moved.window_id);
    const active = transition.model.window(active_window_id) orelse return;
    transition.addEffect(.{ .window_moved = .{
        .window_id = active.window_id,
        .process_id = active.process_id,
        .source = action.space,
        .target = target,
        .should_hide = !request.should_move_native and
            transition.model.activeWorkspace(target.display_id) != target.workspace_id,
        .should_follow_focus = request.should_follow_focus,
    } });
}

fn resolveActionWindow(model: *const Model, window_id: WindowId) ?ActionWindow {
    const window = model.window(window_id) orelse return null;
    const leader = model.window(window.tab_leader_window_id) orelse return null;
    const space = model.space(leader.space_key) orelse return null;
    if (model.activeWorkspace(space.display_id) != space.workspace_id) return null;
    return .{ .leader = leader, .space = space };
}

fn windowInDirection(model: *const Model, action: ActionWindow, direction: FocusDirection) ?WindowId {
    const focused = action.leader.frame;
    const focused_center_x = focused.x + focused.width / 2.0;
    const focused_center_y = focused.y + focused.height / 2.0;
    var best_window_id: ?WindowId = null;
    var best_distance = std.math.inf(f64);

    for (model.windows.items()) |window| {
        if (!window.space_key.eql(action.space.key)) continue;
        if (window.tab_leader_window_id != window.window_id) continue;
        if (window.window_id == action.leader.window_id) continue;

        const center_x = window.frame.x + window.frame.width / 2.0;
        const center_y = window.frame.y + window.frame.height / 2.0;
        const delta_x = center_x - focused_center_x;
        const delta_y = center_y - focused_center_y;
        const is_in_direction = switch (direction) {
            .left => delta_x < 0,
            .right => delta_x > 0,
            .up => delta_y < 0,
            .down => delta_y > 0,
        };
        if (!is_in_direction) continue;

        const distance = @abs(delta_x) + @abs(delta_y);
        if (distance >= best_distance) continue;
        best_distance = distance;
        best_window_id = window.window_id;
    }
    return best_window_id;
}
