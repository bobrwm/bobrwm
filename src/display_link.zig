//! Display-synchronized frame clock for window animations. Each display gets a
//! CADisplayLink from its NSScreen, scheduled on the main run loop in common
//! modes so frames keep coming while a menu is tracking. Links stay allocated
//! and paused (`isPaused = true`) while idle so starting an animation only
//! unpauses an existing link instead of recreating WindowServer display-link
//! state every time; `invalidateAll` tears them down on display reconfigure
//! and shutdown. Frames run on the main thread, where AX writes and animator
//! state belong, and a busy main thread skips refreshes instead of draining
//! a backlog of stale ones. Animations are sampled at the link's target
//! timestamp, when the frame will reach the screen, and newly started
//! animations anchor to one refresh interval before that target so steps are
//! evenly spaced on 60 Hz, ProMotion, and mixed-rate setups alike.
//!
//! Memory management is MRR: each allocated slot owns a +1 retain on its link.

const std = @import("std");
const objc = @import("objc");
const objc_classes = @import("objc_classes.zig");
const workspace = @import("workspace.zig");

const log = std.log.scoped(.display_link);

/// Main-thread frame handler. `anchor_ns` is one refresh interval before
/// `target_ns` (used to anchor newly started animations cleanly to one step in),
/// and `target_ns` is when the frame being produced will be shown. Both are on
/// CoreAnimation's `CACurrentMediaTime` clock.
pub const FrameFn = *const fn (display_id: u32, anchor_ns: i128, target_ns: i128) void;

pub const FrameTimestamps = struct {
    anchor_ns: i128,
    target_ns: i128,
};

const Link = struct {
    display_id: u32 = 0,
    /// +1 retain on the CADisplayLink; null while unallocated.
    ref: ?objc.Object = null,
    paused: bool = true,
};

/// `NSString * const` exported by Foundation. Declared `extern var` for the
/// same reason as `NSWorkspaceApplicationKey` in objc_classes.zig.
extern var NSRunLoopCommonModes: objc.c.id;

var g_links: [workspace.max_displays]Link = @splat(.{});
var g_on_frame: ?FrameFn = null;

pub fn init(on_frame: FrameFn) void {
    g_on_frame = on_frame;
    objc_classes.registerDisplayLinkTarget(fired);
}

/// Start delivering frames for `display_id`, unpausing a cached link when one
/// already exists or creating one on demand. Returns false when no link could
/// be created, e.g. the display is gone.
pub fn start(display_id: u32) bool {
    if (find(display_id)) |link| {
        if (link.paused) {
            link.paused = false;
            link.ref.?.msgSend(void, "setPaused:", .{false});
        }
        return true;
    }

    const link = freeSlot() orelse {
        log.warn("no free display link slot display={d}", .{display_id});
        return false;
    };
    const screen = screenForDisplay(display_id) orelse {
        log.warn("display link screen missing display={d}", .{display_id});
        return false;
    };

    // The link retains its target, so the target needs no other owner.
    const BWDisplayLinkTarget = objc.getClass("BWDisplayLinkTarget").?;
    const target = BWDisplayLinkTarget.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer target.msgSend(void, "release", .{});

    const ref = screen.msgSend(objc.Object, "displayLinkWithTarget:selector:", .{
        target,
        objc.sel("displayLinkFired:"),
    });
    if (ref.value == null) {
        log.warn("display link create failed display={d}", .{display_id});
        return false;
    }

    const NSRunLoop = objc.getClass("NSRunLoop").?;
    const run_loop = NSRunLoop.msgSend(objc.Object, "mainRunLoop", .{});
    ref.msgSend(void, "addToRunLoop:forMode:", .{ run_loop, objc.Object{ .value = NSRunLoopCommonModes } });

    _ = ref.msgSend(objc.Object, "retain", .{});
    link.* = .{ .display_id = display_id, .ref = ref, .paused = false };
    return true;
}

/// Pause frame delivery for `display_id` while keeping the link allocated so
/// future animations can resume without recreating it. No idle wakeups occur
/// while paused.
pub fn pause(display_id: u32) void {
    const link = find(display_id) orelse return;
    if (link.paused) return;
    link.paused = true;
    link.ref.?.msgSend(void, "setPaused:", .{true});
}

/// Invalidate and release every cached link. Used on display reconfiguration
/// (where an NSScreen may have gone away or changed refresh characteristics)
/// and on shutdown.
pub fn invalidateAll() void {
    for (&g_links) |*link| {
        const ref = link.ref orelse continue;
        link.* = .{};

        // Invalidating removes the link from the run loop. Autorelease rather
        // than release in case teardown ever runs during a frame dispatch.
        ref.msgSend(void, "invalidate", .{});
        ref.msgSend(void, "autorelease", .{});
    }
}

/// Convert `CADisplayLink` frame times into nanoseconds on the link's clock.
/// Returns `null` when `target_s` is non-finite, non-positive, or implausibly
/// large so a display sleep/teardown glitch cannot crash `@intFromFloat` or
/// anchor animations to a bogus clock. Otherwise `anchor_ns` is one refresh
/// interval before `target_ns` (clamped at 0) so newly started animations step
/// cleanly by one frame on their first tick. Guards against a stale or
/// inverted `timestamp` right after unpausing by falling back to the link's
/// nominal `duration` (or 60 Hz).
pub fn frameTimestampsNs(timestamp_s: f64, target_s: f64, duration_s: f64) ?FrameTimestamps {
    // >3,000 years of uptime; keeps `target_s * ns_per_s` safely inside i128.
    const max_reasonable_target_s = 1e11;
    if (!std.math.isFinite(target_s) or target_s <= 0.0 or target_s > max_reasonable_target_s) return null;

    const target_ns: i128 = @intFromFloat(target_s * std.time.ns_per_s);
    const raw_dt_s = target_s - timestamp_s;
    const max_reasonable_frame_s = 0.1;
    const frame_dt_s = if (std.math.isFinite(raw_dt_s) and raw_dt_s > 0.0 and raw_dt_s <= max_reasonable_frame_s)
        raw_dt_s
    else if (std.math.isFinite(duration_s) and duration_s > 0.0 and duration_s <= max_reasonable_frame_s)
        duration_s
    else
        1.0 / 60.0;
    const frame_dt_ns: i128 = @intFromFloat(frame_dt_s * std.time.ns_per_s);
    return .{
        .anchor_ns = @max(target_ns - frame_dt_ns, 0),
        .target_ns = target_ns,
    };
}

fn find(display_id: u32) ?*Link {
    for (&g_links) |*link| {
        if (link.ref != null and link.display_id == display_id) return link;
    }
    return null;
}

fn freeSlot() ?*Link {
    for (&g_links) |*link| {
        if (link.ref == null) return link;
    }
    return null;
}

fn screenForDisplay(display_id: u32) ?objc.Object {
    const NSScreen = objc.getClass("NSScreen").?;
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    const NSString = objc.getClass("NSString").?;
    const screen_number_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSScreenNumber"});

    for (0..count) |i| {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        const description = screen.msgSend(objc.Object, "deviceDescription", .{});
        const number = description.msgSend(objc.Object, "objectForKey:", .{screen_number_key});
        if (number.value == null) continue;
        if (number.msgSend(u32, "unsignedIntValue", .{}) == display_id) return screen;
    }
    return null;
}

/// Runs on the main thread from the link's run loop source.
fn fired(ref: objc.Object) void {
    const link = for (&g_links) |*link| {
        if (link.ref) |owned| {
            if (owned.value == ref.value) break link;
        }
    } else return;
    // Drop any callback already queued on the run loop before pause took effect.
    if (link.paused) return;

    const timestamp_s = ref.msgSend(f64, "timestamp", .{});
    const target_s = ref.msgSend(f64, "targetTimestamp", .{});
    const duration_s = ref.msgSend(f64, "duration", .{});
    const times = frameTimestampsNs(timestamp_s, target_s, duration_s) orelse return;
    g_on_frame.?(link.display_id, times.anchor_ns, times.target_ns);
}

test "frameTimestampsNs anchors one refresh before target and guards bad timestamps" {
    const testing = std.testing;

    // 120 Hz ProMotion healthy frame.
    const dt_120 = 1.0 / 120.0;
    const t_120 = frameTimestampsNs(100.0, 100.0 + dt_120, dt_120).?;
    const expected_120: i128 = @intFromFloat(dt_120 * std.time.ns_per_s);
    try testing.expectEqual(expected_120, t_120.target_ns - t_120.anchor_ns);

    // Stale timestamp from before pause (> 100ms old) falls back to nominal duration.
    const dt_60 = 1.0 / 60.0;
    const stale = frameTimestampsNs(10.0, 25.0, dt_60).?;
    const expected_60: i128 = @intFromFloat(dt_60 * std.time.ns_per_s);
    try testing.expectEqual(expected_60, stale.target_ns - stale.anchor_ns);

    // Inverted timestamp with invalid duration falls back to 60 Hz.
    const bad = frameTimestampsNs(30.0, 25.0, 0.0).?;
    try testing.expectEqual(expected_60, bad.target_ns - bad.anchor_ns);

    // Non-finite, non-positive, or huge target timestamps are dropped.
    try testing.expectEqual(@as(?FrameTimestamps, null), frameTimestampsNs(0.0, 0.0, dt_60));
    try testing.expectEqual(@as(?FrameTimestamps, null), frameTimestampsNs(0.0, -1.0, dt_60));
    try testing.expectEqual(@as(?FrameTimestamps, null), frameTimestampsNs(1.0, std.math.nan(f64), dt_60));
    try testing.expectEqual(@as(?FrameTimestamps, null), frameTimestampsNs(1.0, std.math.inf(f64), dt_60));
    try testing.expectEqual(@as(?FrameTimestamps, null), frameTimestampsNs(1.0, 1e20, dt_60));
}
