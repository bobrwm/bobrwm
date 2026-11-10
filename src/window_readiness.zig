//! Whether or not a window is ready to tile (based off of AX responses).
//!
//! Requests are answered on the app's queue and published as
//! `window_readiness_observed` events.

const std = @import("std");
const c = @import("c");
const app_queue = @import("app_queue.zig");
const ax = @import("ax.zig");
const shim = @import("shim_api.zig");
const state_mod = @import("state.zig");
const window_server = @import("window_server.zig");

const log = std.log.scoped(.window_readiness);

const Readiness = state_mod.WindowReadiness;

/// What asked, which decides how the main thread applies the answer.
pub const Purpose = enum(u2) {
    pending_role,
    deferred,
    cleanup,
};

pub const Answer = enum(u2) {
    reject,
    ready,
    pending,
    /// WindowServer no longer has the window.
    gone,
};

pub const Observation = struct {
    purpose: Purpose,
    answer: Answer,

    pub fn encode(self: Observation) u8 {
        return @as(u8, @backingInt(self.purpose)) | (@as(u8, @backingInt(self.answer)) << 2);
    }

    pub fn decode(detail: u8) Observation {
        return .{
            .purpose = @fromBackingInt(@intCast(@as(u2, @truncate(detail)))),
            .answer = @fromBackingInt(@intCast(@as(u2, @truncate(detail >> 2)))),
        };
    }
};

/// A responsive app answers well within it; a hung one holds only its own
/// queue this long per message.
const timeout_seconds: f32 = 0.25;

/// Covers every candidate queue plus a cleanup pass over the managed windows.
const max_requests = 1024;
/// Requests answered per pass: one window-list copy serves the batch, and
/// the app's writes and focus get a turn between batches.
const max_batch = 32;

const Request = struct {
    pid: i32,
    wid: u32,
    purposes: std.EnumSet(Purpose),
};

var g_lock: c.os_unfair_lock = .{};
var g_requests: [max_requests]Request = undefined;
var g_request_count: usize = 0;

/// Main thread, before the first request.
pub fn init() void {
    _ = ax.strings();
    app_queue.setHandler(.readiness, answerRequests);
}

/// Ask whether `wid` is ready on its app's queue. A request already waiting
/// for the window absorbs this one. The caller has checked that the app is a
/// regular one.
pub fn request(pid: i32, wid: u32, purpose: Purpose) void {
    std.debug.assert(pid > 0);
    std.debug.assert(wid > 0);
    if (!queueRequest(pid, wid, purpose)) return;
    _ = app_queue.submit(pid, .readiness);
}

/// Drop requests for an ended process; its queue no longer runs them.
pub fn forgetApp(pid: i32) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    var kept: usize = 0;
    for (g_requests[0..g_request_count]) |queued| {
        if (queued.pid == pid) continue;
        g_requests[kept] = queued;
        kept += 1;
    }
    g_request_count = kept;
}

fn queueRequest(pid: i32, wid: u32, purpose: Purpose) bool {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    for (g_requests[0..g_request_count]) |*queued| {
        if (queued.wid != wid) continue;
        queued.pid = pid;
        queued.purposes.insert(purpose);
        return true;
    }

    if (g_request_count == max_requests) {
        log.debug("request table full; dropping wid={d} pid={d}", .{ wid, pid });
        return false;
    }

    g_requests[g_request_count] = .{ .pid = pid, .wid = wid, .purposes = .initOne(purpose) };
    g_request_count += 1;
    return true;
}

/// Take the app's oldest requests. Order is kept because adoption order sets
/// layout placement.
fn takeRequests(pid: i32, out: *[max_batch]Request) []Request {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);

    var count: usize = 0;
    var kept: usize = 0;
    for (g_requests[0..g_request_count]) |queued| {
        if (queued.pid == pid and count < out.len) {
            out[count] = queued;
            count += 1;
            continue;
        }

        g_requests[kept] = queued;
        kept += 1;
    }
    g_request_count = kept;

    return out[0..count];
}

fn hasRequestFor(pid: i32) bool {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    for (g_requests[0..g_request_count]) |queued| {
        if (queued.pid == pid) return true;
    }

    return false;
}

/// Answer a batch of the app's requests, then requeue for the rest. Runs on
/// that app's queue.
fn answerRequests(app: app_queue.App) void {
    var batch_buffer: [max_batch]Request = undefined;
    const batch = takeRequests(app.pid, &batch_buffer);
    if (batch.len == 0) return;

    defer if (hasRequestFor(app.pid)) {
        _ = app_queue.submit(app.pid, .readiness);
    };

    var wids: [max_batch]u32 = undefined;
    for (batch, 0..) |queued, index| wids[index] = queued.wid;

    // A destroyed window is not in AXWindows either, so its query would
    // report pending until the attempts run out. A failed query keeps all.
    var live_buffer: [max_batch]u32 = undefined;
    const live = window_server.existingWindowIds(wids[0..batch.len], &live_buffer);

    var elements: [max_batch]?c.AXUIElementRef = undefined;
    ax.findWindows(app.pid, wids[0..batch.len], &elements, timeout_seconds);
    defer for (elements[0..batch.len]) |element| {
        if (element) |ref| c.CFRelease(@ptrCast(ref));
    };

    for (batch, 0..) |queued, index| {
        const is_gone = if (live) |ids| std.mem.findScalar(u32, ids, queued.wid) == null else false;
        const answer: Answer = if (is_gone) .gone else if (elements[index]) |win| switch (classify(win)) {
            .reject => .reject,
            .ready => .ready,
            .pending => .pending,
        } else .pending;

        var purposes = queued.purposes.iterator();
        while (purposes.next()) |purpose| {
            const observation: Observation = .{ .purpose = purpose, .answer = answer };
            shim.bw_emit_event_detail(shim.BW_EVENT_WINDOW_READINESS_OBSERVED, queued.pid, queued.wid, observation.encode());
        }
    }
}

/// Classify a window from its AX role and subrole.
fn classify(win: c.AXUIElementRef) Readiness {
    const strings = ax.strings() orelse return .pending;
    // Native open/save panels are app-modal AX windows. They pass the dialog
    // heuristic below, but tiling them resizes the parent app while the user
    // is choosing a file.
    if (ax.isAttributeTrue(win, strings.modal_attr)) return .reject;

    const role: c.CFStringRef = @ptrCast(ax.copyAttribute(win, strings.role_attr) orelse return .pending);
    defer c.CFRelease(@ptrCast(role));
    if (c.CFEqual(@ptrCast(role), @ptrCast(strings.window_role)) == 0) {
        const is_unknown_role = c.CFEqual(@ptrCast(role), @ptrCast(strings.unknown_role)) != 0;
        return if (is_unknown_role) .pending else .reject;
    }

    const subrole: c.CFStringRef = @ptrCast(ax.copyAttribute(win, strings.subrole_attr) orelse return .pending);
    defer c.CFRelease(@ptrCast(subrole));
    if (c.CFEqual(@ptrCast(subrole), @ptrCast(strings.unknown_subrole)) != 0) return .pending;
    if (c.CFEqual(@ptrCast(subrole), @ptrCast(strings.standard_window_subrole)) != 0) return .ready;

    // Some apps report AXFloatingWindow or AXDialog for real top-level
    // windows, but transient chrome-less popups (autocomplete lists) report
    // AXDialog too, and tiling one resizes its parent on every keystroke.
    const is_dialog_like = c.CFEqual(@ptrCast(subrole), @ptrCast(strings.floating_window_subrole)) != 0 or
        c.CFEqual(@ptrCast(subrole), @ptrCast(strings.dialog_subrole)) != 0;

    if (is_dialog_like and ax.hasRealWindowSignal(win, strings)) return .ready;
    return .reject;
}
