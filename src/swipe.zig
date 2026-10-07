//! Allocation-free state machine for intercepted native Spaces gestures.

const std = @import("std");

// Private CGEvent protocol used by the Dock's horizontal Spaces gesture.
// This follows InstantSpaceSwitcher and iss rather than interpreting raw
// contacts: https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/iss.c
pub const event_type_gesture: i64 = 29;
pub const event_type_dock_control: i64 = 30;
pub const hid_type_dock_swipe: i64 = 23;
pub const motion_horizontal: i64 = 1;

pub const Field = struct {
    pub const event_type: i32 = 55;
    pub const source_pid: i32 = 41;
    pub const source_user_data: i32 = 42;
    pub const hid_type: i32 = 110;
    pub const motion: i32 = 123;
    pub const progress: i32 = 124;
    pub const velocity_x: i32 = 129;
    pub const velocity_y: i32 = 130;
    pub const phase: i32 = 132;
};

pub const Phase = enum(i64) {
    none = 0,
    began = 1,
    changed = 2,
    ended = 4,
    cancelled = 8,
    may_begin = 128,
    _,
};

pub const Direction = enum {
    previous,
    next,
};

pub const DetectionSource = enum {
    progress,
    terminal_velocity,
};

pub const Lifecycle = enum {
    none,
    began,
    direction_detected,
    ended,
    cancelled,
    synthetic_passed,
};

pub const Disposition = enum {
    pass_through,
    consume,
    sanitize_terminal,
};

pub const Settings = struct {
    reverse: bool,
    macos_major: u32,
};

pub const DockEvent = struct {
    phase: Phase,
    progress: f64,
    velocity_x: f64,
};

pub const Input = union(enum) {
    reset,
    gesture_companion,
    dock: DockEvent,
    synthetic_dock,
};

pub const Result = struct {
    disposition: Disposition = .pass_through,
    lifecycle: Lifecycle = .none,
    direction: ?Direction = null,
    detection_source: ?DetectionSource = null,
};

pub const State = struct {
    tracking: bool = false,
    fired: bool = false,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn process(self: *State, input: Input, settings: Settings) Result {
        switch (input) {
            .reset => {
                self.reset();
                return .{};
            },
            .synthetic_dock => return .{ .lifecycle = .synthetic_passed },
            .gesture_companion => return .{
                .disposition = if (self.tracking) .consume else .pass_through,
            },
            .dock => |event| return self.processDock(event, settings),
        }
    }

    pub fn assertValid(self: *const State) void {
        if (!self.tracking) std.debug.assert(!self.fired);
    }

    fn processDock(self: *State, event: DockEvent, settings: Settings) Result {
        return switch (event.phase) {
            .began => self.begin(),
            .changed => self.changed(event.progress, settings),
            .ended => self.end(event.velocity_x, settings),
            .cancelled => self.cancel(),
            else => .{ .disposition = if (self.tracking) .consume else .pass_through },
        };
    }

    fn begin(self: *State) Result {
        self.tracking = true;
        self.fired = false;
        return .{ .disposition = .consume, .lifecycle = .began };
    }

    fn changed(self: *State, progress: f64, settings: Settings) Result {
        if (!self.tracking) return .{};
        if (self.fired or progress == 0) return .{ .disposition = .consume };

        self.fired = true;
        return .{
            .disposition = .consume,
            .lifecycle = .direction_detected,
            .direction = directionForValue(progress, settings),
            .detection_source = .progress,
        };
    }

    fn end(self: *State, velocity_x: f64, settings: Settings) Result {
        if (!self.tracking) return .{};

        var result: Result = .{
            .disposition = if (settings.macos_major >= 27) .sanitize_terminal else .consume,
            .lifecycle = .ended,
        };
        if (!self.fired and velocity_x != 0) {
            result.direction = directionForValue(velocity_x, settings);
            result.detection_source = .terminal_velocity;
        }
        self.tracking = false;
        self.fired = false;
        return result;
    }

    fn cancel(self: *State) Result {
        if (!self.tracking) return .{};
        self.tracking = false;
        self.fired = false;
        return .{ .disposition = .consume, .lifecycle = .cancelled };
    }
};

fn directionForValue(value: f64, settings: Settings) Direction {
    std.debug.assert(value != 0);
    // Physical captures on macOS 26/27 use positive progress for next. Do not
    // infer this from synthetic macOS 27 events, which use the opposite sign.
    var moves_next = if (settings.macos_major >= 26) value > 0 else value < 0;
    if (settings.reverse) moves_next = !moves_next;
    return if (moves_next) .next else .previous;
}

test "protocol state remains two bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(State));
}

test "physical direction follows the OS-specific DockControl sign" {
    const cases = [_]struct {
        macos_major: u32,
        value: f64,
        reverse: bool = false,
        expected: Direction,
    }{
        .{ .macos_major = 25, .value = -0.1, .expected = .next },
        .{ .macos_major = 25, .value = 0.1, .expected = .previous },
        .{ .macos_major = 26, .value = 0.1, .expected = .next },
        .{ .macos_major = 26, .value = -0.1, .expected = .previous },
        .{ .macos_major = 27, .value = 0.046661376953125, .expected = .next },
        .{ .macos_major = 27, .value = -0.1, .expected = .previous },
        .{ .macos_major = 27, .value = 0.1, .reverse = true, .expected = .previous },
        .{ .macos_major = 27, .value = -0.1, .reverse = true, .expected = .next },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, directionForValue(case.value, .{
            .reverse = case.reverse,
            .macos_major = case.macos_major,
        }));
    }
}

test "physical swipe fires once and suppresses its complete stream" {
    const settings: Settings = .{ .reverse = false, .macos_major = 25 };
    var state: State = .{};

    var result = state.process(.{ .dock = .{ .phase = .began, .progress = 0, .velocity_x = 0 } }, settings);
    try std.testing.expectEqual(Disposition.consume, result.disposition);
    try std.testing.expectEqual(Lifecycle.began, result.lifecycle);
    try std.testing.expectEqual(Disposition.consume, state.process(.gesture_companion, settings).disposition);

    result = state.process(.{ .dock = .{ .phase = .changed, .progress = -0.2, .velocity_x = 0 } }, settings);
    try std.testing.expectEqual(Direction.next, result.direction.?);
    try std.testing.expectEqual(DetectionSource.progress, result.detection_source.?);
    try std.testing.expectEqual(@as(?Direction, null), state.process(.{
        .dock = .{ .phase = .changed, .progress = -0.4, .velocity_x = 0 },
    }, settings).direction);

    result = state.process(.{ .dock = .{ .phase = .ended, .progress = 0, .velocity_x = -20 } }, settings);
    try std.testing.expectEqual(Disposition.consume, result.disposition);
    try std.testing.expectEqual(Lifecycle.ended, result.lifecycle);
    try std.testing.expect(!state.tracking);
}

test "terminal velocity handles discrete swipe and macOS 27 cleanup" {
    const settings: Settings = .{ .reverse = false, .macos_major = 27 };
    var state: State = .{};
    _ = state.process(.{ .dock = .{ .phase = .began, .progress = 0, .velocity_x = 0 } }, settings);

    const result = state.process(.{
        .dock = .{ .phase = .ended, .progress = 0, .velocity_x = 5.0569610595703125 },
    }, settings);
    try std.testing.expectEqual(Disposition.sanitize_terminal, result.disposition);
    try std.testing.expectEqual(Direction.next, result.direction.?);
    try std.testing.expectEqual(DetectionSource.terminal_velocity, result.detection_source.?);
}

test "synthetic events never start or end an interleaved physical swipe" {
    const settings: Settings = .{ .reverse = false, .macos_major = 27 };
    var state: State = .{};
    const synthetic = state.process(.synthetic_dock, settings);
    try std.testing.expectEqual(Disposition.pass_through, synthetic.disposition);
    try std.testing.expectEqual(Lifecycle.synthetic_passed, synthetic.lifecycle);
    try std.testing.expect(!state.tracking);

    // Keyboard-generated events can arrive before, during, or after the
    // physical stream. Identity, not arrival order, must decide the bypass.
    const began = state.process(.{
        .dock = .{ .phase = .began, .progress = 0, .velocity_x = 0 },
    }, settings);
    try std.testing.expectEqual(Disposition.consume, began.disposition);
    _ = state.process(.synthetic_dock, settings);
    try std.testing.expect(state.tracking);
    try std.testing.expect(!state.fired);
    const changed = state.process(.{
        .dock = .{ .phase = .changed, .progress = 0.2, .velocity_x = 0 },
    }, settings);
    try std.testing.expectEqual(Direction.next, changed.direction.?);
    _ = state.process(.synthetic_dock, settings);
    try std.testing.expect(state.tracking and state.fired);
    const ended = state.process(.{
        .dock = .{ .phase = .ended, .progress = 0.4, .velocity_x = 300 },
    }, settings);
    try std.testing.expectEqual(Disposition.sanitize_terminal, ended.disposition);
    try std.testing.expect(ended.direction == null);
    _ = state.process(.synthetic_dock, settings);
    try std.testing.expect(!state.tracking and !state.fired);
}
