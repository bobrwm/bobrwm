//! Display-synchronized frame clock for window animations. Each display with
//! an in-flight animation gets a CADisplayLink from its NSScreen, scheduled
//! on the main run loop in common modes so frames keep coming while a menu
//! is tracking. Frames run on the main thread, where AX writes and animator
//! state belong, and a busy main thread skips refreshes instead of draining
//! a backlog of stale ones. Animations are sampled at the link's target
//! timestamp, when the frame will reach the screen, instead of at whenever a
//! fixed timer happened to fire, so steps are evenly spaced on 60 Hz,
//! ProMotion, and mixed-rate setups alike.
//!
//! Memory management is MRR: each running slot owns a +1 retain on its link.

const std = @import("std");
const objc = @import("objc");
const cg_extra = @import("cg_extra");
const objc_classes = @import("objc_classes.zig");
const workspace = @import("workspace.zig");

const log = std.log.scoped(.display_link);

/// Main-thread frame handler. `target_ns` is when the frame being produced
/// will be shown, on the `nowNs` clock.
pub const FrameFn = *const fn (display_id: u32, target_ns: i128) void;

const Link = struct {
    display_id: u32 = 0,
    /// +1 retain on the CADisplayLink; null while stopped.
    ref: ?objc.Object = null,
};

/// `NSString * const` exported by Foundation. Declared `extern var` for the
/// same reason as `NSWorkspaceApplicationKey` in objc_classes.zig.
extern var NSRunLoopCommonModes: objc.c.id;

var g_links: [workspace.max_displays]Link = @splat(.{});
var g_on_frame: ?FrameFn = null;
var g_timebase: cg_extra.mach_timebase_info_data_t = .{ .numer = 0, .denom = 0 };

pub fn init(on_frame: FrameFn) void {
    g_on_frame = on_frame;
    _ = cg_extra.mach_timebase_info(&g_timebase);
    std.debug.assert(g_timebase.denom != 0);
    objc_classes.registerDisplayLinkTarget(fired);
}

/// Monotonic nanoseconds on the display link's clock (mach absolute time,
/// which pauses during system sleep and is what CACurrentMediaTime reports).
/// Animation start times must use this clock so they compare against frame
/// target times.
pub fn nowNs() i128 {
    return @divTrunc(@as(i128, cg_extra.mach_absolute_time()) * g_timebase.numer, g_timebase.denom);
}

/// Start delivering frames for `display_id`. No-op if already running.
/// Returns false when no link could be started, e.g. the display is gone.
pub fn start(display_id: u32) bool {
    if (running(display_id) != null) return true;
    const link = idleSlot() orelse {
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
    link.* = .{ .display_id = display_id, .ref = ref };
    return true;
}

/// Stop and release the link for `display_id`. No frame runs after this.
pub fn stop(display_id: u32) void {
    const link = running(display_id) orelse return;
    const ref = link.ref.?;
    link.ref = null;

    // Invalidating removes the link from the run loop. Autorelease rather
    // than release: stop runs from inside the link's own frame callback when
    // the last animation lands, and the link must outlive that dispatch.
    ref.msgSend(void, "invalidate", .{});
    ref.msgSend(void, "autorelease", .{});
}

pub fn stopAll() void {
    for (&g_links) |*link| {
        if (link.ref != null) stop(link.display_id);
    }
}

fn running(display_id: u32) ?*Link {
    for (&g_links) |*link| {
        if (link.ref != null and link.display_id == display_id) return link;
    }
    return null;
}

fn idleSlot() ?*Link {
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

    // CFTimeInterval on the CACurrentMediaTime clock, i.e. mach absolute
    // time in seconds, which is the same clock as nowNs.
    const target_s = ref.msgSend(f64, "targetTimestamp", .{});
    g_on_frame.?(link.display_id, @intFromFloat(target_s * std.time.ns_per_s));
}
