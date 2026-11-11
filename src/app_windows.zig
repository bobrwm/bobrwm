//! An app's AX window list with each window's native tab count, read on the
//! app's queue. Tab decisions on the main thread read the latest snapshot.

const std = @import("std");
const c = @import("c");
const app_queue = @import("app_queue.zig");
const ax = @import("ax.zig");
const shim = @import("shim_api.zig");

pub const max_windows = 128;
const timeout_seconds: f32 = 0.25;

/// Why the list was requested, which decides what the main thread does with it.
pub const Reason = enum(u8) {
    tab_bar,
    offscreen_cleanup,
};

pub const Reasons = std.EnumSet(Reason);

pub const Snapshot = struct {
    pid: i32 = 0,
    windows: [max_windows]ax.AppWindow = undefined,
    count: usize = 0,
    /// The app listed more windows than fit.
    is_truncated: bool = false,
    /// Orders captures for eviction when every slot is taken.
    sequence: u64 = 0,

    pub fn items(self: *const Snapshot) []const ax.AppWindow {
        return self.windows[0..self.count];
    }
};

const PendingReasons = struct {
    pid: i32 = 0,
    reasons: Reasons = .empty,
};

var g_lock: c.os_unfair_lock = .{};
// One per app: a cleanup asks every app with a visible window at once, and a
// snapshot evicted before its answer is applied would skip that app.
var g_snapshots: [app_queue.max_apps]Snapshot = @splat(.{});
var g_sequence: u64 = 0;
var g_pending: [app_queue.max_apps]PendingReasons = @splat(.{});

/// Main thread, before the first request.
pub fn init() void {
    _ = ax.strings();
    app_queue.setHandler(.app_windows, answerRequest);
}

/// Capture `pid`'s windows on its queue and publish `app_windows_observed`
/// with every reason asked for since the last answer. False when nothing was
/// queued, so no answer will come.
pub fn request(pid: i32, reason: Reason) bool {
    std.debug.assert(pid > 0);
    if (!addReason(pid, reason)) return false;
    return app_queue.submit(pid, .app_windows);
}

/// Read and store `pid`'s windows. Runs on the app's queue.
pub fn capture(pid: i32) void {
    var snapshot: Snapshot = .{ .pid = pid };
    const result = ax.appWindows(pid, &snapshot.windows, timeout_seconds);
    snapshot.count = result.count;
    snapshot.is_truncated = result.is_truncated;

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    g_sequence += 1;
    snapshot.sequence = g_sequence;
    var slot = &g_snapshots[0];
    for (&g_snapshots) |*stored| {
        if (stored.pid == pid) {
            slot = stored;
            break;
        }
        if (stored.sequence < slot.sequence) slot = stored;
    }

    slot.* = snapshot;
}

/// Copy the latest snapshot of `pid` into `out`. False when none is stored.
pub fn latest(pid: i32, out: *Snapshot) bool {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_snapshots) |*stored| {
        if (stored.pid != pid) continue;
        out.* = stored.*;
        return true;
    }

    return false;
}

/// Drop an ended process's snapshot; a later process may reuse the PID.
pub fn forgetApp(pid: i32) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_snapshots) |*stored| {
        if (stored.pid == pid) stored.* = .{};
    }

    for (&g_pending) |*pending| {
        if (pending.pid == pid) pending.* = .{};
    }
}

/// Pack reasons into an event's detail byte.
pub fn encodeReasons(reasons: Reasons) u8 {
    return @intCast(reasons.bits.mask);
}

/// Unpack reasons from an event's detail byte.
pub fn decodeReasons(detail: u8) Reasons {
    return .{ .bits = .{ .mask = @truncate(detail) } };
}

fn addReason(pid: i32, reason: Reason) bool {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    var free: ?*PendingReasons = null;
    for (&g_pending) |*pending| {
        if (pending.pid == pid) {
            pending.reasons.insert(reason);
            return true;
        }
        if (free == null and pending.pid == 0) free = pending;
    }

    const slot = free orelse return false;
    slot.* = .{ .pid = pid, .reasons = .initOne(reason) };
    return true;
}

fn takeReasons(pid: i32) Reasons {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (&g_pending) |*pending| {
        if (pending.pid != pid) continue;
        const reasons = pending.reasons;
        pending.* = .{};
        return reasons;
    }

    return .empty;
}

fn answerRequest(app: app_queue.App) void {
    const reasons = takeReasons(app.pid);
    if (reasons.count() == 0) return;

    capture(app.pid);
    shim.bw_emit_event_detail(shim.BW_EVENT_APP_WINDOWS_OBSERVED, app.pid, 0, encodeReasons(reasons));
}
