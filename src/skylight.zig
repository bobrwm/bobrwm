const std = @import("std");
const cg_extra = @import("cg_extra");
const c = @import("c");
const objc = @import("objc");
const log = std.log.scoped(.skylight);

const CFArrayRef = *const anyopaque;
const CFDictionaryRef = *const anyopaque;
const CFStringRef = *const anyopaque;

const CopyManagedDisplaySpacesFn = *const fn (c_int) callconv(.c) ?CFArrayRef;
const CopySpacesForWindowsFn = *const fn (c_int, c_int, CFArrayRef) callconv(.c) ?CFArrayRef;
const MoveWindowsToManagedSpaceFn = *const fn (c_int, CFArrayRef, u64) callconv(.c) void;
const PerformBridgedMoveFn = *const fn (?*anyopaque) callconv(.c) i64;

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
const native_window_batch_capacity: usize = 256;

var g_requires_event_augmentation: ?bool = null;
var g_dock_swipe: DockSwipeState = .{};

const DockSwipeState = struct {
    direction: DockSwipeDirection = .left,
    phase: DockSwipePhase = .began,
    velocity: f64 = 0,
    steps_remaining: u8 = 0,

    fn isActive(self: DockSwipeState) bool {
        return self.steps_remaining > 0;
    }
};

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
    copySpacesForWindows: ?CopySpacesForWindowsFn,
    moveWindowsToManagedSpace: ?MoveWindowsToManagedSpaceFn,
    performBridgedMove: ?PerformBridgedMoveFn,
    bridgedMoveClass: ?objc.Class,
    bridgedMoveSelectorSupported: bool,
    nativeSpacesSupported: bool,

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

        const copy_managed_display_spaces = lib.lookup(CopyManagedDisplaySpacesFn, "SLSCopyManagedDisplaySpaces");
        const copy_spaces_for_windows = lib.lookup(CopySpacesForWindowsFn, "SLSCopySpacesForWindows");
        const move_windows_to_managed_space = lib.lookup(MoveWindowsToManagedSpaceFn, "SLSMoveWindowsToManagedSpace");
        const perform_bridged_move = resolveBridgedMove();
        const bridged_move_class = objc.getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        const bridged_move_selector_supported = if (bridged_move_class) |cls|
            objc.c.class_getInstanceMethod(cls.value, objc.sel("performWithWMBridgeDelegate").value) != null
        else
            false;
        const native_spaces_supported = copy_managed_display_spaces != null and
            copy_spaces_for_windows != null and
            ((bridged_move_class != null and
                (perform_bridged_move != null or bridged_move_selector_supported)) or
                move_windows_to_managed_space != null);

        log.info("SkyLight.framework loaded", .{});

        return .{
            .handle = lib.inner.handle,
            .mainConnectionID = conn_id,
            .getWindowBounds = get_bounds,
            .setFrontProcessWithOptions = set_front,
            .postEventRecordTo = post_event,
            .copyManagedDisplaySpaces = copy_managed_display_spaces,
            .copySpacesForWindows = copy_spaces_for_windows,
            .moveWindowsToManagedSpace = move_windows_to_managed_space,
            .performBridgedMove = perform_bridged_move,
            .bridgedMoveClass = bridged_move_class,
            .bridgedMoveSelectorSupported = bridged_move_selector_supported,
            .nativeSpacesSupported = native_spaces_supported,
        };
    }

    pub fn supportsNativeSpaces(self: *const SkyLight) bool {
        return self.nativeSpacesSupported;
    }

    /// Copy the native Space topology for reuse across one reconciliation pass.
    pub fn nativeSpaceTopology(self: *const SkyLight) ?NativeSpaceTopology {
        const copy_spaces = self.copyManagedDisplaySpaces orelse return null;
        const displays = copy_spaces(self.mainConnectionID()) orelse return null;
        return NativeSpaceTopology.init(displays) orelse {
            c.CFRelease(displays);
            return null;
        };
    }

    /// Return the Bobrwm index of the display's current ordinary native space.
    pub fn currentNativeWorkspace(self: *const SkyLight, display_id: u32, workspace_count: u8) ?u8 {
        var topology = self.nativeSpaceTopology() orelse return null;
        defer topology.deinit();
        return topology.currentWorkspace(display_id, workspace_count);
    }

    /// Switch to a native Space by ID.
    pub fn switchNativeSpaceId(self: *const SkyLight, display_id: u32, target_space_id: u64) bool {
        const started_at_s = c.CFAbsoluteTimeGetCurrent();
        if (!cg_extra.CGPreflightPostEventAccess()) {
            log.warn("native Space switching requires Accessibility permission to post events", .{});
            return false;
        }

        const plan = self.nativeSpaceSwitchPlanToId(display_id, target_space_id) orelse return false;
        if (plan.steps == 0) return true;
        if (!routeDockSwipeToDisplay(display_id)) return false;

        const velocity = dock_swipe_velocity * @as(f64, @floatFromInt(plan.steps));
        const scheduled = performDockSwipes(plan.direction, velocity, plan.steps);
        const elapsed_ms = (c.CFAbsoluteTimeGetCurrent() - started_at_s) * std.time.ms_per_s;
        log.debug("[trace] native Space gesture display={d} target={d} steps={d} scheduled={} elapsed_ms={d:.2}", .{
            display_id,
            target_space_id,
            plan.steps,
            scheduled,
            elapsed_ms,
        });
        return scheduled;
    }

    pub fn moveWindowToNativeSpace(self: *const SkyLight, wid: u32, space_id: u64) bool {
        return self.moveWindowsToNativeSpace(&.{wid}, space_id);
    }

    pub fn moveWindowsToNativeSpace(self: *const SkyLight, wids: []const u32, space_id: u64) bool {
        if (wids.len == 0 or wids.len > native_window_batch_capacity) return false;

        var values: [native_window_batch_capacity]?*const anyopaque = undefined;
        var value_count: usize = 0;
        defer for (values[0..value_count]) |value| c.CFRelease(value);

        for (wids) |*wid| {
            const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, wid) orelse return false;
            values[value_count] = number;
            value_count += 1;
        }

        const windows = c.CFArrayCreate(null, &values, @intCast(value_count), &c.kCFTypeArrayCallBacks) orelse return false;
        defer c.CFRelease(windows);

        if (self.bridgedMoveClass) |cls| {
            const allocated = cls.msgSend(objc.Object, "alloc", .{});
            if (allocated.value == null) return false;
            const operation = allocated.msgSend(objc.Object, "initWithWindows:spaceID:", .{ windows, space_id });
            if (operation.value == null) return false;
            defer operation.msgSend(void, "release", .{});
            // The operation's own bridge keeps the move durable across later
            // Space switches; the local symbol remains a compatibility path.
            if (self.bridgedMoveSelectorSupported) {
                operation.msgSend(void, "performWithWMBridgeDelegate", .{});
                return true;
            }
            if (self.performBridgedMove) |perform| {
                _ = perform(operation.value);
                return true;
            }
        }

        const move = self.moveWindowsToManagedSpace orelse return false;
        move(self.mainConnectionID(), windows, space_id);
        return true;
    }

    pub fn nativeWindowMoveConfirmed(self: *const SkyLight, wid: u32, target_sid: u64, source_sid: u64) ?bool {
        const copy_spaces = self.copySpacesForWindows orelse return null;
        const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &wid) orelse return null;
        defer c.CFRelease(number);
        var values = [_]?*const anyopaque{number};
        const windows = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse return null;
        defer c.CFRelease(windows);
        const spaces = copy_spaces(self.mainConnectionID(), 0x7, windows) orelse return null;
        defer c.CFRelease(spaces);

        var is_on_target = false;
        var is_on_source = false;
        const count = c.CFArrayGetCount(@ptrCast(spaces));
        for (0..@intCast(count)) |index| {
            const space = c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(index)) orelse continue;
            var candidate_sid: i64 = 0;
            if (c.CFNumberGetValue(@ptrCast(space), c.kCFNumberSInt64Type, &candidate_sid) == 0) continue;
            if (candidate_sid <= 0) continue;
            const candidate: u64 = @intCast(candidate_sid);
            if (candidate == target_sid) is_on_target = true;
            if (source_sid != 0 and candidate == source_sid) is_on_source = true;
        }
        return is_on_target and !is_on_source;
    }

    /// Return the unique ordinary workspace containing a window. Windows
    /// shared across multiple ordinary Spaces are deliberately ambiguous.
    pub fn nativeWorkspaceForWindow(self: *const SkyLight, wid: u32, display_id: u32, workspace_count: u8) ?u8 {
        var topology = self.nativeSpaceTopology() orelse return null;
        defer topology.deinit();
        return topology.workspaceForWindow(self, wid, display_id, workspace_count);
    }

    /// Return the unique ordinary native Space containing a window.
    pub fn nativeSpaceIdForWindow(self: *const SkyLight, wid: u32, display_id: u32) ?u64 {
        var topology = self.nativeSpaceTopology() orelse return null;
        defer topology.deinit();
        return topology.spaceIdForWindow(self, wid, display_id);
    }

    fn nativeSpaceSwitchPlan(self: *const SkyLight, display_id: u32, target_workspace_id: u8) ?NativeSpaceSwitchPlan {
        var topology = self.nativeSpaceTopology() orelse return null;
        defer topology.deinit();
        return topology.switchPlan(display_id, target_workspace_id);
    }

    fn nativeSpaceSwitchPlanToId(self: *const SkyLight, display_id: u32, target_space_id: u64) ?NativeSpaceSwitchPlan {
        var topology = self.nativeSpaceTopology() orelse return null;
        defer topology.deinit();
        return topology.switchPlanToId(display_id, target_space_id);
    }
};

/// Owned native Space topology snapshot.
pub const NativeSpaceTopology = struct {
    displays: CFArrayRef,
    keys: NativeSpaceKeys,

    fn init(displays: CFArrayRef) ?NativeSpaceTopology {
        const keys = NativeSpaceKeys.init() orelse return null;
        return .{ .displays = displays, .keys = keys };
    }

    /// Release the copied topology and its lookup keys.
    pub fn deinit(self: *NativeSpaceTopology) void {
        self.keys.deinit();
        c.CFRelease(self.displays);
        self.* = undefined;
    }

    /// Return the Bobrwm workspace currently visible on a display.
    pub fn currentWorkspace(self: *const NativeSpaceTopology, display_id: u32, workspace_count: u8) ?u8 {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const current_sid = self.currentSpaceId(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return workspaceForSpaceId(spaces, current_sid, workspace_count, self.keys.id, self.keys.space_type);
    }

    /// Return the current native Space ID.
    pub fn currentSpaceId(self: *const NativeSpaceTopology, display_id: u32) ?u64 {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const current_space: CFDictionaryRef = @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), self.keys.current_space) orelse return null);
        return spaceId(current_space, self.keys.id);
    }

    /// Return the unique ordinary workspace containing a window.
    pub fn workspaceForWindow(
        self: *const NativeSpaceTopology,
        sky: *const SkyLight,
        wid: u32,
        display_id: u32,
        workspace_count: u8,
    ) ?u8 {
        const copy_window_spaces = sky.copySpacesForWindows orelse return null;
        const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &wid) orelse return null;
        defer c.CFRelease(number);
        var values = [_]?*const anyopaque{number};
        const windows = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse return null;
        defer c.CFRelease(windows);
        const window_spaces = copy_window_spaces(sky.mainConnectionID(), 0x7, windows) orelse return null;
        defer c.CFRelease(window_spaces);

        const display = self.managedDisplayInfo(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return workspaceForWindowSpaces(window_spaces, spaces, workspace_count, self.keys.id, self.keys.space_type);
    }

    pub fn spaceIdForWindow(
        self: *const NativeSpaceTopology,
        sky: *const SkyLight,
        wid: u32,
        display_id: u32,
    ) ?u64 {
        const copy_window_spaces = sky.copySpacesForWindows orelse return null;
        const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &wid) orelse return null;
        defer c.CFRelease(number);
        var values = [_]?*const anyopaque{number};
        const windows = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse return null;
        defer c.CFRelease(windows);
        const window_spaces = copy_window_spaces(sky.mainConnectionID(), 0x7, windows) orelse return null;
        defer c.CFRelease(window_spaces);

        const display = self.managedDisplayInfo(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return spaceIdForWindowSpaces(window_spaces, spaces, self.keys.id, self.keys.space_type);
    }

    pub fn spaceIdAtWorkspace(self: *const NativeSpaceTopology, display_id: u32, workspace_id: u8) ?u64 {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return spaceAtIndex(spaces, workspace_id, self.keys.id, self.keys.space_type);
    }

    pub fn ordinarySpaceCount(self: *const NativeSpaceTopology, display_id: u32) ?u8 {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return countOrdinarySpaces(spaces, self.keys.space_type);
    }

    fn switchPlan(self: *const NativeSpaceTopology, display_id: u32, target_workspace_id: u8) ?NativeSpaceSwitchPlan {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const current_space: CFDictionaryRef = @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), self.keys.current_space) orelse return null);
        const current_sid = spaceId(current_space, self.keys.id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return switchPlanForSpaces(spaces, current_sid, target_workspace_id, self.keys.id, self.keys.space_type);
    }

    fn switchPlanToId(self: *const NativeSpaceTopology, display_id: u32, target_space_id: u64) ?NativeSpaceSwitchPlan {
        const display = self.managedDisplayInfo(display_id) orelse return null;
        const current_sid = self.currentSpaceId(display_id) orelse return null;
        const spaces = self.spacesForDisplay(display) orelse return null;
        return switchPlanForSpaceId(spaces, current_sid, target_space_id, self.keys.id);
    }

    fn managedDisplayInfo(self: *const NativeSpaceTopology, display_id: u32) ?CFDictionaryRef {
        return managedDisplay(self.displays, display_id, self.keys.display);
    }

    fn spacesForDisplay(self: *const NativeSpaceTopology, display: CFDictionaryRef) ?CFArrayRef {
        return @ptrCast(c.CFDictionaryGetValue(@ptrCast(display), self.keys.spaces) orelse return null);
    }
};

const NativeSpaceKeys = struct {
    display: CFStringRef,
    spaces: CFStringRef,
    current_space: CFStringRef,
    id: CFStringRef,
    space_type: CFStringRef,

    fn init() ?NativeSpaceKeys {
        const names = [_][*:0]const u8{ "Display Identifier", "Spaces", "Current Space", "id64", "type" };
        var refs: [names.len]CFStringRef = undefined;
        for (names, 0..) |name, index| {
            refs[index] = cfString(name) orelse {
                var created_count = index;
                while (created_count > 0) : (created_count -= 1) c.CFRelease(refs[created_count - 1]);
                return null;
            };
        }
        return .{
            .display = refs[0],
            .spaces = refs[1],
            .current_space = refs[2],
            .id = refs[3],
            .space_type = refs[4],
        };
    }

    fn deinit(self: *NativeSpaceKeys) void {
        const refs = [_]CFStringRef{ self.space_type, self.id, self.current_space, self.spaces, self.display };
        for (refs) |ref| c.CFRelease(ref);
        self.* = undefined;
    }
};

extern fn _dyld_image_count() u32;
extern fn _dyld_get_image_name(image_index: u32) ?[*:0]const u8;
extern fn _dyld_get_image_header(image_index: u32) ?*const std.macho.mach_header_64;
extern fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

fn resolveBridgedMove() ?PerformBridgedMoveFn {
    const symbol = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
    const address = findSkyLightLocalSymbol(symbol) orelse return null;
    return @ptrFromInt(address);
}

fn findSkyLightLocalSymbol(name: []const u8) ?usize {
    const image_count = _dyld_image_count();
    var image_index: u32 = 0;
    while (image_index < image_count) : (image_index += 1) {
        const image_name = _dyld_get_image_name(image_index) orelse continue;
        if (!std.mem.endsWith(u8, std.mem.span(image_name), "/SkyLight")) continue;

        const header = _dyld_get_image_header(image_index) orelse return null;
        const slide = _dyld_get_image_vmaddr_slide(image_index);
        var linkedit: ?*const std.macho.segment_command_64 = null;
        var symtab: ?*const std.macho.symtab_command = null;

        var command_offset: usize = 0;
        var command_index: u32 = 0;
        while (command_index < header.ncmds) : (command_index += 1) {
            if (command_offset + @sizeOf(std.macho.load_command) > header.sizeofcmds) return null;
            const command_address = @intFromPtr(header) + @sizeOf(std.macho.mach_header_64) + command_offset;
            const command: *const std.macho.load_command = @ptrFromInt(command_address);
            if (command.cmdsize < @sizeOf(std.macho.load_command) or
                command_offset + command.cmdsize > header.sizeofcmds)
            {
                return null;
            }
            if (command.cmd == .SEGMENT_64) {
                const segment: *const std.macho.segment_command_64 = @ptrFromInt(command_address);
                if (std.mem.eql(u8, std.mem.sliceTo(&segment.segname, 0), "__LINKEDIT")) linkedit = segment;
            } else if (command.cmd == .SYMTAB) {
                symtab = @ptrFromInt(command_address);
            }
            command_offset += command.cmdsize;
        }

        const segment = linkedit orelse return null;
        const table = symtab orelse return null;
        if (segment.vmaddr < segment.fileoff) return null;
        const base = applyImageSlide(@intCast(segment.vmaddr - segment.fileoff), slide) orelse return null;
        const strings: [*]const u8 = @ptrFromInt(base + table.stroff);
        const symbols: [*]const std.macho.nlist_64 = @ptrFromInt(base + table.symoff);

        var symbol_index: u32 = 0;
        while (symbol_index < table.nsyms) : (symbol_index += 1) {
            const symbol = symbols[symbol_index];
            if (symbol.n_strx == 0 or symbol.n_strx >= table.strsize or symbol.n_value == 0) continue;
            const available = strings[symbol.n_strx..table.strsize];
            const terminator = std.mem.indexOfScalar(u8, available, 0) orelse continue;
            if (!std.mem.eql(u8, available[0..terminator], name)) continue;
            return applyImageSlide(@intCast(symbol.n_value), slide);
        }
        return null;
    }
    return null;
}

fn applyImageSlide(value: usize, slide: isize) ?usize {
    if (slide >= 0) return std.math.add(usize, value, @intCast(slide)) catch null;
    const partial_magnitude: usize = @intCast(-(slide + 1));
    const magnitude = std.math.add(usize, partial_magnitude, 1) catch return null;
    return std.math.sub(usize, value, magnitude) catch null;
}

fn cfString(value: [*:0]const u8) ?CFStringRef {
    return c.CFStringCreateWithCString(null, value, c.kCFStringEncodingUTF8);
}

fn managedDisplay(displays: CFArrayRef, display_id: u32, display_key: CFStringRef) ?CFDictionaryRef {
    const display_uuid = cg_extra.CGDisplayCreateUUIDFromDisplayID(display_id) orelse return null;
    defer c.CFRelease(display_uuid);
    const display_name = c.CFUUIDCreateString(null, display_uuid) orelse return null;
    defer c.CFRelease(display_name);

    const count = c.CFArrayGetCount(@ptrCast(displays));
    for (0..@intCast(count)) |index| {
        const display: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(displays), @intCast(index)) orelse continue);
        const identifier = c.CFDictionaryGetValue(@ptrCast(display), display_key) orelse continue;
        if (c.CFEqual(identifier, display_name) != 0) return display;
    }
    return null;
}

fn spaceId(space: CFDictionaryRef, id_key: CFStringRef) ?u64 {
    const id_ref = c.CFDictionaryGetValue(@ptrCast(space), id_key) orelse return null;
    var sid: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(id_ref), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) return null;
    return @intCast(sid);
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

fn countOrdinarySpaces(spaces: CFArrayRef, type_key: CFStringRef) ?u8 {
    var ordinary_count: u8 = 0;
    const count = c.CFArrayGetCount(@ptrCast(spaces));
    for (0..@intCast(count)) |index| {
        const space: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(index)) orelse continue);
        const type_ref = c.CFDictionaryGetValue(@ptrCast(space), type_key) orelse continue;
        var space_type: i32 = -1;
        if (c.CFNumberGetValue(@ptrCast(type_ref), c.kCFNumberSInt32Type, &space_type) == 0 or space_type != 0) continue;
        ordinary_count = std.math.add(u8, ordinary_count, 1) catch return null;
    }
    return ordinary_count;
}

fn workspaceForWindowSpaces(
    window_spaces: CFArrayRef,
    display_spaces: CFArrayRef,
    workspace_count: u8,
    id_key: CFStringRef,
    type_key: CFStringRef,
) ?u8 {
    var matched_workspace_id: ?u8 = null;
    const count = c.CFArrayGetCount(@ptrCast(window_spaces));
    for (0..@intCast(count)) |index| {
        const space = c.CFArrayGetValueAtIndex(@ptrCast(window_spaces), @intCast(index)) orelse continue;
        var sid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(space), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) continue;

        const workspace_id = workspaceForSpaceId(display_spaces, @intCast(sid), workspace_count, id_key, type_key) orelse continue;
        if (matched_workspace_id) |matched| {
            if (matched != workspace_id) return null;
        } else {
            matched_workspace_id = workspace_id;
        }
    }
    return matched_workspace_id;
}

fn spaceIdForWindowSpaces(
    window_spaces: CFArrayRef,
    display_spaces: CFArrayRef,
    id_key: CFStringRef,
    type_key: CFStringRef,
) ?u64 {
    var matched_space_id: ?u64 = null;
    const count = c.CFArrayGetCount(@ptrCast(window_spaces));
    for (0..@intCast(count)) |index| {
        const space = c.CFArrayGetValueAtIndex(@ptrCast(window_spaces), @intCast(index)) orelse continue;
        var sid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(space), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) continue;

        const space_id: u64 = @intCast(sid);
        _ = workspaceForSpaceId(display_spaces, space_id, std.math.maxInt(u8), id_key, type_key) orelse continue;
        if (matched_space_id) |matched| {
            if (matched != space_id) return null;
        } else {
            matched_space_id = space_id;
        }
    }
    return matched_space_id;
}

fn workspaceForSpaceId(
    spaces: CFArrayRef,
    target_sid: u64,
    workspace_count: u8,
    id_key: CFStringRef,
    type_key: CFStringRef,
) ?u8 {
    var workspace_id: u8 = 0;
    const count = c.CFArrayGetCount(@ptrCast(spaces));
    for (0..@intCast(count)) |index| {
        const space: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(index)) orelse continue);
        const type_ref = c.CFDictionaryGetValue(@ptrCast(space), type_key) orelse continue;
        var space_type: i32 = -1;
        if (c.CFNumberGetValue(@ptrCast(type_ref), c.kCFNumberSInt32Type, &space_type) == 0 or space_type != 0) continue;

        workspace_id += 1;
        if (workspace_id > workspace_count) return null;
        const id_ref = c.CFDictionaryGetValue(@ptrCast(space), id_key) orelse continue;
        var sid: i64 = 0;
        if (c.CFNumberGetValue(@ptrCast(id_ref), c.kCFNumberSInt64Type, &sid) == 0 or sid <= 0) continue;
        if (@as(u64, @intCast(sid)) == target_sid) return workspace_id;
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

fn switchPlanForSpaceId(spaces: CFArrayRef, current_sid: u64, target_sid: u64, id_key: CFStringRef) ?NativeSpaceSwitchPlan {
    var current_position: ?usize = null;
    var target_position: ?usize = null;

    const count = c.CFArrayGetCount(@ptrCast(spaces));
    for (0..@intCast(count)) |position| {
        const space: CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(@ptrCast(spaces), @intCast(position)) orelse continue);
        const candidate_sid = spaceId(space, id_key) orelse continue;
        if (candidate_sid == current_sid) current_position = position;
        if (candidate_sid == target_sid) target_position = position;
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

fn performDockSwipes(direction: DockSwipeDirection, velocity: f64, steps: u8) bool {
    std.debug.assert(steps > 0);
    if (g_dock_swipe.isActive()) return false;

    if (!requiresEventAugmentation()) {
        for (0..steps) |_| {
            if (!postDockSwipe(.began, direction, velocity)) return false;
            if (!postDockSwipe(.changed, direction, velocity)) return false;
            if (!postDockSwipe(.ended, direction, velocity)) return false;
        }
        return true;
    }

    if (!postDockSwipe(.began, direction, velocity)) return false;
    g_dock_swipe = .{
        .direction = direction,
        .phase = .changed,
        .velocity = velocity,
        .steps_remaining = steps,
    };
    scheduleDockSwipePhase();
    return true;
}

fn scheduleDockSwipePhase() void {
    const delay_ns = @as(i64, dock_swipe_phase_delay_us) * std.time.ns_per_us;
    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, delay_ns),
        cg_extra.dispatch_get_main_queue(),
        null,
        dockSwipePhaseTick,
    );
}

fn dockSwipePhaseTick(_: ?*anyopaque) callconv(.c) void {
    if (!g_dock_swipe.isActive()) return;

    const direction = g_dock_swipe.direction;
    const velocity = g_dock_swipe.velocity;
    if (!postDockSwipe(g_dock_swipe.phase, direction, velocity)) {
        g_dock_swipe = .{};
        return;
    }

    if (g_dock_swipe.phase == .changed) {
        g_dock_swipe.phase = .ended;
        scheduleDockSwipePhase();
        return;
    }

    g_dock_swipe.steps_remaining -= 1;
    if (g_dock_swipe.steps_remaining == 0) {
        g_dock_swipe = .{};
        return;
    }

    if (!postDockSwipe(.began, direction, velocity)) {
        g_dock_swipe = .{};
        return;
    }
    g_dock_swipe.phase = .changed;
    scheduleDockSwipePhase();
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
