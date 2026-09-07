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
    floating_restore,
    user_command,
    animation,
    tab_sync,
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
    manager_unsettled,
    external,
};

pub const Event = union(enum) {
    seed: struct {
        window_id: WindowId,
        observed: Frame,
    },
    observe: struct {
        process_id: i32,
        window_id: WindowId,
        observed: Frame,
        is_move: bool,
        at_ns: i128,
        dragged_window_id: ?WindowId,
    },
    accept_frame: struct {
        window_id: WindowId,
        target: Frame,
        source: IntentSource,
        at_ns: i128,
        settle_interval_ns: ?i128 = null,
    },
    accept_position: struct {
        window_id: WindowId,
        x: f64,
        y: f64,
        source: IntentSource,
        at_ns: i128,
    },
    begin_resample: WindowId,
    defer_resample: struct {
        window_id: WindowId,
        at_ns: i128,
    },
    settle: struct {
        window_id: WindowId,
        observed: Frame,
        at_ns: i128,
    },
    forget: WindowId,
    clear_intents,
};

pub const RejectionReason = enum {
    catalog_full,
    generation_exhausted,
};

pub const Effect = union(enum) {
    observed: struct {
        process_id: i32,
        window_id: WindowId,
        frame: Frame,
        is_move: bool,
        owner: ObservationOwner,
    },
    settled: struct {
        window_id: WindowId,
        frame: Frame,
        pending_intent: ?Intent,
        owner: SettlementOwner,
    },
    rejected: struct {
        window_id: WindowId,
        reason: RejectionReason,
    },
};

pub const Transition = struct {
    state: Self,
    effect: ?Effect = null,
};

pub const max_entries = 1024;

const StoredEntry = struct {
    window_id: WindowId,
    value: Entry,
};

entries: [max_entries]StoredEntry = undefined,
entry_count: u16 = 0,
next_generation: u64 = 1,
settle_interval_ns: i128 = default_settle_interval_ns,

pub fn init() Self {
    return .{};
}

pub fn initWithSettleInterval(settle_interval_ns: i128) Self {
    std.debug.assert(settle_interval_ns > 0);
    return .{ .settle_interval_ns = settle_interval_ns };
}

pub fn reduce(state: Self, event: Event) Transition {
    var transition: Transition = .{ .state = state };
    switch (event) {
        .seed => |observation| {
            transition.state.seedObserved(observation.window_id, observation.observed) catch |err| {
                transition.effect = rejectionEffect(observation.window_id, err);
            };
        },
        .observe => |observation| {
            const owner = transition.state.observe(
                observation.window_id,
                observation.observed,
                observation.at_ns,
                observation.dragged_window_id,
            ) catch |err| {
                transition.effect = rejectionEffect(observation.window_id, err);
                return transition;
            };
            transition.effect = .{ .observed = .{
                .process_id = observation.process_id,
                .window_id = observation.window_id,
                .frame = observation.observed,
                .is_move = observation.is_move,
                .owner = owner,
            } };
        },
        .accept_frame => |accepted| {
            if (accepted.settle_interval_ns) |settle_interval_ns| {
                _ = transition.state.recordFrameAcceptedFor(
                    accepted.window_id,
                    accepted.target,
                    accepted.source,
                    accepted.at_ns,
                    settle_interval_ns,
                ) catch |err| {
                    transition.effect = rejectionEffect(accepted.window_id, err);
                };
            } else {
                _ = transition.state.recordFrameAccepted(
                    accepted.window_id,
                    accepted.target,
                    accepted.source,
                    accepted.at_ns,
                ) catch |err| {
                    transition.effect = rejectionEffect(accepted.window_id, err);
                };
            }
        },
        .accept_position => |accepted| {
            _ = transition.state.recordPositionAccepted(
                accepted.window_id,
                accepted.x,
                accepted.y,
                accepted.source,
                accepted.at_ns,
            ) catch |err| {
                transition.effect = rejectionEffect(accepted.window_id, err);
            };
        },
        .begin_resample => |window_id| transition.state.beginResample(window_id),
        .defer_resample => |resample| transition.state.deferResample(resample.window_id, resample.at_ns),
        .settle => |observation| {
            const pending_intent = if (transition.state.get(observation.window_id)) |entry|
                entry.intent
            else
                null;
            const owner = transition.state.settle(
                observation.window_id,
                observation.observed,
                observation.at_ns,
            );
            transition.effect = .{ .settled = .{
                .window_id = observation.window_id,
                .frame = observation.observed,
                .pending_intent = pending_intent,
                .owner = owner,
            } };
        },
        .forget => |window_id| transition.state.forget(window_id),
        .clear_intents => transition.state.clearIntents(),
    }
    return transition;
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

    const entry = try self.getOrPut(wid);
    entry.intent = intent;
    entry.resample_at_ns = std.math.add(i128, now_ns, default_resample_delay_ns) catch
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
    const entry = self.getPtr(wid).?;
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
    const entry = try self.getOrPut(wid);
    entry.observed = observed;
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

    const entry = try self.getOrPut(wid);
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
/// ownership while it is still settling. Matching samples retain the intent
/// until its deadline so another late notification from the same AX write
/// cannot steal ownership.
pub fn settle(self: *Self, wid: WindowId, observed: Frame, now_ns: i128) SettlementOwner {
    const entry = self.getPtr(wid) orelse return .external;
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
        return .manager_unsettled;
    }

    return .external;
}

/// Project due trailing samples without consuming them.
pub fn dueResamples(self: *const Self, now_ns: i128, out: []WindowId) usize {
    var count: usize = 0;
    for (self.items()) |stored| {
        const due = stored.value.resample_at_ns orelse continue;
        if (due > now_ns) continue;
        if (count == out.len) break;
        out[count] = stored.window_id;
        count += 1;
    }
    return count;
}

pub fn hasPendingResamples(self: *const Self) bool {
    for (self.items()) |stored| {
        if (stored.value.resample_at_ns != null) return true;
    }
    return false;
}

pub fn beginResample(self: *Self, wid: WindowId) void {
    const entry = self.getPtr(wid) orelse return;
    entry.resample_at_ns = null;
}

pub fn deferResample(self: *Self, wid: WindowId, now_ns: i128) void {
    const entry = self.getPtr(wid) orelse return;
    entry.resample_at_ns = std.math.add(i128, now_ns, default_resample_delay_ns) catch
        std.math.maxInt(i128);
}

/// Whether a physical observation proves the window is away from a desired
/// frame. An outstanding write to that same frame owns the settlement window,
/// so its potentially stale observation must not trigger a duplicate write.
pub fn needsRepair(self: *const Self, wid: WindowId, desired: Frame, now_ns: i128) bool {
    const entry = self.get(wid) orelse return false;
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
    const index = self.findIndex(wid) orelse return null;
    return self.entries[index].value;
}

/// Return the number of tracked window identities.
pub fn windowCount(self: *const Self) usize {
    return self.entry_count;
}

pub fn forget(self: *Self, wid: WindowId) void {
    const index = self.findIndex(wid) orelse return;
    self.entry_count -= 1;
    if (index != self.entry_count) self.entries[index] = self.entries[self.entry_count];
}

pub fn replaceWindowId(self: *Self, old_window_id: WindowId, new_window_id: WindowId) void {
    const index = self.findIndex(old_window_id) orelse return;
    std.debug.assert(self.findIndex(new_window_id) == null);
    self.entries[index].window_id = new_window_id;
}

pub fn clearIntents(self: *Self) void {
    for (self.itemsMut()) |*stored| stored.value.intent = null;
}

fn items(self: *const Self) []const StoredEntry {
    return self.entries[0..self.entry_count];
}

fn itemsMut(self: *Self) []StoredEntry {
    return self.entries[0..self.entry_count];
}

fn findIndex(self: *const Self, wid: WindowId) ?usize {
    for (self.items(), 0..) |stored, index| {
        if (stored.window_id == wid) return index;
    }
    return null;
}

fn getPtr(self: *Self, wid: WindowId) ?*Entry {
    const index = self.findIndex(wid) orelse return null;
    return &self.entries[index].value;
}

fn getOrPut(self: *Self, wid: WindowId) !*Entry {
    if (self.getPtr(wid)) |entry| return entry;
    if (self.entry_count == self.entries.len) return error.GeometryCatalogFull;

    const index = self.entry_count;
    self.entry_count += 1;
    self.entries[index] = .{ .window_id = wid, .value = .{} };
    return &self.entries[index].value;
}

fn rejectionEffect(window_id: WindowId, err: anyerror) Effect {
    const reason: RejectionReason = switch (err) {
        error.GeometryCatalogFull => .catalog_full,
        error.GenerationExhausted => .generation_exhausted,
        else => unreachable,
    };
    return .{ .rejected = .{
        .window_id = window_id,
        .reason = reason,
    } };
}

const testing = std.testing;

const tiled: Frame = .{ .x = 4, .y = 37, .width = 750, .height = 941 };
const fullscreen: Frame = .{ .x = 4, .y = 37, .width = 1504, .height = 941 };

test "stale observation inside settlement interval remains manager owned" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, tiled, 1_050, null),
    );
    try testing.expect(coordinator.get(10).?.observed.?.approxEqual(tiled, Frame.tolerance));
    try testing.expect(coordinator.get(10).?.intent != null);
}

test "matching delayed observation is still manager owned" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, fullscreen, 1_500, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "divergent observation after settlement interval is external" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        ObservationOwner.external,
        try coordinator.observe(10, tiled, 1_101, null),
    );
    try testing.expect(coordinator.get(10).?.intent == null);
}

test "only the dragged window overrides manager ownership" {
    var coordinator = Self.initWithSettleInterval(100);

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
    var coordinator = Self.initWithSettleInterval(100);

    const first = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    const second = try coordinator.recordFrameAccepted(10, tiled, .layout, 1_010);
    try testing.expectEqual(first.generation + 1, second.generation);
    try testing.expect(coordinator.get(10).?.intent.?.target.frame.approxEqual(tiled, Frame.tolerance));
}

test "clearIntents preserves physical observations" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    _ = try coordinator.observe(10, fullscreen, 1_001, null);
    coordinator.clearIntents();

    const entry = coordinator.get(10).?;
    try testing.expect(entry.intent == null);
    try testing.expect(entry.observed.?.approxEqual(fullscreen, Frame.tolerance));
}

test "forget removes all window geometry state" {
    var coordinator = Self.init();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    coordinator.forget(10);
    try testing.expect(coordinator.get(10) == null);
}

test "seeding physical state does not arm reconciliation" {
    var coordinator = Self.init();

    try coordinator.seedObserved(10, tiled);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.dueResamples(std.math.maxInt(i128), &due));
}

test "position intent matches without requiring a known size" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordPositionAccepted(10, 1507, 977, .layout, 1_000);
    const observed: Frame = .{ .x = 1507, .y = 977, .width = 750, .height = 941 };
    try testing.expectEqual(
        ObservationOwner.manager,
        try coordinator.observe(10, observed, 1_500, null),
    );
}

test "pending desired frame suppresses repair until settlement ends" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    _ = try coordinator.observe(10, tiled, 1_001, null);
    try testing.expect(!coordinator.needsRepair(10, fullscreen, 1_050));
    try testing.expect(coordinator.needsRepair(10, fullscreen, 1_101));
}

test "every notification schedules a trailing physical sample" {
    var coordinator = Self.init();

    _ = try coordinator.observe(10, tiled, 1_000, null);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.dueResamples(1_000, &due));
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.dueResamples(1_000 + default_resample_delay_ns, &due),
    );
    try testing.expectEqual(@as(WindowId, 10), due[0]);
}

test "every accepted write schedules a trailing physical sample" {
    var coordinator = Self.init();

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    var due: [1]WindowId = undefined;
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.dueResamples(1_000 + default_resample_delay_ns, &due),
    );
    try testing.expectEqual(@as(WindowId, 10), due[0]);
}

test "trailing divergence after an old intent becomes external" {
    var coordinator = Self.initWithSettleInterval(100);

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
    var coordinator = Self.initWithSettleInterval(1_000);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(SettlementOwner.manager, coordinator.settle(10, tiled, 1_100));

    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.dueResamples(1_100, &due));
    try testing.expectEqual(
        @as(usize, 1),
        coordinator.dueResamples(1_100 + default_resample_delay_ns, &due),
    );
}

test "unreached manager intent does not become external input" {
    var coordinator = Self.initWithSettleInterval(100);

    _ = try coordinator.recordFrameAccepted(10, fullscreen, .layout, 1_000);
    try testing.expectEqual(
        SettlementOwner.manager_unsettled,
        coordinator.settle(10, tiled, 1_101),
    );
    try testing.expect(coordinator.get(10).?.intent == null);

    var due: [1]WindowId = undefined;
    try testing.expectEqual(@as(usize, 0), coordinator.dueResamples(1_101, &due));
}

test "value copies do not share geometry entries" {
    var original = Self.init();
    try original.seedObserved(10, tiled);

    var copied = original;
    copied.forget(10);
    try copied.seedObserved(20, fullscreen);

    try testing.expect(original.get(10) != null);
    try testing.expect(original.get(20) == null);
    try testing.expect(copied.get(10) == null);
    try testing.expect(copied.get(20) != null);
}

test "reducer returns geometry state and ownership effects" {
    var transition = reduce(.{}, .{ .accept_frame = .{
        .window_id = 10,
        .target = fullscreen,
        .source = .layout,
        .at_ns = 1_000,
    } });
    try testing.expect(transition.effect == null);

    transition = reduce(transition.state, .{ .observe = .{
        .process_id = 20,
        .window_id = 10,
        .observed = tiled,
        .is_move = false,
        .at_ns = 1_001,
        .dragged_window_id = null,
    } });
    try testing.expectEqual(ObservationOwner.manager, transition.effect.?.observed.owner);

    var due_window_ids: [1]WindowId = undefined;
    const due_at_ns = 1_001 + default_resample_delay_ns;
    try testing.expectEqual(@as(usize, 1), transition.state.dueResamples(due_at_ns, &due_window_ids));
    transition = reduce(transition.state, .{ .begin_resample = 10 });
    try testing.expectEqual(@as(usize, 0), transition.state.dueResamples(due_at_ns, &due_window_ids));
}
