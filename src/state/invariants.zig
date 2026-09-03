//! Cross-domain model invariants.

const std = @import("std");
const model_mod = @import("model.zig");
const window_mod = @import("../window.zig");

const Model = model_mod.Model;
const ProcessRetries = model_mod.ProcessRetries;
const SpaceRef = model_mod.SpaceRef;
const WindowCandidate = model_mod.WindowCandidate;
const WindowCandidates = model_mod.WindowCandidates;
const WorkspaceId = model_mod.WorkspaceId;

fn windowCandidateIsValid(model: *const Model, candidate: WindowCandidate) bool {
    return candidate.process_id > 0 and
        candidate.window_id != 0 and
        model.space(candidate.space_key) != null;
}

pub fn assertModel(model: *const Model) void {
    std.debug.assert(model.next_epoch != 0);
    model.layout.assertValid();
    std.debug.assert(model.spaces.space_count <= model.spaces.spaces.len);
    for (model.spaces.spaces[0..model.spaces.space_count], 0..) |space, index| {
        space.assertValid();
        for (model.spaces.spaces[0..index]) |prior| {
            std.debug.assert(!prior.key.eql(space.key));
            std.debug.assert(prior.display_id != space.display_id or prior.workspace_id != space.workspace_id);
        }
    }
    std.debug.assert(model.windows.count <= model.windows.entries.len);
    for (model.windows.items(), 0..) |window, index| {
        std.debug.assert(window.window_id != 0);
        std.debug.assert(window.process_id > 0);
        std.debug.assert(window.tab_leader_window_id != 0);
        std.debug.assert(frameIsFinite(window.frame));
        if (window.float_frame) |frame| std.debug.assert(frameIsFinite(frame));
        for (model.windows.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != window.window_id);
        }

        const leader = model.window(window.tab_leader_window_id).?;
        std.debug.assert(leader.process_id == window.process_id);
        std.debug.assert(leader.space_key.eql(window.space_key));
        std.debug.assert(leader.tab_leader_window_id == leader.window_id);
        if (window.tab_leader_window_id != window.window_id) continue;

        var member_count: u16 = 0;
        var active_count: u16 = 0;
        for (model.windows.items()) |member| {
            if (member.tab_leader_window_id != window.window_id) continue;
            member_count += 1;
            if (!member.is_suppressed) active_count += 1;
        }
        std.debug.assert(member_count > 0);
        std.debug.assert(active_count == 1);
    }
    for (model.workspace_focus, 0..) |focus, index| {
        std.debug.assert(focus.history_count <= focus.history.len);
        const workspace_id: WorkspaceId = @intCast(index + 1);
        const space = model.logicalWorkspace(workspace_id);
        for (focus.history[0..focus.history_count], 0..) |window_id, history_index| {
            const window = model.window(window_id).?;
            std.debug.assert(window.tab_leader_window_id == window.window_id);
            std.debug.assert(space != null and window.space_key.eql(space.?.key));
            for (focus.history[0..history_index]) |prior| {
                std.debug.assert(prior != window_id);
            }
        }
        if (focus.focused_window_id) |window_id| {
            std.debug.assert(focus.history_count > 0);
            std.debug.assert(focus.history[focus.history_count - 1] == window_id);
        } else {
            std.debug.assert(focus.history_count == 0);
        }
    }
    std.debug.assert(model.workspace_topology.display_count <= model.workspace_topology.displays.len);
    for (model.workspace_topology.displays[0..model.workspace_topology.display_count], 0..) |display, index| {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.active_workspace_id != 0);
        for (model.workspace_topology.displays[0..index]) |prior| {
            std.debug.assert(prior.display_id != display.display_id);
            std.debug.assert(prior.active_workspace_id != display.active_workspace_id);
        }
    }
    if (model.workspace_topology.focused_display_id) |display_id| {
        std.debug.assert(model.workspace_topology.findDisplay(display_id) != null);
    }
    std.debug.assert(model.native_topology.display_count <= model.native_topology.displays.len);
    for (model.native_topology.displays[0..model.native_topology.display_count], 0..) |display, index| {
        std.debug.assert(display.display_id != 0);
        std.debug.assert(display.observed_space_id != 0);
        std.debug.assert(display.space_count <= display.spaces.len);
        for (model.native_topology.displays[0..index]) |prior| {
            std.debug.assert(prior.display_id != display.display_id);
        }
        for (display.spaces[0..display.space_count], 0..) |space, space_index| {
            std.debug.assert(space.id != 0);
            std.debug.assert(space.workspace_id != 0);
            for (display.spaces[0..space_index]) |prior| {
                std.debug.assert(prior.id != space.id);
                std.debug.assert(prior.workspace_id != space.workspace_id);
            }
        }
    }
    if (model.native_topology.display_count > 0) {
        var physical_space_count: u8 = 0;
        for (model.native_topology.displays[0..model.native_topology.display_count]) |display| {
            for (display.spaces[0..display.space_count]) |space| {
                const space_ref = model.space(.{ .id = space.id }).?;
                std.debug.assert(space_ref.workspace_id == space.workspace_id);
                std.debug.assert(space_ref.display_id == display.display_id);
                physical_space_count += 1;
            }
        }
        std.debug.assert(model.spaces.space_count == physical_space_count);
    }
    if (model.pending_switch) |pending| {
        std.debug.assert(pending.epoch != 0);
        pending.request.target.assertValid();
        std.debug.assert(pending.request.target.key.id != 0);
        if (model.observation_timer) |timer| std.debug.assert(timer.epoch == pending.epoch);
    }
    if (model.queued_switch) |queued| {
        queued.target.assertValid();
        std.debug.assert(queued.target.key.id != 0);
    }
    if (model.pending_native_workspace_move) |pending| {
        std.debug.assert(pending.epoch != 0);
        std.debug.assert(pending.source.key.id != 0);
        std.debug.assert(pending.target.key.id != 0);
        std.debug.assert(!pending.source.key.eql(pending.target.key));
        std.debug.assert(pending.source.display_id != pending.target.display_id);
        std.debug.assert(model.workspace_transition != null);
        std.debug.assert(model.workspace_transition.?.epoch == pending.epoch);
    }
    if (model.workspace_transition) |workspace_transition| {
        std.debug.assert(workspace_transition.epoch != 0);
        workspace_transition.target.assertValid();
        const target = model.space(workspace_transition.target.key).?;
        std.debug.assert(target.display_id == workspace_transition.target.display_id);
        std.debug.assert(target.workspace_id == workspace_transition.target.workspace_id);
        std.debug.assert(workspace_transition.deadline_at_ms >= workspace_transition.started_at_ms);
    }
    std.debug.assert(model.pending_native_window_moves.count <= model.pending_native_window_moves.entries.len);
    for (model.pending_native_window_moves.items(), 0..) |pending, index| {
        std.debug.assert(pending.window_id != 0);
        std.debug.assert(pending.epoch != 0);
        std.debug.assert(pending.attempts_remaining > 0);
        std.debug.assert(pending.source.key.id != 0);
        std.debug.assert(pending.target.key.id != 0);
        std.debug.assert(!pending.source.key.eql(pending.target.key));
        std.debug.assert(model.space(pending.source.key) != null);
        std.debug.assert(model.space(pending.target.key) != null);
        for (model.pending_native_window_moves.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != pending.window_id);
        }
    }
    std.debug.assert(model.pending_focus.count <= model.pending_focus.entries.len);
    std.debug.assert(model.pending_focus.next_sequence != 0);
    if (model.workspace_transition == null) std.debug.assert(!model.pending_focus.hasEntries());
    for (model.pending_focus.entries[0..model.pending_focus.count], 0..) |pending, index| {
        std.debug.assert(pending.process_id > 0);
        std.debug.assert(pending.window_id != 0);
        std.debug.assert(pending.source != .keyboard);
        std.debug.assert(pending.sequence != 0);
        std.debug.assert(pending.transition_epoch == model.workspace_transition.?.epoch);
        for (model.pending_focus.entries[0..index]) |prior| {
            std.debug.assert(prior.window_id != pending.window_id);
        }
    }
    if (model.workspace_transition == null) std.debug.assert(model.deferred_follow_focus == null);
    if (model.deferred_follow_focus) |deferred| {
        std.debug.assert(deferred.process_id > 0);
        std.debug.assert(deferred.window_id != 0);
        std.debug.assert(deferred.transition_epoch == model.workspace_transition.?.epoch);
    }
    assertWindowCandidates(model, &model.pending_role_windows);
    assertWindowCandidates(model, &model.deferred_window_candidates);
    assertProcessRetries(&model.app_launch_retries);
    assertProcessRetries(&model.focus_retries);
    if (!model.pointer_drag.is_down) {
        std.debug.assert(model.pointer_drag.candidate_window_id == null);
        std.debug.assert(model.pointer_drag.active_window_id == null);
        std.debug.assert(!model.pointer_drag.should_reconcile_on_drop);
    }
    if (model.pointer_drag.candidate_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
    }
    if (model.pointer_drag.active_window_id) |window_id| {
        std.debug.assert(model.pointer_drag.is_down);
        std.debug.assert(model.pointer_drag.candidate_window_id == window_id);
    }
    if (model.pointer_drag.should_reconcile_on_drop) {
        std.debug.assert(model.pointer_drag.active_window_id != null);
    }
    if (model.drag_preview.source_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
    }
    if (model.drag_preview.target_window_id) |window_id| {
        std.debug.assert(model.window(window_id) != null);
        std.debug.assert(model.drag_preview.source_window_id != null);
    }
    if (model.drag_preview.is_visible) std.debug.assert(model.drag_preview.target_window_id != null);
    std.debug.assert(model.retile_request.display_count <= model.retile_request.display_ids.len);
    if (model.retile_request.all_displays) std.debug.assert(model.retile_request.display_count == 0);
    for (model.retile_request.display_ids[0..model.retile_request.display_count], 0..) |display_id, index| {
        std.debug.assert(display_id != 0);
        for (model.retile_request.display_ids[0..index]) |prior| {
            std.debug.assert(prior != display_id);
        }
    }
    std.debug.assert(model.cleanup_request.process_count <= model.cleanup_request.process_ids.len);
    for (model.cleanup_request.process_ids[0..model.cleanup_request.process_count], 0..) |process_id, index| {
        std.debug.assert(process_id > 0);
        for (model.cleanup_request.process_ids[0..index]) |prior| {
            std.debug.assert(prior != process_id);
        }
    }
    std.debug.assert(crossDomainStateIsValid(model));
}

fn assertWindowCandidates(model: *const Model, candidates: *const WindowCandidates) void {
    std.debug.assert(candidates.count <= candidates.entries.len);
    for (candidates.items(), 0..) |candidate, index| {
        std.debug.assert(windowCandidateIsValid(model, candidate));
        std.debug.assert(model.window(candidate.window_id) == null);
        for (candidates.items()[0..index]) |prior| {
            std.debug.assert(prior.window_id != candidate.window_id);
        }
    }
}

fn assertProcessRetries(retries: *const ProcessRetries) void {
    std.debug.assert(retries.count <= retries.entries.len);
    for (retries.items(), 0..) |retry, index| {
        std.debug.assert(retry.process_id > 0);
        for (retries.items()[0..index]) |prior| {
            std.debug.assert(prior.process_id != retry.process_id);
        }
    }
}

pub fn crossDomainStateIsValid(model: *const Model) bool {
    if (model.geometry.windowCount() != model.windows.count) return false;

    var layout_window_count: usize = 0;
    for (model.windows.items()) |window| {
        if (model.space(window.space_key) == null) return false;
        if (model.geometry.get(window.window_id) == null) return false;
        if (!model.layout.contains(window.space_key, window.window_id)) continue;
        if (window.tab_leader_window_id != window.window_id) return false;
        if (window.mode != .tiled) return false;
        layout_window_count += 1;
    }
    return layout_window_count == model.layout.totalWindowCount();
}

pub fn frameIsFinite(frame: window_mod.Window.Frame) bool {
    return std.math.isFinite(frame.x) and
        std.math.isFinite(frame.y) and
        std.math.isFinite(frame.width) and
        std.math.isFinite(frame.height);
}
