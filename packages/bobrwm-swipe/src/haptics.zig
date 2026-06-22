//! Haptics module for macOS
//! Performs haptic feedback via the private MTActuator API.
//! For debugging this module, just pray and hope that it works.

const std = @import("std");
const builtin = @import("builtin");

// ── Public types ─────────────────────────────────────────────────────────────

pub const HapticPattern = enum {
    generic,
    alignment,
    level_change,
};

// ── CoreFoundation / IOKit opaque types ──────────────────────────────────────

const CFTypeRef = *anyopaque;
const CFStringRef = *anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFNumberRef = *anyopaque;

const CFNumberType = enum(i32) {
    sint64_type = 4,
    _,
};

const kern_return_t = i32;
const io_object_t = u32;
const io_iterator_t = u32;
const io_registry_entry_t = u32;
const mach_port_t = u32;

// ── External symbols ─────────────────────────────────────────────────────────

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFGetTypeID(cf: CFTypeRef) usize;
extern "c" fn CFNumberGetTypeID() usize;
extern "c" fn CFNumberGetValue(number: CFNumberRef, theType: i32, valuePtr: *u64) bool;
extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cstr: [*:0]const u8,
    encoding: u32,
) CFStringRef;

extern "IOKit" fn IOServiceMatching(name: [*:0]const u8) CFTypeRef;
extern "IOKit" fn IOServiceGetMatchingServices(
    master: mach_port_t,
    matching: CFTypeRef,
    iter: *io_iterator_t,
) kern_return_t;
extern "IOKit" fn IOIteratorNext(iter: io_iterator_t) io_object_t;
extern "IOKit" fn IOObjectRelease(obj: io_object_t) kern_return_t;
extern "IOKit" fn IORegistryEntryCreateCFProperty(
    entry: io_registry_entry_t,
    key: CFStringRef,
    allocator: CFAllocatorRef,
    options: u32,
) ?CFTypeRef;

// MultitouchSupport private framework
extern fn MTActuatorCreateFromDeviceID(device_id: u64) ?CFTypeRef;
extern fn MTActuatorOpen(actuator: CFTypeRef) i32;
extern fn MTActuatorIsOpen(actuator: CFTypeRef) bool;
extern fn MTActuatorActuate(actuator: CFTypeRef, pattern: i32, unk: i32, f1: f32, f2: f32) i32;

// ── Helpers ───────────────────────────────────────────────────────────────────

const kCFStringEncodingUTF8: u32 = 0x08000100;

inline fn patternIndex(pattern: HapticPattern) i32 {
    return switch (pattern) {
        .generic => 0,
        .alignment => 1,
        .level_change => 2,
    };
}

inline fn kIOMainPortDefault() mach_port_t {
    return 0;
}

// ── MtsState ──────────────────────────────────────────────────────────────────

const MtsState = struct {
    actuators: std.ArrayList(CFTypeRef),

    fn openDefaultOrAll(allocator: std.mem.Allocator) ?MtsState {
        var iter: io_iterator_t = 0;

        const matching = IOServiceMatching("AppleMultitouchDevice");
        if (IOServiceGetMatchingServices(kIOMainPortDefault(), matching, &iter) != 0) {
            CFRelease(matching);
            return null;
        }
        // IOServiceGetMatchingServices consumes the matching dict reference.

        // CFString key for "Multitouch ID"
        const key: CFStringRef = CFStringCreateWithCString(
            null,
            "Multitouch ID",
            kCFStringEncodingUTF8,
        );
        defer CFRelease(key);

        var actuators = std.ArrayList(CFTypeRef).init(allocator);

        while (true) {
            const dev = IOIteratorNext(iter);
            if (dev == 0) break;
            defer _ = IOObjectRelease(dev);

            const id_ref_opt = IORegistryEntryCreateCFProperty(dev, key, null, 0);
            if (id_ref_opt) |id_ref| {
                defer CFRelease(id_ref);

                if (CFGetTypeID(id_ref) == CFNumberGetTypeID()) {
                    var device_id: u64 = 0;
                    if (CFNumberGetValue(
                        @ptrCast(id_ref),
                        @intFromEnum(CFNumberType.sint64_type),
                        &device_id,
                    )) {
                        if (MTActuatorCreateFromDeviceID(device_id)) |act| {
                            if (MTActuatorOpen(act) == 0) {
                                actuators.append(act) catch {
                                    CFRelease(act);
                                };
                            } else {
                                CFRelease(act);
                            }
                        }
                    }
                }
            }
        }

        if (iter != 0) _ = IOObjectRelease(iter);

        if (actuators.items.len == 0) {
            actuators.deinit();
            return null;
        }

        return MtsState{ .actuators = actuators };
    }

    fn deinit(self: *MtsState) void {
        for (self.actuators.items) |act| {
            CFRelease(act);
        }
        self.actuators.deinit();
    }
};

// ── Global singleton (lazy init) ──────────────────────────────────────────────

var mts_once = std.once(initMts);
var mts_state_global: ?MtsState = null;

fn initMts() void {
    // Use the page allocator for the long-lived actuator list.
    mts_state_global = MtsState.openDefaultOrAll(std.heap.page_allocator);
}

fn mtsState() ?*const MtsState {
    mts_once.call();
    return if (mts_state_global) |*s| s else null;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Perform haptic feedback using the given pattern.
/// Returns true if at least one actuator fired successfully.
/// Just use this function to perform haptic feedback... please don't
/// remake it unless you're a genius or absolutely have to.
pub fn performHaptic(pattern: HapticPattern) bool {
    const state = mtsState() orelse return false;
    const pat = patternIndex(pattern);
    var any_ok = false;

    for (state.actuators.items) |act| {
        if (MTActuatorIsOpen(act)) {
            const kr = MTActuatorActuate(act, pat, 0, 0.0, 0.0);
            any_ok = any_ok or (kr == 0);
        }
    }

    return any_ok;
}
