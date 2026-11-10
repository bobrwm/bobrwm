//! WindowServer window-existence queries, safe to call from any thread.

const std = @import("std");
const c = @import("c");
const cg_extra = @import("cg_extra");

/// Largest batch one call accepts; matches the managed-window catalog.
pub const max_batch = 1024;

/// The subset of `window_ids` WindowServer still knows, on any Space and on-
/// or off-screen, written to `out` in one round trip. Null when WindowServer
/// cannot answer, so callers keep everything rather than mistake a failed
/// query for destruction. SkyLight bounds cannot answer this: they also fail
/// for windows still under construction.
pub fn existingWindowIds(window_ids: []const u32, out: []u32) ?[]u32 {
    std.debug.assert(window_ids.len <= max_batch);
    std.debug.assert(out.len >= window_ids.len);
    if (window_ids.len == 0) return out[0..0];

    // The CG API reads raw CGWindowID values, so the array has no callbacks.
    var values: [max_batch]?*const anyopaque = undefined;
    for (window_ids, 0..) |wid, index| {
        std.debug.assert(wid != 0);
        values[index] = @ptrFromInt(wid);
    }
    const ids_ref = c.CFArrayCreate(null, &values, @intCast(window_ids.len), null) orelse return null;
    defer c.CFRelease(@ptrCast(ids_ref));

    const descriptions = cg_extra.CGWindowListCreateDescriptionFromArray(ids_ref) orelse return null;
    defer c.CFRelease(@ptrCast(descriptions));

    var count: usize = 0;
    const description_count = c.CFArrayGetCount(descriptions);
    var index: c.CFIndex = 0;
    while (index < description_count and count < out.len) : (index += 1) {
        const info: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(descriptions, index) orelse continue);
        const number: c.CFNumberRef = @ptrCast(c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber) orelse continue);
        var wid: u32 = 0;
        if (c.CFNumberGetValue(number, c.kCFNumberSInt32Type, &wid) == 0) continue;
        out[count] = wid;
        count += 1;
    }
    if (count == 0 and !isAnswering()) return null;
    return out[0..count];
}

/// Whether WindowServer still knows `wid`. A failed query counts as present,
/// so a transient failure never drops a live window.
pub fn hasWindow(wid: u32) bool {
    var out: [1]u32 = undefined;
    const existing = existingWindowIds(&.{wid}, &out) orelse return true;
    return existing.len > 0;
}

/// An empty description list is either every window gone or a WindowServer
/// that is not answering. The on-screen list always holds at least the menu
/// bar, so an empty one means the query failed.
fn isAnswering() bool {
    const options = cg_extra.kCGWindowListOptionOnScreenOnly;
    const list = cg_extra.CGWindowListCopyWindowInfo(options, cg_extra.kCGNullWindowID) orelse return false;
    defer c.CFRelease(@ptrCast(list));
    return c.CFArrayGetCount(list) > 0;
}

test "existing window IDs keep live windows and drop unknown ones" {
    const testing = std.testing;
    const list = cg_extra.CGWindowListCopyWindowInfo(
        cg_extra.kCGWindowListOptionOnScreenOnly,
        cg_extra.kCGNullWindowID,
    ) orelse return error.SkipZigTest;
    defer c.CFRelease(@ptrCast(list));
    const count = c.CFArrayGetCount(list);
    if (count == 0) return error.SkipZigTest;

    // Back to front, the last entry is a session-lifetime WindowServer or
    // wallpaper window; the frontmost can be a tooltip that closes mid-test.
    const info: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(list, count - 1).?);
    const number: c.CFNumberRef = @ptrCast(c.CFDictionaryGetValue(info, cg_extra.kCGWindowNumber).?);
    var live_wid: u32 = 0;
    try testing.expect(c.CFNumberGetValue(number, c.kCFNumberSInt32Type, &live_wid) != 0);

    // Window IDs count up from small values within a login session.
    const unknown_wid: u32 = 0xFFFF_FFF0;
    var out: [2]u32 = undefined;
    const existing = existingWindowIds(&.{ live_wid, unknown_wid }, &out) orelse return error.SkipZigTest;
    try testing.expectEqualSlices(u32, &.{live_wid}, existing);

    var empty_out: [1]u32 = undefined;
    const none = existingWindowIds(&.{unknown_wid}, &empty_out) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 0), none.len);
}
