//! Managed-window lifecycle transitions.

const std = @import("std");
const model_mod = @import("../model.zig");
const layout_reducer = @import("layout.zig");
const pointer_reducer = @import("pointer.zig");

const Event = model_mod.Event;
const Transition = model_mod.Transition;
const WindowAdoption = model_mod.WindowAdoption;
const WindowId = model_mod.WindowId;
const WindowTabDetachment = model_mod.WindowTabDetachment;
const WindowTabGroupObservation = model_mod.WindowTabGroupObservation;
const WindowTabGroupSnapshot = model_mod.WindowTabGroupSnapshot;
const WindowUpdate = model_mod.WindowUpdate;

pub fn reduceWindowAdopted(transition: *Transition, adoption: WindowAdoption) void {
    const original_model = transition.model;
    const window = adoption.managedWindow();
    if (window.window_id == 0 or window.process_id <= 0) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .invalid_window,
        } });
        return;
    }
    if (transition.model.window(window.window_id) != null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .window_exists,
        } });
        return;
    }
    if (transition.model.space(window.space_key) == null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .space_missing,
        } });
        return;
    }
    if (transition.model.windows.count == transition.model.windows.entries.len) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.window_id,
            .reason = .catalog_full,
        } });
        return;
    }
    if (adoption.layout) |layout| {
        if (window.mode != .tiled) {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = window.window_id,
                .reason = .invalid_window,
            } });
            return;
        }
        if (!layout_reducer.applyEvent(transition, .{ .insert = .{
            .space_key = window.space_key,
            .kind = layout.kind,
            .window_id = window.window_id,
            .options = layout.options,
        } })) return;
    }

    var adopted = window;
    adopted.tab_leader_window_id = adopted.window_id;
    adopted.is_suppressed = false;
    std.debug.assert(transition.model.windows.put(adopted));
    transition.model.geometry.seedObserved(adopted.window_id, adopted.frame) catch unreachable;

    if (adoption.tab_group) |observation| {
        const effect_count = transition.effect_count;
        reduceWindowTabGroupObserved(transition, observation);
        if (transition.effect_count != effect_count) {
            transition.model = original_model;
            return;
        }
    }

    _ = transition.model.pending_role_windows.remove(adopted.window_id);
    _ = transition.model.deferred_window_candidates.remove(adopted.window_id);
}

pub fn reduceWindowUpdated(transition: *Transition, update: WindowUpdate) void {
    const window = update.window;
    const previous = transition.model.window(window.wid) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.wid,
            .reason = .window_missing,
        } });
        return;
    };
    if (previous.process_id != window.pid) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = window.wid,
            .reason = .invalid_window,
        } });
        return;
    }

    const is_layout_owner = previous.tab_leader_window_id == previous.window_id;
    if (is_layout_owner and previous.mode != window.mode) {
        if (window.mode == .tiled) {
            const layout = update.layout orelse {
                transition.addEffect(.{ .window_catalog_rejected = .{
                    .window_id = window.wid,
                    .reason = .layout_missing,
                } });
                return;
            };
            if (!layout_reducer.applyEvent(transition, .{ .insert = .{
                .space_key = previous.space_key,
                .kind = layout.kind,
                .window_id = window.wid,
                .options = layout.options,
            } })) return;
        } else {
            _ = layout_reducer.applyEvent(transition, .{ .remove = .{
                .space_key = previous.space_key,
                .window_id = window.wid,
            } });
        }
    }

    std.debug.assert(transition.model.windows.update(window));
}

pub fn reduceWindowRemoved(transition: *Transition, window_id: WindowId) void {
    const window = transition.model.window(window_id) orelse return;
    const group = transition.model.windowTabGroup(window_id);
    const owned_layout = window.tab_leader_window_id == window_id and
        transition.model.layout.contains(window.space_key, window_id);

    pointer_reducer.removeWindowFromPointerState(transition, window_id);
    _ = transition.model.pending_native_window_moves.remove(window_id);
    std.debug.assert(transition.model.windows.remove(window_id));
    transition.model.geometry.forget(window_id);
    if (!owned_layout) return;

    const successor_window_id: ?WindowId = if (group) |snapshot| blk: {
        for (snapshot.members()) |member_window_id| {
            if (member_window_id == window_id) continue;
            break :blk transition.model.windowTabLeader(member_window_id);
        }
        break :blk null;
    } else null;
    if (successor_window_id) |successor| {
        _ = layout_reducer.applyEvent(transition, .{ .replace_window_id = .{
            .space_key = window.space_key,
            .old_window_id = window_id,
            .new_window_id = successor,
        } });
        return;
    }

    _ = layout_reducer.applyEvent(transition, .{ .remove = .{
        .space_key = window.space_key,
        .window_id = window_id,
    } });
}

pub fn reduceWindowIdReplaced(
    transition: *Transition,
    replacement: @FieldType(Event, "replace_window_id"),
) void {
    if (replacement.new_window_id == 0) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.new_window_id,
            .reason = .invalid_window,
        } });
        return;
    }
    if (transition.model.window(replacement.new_window_id) != null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.new_window_id,
            .reason = .window_exists,
        } });
        return;
    }
    const previous = transition.model.window(replacement.old_window_id) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = replacement.old_window_id,
            .reason = .window_missing,
        } });
        return;
    };
    if (transition.model.layout.contains(previous.space_key, replacement.old_window_id)) {
        _ = layout_reducer.applyEvent(transition, .{ .replace_window_id = .{
            .space_key = previous.space_key,
            .old_window_id = replacement.old_window_id,
            .new_window_id = replacement.new_window_id,
        } });
    }

    std.debug.assert(transition.model.windows.replaceId(replacement.old_window_id, replacement.new_window_id));
    transition.model.geometry.replaceWindowId(replacement.old_window_id, replacement.new_window_id);
    if (transition.model.pending_native_window_moves.remove(replacement.old_window_id)) |pending| {
        var updated = pending;
        updated.window_id = replacement.new_window_id;
        std.debug.assert(transition.model.pending_native_window_moves.put(updated));
    }
    pointer_reducer.replacePointerWindowId(&transition.model, replacement.old_window_id, replacement.new_window_id);
    _ = transition.model.pending_role_windows.remove(replacement.new_window_id);
    _ = transition.model.deferred_window_candidates.remove(replacement.new_window_id);
    for (&transition.model.workspace_focus) |*focus| {
        focus.replaceWindowId(replacement.old_window_id, replacement.new_window_id);
    }
}

pub fn reduceWindowSpaceAssigned(
    transition: *Transition,
    assignment: @FieldType(Event, "assign_window_space"),
) void {
    if (transition.model.space(assignment.space_key) == null) {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = assignment.window_id,
            .reason = .space_missing,
        } });
        return;
    }
    const window = transition.model.window(assignment.window_id) orelse {
        transition.addEffect(.{ .window_catalog_rejected = .{
            .window_id = assignment.window_id,
            .reason = .window_missing,
        } });
        return;
    };
    const leader = transition.model.window(window.tab_leader_window_id).?;
    if (leader.space_key.eql(assignment.space_key)) return;

    if (transition.model.layout.contains(leader.space_key, leader.window_id)) {
        const layout = assignment.layout orelse {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = assignment.window_id,
                .reason = .layout_missing,
            } });
            return;
        };
        if (!layout_reducer.applyEvent(transition, .{ .move_window = .{
            .source_key = leader.space_key,
            .target_key = assignment.space_key,
            .kind = layout.kind,
            .window_id = leader.window_id,
            .options = layout.options,
        } })) return;
    }

    std.debug.assert(transition.model.windows.assignSpace(assignment.window_id, assignment.space_key));
}

pub fn reduceWindowTabGroupObserved(
    transition: *Transition,
    observation: WindowTabGroupObservation,
) void {
    if (observation.member_count > observation.member_window_ids.len) {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    }
    const leader = transition.model.window(observation.leader_window_id) orelse {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    };
    if (observation.member_count < 2 or
        !observation.contains(observation.leader_window_id) or
        !observation.contains(observation.active_window_id))
    {
        rejectWindowTabGroup(transition, observation.leader_window_id);
        return;
    }
    for (observation.members(), 0..) |window_id, index| {
        for (observation.members()[0..index]) |prior_window_id| {
            if (prior_window_id != window_id) continue;
            rejectWindowTabGroup(transition, window_id);
            return;
        }
        const member = transition.model.window(window_id) orelse {
            rejectWindowTabGroup(transition, window_id);
            return;
        };
        if (member.process_id != leader.process_id or
            (member.tab_leader_window_id != member.window_id and
                member.tab_leader_window_id != observation.leader_window_id))
        {
            rejectWindowTabGroup(transition, window_id);
            return;
        }
    }

    for (observation.members()) |window_id| {
        if (window_id == observation.leader_window_id) continue;
        const member = transition.model.window(window_id).?;
        if (!transition.model.layout.contains(member.space_key, window_id)) continue;
        _ = layout_reducer.applyEvent(transition, .{ .remove = .{
            .space_key = member.space_key,
            .window_id = window_id,
        } });
    }
    for (observation.members()) |window_id| {
        std.debug.assert(transition.model.windows.assignSpace(window_id, leader.space_key));
    }
    transition.model.windows.observeTabGroup(observation);
}

pub fn reduceWindowTabDetached(transition: *Transition, detachment: WindowTabDetachment) void {
    const window = transition.model.window(detachment.window_id) orelse {
        rejectWindowTabGroup(transition, detachment.window_id);
        return;
    };
    const group = transition.model.windowTabGroup(detachment.window_id) orelse return;
    if (window.mode == .tiled and
        transition.model.layout.contains(window.space_key, group.leader_window_id))
    {
        const layout = detachment.layout orelse {
            transition.addEffect(.{ .window_catalog_rejected = .{
                .window_id = detachment.window_id,
                .reason = .layout_missing,
            } });
            return;
        };

        const original_layout = transition.model.layout;
        const is_leader = group.leader_window_id == detachment.window_id;
        const inserted_window_id = if (is_leader and group.member_count == 2)
            firstOtherGroupMember(&group, detachment.window_id).?
        else
            detachment.window_id;
        var options = layout.options;
        if (is_leader and group.member_count > 2) {
            const successor = firstOtherGroupMember(&group, detachment.window_id).?;
            if (options.anchor_wid == detachment.window_id) options.anchor_wid = successor;
            _ = layout_reducer.applyEvent(transition, .{ .replace_window_id = .{
                .space_key = window.space_key,
                .old_window_id = detachment.window_id,
                .new_window_id = successor,
            } });
        }
        if (!layout_reducer.applyEvent(transition, .{ .insert = .{
            .space_key = window.space_key,
            .kind = layout.kind,
            .window_id = inserted_window_id,
            .options = options,
        } })) {
            transition.model.layout = original_layout;
            return;
        }
    }

    std.debug.assert(transition.model.windows.detachTab(detachment.window_id));
}

fn firstOtherGroupMember(group: *const WindowTabGroupSnapshot, window_id: WindowId) ?WindowId {
    for (group.members()) |member_window_id| {
        if (member_window_id != window_id) return member_window_id;
    }
    return null;
}

pub fn reduceWorkspaceFocusRecorded(
    transition: *Transition,
    focus: @FieldType(Event, "record_workspace_focus"),
) void {
    const space = transition.model.logicalWorkspace(focus.workspace_id) orelse return;
    const window = transition.model.window(focus.window_id) orelse return;
    const leader = transition.model.window(window.tab_leader_window_id).?;
    if (!leader.space_key.eql(space.key)) return;

    transition.model.workspace_focus[focus.workspace_id - 1].record(leader.window_id);
}

fn rejectWindowTabGroup(transition: *Transition, window_id: WindowId) void {
    transition.addEffect(.{ .window_catalog_rejected = .{
        .window_id = window_id,
        .reason = .invalid_tab_group,
    } });
}
