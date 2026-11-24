//! Watch the Mission Control settings that break workspace numbering.
//!
//! - "Automatically rearrange Spaces based on most recent use": BobrWM
//!   numbers workspaces in Mission Control order when it starts, so a restart
//!   after macOS reorders Spaces renumbers them.
//! - "Displays have separate Spaces": BobrWM maps each display's own Spaces
//!   to workspaces; with one shared set of Spaces that mapping does not hold.
//!   The preference only applies after logging out, so the running session's
//!   mode is read from WindowServer instead.
//!
//! Neither setting posts a notification, so they are polled. Each read is an
//! IPC round trip to cfprefsd or WindowServer, so the poll runs on a
//! background queue and each changed reading is published as
//! `spaces_settings_observed` for the reducer.

const std = @import("std");
const c = @import("c");
const cg_extra = @import("cg_extra");
const shim = @import("shim_api.zig");
const skylight = @import("skylight.zig");

/// Short enough that changing a setting clears the warning while the user is
/// still looking at it; one preference read costs well under 1ms.
const poll_interval_ms: u64 = 2000;

pub const Reading = struct {
    rearranges_automatically: bool,
    displays_share_spaces: bool,

    pub fn encode(self: Reading) u8 {
        return @as(u8, @intFromBool(self.rearranges_automatically)) |
            (@as(u8, @intFromBool(self.displays_share_spaces)) << 1);
    }

    pub fn decode(detail: u8) Reading {
        return .{
            .rearranges_automatically = detail & 1 != 0,
            .displays_share_spaces = detail & (1 << 1) != 0,
        };
    }
};

/// Above every encoded reading, so the next reading is always published.
const reading_unknown: u8 = 0xff;

var g_queue: c.dispatch_queue_t = null;
var g_source: c.dispatch_source_t = null;
var g_cancel_done: c.dispatch_semaphore_t = null;
var g_stopping: std.atomic.Value(bool) = .init(false);
/// Set before the timer starts and cleared only after `stop` waits for cancel.
var g_sky: ?*const skylight.SkyLight = null;
/// Last reading published. Atomic because `forgetLastReading` runs on the
/// main thread while the poll runs on a background queue.
var g_last_reading: std.atomic.Value(u8) = .init(reading_unknown);

/// Main thread. The first reading is published right away. `sky` must
/// outlive the poll.
pub fn start(sky: ?*const skylight.SkyLight) void {
    if (g_source != null) return;

    const cancel_done = c.dispatch_semaphore_create(0) orelse return;
    const attr = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_UTILITY, 0);
    const queue = c.dispatch_queue_create("com.bobrwm.spaces-settings", attr) orelse {
        c.dispatch_release(.{ ._dsema = cancel_done });
        return;
    };
    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_TIMER(),
        0,
        0,
        queue,
    ) orelse {
        c.dispatch_release(.{ ._dq = queue });
        c.dispatch_release(.{ ._dsema = cancel_done });
        return;
    };

    g_sky = sky;
    g_stopping.store(false, .release);
    g_cancel_done = cancel_done;
    g_queue = queue;
    g_source = source;

    const interval_ns = poll_interval_ms * c.NSEC_PER_MSEC;
    c.dispatch_source_set_timer(
        source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, 0),
        interval_ns,
        500 * c.NSEC_PER_MSEC,
    );
    c.dispatch_source_set_event_handler_f(source, poll);
    c.dispatch_source_set_cancel_handler_f(source, sourceCancelled);
    g_last_reading.store(reading_unknown, .release);
    c.dispatch_resume(.{ ._ds = source });
}

/// Main thread. Waits for the cancel handler so no in-flight poll can read
/// `g_sky` or emit events after this returns.
pub fn stop() void {
    g_stopping.store(true, .release);
    if (g_source) |source| {
        c.dispatch_source_cancel(source);
        if (g_cancel_done) |sem| _ = c.dispatch_semaphore_wait(sem, c.DISPATCH_TIME_FOREVER);
        c.dispatch_release(.{ ._ds = source });
        g_source = null;
    }
    if (g_cancel_done) |sem| {
        c.dispatch_release(.{ ._dsema = sem });
        g_cancel_done = null;
    }
    if (g_queue) |queue| {
        c.dispatch_release(.{ ._dq = queue });
        g_queue = null;
    }
    g_sky = null;
}

/// Publish the next reading even if it has not changed, for when the last
/// one may have been dropped from the event ring.
pub fn forgetLastReading() void {
    g_last_reading.store(reading_unknown, .release);
}

fn sourceCancelled(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    if (g_cancel_done) |sem| _ = c.dispatch_semaphore_signal(sem);
}

fn poll(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    if (g_stopping.load(.acquire)) return;
    const reading: Reading = .{
        // Unset means the macOS default, which is on.
        .rearranges_automatically = readBool("com.apple.dock", "mru-spaces", true) orelse return,
        .displays_share_spaces = displaysShareSpaces() orelse return,
    };
    if (g_stopping.load(.acquire)) return;
    const encoded = reading.encode();
    if (g_last_reading.swap(encoded, .acq_rel) == encoded) return;

    shim.bw_emit_event_detail(shim.BW_EVENT_SPACES_SETTINGS_OBSERVED, 0, 0, encoded);
}

fn displaysShareSpaces() ?bool {
    if (g_sky) |sky| {
        if (sky.displaysHaveSeparateSpaces()) |is_separate| return !is_separate;
    }
    // Without the session mode, the preference, which may not apply until the
    // user logs out. Unset means separate Spaces, the macOS default.
    return readBool("com.apple.spaces", "spans-displays", false);
}

/// `default` when the key is unset; null when it could not be read.
fn readBool(domain_name: [*:0]const u8, key_name: [*:0]const u8, default: bool) ?bool {
    const domain = c.CFStringCreateWithCString(null, domain_name, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(@ptrCast(domain));
    const key = c.CFStringCreateWithCString(null, key_name, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(@ptrCast(key));

    // System Settings writes these domains; drop the cached copy.
    _ = c.CFPreferencesAppSynchronize(domain);
    const value = c.CFPreferencesCopyAppValue(key, domain) orelse return default;
    defer c.CFRelease(value);

    const type_id = c.CFGetTypeID(value);
    if (type_id == c.CFBooleanGetTypeID()) return c.CFBooleanGetValue(@ptrCast(value)) != 0;
    if (type_id == c.CFNumberGetTypeID()) {
        var number: i32 = 0;
        if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt32Type, &number) == 0) return null;
        return number != 0;
    }
    return null;
}
