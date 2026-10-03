//! Allocation-free pointer-focus event coalescing and retry policy.

const std = @import("std");

const retry_delay_ns: i128 = 100 * std.time.ns_per_ms;

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
    var bytes = [_]u8{0} ** 0xf8;
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
    var bytes = [_]u8{0} ** 0xf8;
    bytes[0x04] = 0xf8;
    bytes[0x08] = 0x0d;
    bytes[0x8a] = subtype;
    std.mem.writeInt(u32, bytes[0x3c..0x40], window_id, .little);
    return bytes;
}

pub const State = struct {
    mouse_move_pending: bool = false,
    event_window_id: u32 = 0,
    hovered_window_id: u32 = 0,
    retry_window_id: u32 = 0,
    retry_at_ns: i128 = 0,
    fallback_logged: bool = false,

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

    /// Consume the coalesced move and decide whether its hit-tested window
    /// needs a focus attempt. Blocked moves do not consume the hover change.
    pub fn shouldAttempt(self: *State, window_id: u32, now_ns: i128, blocked: bool) bool {
        self.mouse_move_pending = false;
        if (blocked) return false;

        if (window_id != self.hovered_window_id) {
            self.hovered_window_id = window_id;
            self.clearRetry();
            return window_id != 0;
        }
        return window_id != 0 and
            self.retry_window_id == window_id and
            now_ns >= self.retry_at_ns;
    }

    pub fn focusFailed(self: *State, window_id: u32, now_ns: i128) void {
        if (self.hovered_window_id != window_id) return;
        self.retry_window_id = window_id;
        self.retry_at_ns = now_ns +| retry_delay_ns;
    }

    pub fn focusSucceeded(self: *State, window_id: u32) void {
        if (self.hovered_window_id == window_id) self.clearRetry();
    }

    pub fn isHovered(self: *const State, window_id: u32) bool {
        return window_id != 0 and self.hovered_window_id == window_id;
    }

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    fn clearRetry(self: *State) void {
        self.retry_window_id = 0;
        self.retry_at_ns = 0;
    }
};

test "mouse moves coalesce until consumed" {
    var state: State = .{};
    try std.testing.expect(state.queueMouseMove(10));
    try std.testing.expect(!state.queueMouseMove(20));
    try std.testing.expectEqual(@as(u32, 20), state.eventWindowId());
    try std.testing.expect(state.shouldAttempt(20, 100, false));
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

test "unchanged hover retries only after a failed-focus backoff" {
    var state: State = .{};
    try std.testing.expect(state.shouldAttempt(10, 100, false));
    state.focusFailed(10, 100);

    try std.testing.expect(!state.shouldAttempt(10, 100 + retry_delay_ns - 1, false));
    try std.testing.expect(state.shouldAttempt(10, 100 + retry_delay_ns, false));
    state.focusSucceeded(10);
    try std.testing.expect(!state.shouldAttempt(10, 100 + retry_delay_ns * 2, false));
}

test "blocked moves preserve the next hover attempt" {
    var state: State = .{};
    try std.testing.expect(!state.shouldAttempt(20, 100, true));
    try std.testing.expect(state.shouldAttempt(20, 101, false));
}

test "leaving a window clears its failed-focus backoff" {
    var state: State = .{};
    try std.testing.expect(state.shouldAttempt(10, 100, false));
    state.focusFailed(10, 100);
    try std.testing.expect(!state.shouldAttempt(0, 101, false));
    try std.testing.expect(state.shouldAttempt(10, 102, false));
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
