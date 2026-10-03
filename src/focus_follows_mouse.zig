//! Allocation-free pointer-focus coalescing and confirmation intent state.

const std = @import("std");

/// Convert CoreGraphics' signed event field to a valid WindowServer ID.
pub fn normalizeEventWindowId(value: i64) ?u32 {
    if (value <= 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

/// Build one half of the private SkyLight pair that makes a specific window
/// key without using AX raise. Kinds 0x01 and 0x02 are posted in sequence.
/// Layout adapted from yabai's `window_manager_make_key_window`:
/// https://github.com/koekeishiya/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L1269-L1291
pub fn keyWindowEventRecord(window_id: u32, kind: u8) [0xf8]u8 {
    var bytes: [0xf8]u8 = @splat(0);
    bytes[0x04] = 0xf8;
    bytes[0x08] = kind;
    bytes[0x3a] = 0x10;
    @memset(bytes[0x20..0x30], 0xFF);
    std.mem.writeInt(u32, bytes[0x3c..0x40], window_id, .little);
    return bytes;
}

/// Build the private same-process handoff record. Subtype 0x02 deactivates the
/// previous key window; subtype 0x01 activates the target after the 40 ms gap.
/// Layout adapted from yabai's same-PSN focus workaround:
/// https://github.com/koekeishiya/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L1293-L1318
pub fn sameProcessEventRecord(window_id: u32, subtype: u8) [0xf8]u8 {
    var bytes: [0xf8]u8 = @splat(0);
    bytes[0x04] = 0xf8;
    bytes[0x08] = 0x0d;
    bytes[0x8a] = subtype;
    std.mem.writeInt(u32, bytes[0x3c..0x40], window_id, .little);
    return bytes;
}

pub const IntentPhase = enum {
    handoff,
    awaiting_confirmation,
};

pub const Intent = struct {
    generation: u64,
    process_id: i32,
    window_id: u32,
    previous_window_id: u32,
    phase: IntentPhase,
};

pub const HoverUpdate = enum {
    blocked,
    unchanged,
    left,
    entered,
};

pub const State = struct {
    mouse_move_pending: bool = false,
    event_window_id: u32 = 0,
    hovered_window_id: u32 = 0,
    fallback_logged: bool = false,
    next_generation: u64 = 1,
    intent: ?Intent = null,

    /// Retain the newest event metadata, but enqueue only the first mouse move
    /// awaiting main-loop handling so stale samples cannot fill the queue.
    pub fn queueMouseMove(self: *State, window_id: u32) bool {
        self.event_window_id = window_id;
        if (self.mouse_move_pending) return false;
        self.mouse_move_pending = true;
        return true;
    }

    pub fn eventWindowId(self: *const State) u32 {
        return self.event_window_id;
    }

    /// Return true only for the first WindowServer hit-test fallback. Missing
    /// event metadata is expected over some system surfaces, so log it once.
    pub fn noteFallback(self: *State) bool {
        if (self.fallback_logged) return false;
        self.fallback_logged = true;
        return true;
    }

    /// Consume the coalesced move and classify its hover transition. Blocked
    /// moves do not consume a transition that should be retried when unblocked.
    pub fn updateHover(self: *State, window_id: u32, blocked: bool) HoverUpdate {
        self.mouse_move_pending = false;
        if (blocked) return .blocked;
        if (window_id == self.hovered_window_id) return .unchanged;

        self.hovered_window_id = window_id;
        return if (window_id == 0) .left else .entered;
    }

    /// Let the next mouse sample create a fresh intent for this same target.
    pub fn rearm(self: *State, window_id: u32) void {
        if (self.hovered_window_id == window_id) self.hovered_window_id = 0;
    }

    pub fn beginIntent(
        self: *State,
        process_id: i32,
        window_id: u32,
        previous_window_id: u32,
        phase: IntentPhase,
    ) Intent {
        const intent: Intent = .{
            .generation = self.takeGeneration(),
            .process_id = process_id,
            .window_id = window_id,
            .previous_window_id = previous_window_id,
            .phase = phase,
        };
        self.intent = intent;
        return intent;
    }

    pub fn isHovered(self: *const State, window_id: u32) bool {
        return window_id != 0 and self.hovered_window_id == window_id;
    }

    pub fn advanceIntent(self: *State, generation: u64) bool {
        const intent = if (self.intent) |*pending| pending else return false;
        if (intent.generation != generation) return false;
        intent.phase = .awaiting_confirmation;
        return true;
    }

    pub fn confirmIntent(self: *State, process_id: i32, window_id: u32) ?Intent {
        const intent = self.intent orelse return null;
        if (intent.phase != .awaiting_confirmation or
            intent.process_id != process_id or
            intent.window_id != window_id) return null;
        self.intent = null;
        return intent;
    }

    pub fn cancelIntent(self: *State) ?Intent {
        const intent = self.intent;
        self.intent = null;
        return intent;
    }

    pub fn reset(self: *State) void {
        const next_generation = self.next_generation;
        self.* = .{ .next_generation = next_generation };
    }

    fn takeGeneration(self: *State) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }
};

test "mouse moves coalesce until consumed" {
    var state: State = .{};
    try std.testing.expect(state.queueMouseMove(10));
    try std.testing.expect(!state.queueMouseMove(20));
    try std.testing.expectEqual(@as(u32, 20), state.eventWindowId());
    try std.testing.expectEqual(HoverUpdate.entered, state.updateHover(20, false));
    try std.testing.expect(state.queueMouseMove(30));
}

test "fallback logging is emitted once per reset" {
    var state: State = .{};
    try std.testing.expect(state.noteFallback());
    try std.testing.expect(!state.noteFallback());
    state.reset();
    try std.testing.expect(state.noteFallback());
}

test "event window ids accept only nonzero uint32 values" {
    try std.testing.expectEqual(@as(?u32, null), normalizeEventWindowId(-1));
    try std.testing.expectEqual(@as(?u32, null), normalizeEventWindowId(0));
    try std.testing.expectEqual(@as(?u32, 0x89abcdef), normalizeEventWindowId(0x89abcdef));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), normalizeEventWindowId(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(?u32, null), normalizeEventWindowId(@as(i64, std.math.maxInt(u32)) + 1));
}

test "hover transitions do not consume blocked movement" {
    var state: State = .{};
    try std.testing.expectEqual(HoverUpdate.blocked, state.updateHover(20, true));
    try std.testing.expectEqual(HoverUpdate.entered, state.updateHover(20, false));
    try std.testing.expectEqual(HoverUpdate.unchanged, state.updateHover(20, false));
    try std.testing.expectEqual(HoverUpdate.left, state.updateHover(0, false));
}

test "rearm permits the same hovered target on the next sample" {
    var state: State = .{};
    try std.testing.expectEqual(HoverUpdate.entered, state.updateHover(10, false));
    state.rearm(10);
    try std.testing.expectEqual(HoverUpdate.entered, state.updateHover(10, false));
}

test "intent confirmation requires the exact process and window" {
    var state: State = .{};
    const intent = state.beginIntent(42, 100, 90, .handoff);
    try std.testing.expectEqual(@as(?Intent, null), state.confirmIntent(42, 100));
    try std.testing.expectEqual(@as(?Intent, null), state.confirmIntent(42, 90));
    try std.testing.expectEqual(@as(?Intent, null), state.confirmIntent(43, 100));
    try std.testing.expect(state.advanceIntent(intent.generation));
    try std.testing.expectEqual(IntentPhase.awaiting_confirmation, state.intent.?.phase);
    try std.testing.expectEqual(intent.generation, state.confirmIntent(42, 100).?.generation);
    try std.testing.expectEqual(@as(?Intent, null), state.intent);
}

test "superseded intent rejects stale phase transitions" {
    var state: State = .{};
    const first = state.beginIntent(42, 100, 90, .handoff);
    const second = state.beginIntent(42, 101, 90, .handoff);
    try std.testing.expect(!state.advanceIntent(first.generation));
    try std.testing.expect(state.advanceIntent(second.generation));
    try std.testing.expectEqual(second.generation, state.cancelIntent().?.generation);
}

test "reset preserves generation against stale asynchronous results" {
    var state: State = .{};
    const first = state.beginIntent(42, 100, 90, .handoff);
    state.reset();
    const second = state.beginIntent(42, 100, 90, .handoff);
    try std.testing.expect(first.generation != second.generation);
}

test "key-window event record encodes kind and window id" {
    const record = keyWindowEventRecord(0x12345678, 0x02);
    try std.testing.expectEqual(@as(u8, 0xf8), record[0x04]);
    try std.testing.expectEqual(@as(u8, 0x02), record[0x08]);
    try std.testing.expectEqual(@as(u8, 0x10), record[0x3a]);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, record[0x3c..0x40]);
    for (record[0x20..0x30]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
}

test "same-process event record encodes subtype and window id" {
    const record = sameProcessEventRecord(0x89abcdef, 0x01);
    try std.testing.expectEqual(@as(u8, 0xf8), record[0x04]);
    try std.testing.expectEqual(@as(u8, 0x0d), record[0x08]);
    try std.testing.expectEqual(@as(u8, 0x01), record[0x8a]);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89 }, record[0x3c..0x40]);
}
