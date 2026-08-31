const std = @import("std");
const cg_extra = @import("cg_extra");
const c = @import("c");
const log = std.log.scoped(.skylight);

const CFArrayRef = *const anyopaque;
const CFDictionaryRef = *const anyopaque;
const CFStringRef = *const anyopaque;

const CopyManagedDisplaySpacesFn = *const fn (c_int) callconv(.c) ?CFArrayRef;
const MoveWindowsToManagedSpaceFn = *const fn (c_int, CFArrayRef, u64) callconv(.c) void;

const DockSwipeDirection = enum {
    left,
    right,

    fn sign(self: DockSwipeDirection) f64 {
        return if (self == .right) 1.0 else -1.0;
    }
};

const NativeSpaceSwitchPlan = struct {
    direction: DockSwipeDirection,
    steps: u8,
};

const dock_swipe_velocity: f64 = 2000.0;
const dock_swipe_progress: f64 = 1.401298464324817e-45;
const dock_swipe_modern_progress: f64 = 0.000016;
const dock_swipe_phase_delay_us: c_uint = 10_000;
const serialized_event_capacity: usize = 4096;

var g_requires_event_augmentation: ?bool = null;

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const CGPoint = extern struct {
    x: f64,
    y: f64,
};

pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

pub const ProcessSerialNumber = extern struct {
    high: u32,
    low: u32,
};

pub const SetFrontProcessFn = *const fn (*ProcessSerialNumber, u32, u32) callconv(.c) c_int;
pub const PostEventRecordFn = *const fn (*ProcessSerialNumber, [*]u8) callconv(.c) c_int;

pub const SkyLight = struct {
    handle: *anyopaque,
    mainConnectionID: *const fn () callconv(.c) c_int,
    getWindowBounds: *const fn (c_int, u32, *CGRect) callconv(.c) c_int,
    /// Private focus-activation symbols (yabai's path). Optional: if either is
    /// missing the caller falls back to Cocoa activation.
    setFrontProcessWithOptions: ?SetFrontProcessFn,
    postEventRecordTo: ?PostEventRecordFn,
    copyManagedDisplaySpaces: ?CopyManagedDisplaySpacesFn,
    moveWindowsToManagedSpace: ?MoveWindowsToManagedSpaceFn,

    pub fn init() ?SkyLight {
        var lib = std.DynLib.open("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") catch {
            log.err("failed to load SkyLight.framework", .{});
            return null;
        };

        const conn_id = lib.lookup(
            *const fn () callconv(.c) c_int,
            "SLSMainConnectionID",
        ) orelse {
            log.err("failed to resolve SLSMainConnectionID", .{});
            lib.close();
            return null;
        };

        const get_bounds = lib.lookup(
            *const fn (c_int, u32, *CGRect) callconv(.c) c_int,
            "SLSGetWindowBounds",
        ) orelse {
            log.err("failed to resolve SLSGetWindowBounds", .{});
            lib.close();
            return null;
        };

        const set_front = lib.lookup(SetFrontProcessFn, "SLPSSetFrontProcessWithOptions");
        const post_event = lib.lookup(PostEventRecordFn, "SLPSPostEventRecordTo");
        if (set_front == null or post_event == null) {
            log.warn("SkyLight focus-activation symbols unavailable; using Cocoa activation fallback", .{});
        }

        log.info("SkyLight.framework loaded", .{});

        return .{
            .handle = lib.inner.handle,
            .mainConnectionID = conn_id,
            .getWindowBounds = get_bounds,
            .setFrontProcessWithOptions = set_front,
            .postEventRecordTo = post_event,
            .copyManagedDisplaySpaces = lib.lookup(CopyManagedDisplaySpacesFn, "SLSCopyManagedDisplaySpaces"),
            .moveWindowsToManagedSpace = lib.lookup(MoveWindowsToManagedSpaceFn, "SLSMoveWindowsToManagedSpace"),
        };
    }

    pub fn supportsNativeSpaces(self: *const SkyLight) bool {
        return self.copyManagedDisplaySpaces != null and
            self.moveWindowsToManagedSpace != null;
    }

    /// Return the Bobrwm index of the display's current ordinary native space.
    pub fn currentNativeWorkspace(self: *const SkyLight, display_id: u32, workspace_count: u8) ?u8 {
        const current_sid = self.currentNativeSpaceId(display_id) orelse return null;

        var workspace_id: u8 = 1;
        while (workspace_id <= workspace_count) : (workspace_id += 1) {
            const sid = self.nativeSpaceId(display_id, workspace_id) orelse continue;
            if (sid == current_sid) return workspace_id;
        }
        return null;
    }

    /// Resolve Bobrwm's stable 1-based workspace index to the corresponding
    /// ordinary Mission Control space on a display. Full-screen spaces are
    /// deliberately skipped because Mission Control inserts and removes them.
    pub fn nativeSpaceId(self: *const SkyLight, display_id: u32, workspace_id: u8) ?u64 {
        const copy_spaces = self.copyManagedDisplaySpaces orelse return null;
        const displays = copy_spaces(self.mainConnectionID()) orelse return null;
        defer c.CFRelease(displays);

        const display_uuid = cg_extra.CGDisplayCreateUUIDFromDisplayID(display_id) orelse return null;
        defer c.CFRelease(display_uuid);
        const display_name = c.CFUUIDCreateString(null, display_uuid) orelse return null;
        defer c.CFRelease(display_name);

        const display_key = cfString("Display Identifier") orelse return null;
        defer c.CFRelease(display_key);
        const spaces_key = cfString("Spaces") orelse return null;
        defer c.CFRelease(spaces_key);
        const id_key = cfString("id64") orelse return null;
        defer c.CFRelease(id_key);
        const type_key = cfString("type") orelse return null;
        defer c.CFRelease(type_key);

        const display_count = c.CFArrayGetCount(@ptrCast(displays));
        for (0..@intCast(display_count)) |display_index| {
            const display: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(displays), @intCast(display_index)) orelse continue);
            const identifier = c.CFDictionaryGetValue(@ptrCast(display), display_key) orelse continue;
            if (c.CFEqual(identifier, display_name) == 0) continue;
            const spaces: CFArrayRef = @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), spaces_key) orelse return null);
            return spaceAtIndex(spaces, workspace_id, id_key, type_key);
        }
        return null;
    }

    /// Ask Dock to perform the native transition using the high-velocity
    /// gesture sequence from InstantSpaceSwitcher and strafe.
    pub fn switchNativeSpace(self: *const SkyLight, display_id: u32, from_id: u8, to_id: u8) bool {
        if (!cg_extra.CGPreflightPostEventAccess()) {
            log.warn("native Space switching requires Accessibility permission to post events", .{});
            return false;
        }

        const current_sid = self.nativeSpaceId(display_id, from_id) orelse return false;
        const plan = self.nativeSpaceSwitchPlan(display_id, current_sid, to_id) orelse return false;
        if (plan.steps == 0) return true;
        if (!routeDockSwipeToDisplay(display_id)) return false;

        const velocity = dock_swipe_velocity * @as(f64, @floatFromInt(plan.steps));
        for (0..plan.steps) |_| {
            if (!performDockSwipe(plan.direction, velocity)) return false;
        }
        return true;
    }

    pub fn moveWindowToNativeSpace(self: *const SkyLight, wid: u32, display_id: u32, workspace_id: u8) bool {
        const move = self.moveWindowsToManagedSpace orelse return false;
        const sid = self.nativeSpaceId(display_id, workspace_id) orelse return false;
        const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &wid) orelse return false;
        defer c.CFRelease(number);
        var values = [_]?*const anyopaque{number};
        const windows = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse return false;
        defer c.CFRelease(windows);
        move(self.mainConnectionID(), windows, sid);
        return true;
    }

    fn currentNativeSpaceId(self: *const SkyLight, display_id: u32) ?u64 {
        const copy_spaces = self.copyManagedDisplaySpaces orelse return null;
        const displays = copy_spaces(self.mainConnectionID()) orelse return null;
        defer c.CFRelease(displays);

        const display_uuid = cg_extra.CGDisplayCreateUUIDFromDisplayID(display_id) orelse return null;
        defer c.CFRelease(display_uuid);
        const display_name = c.CFUUIDCreateString(null, display_uuid) orelse return null;
        defer c.CFRelease(display_name);

        const display_key = cfString("Display Identifier") orelse return null;
        defer c.CFRelease(display_key);
        const current_space_key = cfString("Current Space") orelse return null;
        defer c.CFRelease(current_space_key);
        const id_key = cfString("id64") orelse return null;
        defer c.CFRelease(id_key);

        const display_count = c.CFArrayGetCount(@ptrCast(displays));
        for (0..@intCast(display_count)) |display_index| {
            const display: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(displays), @intCast(display_index)) orelse continue);
            const identifier = c.CFDictionaryGetValue(@ptrCast(display), display_key) orelse continue;
            if (c.CFEqual(identifier, display_name) == 0) continue;
            const current_space: CFDictionaryRef = @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), current_space_key) orelse return null);
            const id_ref = c.CFDictionaryGetValue(@ptrCast(current_space), id_key) orelse return null;
            var sid: i64 = 0;
            if (c.CFNumberGetValue(@ptrCast(id_ref), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) return null;
            return @intCast(sid);
        }
        return null;
    }

    fn nativeSpaceSwitchPlan(self: *const SkyLight, display_id: u32, current_sid: u64, target_workspace_id: u8) ?NativeSpaceSwitchPlan {
        const copy_spaces = self.copyManagedDisplaySpaces orelse return null;
        const displays = copy_spaces(self.mainConnectionID()) orelse return null;
        defer c.CFRelease(displays);

        const display_uuid = cg_extra.CGDisplayCreateUUIDFromDisplayID(display_id) orelse return null;
        defer c.CFRelease(display_uuid);
        const display_name = c.CFUUIDCreateString(null, display_uuid) orelse return null;
        defer c.CFRelease(display_name);

        const display_key = cfString("Display Identifier") orelse return null;
        defer c.CFRelease(display_key);
        const spaces_key = cfString("Spaces") orelse return null;
        defer c.CFRelease(spaces_key);
        const id_key = cfString("id64") orelse return null;
        defer c.CFRelease(id_key);
        const type_key = cfString("type") orelse return null;
        defer c.CFRelease(type_key);

        const display_count = c.CFArrayGetCount(@ptrCast(displays));
        for (0..@intCast(display_count)) |display_index| {
            const display: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(displays), @intCast(display_index)) orelse continue);
            const identifier = c.CFDictionaryGetValue(@ptrCast(display), display_key) orelse continue;
            if (c.CFEqual(identifier, display_name) == 0) continue;
            const spaces: CFArrayRef = @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), spaces_key) orelse return null);
            return switchPlanForSpaces(spaces, current_sid, target_workspace_id, id_key, type_key);
        }
        return null;
    }
};

fn cfString(value: [*:0]const u8) ?CFStringRef {
    return c.CFStringCreateWithCString(null, value, c.kCFStringEncodingUTF8);
}

fn spaceAtIndex(spaces: CFArrayRef, workspace_id: u8, id_key: CFStringRef, type_key: CFStringRef) ?u64 {
    var ordinary_index: u8 = 0;
    const count = c.CFArrayGetCount(@ptrCast(spaces));
    for (0..@intCast(count)) |i| {
        const space: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(i)) orelse continue);
        const type_ref = c.CFDictionaryGetValue(@ptrCast(space), type_key) orelse continue;
        var space_type: i32 = -1;
        if (c.CFNumberGetValue(@ptrCast(type_ref), c.kCFNumberSInt32Type, &space_type) == 0 or space_type != 0) continue;
        ordinary_index += 1;
        if (ordinary_index != workspace_id) continue;
        const id_ref = c.CFDictionaryGetValue(@ptrCast(space), id_key) orelse return null;
        var sid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(id_ref), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) return null;
        return @intCast(sid);
    }
    return null;
}

fn switchPlanForSpaces(spaces: CFArrayRef, current_sid: u64, target_workspace_id: u8, id_key: CFStringRef, type_key: CFStringRef) ?NativeSpaceSwitchPlan {
    var current_position: ?usize = null;
    var target_position: ?usize = null;
    var ordinary_index: u8 = 0;

    const count = c.CFArrayGetCount(@ptrCast(spaces));
    for (0..@intCast(count)) |position| {
        const space: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(position)) orelse continue);
        const id_ref = c.CFDictionaryGetValue(@ptrCast(space), id_key) orelse continue;
        var sid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(id_ref), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) continue;
        if (@as(u64, @intCast(sid)) == current_sid) current_position = position;

        const type_ref = c.CFDictionaryGetValue(@ptrCast(space), type_key) orelse continue;
        var space_type: i32 = -1;
        if (c.CFNumberGetValue(@ptrCast(type_ref), c.kCFNumberSInt32Type, &space_type) == 0 or space_type != 0) continue;
        ordinary_index += 1;
        if (ordinary_index == target_workspace_id) target_position = position;
    }

    return makeSwitchPlan(current_position orelse return null, target_position orelse return null);
}

fn makeSwitchPlan(current_position: usize, target_position: usize) NativeSpaceSwitchPlan {
    const direction: DockSwipeDirection = if (target_position >= current_position) .right else .left;
    const steps = if (target_position >= current_position)
        target_position - current_position
    else
        current_position - target_position;
    return .{ .direction = direction, .steps = @intCast(steps) };
}

const DockSwipePhase = enum(i64) {
    began = 1,
    changed = 2,
    ended = 4,
};

fn postDockSwipe(phase: DockSwipePhase, direction: DockSwipeDirection, velocity: f64) bool {
    const event = cg_extra.CGEventCreate(null) orelse return false;
    defer c.CFRelease(event);

    const sign = direction.sign();
    const is_augmented = requiresEventAugmentation();
    const progress = if (is_augmented) dock_swipe_modern_progress else dock_swipe_progress;
    const event_sign = if (is_augmented) -sign else sign;

    cg_extra.CGEventSetIntegerValueField(event, 55, 30);
    cg_extra.CGEventSetIntegerValueField(event, 110, 23);
    cg_extra.CGEventSetIntegerValueField(event, 123, 1);
    cg_extra.CGEventSetIntegerValueField(event, 132, @intFromEnum(phase));
    cg_extra.CGEventSetDoubleValueField(event, 124, event_sign * progress);

    if (is_augmented) {
        cg_extra.CGEventSetIntegerValueField(event, 134, @intFromEnum(phase));
        cg_extra.CGEventSetDoubleValueField(event, 138, 3.0);
        cg_extra.CGEventSetDoubleValueField(event, 169, @floatFromInt(cg_extra.mach_absolute_time()));
        cg_extra.CGEventSetDoubleValueField(event, 125, 0.1);
        if (phase == .ended) {
            cg_extra.CGEventSetDoubleValueField(event, 129, event_sign * velocity);
        }

        const augmented = augmentDockSwipeEvent(event, phase, event_sign * progress, event_sign * velocity) orelse return false;
        defer c.CFRelease(augmented);
        cg_extra.CGEventPost(c.kCGSessionEventTap, augmented);
        return true;
    }

    cg_extra.CGEventSetDoubleValueField(event, 129, sign * velocity);
    cg_extra.CGEventSetDoubleValueField(event, 130, sign * velocity);
    cg_extra.CGEventPost(c.kCGSessionEventTap, event);
    return true;
}

fn performDockSwipe(direction: DockSwipeDirection, velocity: f64) bool {
    const phase_delay_us = if (requiresEventAugmentation()) dock_swipe_phase_delay_us else 0;

    if (!postDockSwipe(.began, direction, velocity)) return false;
    if (phase_delay_us > 0) _ = c.usleep(phase_delay_us);
    if (!postDockSwipe(.changed, direction, velocity)) return false;
    if (phase_delay_us > 0) _ = c.usleep(phase_delay_us);
    return postDockSwipe(.ended, direction, velocity);
}

fn augmentDockSwipeEvent(event: c.CGEventRef, phase: DockSwipePhase, progress: f64, velocity: f64) c.CGEventRef {
    const data = cg_extra.CGEventCreateData(null, event) orelse return null;
    defer c.CFRelease(data);

    const original_length_raw = c.CFDataGetLength(data);
    if (original_length_raw < 4) return null;
    const original_length: usize = @intCast(original_length_raw);
    const original_bytes = c.CFDataGetBytePtr(data);
    if (original_bytes[0] != 0 or original_bytes[1] != 0 or original_bytes[2] != 0 or original_bytes[3] != 2) return null;

    var payload: [96]u8 = @splat(0);
    const payload_length = makeDockSwipePayload(&payload, event, phase, progress, velocity);

    var serialized: [serialized_event_capacity]u8 = undefined;
    const new_length = injectDockSwipePayload(
        original_bytes[0..original_length],
        payload[0..payload_length],
        &serialized,
    ) orelse return null;

    const augmented_data = c.CFDataCreate(null, serialized[0..new_length].ptr, @intCast(new_length)) orelse return null;
    defer c.CFRelease(augmented_data);
    return cg_extra.CGEventCreateFromData(null, augmented_data);
}

fn injectDockSwipePayload(original: []const u8, payload: []const u8, output: []u8) ?usize {
    if (original.len < 4) return null;
    if (original[0] != 0 or original[1] != 0 or original[2] != 0 or original[3] != 2) return null;
    if (output.len < 4) return null;

    @memcpy(output[0..4], original[0..4]);
    var read_offset: usize = 4;
    var write_offset: usize = 4;
    var has_payload = false;

    while (read_offset < original.len) {
        if (read_offset + 4 > original.len) return null;

        const size_words = readU16Big(original[read_offset..][0..2]);
        const tag_and_field = readU16Big(original[read_offset + 2 ..][0..2]);
        const tag: u2 = @truncate(tag_and_field >> 14);
        const field_id = tag_and_field & 0x3fff;
        const field_payload_length: usize = switch (tag) {
            0 => if (size_words == 1) 8 else if (size_words > 1) size_words else return null,
            1, 3 => @as(usize, size_words) * 4,
            else => return null,
        };
        const field_length = 4 + field_payload_length;
        if (read_offset + field_length > original.len) return null;

        if (field_id == 4205) {
            if (write_offset + 4 + payload.len > output.len) return null;
            writeU16Big(output[write_offset..][0..2], @intCast(payload.len));
            writeU16Big(output[write_offset + 2 ..][0..2], 4205);
            @memcpy(output[write_offset + 4 .. write_offset + 4 + payload.len], payload);
            write_offset += 4 + payload.len;
            has_payload = true;
        } else {
            if (write_offset + field_length > output.len) return null;
            @memcpy(output[write_offset .. write_offset + field_length], original[read_offset .. read_offset + field_length]);
            write_offset += field_length;
        }

        read_offset += field_length;
    }

    if (has_payload) return write_offset;
    if (write_offset + 4 + payload.len > output.len) return null;

    writeU16Big(output[write_offset..][0..2], @intCast(payload.len));
    writeU16Big(output[write_offset + 2 ..][0..2], 4205);
    @memcpy(output[write_offset + 4 .. write_offset + 4 + payload.len], payload);
    return write_offset + 4 + payload.len;
}

fn makeDockSwipePayload(output: *[96]u8, event: c.CGEventRef, phase: DockSwipePhase, progress: f64, velocity: f64) usize {
    @memset(output, 0);

    const has_velocity = phase == .ended;
    const payload_length: usize = if (has_velocity) 96 else 68;
    var timestamp = cg_extra.CGEventGetTimestamp(event);
    if (timestamp == 0) timestamp = cg_extra.mach_absolute_time();

    writeU64Little(output[0..8], timestamp);
    writeU32Little(output[24..28], if (has_velocity) 2 else 1);

    writeU32Little(output[28..32], 40);
    writeU32Little(output[32..36], 23);
    writeU32Little(output[36..40], @as(u32, @intCast(@intFromEnum(phase))) << 24);
    writeI32Little(output[44..48], fixed1616(0.1));
    writeU16Little(output[60..62], 1);
    writeU16Little(output[62..64], 3);
    writeI32Little(output[64..68], fixed1616(progress));

    if (!has_velocity) return payload_length;

    writeU32Little(output[68..72], 28);
    writeU32Little(output[72..76], 9);
    output[80] = 1;
    writeI32Little(output[84..88], fixed1616(velocity));
    return payload_length;
}

fn requiresEventAugmentation() bool {
    if (g_requires_event_augmentation) |is_required| return is_required;

    var version: [32]u8 = @splat(0);
    var version_length = version.len;
    if (cg_extra.sysctlbyname("kern.osproductversion", @ptrCast(&version), &version_length, null, 0) != 0) {
        g_requires_event_augmentation = false;
        return false;
    }

    var major: u32 = 0;
    for (version[0..@min(version_length, version.len)]) |byte| {
        if (byte < '0' or byte > '9') break;
        major = major * 10 + byte - '0';
    }

    const is_required = major >= 27;
    g_requires_event_augmentation = is_required;
    return is_required;
}

fn fixed1616(value: f64) i32 {
    const scaled = value * 65536.0;
    const fixed: i32 = @intFromFloat(scaled);
    if (fixed != 0 or value == 0) return fixed;
    return if (value > 0) 1 else -1;
}

fn writeU16Little(output: []u8, value: u16) void {
    std.debug.assert(output.len == 2);
    output[0] = @truncate(value);
    output[1] = @truncate(value >> 8);
}

fn writeU32Little(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value);
    output[1] = @truncate(value >> 8);
    output[2] = @truncate(value >> 16);
    output[3] = @truncate(value >> 24);
}

fn writeI32Little(output: []u8, value: i32) void {
    writeU32Little(output, @bitCast(value));
}

fn writeU64Little(output: []u8, value: u64) void {
    std.debug.assert(output.len == 8);
    for (output, 0..) |*byte, shift| {
        byte.* = @truncate(value >> @intCast(shift * 8));
    }
}

fn writeU16Big(output: []u8, value: u16) void {
    std.debug.assert(output.len == 2);
    output[0] = @truncate(value >> 8);
    output[1] = @truncate(value);
}

fn readU16Big(input: []const u8) u16 {
    std.debug.assert(input.len == 2);
    return (@as(u16, input[0]) << 8) | input[1];
}

fn routeDockSwipeToDisplay(display_id: u32) bool {
    const cursor_event = cg_extra.CGEventCreate(null) orelse return false;
    const cursor_location = cg_extra.CGEventGetLocation(cursor_event);
    c.CFRelease(cursor_event);

    var cursor_displays: [1]u32 = undefined;
    var cursor_display_count: u32 = 0;
    if (cg_extra.CGGetDisplaysWithPoint(cursor_location, cursor_displays.len, &cursor_displays, &cursor_display_count) != c.kCGErrorSuccess) return false;
    if (cursor_display_count > 0 and cursor_displays[0] == display_id) return true;

    const bounds = cg_extra.CGDisplayBounds(display_id);
    const center: c.CGPoint = .{
        .x = bounds.origin.x + bounds.size.width / 2.0,
        .y = bounds.origin.y + bounds.size.height / 2.0,
    };
    return c.CGWarpMouseCursorPosition(center) == c.kCGErrorSuccess;
}

test "native Space switch plan uses physical positions" {
    const right = makeSwitchPlan(1, 5);
    try std.testing.expectEqual(DockSwipeDirection.right, right.direction);
    try std.testing.expectEqual(@as(u8, 4), right.steps);

    const left = makeSwitchPlan(6, 2);
    try std.testing.expectEqual(DockSwipeDirection.left, left.direction);
    try std.testing.expectEqual(@as(u8, 4), left.steps);

    const same = makeSwitchPlan(3, 3);
    try std.testing.expectEqual(@as(u8, 0), same.steps);
}

test "macOS 27 gesture values survive fixed point encoding" {
    try std.testing.expectEqual(@as(i32, 1), fixed1616(dock_swipe_modern_progress));
    try std.testing.expectEqual(@as(i32, -1), fixed1616(-dock_swipe_modern_progress));
    try std.testing.expectEqual(@as(i32, 131_072_000), fixed1616(dock_swipe_velocity));
}

test "serialized gesture payload is appended or replaced" {
    const version = [_]u8{ 0, 0, 0, 2 };
    const payload = [_]u8{ 1, 2, 3 };
    var appended: [32]u8 = undefined;
    const appended_length = injectDockSwipePayload(&version, &payload, &appended).?;
    try std.testing.expectEqual(@as(usize, 11), appended_length);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0x10, 0x6d, 1, 2, 3 }, appended[4..appended_length]);

    const existing = [_]u8{ 0, 0, 0, 2, 0, 3, 0x10, 0x6d, 9, 9, 9 };
    const replacement = [_]u8{ 4, 5, 6, 7 };
    var replaced: [32]u8 = undefined;
    const replaced_length = injectDockSwipePayload(&existing, &replacement, &replaced).?;
    try std.testing.expectEqual(@as(usize, 12), replaced_length);
    try std.testing.expectEqualSlices(u8, &.{ 0, 4, 0x10, 0x6d, 4, 5, 6, 7 }, replaced[4..replaced_length]);
}
