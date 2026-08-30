//! Tracks geometry ownership across asynchronous AX and WindowServer updates.
//!
//! AX frame writes complete before the corresponding move/resize notifications
//! arrive, and WindowServer bounds can still expose the previous frame when an
//! early notification is handled. This module records bobrwm's accepted frame
//! intents separately from observed physical frames so notification consumers
//! can distinguish manager echoes from user or application-driven geometry.

const Self = @This();

const std = @import("std");
const window_mod = @import("window.zig");

const WindowId = window_mod.WindowId;
const Frame = window_mod.Window.Frame;

/// Notifications inside this interval belong to the accepted AX write even
/// when WindowServer still returns its previous frame. Matching notifications
/// remain manager-owned after the deadline because delivery itself can lag.
pub const default_settle_interval_ns: i128 = 500 * std.time.ns_per_ms;

pub const IntentSource = enum {
    layout,
    workspace_park,
    floating_restore,
    user_command,
    animation,
    tab_sync,
    exit_restore,
};

pub const Intent = struct {
    target: Frame,
    source: IntentSource,
    generation: u64,
    accepted_at_ns: i128,
    settle_deadline_ns: i128,
};

pub const Entry = struct {
    /// Most recent bounds sampled from WindowServer, never a desired frame.
    observed: ?Frame = null,
    /// Latest AX target accepted for this window, retained through its echo
    /// window so stale notifications cannot take ownership of stored state.
    intent: ?Intent = null,
};

pub const ObservationOwner = enum {
    manager,
    user,
    external,
};

allocator: std.mem.Allocator,
entries: std.AutoHashMapUnmanaged(WindowId, Entry) = .empty,
next_generation: u64 = 1,
settle_interval_ns: i128,

pub fn init(allocator: std.mem.Allocator) Self {
    return initWithSettleInterval(allocator, default_settle_interval_ns);
}

pub fn initWithSettleInterval(allocator: std.mem.Allocator, settle_interval_ns: i128) Self {
    std.debug.assert(settle_interval_ns > 0);
    return .{
        .allocator = allocator,
        .settle_interval_ns = settle_interval_ns,
    };
}

pub fn deinit(self: *Self) void {
    self.entries.deinit(self.allocator);
}

/// Reserve coordinator entries before window discovery starts. Geometry
/// tracking must not become the first allocation attempted after AX has
/// already accepted a write.
pub fn ensureTotalCapacity(self: *Self, capacity: u32) !void {
    try self.entries.ensureTotalCapacity(self.allocator, capacity);
}

/// Record a frame write only after AX accepted the full operation. A newer
/// write replaces the prior intent and advances the generation, so delayed
/// notifications from the prior write remain manager-owned during the new
/// intent's settlement interval.
pub fn recordAccepted(
    self: *Self,
    wid: WindowId,
    target: Frame,
    source: IntentSource,
    now_ns: i128,
) !Intent {
    std.debug.assert(wid > 0);
    std.debug.assert(target.width > 0 and target.height > 0);

    const generation = self.next_generation;
    if (generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    self.next_generation += 1;

    const intent: Intent = .{
        .target = target,
        .source = source,
        .generation = generation,
        .accepted_at_ns = now_ns,
        .settle_deadline_ns = std.math.add(i128, now_ns, self.settle_interval_ns) catch
            std.math.maxInt(i128),
    };

    const result = try self.entries.getOrPut(self.allocator, wid);
    if (!result.found_existing) result.value_ptr.* = .{};
    result.value_ptr.intent = intent;
    return intent;
}

/// Classify a WindowServer observation. Only the exact window identified as
/// the active pointer drag can take user ownership; a mouse button held over a
/// different window does not invalidate an outstanding manager intent.
pub fn observe(
    self: *Self,
    wid: WindowId,
    observed: Frame,
    now_ns: i128,
    dragged_wid: ?WindowId,
) !ObservationOwner {
    std.debug.assert(wid > 0);
    std.debug.assert(observed.width >= 0 and observed.height >= 0);

    const result = try self.entries.getOrPut(self.allocator, wid);
    if (!result.found_existing) result.value_ptr.* = .{};
    const entry = result.value_ptr;
    entry.observed = observed;

    if (dragged_wid == wid) {
        entry.intent = null;
        return .user;
    }

    if (entry.intent) |intent| {
        const still_settling = now_ns <= intent.settle_deadline_ns;
        const reached_target = observed.approxEqual(intent.target, Frame.tolerance);
        if (still_settling or reached_target) {
            // Once a delayed notification confirms the target after the grace
            // interval, retain the observation but release the old intent.
            if (!still_settling and reached_target) entry.intent = null;
            return .manager;
        }
        entry.intent = null;
    }

    return .external;
}

pub fn get(self: *const Self, wid: WindowId) ?Entry {
    return self.entries.get(wid);
}

pub fn forget(self: *Self, wid: WindowId) void {
    _ = self.entries.remove(wid);
}

pub fn clearIntents(self: *Self) void {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| entry.intent = null;
}

const testing = std.testing;

const tiled: Frame = .{ .x = 4, .y = 37, .width = 750, .height = 941 };
const fullscreen: Frame = .{ .x = 4, .y = 37, .width = 1504, .height = 941 };

test "stale observation inside settlement interval remains manager owned" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, tiled, 1_050, null),
    );
    try testing.expect(coordinator.get(10).?.observed.?.approxEqual(tiled, Frame.tolerance));
    try testing.expect(coordinator.get(10).?.intent != null);
}

test "matching delayed observation is still manager owned" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, fullscreen, 1_500, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "divergent observation after settlement interval is external" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.external,
        try coordinator.observe(10, tiled, 1_101, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "only the dragged window overrides manager ownership" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, tiled, 1_050, 20),
    );
    try testing.expectEqual(
        ObservationOwner.user,
        try coordinator.observe(10, tiled, 1_051, 10),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "new accepted write supersedes the prior generation" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    const first = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    const second = try coordinator.recordAccepted(10, tiled, .layout, 1_010);
    try testing.expectEqual(first.generation + 1, second.generation);
    try testing.expect(coordinator.get(10).?.intent.?.target.approxEqual(tiled, Frame.tolerance));
}

test "clearIntents preserves physical observations" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    _ = try coordinator.observe(10, fullscreen, 1_001, null);
    coordinator.clearIntents();

    const entry = coordinator.get(10).?;
    try testing.expect(entry.intent == null);
    try testing.expect(entry.observed.?.approxEqual(fullscreen, Frame.tolerance));
}

test "forget removes all window geometry state" {
    var coordinator = Self.init(testing.allocator);
    defer coordinator.deinit();

    _ = try coordinator.recordAccepted(10, fullscreen, .layout, 1_000);
    coordinator.forget(10);
    try testing.expect(coordinator.get(10) == null);
}
