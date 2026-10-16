//! Hand-written declarations for CoreGraphics, CoreVideo, and libdispatch
//! symbols that Aro (Zig 0.16's translate-c backend) cannot expose:
//!
//! - `CGEvent.h` / `CGWindow.h` use Apple blocks syntax that Aro does
//!   not parse, so they are excluded from `c.h`.
//! - `dispatch_get_main_queue()` and the `DISPATCH_SOURCE_TYPE_*`
//!   macros take the address of opaque externs (`_dispatch_main_q`,
//!   `_dispatch_source_type_*`). Aro emits these as
//!   `@compileError("local variable has opaque type")` because their
//!   sizes are unknown. Re-declaring them as `anyopaque` and casting
//!   gives a working pointer at link time.
//!
//! Linked against the CoreGraphics and CoreVideo frameworks and libdispatch
//! via libSystem (see build.zig).

const c = @import("c");

// CGEvent.h

pub extern fn CGEventGetFlags(event: c.CGEventRef) c.CGEventFlags;

pub extern fn CGEventGetLocation(event: c.CGEventRef) c.CGPoint;

pub extern fn CGEventCreate(source: c.CGEventSourceRef) c.CGEventRef;

pub extern fn CGEventCreateData(allocator: c.CFAllocatorRef, event: c.CGEventRef) c.CFDataRef;

pub extern fn CGEventCreateFromData(allocator: c.CFAllocatorRef, data: c.CFDataRef) c.CGEventRef;

pub extern fn CGEventGetTimestamp(event: c.CGEventRef) u64;

pub extern fn CGEventSetIntegerValueField(
    event: c.CGEventRef,
    field: c.CGEventField,
    value: i64,
) void;

pub extern fn CGEventSetDoubleValueField(
    event: c.CGEventRef,
    field: c.CGEventField,
    value: f64,
) void;

pub extern fn CGEventPost(tap: c.CGEventTapLocation, event: c.CGEventRef) void;

pub extern fn CGPreflightPostEventAccess() bool;

pub extern fn mach_absolute_time() u64;

pub extern fn sysctlbyname(
    name: [*:0]const u8,
    old_value: ?*anyopaque,
    old_length: *usize,
    new_value: ?*const anyopaque,
    new_length: usize,
) c_int;

pub extern fn CGEventGetIntegerValueField(
    event: c.CGEventRef,
    field: c.CGEventField,
) i64;

pub extern fn CGEventGetDoubleValueField(
    event: c.CGEventRef,
    field: c.CGEventField,
) f64;

pub const CGEventTapCallBack = ?*const fn (
    proxy: c.CGEventTapProxy,
    @"type": c.CGEventType,
    event: c.CGEventRef,
    user_info: ?*anyopaque,
) callconv(.c) c.CGEventRef;

pub extern fn CGEventTapCreate(
    tap: c.CGEventTapLocation,
    place: c.CGEventTapPlacement,
    options: c.CGEventTapOptions,
    events_of_interest: c.CGEventMask,
    callback: CGEventTapCallBack,
    user_info: ?*anyopaque,
) c.CFMachPortRef;

pub extern fn CGEventTapEnable(tap: c.CFMachPortRef, enable: bool) void;

// CGWindow.h

pub const CGWindowID = u32;
pub const kCGNullWindowID: CGWindowID = 0;

pub const CGWindowListOption = u32;
pub const kCGWindowListOptionAll: CGWindowListOption = 0;
pub const kCGWindowListOptionOnScreenOnly: CGWindowListOption = 1 << 0;
pub const kCGWindowListOptionOnScreenAboveWindow: CGWindowListOption = 1 << 1;
pub const kCGWindowListOptionOnScreenBelowWindow: CGWindowListOption = 1 << 2;
pub const kCGWindowListOptionIncludingWindow: CGWindowListOption = 1 << 3;
pub const kCGWindowListExcludeDesktopElements: CGWindowListOption = 1 << 4;

pub extern fn CGWindowListCopyWindowInfo(
    option: CGWindowListOption,
    relative_to_window: CGWindowID,
) c.CFArrayRef;

// CGDirectDisplay.h — excluded from c.h (Aro can't parse the full header).
// Only the UUID accessor is needed: a per-display identity that survives
// unplug/replug and sleep/wake, unlike CGDirectDisplayID which macOS reassigns.
// Returns a +1 CFUUIDRef the caller must CFRelease.
pub extern fn CGDisplayCreateUUIDFromDisplayID(display: u32) c.CFUUIDRef;

pub extern fn CGDisplayBounds(display: u32) c.CGRect;

pub extern fn CGGetDisplaysWithPoint(
    point: c.CGPoint,
    max_displays: u32,
    displays: [*]u32,
    matching_display_count: *u32,
) c.CGError;

// CFStringRef constants exported by CoreGraphics; resolved at link time.
pub extern const kCGWindowNumber: c.CFStringRef;
pub extern const kCGWindowLayer: c.CFStringRef;
pub extern const kCGWindowOwnerPID: c.CFStringRef;
pub extern const kCGWindowBounds: c.CFStringRef;
pub extern const kCGWindowAlpha: c.CFStringRef;

// libdispatch

pub extern var _dispatch_main_q: anyopaque;
pub extern const _dispatch_source_type_timer: anyopaque;
pub extern const _dispatch_source_type_read: anyopaque;
pub extern const _dispatch_source_type_vnode: anyopaque;
pub extern const _dispatch_source_type_data_or: anyopaque;

pub inline fn dispatch_get_main_queue() c.dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

pub inline fn DISPATCH_SOURCE_TYPE_TIMER() c.dispatch_source_type_t {
    return @ptrCast(&_dispatch_source_type_timer);
}

pub inline fn DISPATCH_SOURCE_TYPE_READ() c.dispatch_source_type_t {
    return @ptrCast(&_dispatch_source_type_read);
}

pub inline fn DISPATCH_SOURCE_TYPE_VNODE() c.dispatch_source_type_t {
    return @ptrCast(&_dispatch_source_type_vnode);
}

pub inline fn DISPATCH_SOURCE_TYPE_DATA_OR() c.dispatch_source_type_t {
    return @ptrCast(&_dispatch_source_type_data_or);
}

// CoreVideo — CVDisplayLink.h pulls in CGDirectDisplay.h, which c.h excludes.

pub const CVReturn = i32;
pub const kCVReturnSuccess: CVReturn = 0;
pub const CVOptionFlags = u64;
pub const CVDisplayLinkRef = ?*opaque {};

pub const CVSMPTETime = extern struct {
    subframes: i16,
    subframe_divisor: i16,
    counter: u32,
    type: u32,
    flags: u32,
    hours: i16,
    minutes: i16,
    seconds: i16,
    frames: i16,
};

pub const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    /// Mach absolute time (`mach_absolute_time` units).
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: CVSMPTETime,
    flags: u64,
    reserved: u64,
};

pub const CVDisplayLinkOutputCallback = *const fn (
    link: CVDisplayLinkRef,
    now: *const CVTimeStamp,
    output_time: *const CVTimeStamp,
    flags_in: CVOptionFlags,
    flags_out: *CVOptionFlags,
    context: ?*anyopaque,
) callconv(.c) CVReturn;

pub extern fn CVDisplayLinkCreateWithCGDisplay(display: u32, link_out: *CVDisplayLinkRef) CVReturn;
pub extern fn CVDisplayLinkSetOutputCallback(
    link: CVDisplayLinkRef,
    callback: CVDisplayLinkOutputCallback,
    context: ?*anyopaque,
) CVReturn;
pub extern fn CVDisplayLinkStart(link: CVDisplayLinkRef) CVReturn;
pub extern fn CVDisplayLinkStop(link: CVDisplayLinkRef) CVReturn;
pub extern fn CVDisplayLinkRelease(link: CVDisplayLinkRef) void;

pub const mach_timebase_info_data_t = extern struct {
    numer: u32,
    denom: u32,
};

pub extern fn mach_timebase_info(info: *mach_timebase_info_data_t) c_int;
