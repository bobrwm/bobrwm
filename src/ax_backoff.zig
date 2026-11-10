//! Per-app backoff when AX readiness queries time out on the main thread.
//!
//! Hung apps don't answer AX messages until their main thread recovers, so
//! querying the app repeatedly will stall our own main thread. Instead, we can
//! back off and try again later on a poll tick.

const std = @import("std");
const osutil = @import("osutil.zig");

const backoff_ms: i128 = 2000;
const max_apps = 16;

const Entry = struct {
    process_id: i32 = 0,
    until_ns: i128 = 0,
};

var g_entries: [max_apps]Entry = @splat(.{});

pub fn isBackedOff(pid: i32) bool {
    const now_ns = osutil.nanoTimestamp();
    for (g_entries) |entry| {
        if (entry.process_id == pid and entry.until_ns > now_ns) return true;
    }

    return false;
}

/// Back `pid` off. Reuses its slot, else the one expiring first: expired and
/// unused slots sort before every live backoff.
pub fn backOff(pid: i32) void {
    std.debug.assert(pid > 0);
    var slot = &g_entries[0];
    for (&g_entries) |*entry| {
        if (entry.process_id == pid) {
            slot = entry;
            break;
        }
        if (entry.until_ns < slot.until_ns) slot = entry;
    }

    slot.* = .{
        .process_id = pid,
        .until_ns = osutil.nanoTimestamp() + backoff_ms * std.time.ns_per_ms,
    };
}
