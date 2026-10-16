//! Display-synchronized frame clock for window animations. Each display with
//! an in-flight animation gets a CVDisplayLink that fires once per refresh
//! on a CoreVideo thread. The callback only records when the frame will reach
//! the screen and signals a DATA_OR dispatch source on the main queue, because
//! AX writes and animator state belong to the main thread. The source
//! coalesces signals, so a busy main thread drops frames instead of draining
//! a backlog of stale ones, and cancelling it guarantees no frame runs after
//! stop. Animations are sampled at that output time instead of at whenever a
//! fixed timer happened to fire, so steps are evenly spaced on 60 Hz,
//! ProMotion, and mixed-rate setups alike.
//!
//! CVDisplayLink is deprecated in favour of NSScreen.displayLink, but that
//! needs macOS 14 and the deployment target is macOS 13.

const std = @import("std");
const c = @import("c");
const cg_extra = @import("cg_extra");
const workspace = @import("workspace.zig");

const log = std.log.scoped(.display_link);

/// Main-thread frame handler. `target_ns` is when the frame being produced
/// will be shown, on the `nowNs` clock.
pub const FrameFn = *const fn (display_id: u32, target_ns: i128) void;

const Link = struct {
    display_id: u32 = 0,
    /// Main thread only; null while stopped.
    ref: cg_extra.CVDisplayLinkRef = null,
    /// Main-queue frame source the CoreVideo thread signals. Set before the
    /// link starts and cleared after it stops, so the callback always sees it.
    source: c.dispatch_source_t = null,
    target_host_time: std.atomic.Value(u64) = .init(0),
};

/// Static storage: the CoreVideo thread and frame sources hold raw pointers
/// to these slots, so they must never move or be freed.
var g_links: [workspace.max_displays]Link = @splat(.{});
var g_on_frame: ?FrameFn = null;
var g_timebase: cg_extra.mach_timebase_info_data_t = .{ .numer = 0, .denom = 0 };

pub fn init(on_frame: FrameFn) void {
    g_on_frame = on_frame;
    _ = cg_extra.mach_timebase_info(&g_timebase);
    std.debug.assert(g_timebase.denom != 0);
}

/// Monotonic nanoseconds on the display link's clock (mach absolute time,
/// which pauses during system sleep). Animation start times must use this
/// clock so they compare against frame target times.
pub fn nowNs() i128 {
    return hostTimeToNs(cg_extra.mach_absolute_time());
}

/// Start delivering frames for `display_id`. No-op if already running.
/// Returns false when no link could be started, e.g. the display is gone.
pub fn start(display_id: u32) bool {
    if (running(display_id) != null) return true;
    const link = idleSlot() orelse {
        log.warn("no free display link slot display={d}", .{display_id});
        return false;
    };

    var ref: cg_extra.CVDisplayLinkRef = null;
    if (cg_extra.CVDisplayLinkCreateWithCGDisplay(display_id, &ref) != cg_extra.kCVReturnSuccess) {
        log.warn("display link create failed display={d}", .{display_id});
        return false;
    }
    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_DATA_OR(),
        0,
        0,
        cg_extra.dispatch_get_main_queue(),
    ) orelse {
        log.warn("frame source create failed display={d}", .{display_id});
        cg_extra.CVDisplayLinkRelease(ref);
        return false;
    };
    c.dispatch_set_context(.{ ._ds = source }, link);
    c.dispatch_source_set_event_handler_f(source, runFrame);
    c.dispatch_resume(.{ ._ds = source });

    link.display_id = display_id;
    link.ref = ref;
    link.source = source;
    if (cg_extra.CVDisplayLinkSetOutputCallback(ref, outputCallback, link) != cg_extra.kCVReturnSuccess or
        cg_extra.CVDisplayLinkStart(ref) != cg_extra.kCVReturnSuccess)
    {
        log.warn("display link start failed display={d}", .{display_id});
        release(link);
        return false;
    }
    return true;
}

/// Stop and release the link for `display_id`. No frame runs after this.
pub fn stop(display_id: u32) void {
    const link = running(display_id) orelse return;
    // CVDisplayLinkStop waits for an in-flight output callback, so the
    // CoreVideo thread is done with the source before it is cancelled.
    _ = cg_extra.CVDisplayLinkStop(link.ref);
    release(link);
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

/// Cancelling on the main queue, which runs the handler, means a signal
/// still pending is dropped rather than delivered to the slot's next display.
/// GCD keeps the source alive until cancellation completes.
fn release(link: *Link) void {
    c.dispatch_source_cancel(link.source);
    c.dispatch_release(.{ ._ds = link.source });
    cg_extra.CVDisplayLinkRelease(link.ref);
    link.source = null;
    link.ref = null;
}

fn hostTimeToNs(host_time: u64) i128 {
    return @divTrunc(@as(i128, host_time) * g_timebase.numer, g_timebase.denom);
}

/// Runs on the CoreVideo display link thread.
fn outputCallback(
    _: cg_extra.CVDisplayLinkRef,
    _: *const cg_extra.CVTimeStamp,
    output_time: *const cg_extra.CVTimeStamp,
    _: cg_extra.CVOptionFlags,
    _: *cg_extra.CVOptionFlags,
    context: ?*anyopaque,
) callconv(.c) cg_extra.CVReturn {
    const link: *Link = @ptrCast(@alignCast(context.?));
    link.target_host_time.store(output_time.host_time, .release);
    c.dispatch_source_merge_data(link.source, 1);
    return cg_extra.kCVReturnSuccess;
}

fn runFrame(context: ?*anyopaque) callconv(.c) void {
    const link: *Link = @ptrCast(@alignCast(context.?));
    g_on_frame.?(link.display_id, hostTimeToNs(link.target_host_time.load(.acquire)));
}
