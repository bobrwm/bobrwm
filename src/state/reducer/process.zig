//! Process lifecycle transitions.

const std = @import("std");
const model_mod = @import("../model.zig");
const pointer_reducer = @import("pointer.zig");

const ProcessIdentity = model_mod.ProcessIdentity;
const Transition = model_mod.Transition;

pub fn reduceProcessObserved(transition: *Transition, identity: ProcessIdentity) void {
    std.debug.assert(identity.process_id > 0);
    const processes = &transition.model.processes;

    const known = processes.get(identity.process_id) orelse {
        if (!processes.put(identity)) transition.addEffect(.{ .process_table_full = identity });
        return;
    };
    if (known.started_at_us == identity.started_at_us) return;

    forgetProcess(transition, identity.process_id);
    std.debug.assert(processes.put(identity));
    transition.addEffect(.{ .process_replaced = identity.process_id });
}

pub fn reduceProcessTerminated(transition: *Transition, process_id: i32) void {
    std.debug.assert(process_id > 0);
    forgetProcess(transition, process_id);
    _ = transition.model.processes.remove(process_id);

    // Untracked PIDs end too: the shell can hold state for a process whose
    // start time it could not read.
    transition.addEffect(.{ .process_ended = process_id });
}

/// Drop reducer state keyed by the PID. Windows leave through the shell's
/// per-window removal, which one transition's effect budget cannot hold.
fn forgetProcess(transition: *Transition, process_id: i32) void {
    const model = transition.model;
    pointer_reducer.reduceProcessTerminated(transition, process_id);
    model.pending_role_windows.removeProcess(process_id);
    model.deferred_window_candidates.removeProcess(process_id);
    _ = model.app_launch_retries.remove(process_id);
    _ = model.focus_retries.remove(process_id);
}
