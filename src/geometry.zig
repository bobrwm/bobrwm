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
/// Delay before re-reading WindowServer after an AX notification. The first
/// read can precede the physical update and no second notification is
/// guaranteed, so every notification requires one trailing sample.
pub const default_resample_delay_ns: i128 = 75 * std.time.ns_per_ms;

pub const IntentSource = enum {
    layout,
    workspace_park,
    floating_restore,
    user_command,
    animation,
    tab_sync,
    exit_restore,
};

pub const Position = struct {
    x: f64,
    y: f64,
};

pub const Target = union(enum) {
    frame: Frame,
    position: Position,

    pub fn matches(self: Target, observed: Frame) bool {
        return switch (self) {
            .frame => |frame| observed.approxEqual(frame, Frame.tolerance),
            .position => |position| @abs(observed.x - position.x) <= Frame.tolerance and
                @abs(observed.y - position.y) <= Frame.tolerance,
        };
    }
};

pub const Intent = struct {
    target: Target,
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
    /// Absolute time for the mandatory trailing WindowServer sample.
    resample_at_ns: ?i128 = null,
};

pub const ObservationOwner = enum {
    manager,
    user,
    external,
};

pub const SettlementOwner = enum {
    manager,
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
fn recordAccepted(
    self: *Self,
    wid: WindowId,
    target: Target,
    source: IntentSource,
    now_ns: i128,
) !Intent {
    std.debug.assert(wid > 0);
    switch (target) {
        .frame => |frame| std.debug.assert(frame.width > 0 and frame.height > 0),
        .position => {},
    }

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
    result.value_ptr.resample_at_ns = std.math.add(i128, now_ns, default_resample_delay_ns) catch
        std.math.maxInt(i128);
    return intent;
}

pub fn recordFrameAccepted(
    self: *Self,
    wid: WindowId,
    target: Frame,
    source: IntentSource,
    now_ns: i128,
) !Intent {
    return self.recordAccepted(wid, .{ .frame = target }, source, now_ns);
}

pub fn recordFrameAcceptedFor(
    self: *Self,
    wid: WindowId,
    target: Frame,
    source: IntentSource,
    now_ns: i128,
    settle_interval_ns: i128,
) !Intent {
    std.debug.assert(settle_interval_ns > 0);
    _ = try self.recordFrameAccepted(wid, target, source, now_ns);
    const entry = self.entries.getPtr(wid).?;
    entry.intent.?.settle_deadline_ns = std.math.add(i128, now_ns, settle_interval_ns) catch
        std.math.maxInt(i128);
    return entry.intent.?;
}

pub fn recordPositionAccepted(
    self: *Self,
    wid: WindowId,
    x: f64,
    y: f64,
    source: IntentSource,
    now_ns: i128,
) !Intent {
    return self.recordAccepted(wid, .{ .position = .{ .x = x, .y = y } }, source, now_ns);
}

/// Seed a newly discovered physical frame without manufacturing a geometry
/// notification or settlement timer. Existing intent is preserved for ID
/// replacement paths that successfully wrote the replacement before adoption.
pub fn seedObserved(self: *Self, wid: WindowId, observed: Frame) !void {
    std.debug.assert(wid > 0);
    const result = try self.entries.getOrPut(self.allocator, wid);
    if (!result.found_existing) result.value_ptr.* = .{};
    result.value_ptr.observed = observed;
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
    entry.resample_at_ns = std.math.add(i128, now_ns, default_resample_delay_ns) catch
        std.math.maxInt(i128);

    if (dragged_wid == wid) {
        entry.intent = null;
        return .user;
    }

    if (entry.intent) |intent| {
        const still_settling = now_ns <= intent.settle_deadline_ns;
        const reached_target = intent.target.matches(observed);
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

/// Record the mandatory trailing WindowServer sample. A manager intent keeps
/// ownership while it is still settling; a divergent sample after its
/// deadline is external. Matching samples retain the intent until its deadline
/// so another late notification from the same AX write cannot steal ownership.
pub fn settle(self: *Self, wid: WindowId, observed: Frame, now_ns: i128) SettlementOwner {
    const entry = self.entries.getPtr(wid) orelse return .external;
    entry.observed = observed;
    entry.resample_at_ns = null;

    if (entry.intent) |intent| {
        const reached_target = intent.target.matches(observed);
        if (now_ns <= intent.settle_deadline_ns) {
            entry.resample_at_ns = if (reached_target)
                intent.settle_deadline_ns
            else
                std.math.add(i128, now_ns, default_resample_delay_ns) catch std.math.maxInt(i128);
            return .manager;
        }
        entry.intent = null;
        if (reached_target) return .manager;
    }

    return .external;
}

/// Collect due trailing samples without allocating. Entries beyond `out` stay
/// armed for the next timer tick; callers can therefore use a fixed buffer
/// without silently losing reconciliation work.
pub fn collectDueResamples(self: *Self, now_ns: i128, out: []WindowId) usize {
    var count: usize = 0;
    var it = self.entries.iterator();
    while (it.next()) |entry| {
        const due = entry.value_ptr.resample_at_ns orelse continue;
        if (due > now_ns) continue;
        if (count == out.len) break;
        out[count] = entry.key_ptr.*;
        count += 1;
        entry.value_ptr.resample_at_ns = null;
    }
    return count;
}

pub fn hasPendingResamples(self: *const Self) bool {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.resample_at_ns != null) return true;
    }
    return false;
}

pub fn deferResample(self: *Self, wid: WindowId, now_ns: i128) void {
    const entry = self.entries.getPtr(wid) orelse return;
    entry.resample_at_ns = std.math.add(i128, now_ns, default_resample_delay_ns) catch
        std.math.maxInt(i128);
}

/// Whether a physical observation proves the window is away from a desired
/// frame. An outstanding write to that same frame owns the settlement window,
/// so its potentially stale observation must not trigger a duplicate write.
pub fn needsRepair(self: *const Self, wid: WindowId, desired: Frame, now_ns: i128) bool {
    const entry = self.entries.get(wid) orelse return false;
    if (entry.intent) |intent| {
        if (now_ns <= intent.settle_deadline_ns) {
            switch (intent.target) {
                .frame => |target| if (target.approxEqual(desired, Frame.tolerance)) return false,
                .position => {},
            }
        }
    }
    const observed = entry.observed orelse return false;
    return !observed.approxEqual(desired, Frame.tolerance);
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

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
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

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, fullscreen, 1_500, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "divergent observation after settlement interval is external" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.external,
        try coordinator.observe(10, tiled, 1_101, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "only the dragged window overrides manager ownership" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
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

    const first = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    const second = try coordinator.recordFrameAccepted(10, tiled, .layout, 1_010);
    try testing.expectEqual(first.generation + 1, second.generation);
    try testing.expect(coordinator.get(10).?.intent.?.target.frame.approxEqual(tiled, Frame.tolerance));
}

test "clearIntents preserves physical observations" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    _ = try coordinator.observe(10, fullscreen, 1_001, null);
    coordinator.clearIntents();

    const entry = coordinator.get(10).?;
    try testing.expect(entry.intent == null);
    try testing.expect(entry.observed.?.approxEqual(fullscreen, Frame.tolerance));
}

test "forget removes all window geometry state" {
    var coordinator = Self.init(testing.allocator);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    coordinator.forget(10);
    try testing.expect(coordinator.get(10) == null);
}

test "seeding physical state does not arm reconciliation" {
    var coordinator = Self.init(testing.allocator);
    defer coordinator.deinit();

    try coordinator.seedObserved(10, tiled);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.collectDueResamples(std.math.maxInt(i128), &due));
}

test "position intent matches without requiring a known size" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordPositionAccepted(10, 1507, 977, .workspace_park, 1_000);
    const parked: Frame = .{ .x = 1507, .y = 977, .width = 750, .height = 941 };
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, parked, 1_500, null),
    );
}

test "pending desired frame suppresses repair until settlement ends" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    _ = try coordinator.observe(10, tiled, 1_001, null);
    try testing.expect(!coordinator.needsRepair(10, fullscreen, 1_050));
    try testing.expect(coordinator.needsRepair(10, fullscreen, 1_101));
}

test "every notification schedules a trailing physical sample" {
    var coordinator = Self.init(testing.allocator);
    defer coordinator.deinit();

    _ = try coordinator.observe(10, tiled, 1_000, null);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.collectDueResamples(1_000, &due));
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.collectDueResamples(1_000 + default_resample_delay_ns, &due),
    );
    try testing.expectEqual(@as(WindowId, 10), due[0]);
}

test "every accepted write schedules a trailing physical sample" {
    var coordinator = Self.init(testing.allocator);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.collectDueResamples(1_000 + default_resample_delay_ns, &due),
    );
    try testing.expectEqual(@as(WindowId, 10), due[0]);
}

test "trailing divergence after an old intent becomes external" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 100);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, tiled, .layout, 1_000);
    // The immediate notification still sees the old target and looks like a
    // delayed manager echo even though an external resize is in progress.
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, tiled, 1_500, null),
    );
    try testing.expectEqual(SettlementOwner.external, coordinator.settle(10, fullscreen, 1_600));
}

test "trailing manager divergence resamples until its deadline" {
    var coordinator = Self.initWithSettleInterval(testing.allocator, 1_000);
    defer coordinator.deinit();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(SettlementOwner.manager, coordinator.settle(10, tiled, 1_100));

    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.collectDueResamples(1_100, &due));
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.collectDueResamples(1_100 + default_resample_delay_ns, &due),
    );
}
