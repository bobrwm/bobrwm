//! Window-discovery and process-retry transitions.

const model_mod = @import("../model.zig");
const workspace_reducer = @import("workspace.zig");

const DeferredWindowExpiryReason = model_mod.DeferredWindowExpiryReason;
const Event = model_mod.Event;
const ProcessRetries = model_mod.ProcessRetries;
const ProcessRetry = model_mod.ProcessRetry;
const Transition = model_mod.Transition;
const WindowCandidate = model_mod.WindowCandidate;
const WindowId = model_mod.WindowId;

pub fn reducePendingRoleTracked(transition: *Transition, candidate: WindowCandidate) void {
    if (!workspace_reducer.windowCandidateIsValid(&transition.model, candidate) or candidate.attempts_remaining == 0) return;
    if (transition.model.window(candidate.window_id) != null) {
        _ = transition.model.pending_role_windows.remove(candidate.window_id);
        return;
    }
    if (!transition.model.pending_role_windows.track(candidate, true)) {
        @panic("pending role window capacity exceeded");
    }
}

pub fn reducePendingRoleObserved(
    transition: *Transition,
    observation: @FieldType(Event, "pending_role_observed"),
) void {
    if (transition.model.window(observation.window_id) != null) {
        _ = transition.model.pending_role_windows.remove(observation.window_id);
        return;
    }
    const candidate = transition.model.pending_role_windows.getPtr(observation.window_id) orelse return;

    switch (observation.readiness) {
        .reject => _ = transition.model.pending_role_windows.remove(observation.window_id),
        .ready => {
            const ready = transition.model.pending_role_windows.remove(observation.window_id).?;
            transition.addEffect(.{ .pending_role_ready = ready });
        },
        .pending => {
            if (candidate.attempts_remaining > 0) {
                candidate.attempts_remaining -= 1;
                return;
            }
            const expired = transition.model.pending_role_windows.remove(observation.window_id).?;
            transition.addEffect(.{ .pending_role_expired = expired });
        },
    }
}

pub fn reduceDeferredWindowTracked(transition: *Transition, candidate: WindowCandidate) void {
    if (!workspace_reducer.windowCandidateIsValid(&transition.model, candidate) or candidate.attempts_remaining == 0) return;
    if (transition.model.window(candidate.window_id) != null) {
        _ = transition.model.deferred_window_candidates.remove(candidate.window_id);
        return;
    }
    if (!transition.model.deferred_window_candidates.track(candidate, false)) {
        @panic("deferred window candidate capacity exceeded");
    }
}

pub fn reduceDeferredWindowObserved(
    transition: *Transition,
    observation: @FieldType(Event, "deferred_window_observed"),
) void {
    if (transition.model.window(observation.window_id) != null) {
        _ = transition.model.deferred_window_candidates.remove(observation.window_id);
        return;
    }
    const candidate = transition.model.deferred_window_candidates.getPtr(observation.window_id) orelse return;

    switch (observation.readiness) {
        .reject => _ = transition.model.deferred_window_candidates.remove(observation.window_id),
        .pending => expireOrDecrementDeferredWindow(transition, candidate, .role_pending),
        .ready => {
            if (!observation.is_visible) {
                expireOrDecrementDeferredWindow(transition, candidate, .off_screen);
                return;
            }
            transition.addEffect(.{ .deferred_window_ready = candidate.* });
        },
    }
}

pub fn reduceDeferredWindowPromotionFailed(transition: *Transition, window_id: WindowId) void {
    const candidate = transition.model.deferred_window_candidates.getPtr(window_id) orelse return;
    expireOrDecrementDeferredWindow(transition, candidate, .unsettled_bounds);
}

pub fn expireOrDecrementDeferredWindow(
    transition: *Transition,
    candidate: *WindowCandidate,
    reason: DeferredWindowExpiryReason,
) void {
    if (candidate.attempts_remaining > 0) {
        candidate.attempts_remaining -= 1;
        return;
    }
    const expired = transition.model.deferred_window_candidates.remove(candidate.window_id).?;
    transition.addEffect(.{ .deferred_window_expired = .{
        .candidate = expired,
        .reason = reason,
    } });
}

pub fn reduceProcessRetryTracked(retries: *ProcessRetries, retry: ProcessRetry) void {
    if (retry.process_id <= 0 or retry.attempts_remaining == 0) return;
    if (!retries.track(retry)) @panic("process retry capacity exceeded");
}

pub fn reduceAppLaunchRetryTimer(transition: *Transition, process_id: i32) void {
    const retry = transition.model.app_launch_retries.getPtr(process_id) orelse return;
    if (retry.attempts_remaining > 0) {
        retry.attempts_remaining -= 1;
        return;
    }
    _ = transition.model.app_launch_retries.remove(process_id);
    transition.addEffect(.{ .app_launch_retry_ready = process_id });
}

pub fn reduceFocusRetryObserved(
    transition: *Transition,
    observation: @FieldType(Event, "focus_retry_observed"),
) void {
    const retry = transition.model.focus_retries.getPtr(observation.process_id) orelse return;
    if (observation.focused_window_id != 0) {
        _ = transition.model.focus_retries.remove(observation.process_id);
        transition.addEffect(.{ .focus_retry_resolved = .{
            .process_id = observation.process_id,
            .window_id = observation.focused_window_id,
        } });
        return;
    }
    if (retry.attempts_remaining > 0) {
        retry.attempts_remaining -= 1;
        return;
    }
    _ = transition.model.focus_retries.remove(observation.process_id);
    transition.addEffect(.{ .focus_retry_expired = observation.process_id });
}
