//! Tab and resize facts read on the shared app queues. Focus and readiness
//! stay with focus_query and window_readiness.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const app_queue = @import("app_queue.zig");
const ax = @import("ax.zig");
const event = @import("event.zig");
const osutil = @import("osutil.zig");
const shim = @import("shim_api.zig");

const log = std.log.scoped(.app_windows);

extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

const timeout_seconds: f32 = 0.25;
const unknown_tabs = std.math.maxInt(u16);

pub const Window = struct {
    wid: u32,
    tabs: u16 = unknown_tabs,
    can_resize: enum(u8) { unknown, no, yes } = .unknown,

    pub fn tabCount(self: Window) ?usize {
        return if (self.tabs == unknown_tabs) null else self.tabs;
    }
};

pub const Snapshot = struct {
    windows: [128]Window = undefined,
    count: usize = 0,
    complete: bool = false,

    pub fn window(self: *const Snapshot, wid: u32) ?Window {
        for (self.windows[0..self.count]) |entry| {
            if (entry.wid == wid) return entry;
        }
        return null;
    }
};

const Slot = struct {
    pid: i32 = 0,
    version: u32 = 0,
    running: bool = false,
    cursor: usize = 0,
    building_version: u32 = 0,
    elements: c.CFArrayRef = null,
    building: Snapshot = .{},
    published: Snapshot = .{},
    published_version: u32 = 0,
    published_at_ns: i128 = 0,
};

var g_lock: c.os_unfair_lock = .{};
var g_version: u32 = 0;
// A cache, not another scheduler: all jobs use app_queue's serial queues.
var g_slots: [64]Slot = @splat(.{});

pub fn init() void {
    _ = ax.strings();
    app_queue.setHandler(.windows, readNextWindow);
}

/// Main thread. Invalidates old answers, including any read still running.
pub fn invalidate(pid: i32) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    for (&g_slots) |*slot| {
        if (slot.pid == pid) slot.version = nextVersion();
    }
}

pub fn forgetApp(pid: i32) void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    for (&g_slots) |*slot| {
        if (slot.pid != pid) continue;
        slot.pid = 0;
        slot.version = nextVersion();
        if (!slot.running) resetBuild(slot);
    }
}

pub fn deinit() void {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    for (&g_slots) |*slot| {
        slot.pid = 0;
        slot.version = nextVersion();
        if (!slot.running) resetBuild(slot);
    }
}

/// Copy a fresh answer, or ask the app and return unknown. Never waits on AX.
pub fn snapshot(pid: i32, out: *Snapshot) bool {
    c.os_unfair_lock_lock(&g_lock);
    var free: ?*Slot = null;
    for (&g_slots) |*slot| {
        if (slot.pid != pid) {
            if (!slot.running and slot.pid == 0) {
                free = slot;
            } else if (free == null and !slot.running and slot.elements == null and slot.published_at_ns != 0 and
                osutil.nanoTimestamp() - slot.published_at_ns > std.time.ns_per_s)
            {
                free = slot;
            }
            continue;
        }
        if (slot.published_version == slot.version and slot.published_at_ns != 0) {
            if (osutil.nanoTimestamp() - slot.published_at_ns < std.time.ns_per_s) {
                out.* = slot.published;
                c.os_unfair_lock_unlock(&g_lock);
                return true;
            }
            slot.version = nextVersion();
        }
        c.os_unfair_lock_unlock(&g_lock);
        _ = app_queue.submit(pid, .windows);
        return false;
    }
    if (free) |slot| {
        const version = nextVersion();
        slot.* = .{ .pid = pid, .version = version };
    }
    c.os_unfair_lock_unlock(&g_lock);
    if (free != null) _ = app_queue.submit(pid, .windows);
    return false;
}

/// A ring event is only a wakeup. Its version must still match the cache.
pub fn accepts(pid: i32, version: u32) bool {
    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    for (&g_slots) |*slot| {
        if (slot.pid == pid) return slot.version == version and slot.published_version == version;
    }
    return false;
}

fn readNextWindow(app: app_queue.App) void {
    c.os_unfair_lock_lock(&g_lock);
    const slot = for (&g_slots) |*candidate| {
        if (candidate.pid == app.pid) break candidate;
    } else {
        c.os_unfair_lock_unlock(&g_lock);
        return;
    };
    if (slot.running or (slot.published_version == slot.version and slot.published_at_ns != 0)) {
        c.os_unfair_lock_unlock(&g_lock);
        return;
    }
    slot.running = true;
    const version = slot.version;
    if (slot.building_version != version) {
        resetBuild(slot);
        slot.building_version = version;
    }
    c.os_unfair_lock_unlock(&g_lock);

    // Each turn handles one window. Even a slow title bar cannot make every
    // later window start over, and focus/writes get a turn between windows.
    const done = readWindowAtCursor(app.pid, slot);

    c.os_unfair_lock_lock(&g_lock);
    defer c.os_unfair_lock_unlock(&g_lock);
    slot.running = false;
    if (slot.pid != app.pid or slot.version != version) {
        resetBuild(slot);
        if (slot.pid == app.pid) _ = app_queue.submit(app.pid, .windows);
        return;
    }
    if (!done) {
        _ = app_queue.submit(app.pid, .windows);
        return;
    }
    slot.published = slot.building;
    slot.published_version = version;
    slot.published_at_ns = osutil.nanoTimestamp();
    log.debug("read pid={d} windows={d} complete={}", .{ app.pid, slot.building.count, slot.building.complete });
    resetBuild(slot);
    if (builtin.is_test) {
        TestIO.version = version;
        _ = c.dispatch_semaphore_signal(TestIO.published);
    } else shim.bw_emit_event(@backingInt(event.EventKind.app_windows_observed), app.pid, version);
}

fn readWindowAtCursor(pid: i32, slot: *Slot) bool {
    const strings = ax.strings() orelse return true;
    if (slot.elements == null) {
        if (builtin.is_test) {
            var elements = [_]?*const anyopaque{ @ptrFromInt(100), @ptrFromInt(101), @ptrFromInt(102) };
            slot.elements = c.CFArrayCreate(null, &elements, elements.len, null);
        } else {
            const app = c.AXUIElementCreateApplication(pid) orelse return true;
            defer c.CFRelease(@ptrCast(app));
            _ = c.AXUIElementSetMessagingTimeout(app, timeout_seconds);
            const err = c.AXUIElementCopyAttributeValue(app, strings.windows_attr, @ptrCast(&slot.elements));
            if (err != c.kAXErrorSuccess or slot.elements == null) return true;
        }
        if (c.CFGetTypeID(@ptrCast(slot.elements)) != c.CFArrayGetTypeID()) return true;
        slot.building.complete = c.CFArrayGetCount(slot.elements) <= slot.building.windows.len;
    }
    const windows = slot.elements.?;
    const count: usize = @intCast(c.CFArrayGetCount(windows));
    if (slot.cursor >= @min(count, slot.building.windows.len)) return true;
    const index = slot.cursor;
    slot.cursor += 1;
    const element: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows, @intCast(index)) orelse {
        slot.building.complete = false;
        return false;
    });
    const entry = (if (builtin.is_test) TestIO.read(element) else readWindow(element, strings)) orelse {
        slot.building.complete = false;
        return false;
    };
    slot.building.windows[slot.building.count] = entry;
    slot.building.count += 1;
    return false;
}

fn readWindow(element: c.AXUIElementRef, strings: *const ax.AxStrings) ?Window {
    _ = c.AXUIElementSetMessagingTimeout(element, timeout_seconds);
    var wid: u32 = 0;
    if (_AXUIElementGetWindow(element, &wid) != c.kAXErrorSuccess or wid == 0) return null;
    var entry: Window = .{ .wid = wid };
    var resizable: c.Boolean = 0;
    if (c.AXUIElementIsAttributeSettable(element, strings.size_attr, &resizable) == c.kAXErrorSuccess) {
        entry.can_resize = if (resizable != 0) .yes else .no;
    }
    if (ax.tabCountForElement(element, strings, timeout_seconds, osutil.nanoTimestamp() + 100 * std.time.ns_per_ms)) |tabs| {
        entry.tabs = @intCast(@min(tabs, unknown_tabs - 1));
    }
    return entry;
}

fn resetBuild(slot: *Slot) void {
    if (slot.elements) |elements| c.CFRelease(@ptrCast(elements));
    slot.elements = null;
    slot.cursor = 0;
    slot.building = .{};
}

// Caller holds g_lock. A PID reused in another cache slot must not accept
// a ring event left over from its previous process.
fn nextVersion() u32 {
    g_version +%= 1;
    return g_version;
}

const TestIO = struct {
    var started: c.dispatch_semaphore_t = null;
    var gate: c.dispatch_semaphore_t = null;
    var published: c.dispatch_semaphore_t = null;
    var version: u32 = 0;
    var hold_first = true;

    fn read(element: c.AXUIElementRef) ?Window {
        if (hold_first) {
            hold_first = false;
            _ = c.dispatch_semaphore_signal(started);
            _ = c.dispatch_semaphore_wait(gate, c.DISPATCH_TIME_FOREVER);
        }
        // The first window has unknown tabs. Later windows must still arrive.
        const wid: u32 = @intCast(@intFromPtr(element));
        return .{
            .wid = wid,
            .tabs = if (wid == 100) unknown_tabs else @intCast(wid - 99),
        };
    }
};

test "slow windows preserve progress and invalidation rejects old answers" {
    const testing = std.testing;
    TestIO.started = c.dispatch_semaphore_create(0);
    TestIO.gate = c.dispatch_semaphore_create(0);
    TestIO.published = c.dispatch_semaphore_create(0);
    defer for ([_]c.dispatch_semaphore_t{ TestIO.started, TestIO.gate, TestIO.published }) |semaphore| {
        c.dispatch_release(.{ ._dsema = semaphore });
    };
    init();
    defer deinit();
    const pid = 42421;
    defer app_queue.forget(pid);
    var result: Snapshot = undefined;
    try testing.expect(!snapshot(pid, &result));
    _ = c.dispatch_semaphore_wait(TestIO.started, c.DISPATCH_TIME_FOREVER);
    // Polling must not reset progress; an actual change must discard the read.
    const waiting = !snapshot(pid, &result);
    invalidate(pid);
    _ = c.dispatch_semaphore_signal(TestIO.gate);
    const delivered = c.dispatch_semaphore_wait(TestIO.published, c.dispatch_time(c.DISPATCH_TIME_NOW, 2 * std.time.ns_per_s));
    try testing.expect(waiting);
    try testing.expectEqual(@as(c_long, 0), delivered);
    try testing.expect(snapshot(pid, &result));
    try testing.expect(result.complete);
    try testing.expectEqual(@as(usize, 3), result.count);
    try testing.expect(result.window(100).?.tabCount() == null);
    try testing.expectEqual(@as(?usize, 3), result.window(102).?.tabCount());
    const previous = TestIO.version;
    try testing.expect(accepts(pid, previous));
    forgetApp(pid);
    try testing.expect(!accepts(pid, previous));
    try testing.expect(!snapshot(pid, &result));
    try testing.expectEqual(@as(c_long, 0), c.dispatch_semaphore_wait(TestIO.published, c.dispatch_time(c.DISPATCH_TIME_NOW, 2 * std.time.ns_per_s)));
    try testing.expect(snapshot(pid, &result));
    try testing.expect(!accepts(pid, previous));
    deinit();
    try testing.expect(!accepts(pid, TestIO.version));
}
