//! Fixed-capacity single-producer, single-consumer queue.
//!
//! A producer may itself be protected by an external lock, which is how the
//! AX event bridge serializes multiple callback threads before entering this
//! queue. The consumer must remain unique.

const std = @import("std");

/// Build a queue that holds exactly `capacity` values without allocation.
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("queue capacity must be positive");

    return struct {
        const Self = @This();
        const storage_len = capacity + 1;

        buf: [storage_len]T = undefined,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        /// Publish a value, returning false without modifying the queue when
        /// all advertised slots are occupied.
        pub fn push(self: *Self, value: T) bool {
            const tail = self.tail.load(.monotonic);
            const next = (tail + 1) % storage_len;
            if (next == self.head.load(.acquire)) return false;

            self.buf[tail] = value;
            self.tail.store(next, .release);
            return true;
        }

        /// Remove the oldest published value, or null when the queue is empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;

            const value = self.buf[head];
            self.head.store((head + 1) % storage_len, .release);
            return value;
        }
    };
}

test "queue exposes its full capacity and preserves FIFO order" {
    var queue: Queue(u8, 3) = .{};

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(!queue.push(4));

    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
}

test "queue wraps without reordering values" {
    var queue: Queue(u16, 2) = .{};

    try std.testing.expect(queue.push(10));
    try std.testing.expect(queue.push(20));
    try std.testing.expectEqual(@as(?u16, 10), queue.pop());
    try std.testing.expect(queue.push(30));
    try std.testing.expectEqual(@as(?u16, 20), queue.pop());
    try std.testing.expectEqual(@as(?u16, 30), queue.pop());
}
