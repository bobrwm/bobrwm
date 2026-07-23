//! Inactive-window dimming via owned black overlay panels ("HazeOver" style).
//!
//! For every visible managed window except the focused one, a borderless,
//! click-through black `NSPanel` is positioned exactly over the window's frame
//! at `level` opacity and ordered directly above that window. Overlaying black
//! is a true multiplicative darken (`content * (1 - level)`), so it preserves
//! hue with no color cast — unlike the SkyLight brightness filter, which adds a
//! constant offset and washes colors out.
//!
//! The panels are owned by bobrwm's own connection, so this needs neither SIP
//! disabled nor injection: we never touch the foreign windows, only draw over
//! them. `orderWindow:relativeTo:` places each overlay immediately above its
//! target window in the global z-order, so the focused window (which has no
//! overlay) stays clear even when windows overlap.
//!
//! Overlays are pooled and reused. apply() is called once per settled event
//! drain; it only reconfigures a panel when its target or frame changed, so an
//! unchanged frame issues no AppKit work and does not flicker.

const std = @import("std");
const objc = @import("objc");
const config = @import("config.zig");

const log = std.log.scoped(.dim);

/// Set from `config.dimmed_inactive` at startup and on config reload.
/// When false, apply() is a no-op.
pub var enabled: bool = false;
/// Overlay opacity in [0, 1] (0 = transparent, 1 = fully black).
pub var level: f64 = 0.35;

/// A window to (potentially) dim, in CG coordinates (top-left origin).
pub const Entry = struct {
    wid: u32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

const max_overlays = 64;

const ns_window_style_mask_borderless: usize = 0;
const ns_backing_store_buffered: usize = 2;
const ns_window_order_above: i64 = 1;

// Corner radius (points) applied to overlays so their edges follow the rounded
// corners of macOS windows instead of poking out as black squares. Matches the
// standard macOS window rounding closely enough that no black corner shows.
const overlay_corner_radius: f64 = 10.0;
const ns_window_collection_behavior_can_join_all_spaces: usize = 1 << 0;
const ns_window_collection_behavior_transient: usize = 1 << 3;
const ns_window_collection_behavior_full_screen_auxiliary: usize = 1 << 8;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const Slot = struct {
    panel: objc.Object,
    wid: u32 = 0, // target window; 0 when the slot is hidden/free
    shown: bool = false,
    frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
};

var slots: [max_overlays]Slot = undefined;
var slot_count: usize = 0; // number of lazily created panels

pub fn configure(cfg: config.DimConfig) void {
    enabled = cfg.enabled;
    level = std.math.clamp(@as(f64, cfg.level), 0.0, 1.0);
    for (slots[0..slot_count]) |*slot| {
        slot.panel.msgSend(void, "setAlphaValue:", .{level});
    }
    if (!enabled) resetAll();
}

/// Show/position overlays so every entry except a focused window is dimmed.
/// `focused` holds the active window of each display's visible workspace, so
/// the frontmost window on every display stays bright. Diffs against current
/// panel state; unchanged overlays are left untouched.
pub fn apply(focused: []const u32, entries: []const Entry) void {
    if (!enabled) return;
    std.debug.assert(level >= 0.0 and level <= 1.0);

    // Nothing focused anywhere (focus loss / mid-transition): undim rather than
    // dimming the whole screen.
    if (focused.len == 0) {
        resetAll();
        return;
    }

    // Pass 1: hide overlays whose target is no longer a dim candidate.
    for (slots[0..slot_count]) |*s| {
        if (!s.shown) continue;
        if (!isDimTarget(entries, focused, s.wid)) hideSlot(s);
    }

    // Pass 2: ensure an overlay exists (and is current) for each candidate.
    for (entries) |e| {
        if (e.wid == 0 or contains(focused, e.wid)) continue;
        if (e.w <= 0 or e.h <= 0) continue;
        ensureOverlay(e);
    }
}

/// Flip the enabled state at runtime and return the new value. When turning
/// off, overlays are hidden immediately; when turning on, the caller re-applies
/// the current snapshot so dimming appears without waiting for the next drain.
pub fn toggle() bool {
    enabled = !enabled;
    if (!enabled) resetAll();
    return enabled;
}

/// Hide every overlay. Called on focus loss, feature disable, and shutdown.
pub fn resetAll() void {
    for (slots[0..slot_count]) |*s| {
        if (s.shown) hideSlot(s);
    }
}

fn contains(set: []const u32, wid: u32) bool {
    for (set) |w| {
        if (w == wid) return true;
    }
    return false;
}

fn isDimTarget(entries: []const Entry, focused: []const u32, wid: u32) bool {
    if (wid == 0 or contains(focused, wid)) return false;
    for (entries) |e| {
        if (e.wid == wid) return true;
    }
    return false;
}

fn ensureOverlay(e: Entry) void {
    const frame = nsRectFromCg(e.x, e.y, e.w, e.h);

    // Reuse an overlay already targeting this window: only re-place it if its
    // frame moved. Ordering and framing are skipped when nothing changed to
    // avoid needless AppKit churn and flicker.
    for (slots[0..slot_count]) |*s| {
        if (s.shown and s.wid == e.wid) {
            if (!rectEql(s.frame, frame)) {
                s.panel.msgSend(void, "setFrame:display:", .{ frame, true });
                s.frame = frame;
                orderAbove(s.panel, e.wid);
            }
            return;
        }
    }

    // New target: opacity is already set at panel creation, so only frame and
    // z-order need setting here.
    const s = acquireSlot() orelse return;
    s.wid = e.wid;
    s.frame = frame;
    s.shown = true;
    s.panel.msgSend(void, "setFrame:display:", .{ frame, true });
    orderAbove(s.panel, e.wid);
}

fn orderAbove(panel: objc.Object, wid: u32) void {
    panel.msgSend(void, "orderWindow:relativeTo:", .{ ns_window_order_above, @as(i64, wid) });
}

fn hideSlot(s: *Slot) void {
    const nil_object: objc.Object = .{ .value = null };
    s.panel.msgSend(void, "orderOut:", .{nil_object});
    s.shown = false;
    s.wid = 0;
}

fn acquireSlot() ?*Slot {
    for (slots[0..slot_count]) |*s| {
        if (!s.shown) return s;
    }
    if (slot_count >= max_overlays) {
        log.warn("overlay pool exhausted ({d}); some inactive windows not dimmed", .{max_overlays});
        return null;
    }
    const panel = createPanel() orelse return null;
    slots[slot_count] = .{ .panel = panel };
    const s = &slots[slot_count];
    slot_count += 1;
    return s;
}

fn createPanel() ?objc.Object {
    const NSPanel = objc.getClass("NSPanel") orelse return null;
    const NSColor = objc.getClass("NSColor") orelse return null;

    const default_rect: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    const panel = NSPanel.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithContentRect:styleMask:backing:defer:",
        .{ default_rect, ns_window_style_mask_borderless, ns_backing_store_buffered, false },
    );
    if (panel.value == null) return null;

    panel.msgSend(void, "setOpaque:", .{false});
    panel.msgSend(void, "setHasShadow:", .{false});
    panel.msgSend(void, "setIgnoresMouseEvents:", .{true});
    panel.msgSend(void, "setHidesOnDeactivate:", .{false});

    // The window itself is clear; the darkening comes from a rounded, black
    // layer in the content view so the overlay's corners follow the window's
    // rounded corners instead of covering them with black squares.
    const clear = NSColor.msgSend(objc.Object, "clearColor", .{});
    if (clear.value != null) panel.msgSend(void, "setBackgroundColor:", .{clear});

    const content = panel.msgSend(objc.Object, "contentView", .{});
    if (content.value != null) {
        content.msgSend(void, "setWantsLayer:", .{true});
        const layer = content.msgSend(objc.Object, "layer", .{});
        if (layer.value != null) {
            layer.msgSend(void, "setCornerRadius:", .{overlay_corner_radius});
            layer.msgSend(void, "setMasksToBounds:", .{true});
            const black = NSColor.msgSend(objc.Object, "blackColor", .{});
            if (black.value != null) {
                if (black.msgSend(?*anyopaque, "CGColor", .{})) |cg_black| {
                    layer.msgSend(void, "setBackgroundColor:", .{cg_black});
                }
            }
        }
    }

    // configure() updates existing panels when config is hot-reloaded; newly
    // allocated panels start at the current level here.
    panel.msgSend(void, "setAlphaValue:", .{level});

    const collection_behavior =
        ns_window_collection_behavior_can_join_all_spaces |
        ns_window_collection_behavior_full_screen_auxiliary |
        ns_window_collection_behavior_transient;
    panel.msgSend(void, "setCollectionBehavior:", .{collection_behavior});

    return panel;
}

fn rectEql(a: NSRect, b: NSRect) bool {
    return a.origin.x == b.origin.x and a.origin.y == b.origin.y and
        a.size.width == b.size.width and a.size.height == b.size.height;
}

/// Convert a CG rect (top-left origin) to an NS rect (bottom-left origin),
/// flipping against the topmost screen edge across all displays.
fn nsRectFromCg(x: f64, y: f64, width: f64, height: f64) NSRect {
    const fallback: NSRect = .{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = width, .height = height },
    };

    const NSScreen = objc.getClass("NSScreen") orelse return fallback;
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    if (count == 0) return fallback;

    var global_top: f64 = -std.math.inf(f64);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const screen = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        const frame = screen.msgSend(NSRect, "frame", .{});
        const top = frame.origin.y + frame.size.height;
        if (top > global_top) global_top = top;
    }

    std.debug.assert(global_top != -std.math.inf(f64));
    return .{
        .origin = .{ .x = x, .y = global_top - (y + height) },
        .size = .{ .width = width, .height = height },
    };
}

// Tests

const t = std.testing;

test "configure clamps level and sets enabled" {
    configure(.{ .enabled = true, .level = 2.0 });
    try t.expect(enabled);
    try t.expectApproxEqAbs(@as(f64, 1.0), level, 0.0001);

    configure(.{ .enabled = false, .level = -0.5 });
    try t.expect(!enabled);
    try t.expectApproxEqAbs(@as(f64, 0.0), level, 0.0001);

    configure(.{ .enabled = true, .level = 0.4 });
    try t.expectApproxEqAbs(@as(f64, 0.4), level, 0.0001);
}

test "isDimTarget" {
    const entries = [_]Entry{
        .{ .wid = 3, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 7, .x = 0, .y = 0, .w = 10, .h = 10 },
    };
    const focused = [_]u32{7};
    try t.expect(isDimTarget(&entries, &focused, 3)); // 3 is inactive → dim
    try t.expect(!isDimTarget(&entries, &focused, 7)); // 7 is focused → no dim
    try t.expect(!isDimTarget(&entries, &focused, 9)); // 9 not visible → no dim
    try t.expect(!isDimTarget(&entries, &focused, 0)); // 0 is not a window
}

test "isDimTarget with per-display focus set" {
    const entries = [_]Entry{
        .{ .wid = 3, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 7, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 8, .x = 0, .y = 0, .w = 10, .h = 10 },
    };
    // Two displays, each with its own focused window.
    const focused = [_]u32{ 7, 8 };
    try t.expect(isDimTarget(&entries, &focused, 3)); // inactive → dim
    try t.expect(!isDimTarget(&entries, &focused, 7)); // focused on display A
    try t.expect(!isDimTarget(&entries, &focused, 8)); // focused on display B
}

test "apply is a no-op when disabled" {
    // Guard against a regression where apply() touches AppKit or slot state
    // while the feature is off. With enabled = false it must return before any
    // panel work, leaving slot bookkeeping untouched.
    const saved_enabled = enabled;
    const saved_slot_count = slot_count;
    defer {
        enabled = saved_enabled;
        slot_count = saved_slot_count;
    }

    enabled = false;
    slot_count = 0;
    const entries = [_]Entry{.{ .wid = 3, .x = 0, .y = 0, .w = 10, .h = 10 }};
    const focused = [_]u32{7};
    apply(&focused, &entries);
    try t.expectEqual(@as(usize, 0), slot_count);
}

test "toggle flips enabled and returns new state" {
    const saved_enabled = enabled;
    const saved_slot_count = slot_count;
    defer {
        enabled = saved_enabled;
        slot_count = saved_slot_count;
    }

    enabled = false;
    slot_count = 0; // no live panels, so resetAll on toggle-off stays a no-op
    try t.expectEqual(true, toggle());
    try t.expect(enabled);
    try t.expectEqual(false, toggle());
    try t.expect(!enabled);
}

test "contains" {
    const set = [_]u32{ 5, 9 };
    try t.expect(contains(&set, 5));
    try t.expect(contains(&set, 9));
    try t.expect(!contains(&set, 4));
    try t.expect(!contains(&[_]u32{}, 5)); // empty set matches nothing
}

test "rectEql" {
    const a: NSRect = .{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 3, .height = 4 } };
    const b: NSRect = .{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 3, .height = 4 } };
    const c: NSRect = .{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 3, .height = 5 } };
    try t.expect(rectEql(a, b));
    try t.expect(!rectEql(a, c));
}
