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
//! Overlays are pooled and reused. apply() runs at the end of each event drain
//! and when an animation finishes; it only reconfigures a panel when its target
//! or frame changed, so an unchanged frame issues no AppKit work and does not
//! flicker.

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
    pid: i32,
    display_id: u32,
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
pub const CGPoint = extern struct { x: f64, y: f64 };
const CGRect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };

pub const SlsTransactionRef = *anyopaque;
const sls_order_out: c_int = 0;
const sls_order_above: c_int = 1;

// Verified against macOS 27.2.1 ARM64 SkyLight: transaction setters and
// SLSTransactionCommit return void (leaving unrelated bytes in w0).
pub const MainConnectionIdFn = *const fn () callconv(.c) c_int;
pub const TransactionCreateFn = *const fn (c_int) callconv(.c) ?SlsTransactionRef;
pub const TransactionCommitFn = *const fn (SlsTransactionRef, c_int) callconv(.c) void;
pub const TransactionMoveWindowFn = *const fn (SlsTransactionRef, u32, CGPoint) callconv(.c) void;
pub const TransactionOrderWindowFn = *const fn (SlsTransactionRef, u32, c_int, u32) callconv(.c) void;
pub const ReleaseFn = *const fn (*const anyopaque) callconv(.c) void;

extern "c" fn CFRelease(cf: *const anyopaque) void;

/// Optional SkyLight `SLSTransaction*` function table injected from
/// `skylight.zig` at startup so SkyLight symbol lookup stays in one place.
pub const SlsOps = struct {
    mainConnectionID: MainConnectionIdFn,
    transactionCreate: TransactionCreateFn,
    transactionCommit: TransactionCommitFn,
    transactionMoveWindow: TransactionMoveWindowFn,
    transactionOrderWindow: TransactionOrderWindowFn,
    release: ReleaseFn = CFRelease,
};

var sls_ops: ?SlsOps = null;

/// Install (or clear) the SkyLight transaction ops used to batch overlay
/// updates. When unset, overlays fall back cleanly to AppKit.
pub fn setSlsOps(ops: ?SlsOps) void {
    sls_ops = ops;
}

/// Batches owned-overlay moves and z-order updates into one async WindowServer
/// `SLSTransaction`, avoiding per-panel AppKit/Mach overhead on animation ticks
/// and snapshot diffs. Lazily creates the transaction on the first encoded op
/// so idle batches do no work.
pub const Batch = struct {
    api: ?SlsOps,
    tx: ?SlsTransactionRef = null,

    pub fn begin() Batch {
        return .{ .api = sls_ops };
    }

    /// Move an existing overlay inside this batch without re-diffing the
    /// snapshot. Used per animation tick, where a full snapshot would cost a
    /// WindowServer window-list copy every frame.
    pub fn follow(self: *Batch, wid: u32, x: f64, y: f64, w: f64, h: f64) void {
        if (!enabled) return;

        const target: CGRect = .{ .x = x, .y = y, .w = w, .h = h };
        for (slots[0..slot_count]) |*s| {
            if (!s.shown or s.wid != wid) continue;
            if (cgRectEql(s.cg_frame, target)) return;
            moveOrResizeSlot(s, target, self);
            return;
        }
    }

    pub fn commit(self: *Batch) void {
        const tx = self.tx orelse return;
        const api = self.api.?;
        self.tx = null;
        // sync=0 commits asynchronously in WindowServer submission order,
        // avoiding a synchronous main-thread round-trip.
        api.transactionCommit(tx, 0);
        api.release(tx);
    }

    fn ensureTx(self: *Batch) ?SlsTransactionRef {
        if (self.tx) |tx| return tx;
        const api = self.api orelse return null;
        const tx = api.transactionCreate(api.mainConnectionID()) orelse return null;
        self.tx = tx;
        return tx;
    }

    fn moveWindow(self: *Batch, panel_wid: u32, x: f64, y: f64) bool {
        const tx = self.ensureTx() orelse return false;
        self.api.?.transactionMoveWindow(tx, panel_wid, .{ .x = x, .y = y });
        return true;
    }

    fn orderWindow(self: *Batch, panel_wid: u32, order: c_int, relative_wid: u32) bool {
        const tx = self.ensureTx() orelse return false;
        self.api.?.transactionOrderWindow(tx, panel_wid, order, relative_wid);
        return true;
    }
};

const Slot = struct {
    panel: objc.Object,
    panel_wid: u32 = 0, // panel's CGWindowID once ordered in by AppKit
    wid: u32 = 0, // target window; 0 when the slot is hidden/free
    pid: i32 = 0,
    display_id: u32 = 0,
    shown: bool = false,
    /// True once AppKit has ordered this panel in at least once so its backing
    /// store and rounded-corner layer exist in WindowServer.
    backing_ready: bool = false,
    // Ordered during the current apply(), so restacking can skip it.
    is_ordered: bool = false,
    /// Authoritative CG frame (top-left origin) in WindowServer.
    cg_frame: CGRect = .{},
    /// Backing store size currently owned by AppKit's last `setFrame:`.
    backing_w: f64 = 0,
    backing_h: f64 = 0,
    /// Set when `SLSTransactionMoveWindowWithGroup` moved the panel without
    /// updating AppKit's cached frame origin. A subsequent resize re-asserts
    /// the CG origin via SLS so AppKit cannot skip an unchanged cached origin.
    origin_sls_dirty: bool = false,
};

var slots: [max_overlays]Slot = undefined;
var slot_count: usize = 0; // number of lazily created panels

// Frontmost app at the last apply(). Activation raises all of an app's
// windows above their overlays, focused or not.
var applied_frontmost_pid: i32 = 0;

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
pub fn apply(focused: []const u32, frontmost_pid: i32, entries: []const Entry) void {
    if (!enabled) return;
    std.debug.assert(level >= 0.0 and level <= 1.0);

    // Nothing focused anywhere (focus loss / mid-transition): undim rather than
    // dimming the whole screen.
    if (focused.len == 0) {
        resetAll();
        return;
    }

    var batch = Batch.begin();
    defer batch.commit();

    // Pass 1: hide overlays whose target is no longer a dim candidate.
    for (slots[0..slot_count]) |*s| {
        if (!s.shown) continue;
        if (!isDimTarget(entries, focused, s.wid)) hideSlot(s, &batch);
    }

    // Pass 2: ensure an overlay exists (and is current) for each candidate.
    for (slots[0..slot_count]) |*s| s.is_ordered = false;
    for (entries) |e| {
        if (e.wid == 0 or contains(focused, e.wid)) continue;
        if (e.w <= 0 or e.h <= 0) continue;
        ensureOverlay(e, &batch);
    }

    // Only the activated app's windows were raised, so only its overlays can
    // have ended up beneath their targets.
    if (frontmost_pid == applied_frontmost_pid) return;
    applied_frontmost_pid = frontmost_pid;
    for (slots[0..slot_count]) |*s| {
        if (s.shown and !s.is_ordered and s.pid == frontmost_pid) orderAbove(s, &batch);
    }
}

/// Hide the overlays on one display without a snapshot, so a Space switch can
/// clear them before the slide starts.
pub fn hideDisplay(display_id: u32) void {
    var batch = Batch.begin();
    defer batch.commit();
    for (slots[0..slot_count]) |*s| {
        if (s.shown and s.display_id == display_id) hideSlot(s, &batch);
    }
}

/// Move an existing overlay to a new CG frame without re-diffing the
/// snapshot. Prefer `Batch.begin()` + `batch.follow(...)` when updating
/// multiple overlays in one tick so all moves share a single transaction.
pub fn follow(wid: u32, x: f64, y: f64, w: f64, h: f64) void {
    var batch = Batch.begin();
    defer batch.commit();
    batch.follow(wid, x, y, w, h);
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
    var batch = Batch.begin();
    defer batch.commit();
    for (slots[0..slot_count]) |*s| {
        if (s.shown) hideSlot(s, &batch);
    }
    applied_frontmost_pid = 0;
}

fn contains(set: []const u32, wid: u32) bool {
    return std.mem.findScalar(u32, set, wid) != null;
}

fn isDimTarget(entries: []const Entry, focused: []const u32, wid: u32) bool {
    if (wid == 0 or contains(focused, wid)) return false;
    for (entries) |e| {
        if (e.wid == wid) return true;
    }
    return false;
}

fn ensureOverlay(e: Entry, batch: *Batch) void {
    const target: CGRect = .{ .x = e.x, .y = e.y, .w = e.w, .h = e.h };

    // Reuse an overlay already targeting this window: only re-place it if its
    // frame moved. Ordering and framing are skipped when nothing changed to
    // avoid needless AppKit churn and flicker.
    for (slots[0..slot_count]) |*s| {
        if (s.shown and s.wid == e.wid) {
            s.display_id = e.display_id;
            if (!cgRectEql(s.cg_frame, target)) {
                moveOrResizeSlot(s, target, batch);
                orderAbove(s, batch);
            }
            return;
        }
    }

    // New target: opacity is already set at panel creation, so only frame and
    // z-order need setting here.
    const s = acquireSlot() orelse return;
    s.wid = e.wid;
    s.pid = e.pid;
    s.display_id = e.display_id;
    s.shown = true;

    if (s.backing_ready) {
        moveOrResizeSlot(s, target, batch);
        orderAbove(s, batch);
        return;
    }

    // First-ever show for a newly created panel: go through AppKit once so
    // the backing store and rounded-corner layer are materialized.
    const ns_frame = nsRectFromCg(target.x, target.y, target.w, target.h);
    s.panel.msgSend(void, "setFrame:display:", .{ ns_frame, true });
    s.panel.msgSend(void, "orderWindow:relativeTo:", .{ ns_window_order_above, @as(i64, s.wid) });
    const wn = s.panel.msgSend(i64, "windowNumber", .{});
    if (wn > 0) s.panel_wid = @intCast(wn);
    s.backing_ready = true;
    s.cg_frame = target;
    s.backing_w = target.w;
    s.backing_h = target.h;
    s.origin_sls_dirty = false;
    s.is_ordered = true;
}

/// Update a backing-ready panel's geometry: pure moves encode directly into
/// `batch` via `SLSTransactionMoveWindowWithGroup` (~4us for 4 overlays),
/// while size changes resize the backing store via AppKit to preserve crisp
/// rounded corners.
fn moveOrResizeSlot(s: *Slot, target: CGRect, batch: *Batch) void {
    const same_backing_size = s.backing_w == target.w and s.backing_h == target.h;
    if (same_backing_size and s.backing_ready and s.panel_wid != 0) {
        if (batch.moveWindow(s.panel_wid, target.x, target.y)) {
            s.cg_frame = target;
            s.origin_sls_dirty = true;
            return;
        }
    }

    // The content is a static layer; forcing a redraw per tick buys nothing.
    const ns_frame = nsRectFromCg(target.x, target.y, target.w, target.h);
    s.panel.msgSend(void, "setFrame:display:", .{ ns_frame, false });
    if (s.origin_sls_dirty and s.panel_wid != 0) {
        // Re-assert the CG origin in the batch in case AppKit's stale cached
        // NS origin matched `ns_frame.origin` and skipped sending the move.
        _ = batch.moveWindow(s.panel_wid, target.x, target.y);
    }
    s.cg_frame = target;
    s.backing_w = target.w;
    s.backing_h = target.h;
    s.origin_sls_dirty = false;
}

fn orderAbove(s: *Slot, batch: *Batch) void {
    if (s.backing_ready and s.panel_wid != 0 and batch.orderWindow(s.panel_wid, sls_order_above, s.wid)) {
        s.is_ordered = true;
        return;
    }
    s.panel.msgSend(void, "orderWindow:relativeTo:", .{ ns_window_order_above, @as(i64, s.wid) });
    s.is_ordered = true;
}

fn hideSlot(s: *Slot, batch: *Batch) void {
    if (s.backing_ready and s.panel_wid != 0 and batch.orderWindow(s.panel_wid, sls_order_out, 0)) {
        s.shown = false;
        s.wid = 0;
        return;
    }
    const nil_object: objc.Object = .{ .value = null };
    s.panel.msgSend(void, "orderOut:", .{nil_object});
    s.backing_ready = false;
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

fn cgRectEql(a: CGRect, b: CGRect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

/// Convert a CG rect (top-left origin) to an NS rect (bottom-left origin),
/// flipping against the primary screen's top edge.
fn nsRectFromCg(x: f64, y: f64, width: f64, height: f64) NSRect {
    const fallback: NSRect = .{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = width, .height = height },
    };

    const NSScreen = objc.getClass("NSScreen") orelse return fallback;
    const screens = NSScreen.msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    if (count == 0) return fallback;

    // CG's origin is the top-left of screens[0], the menu-bar display.
    const primary = screens.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)});
    const primary_frame = primary.msgSend(NSRect, "frame", .{});
    const primary_top = primary_frame.origin.y + primary_frame.size.height;
    return .{
        .origin = .{ .x = x, .y = primary_top - (y + height) },
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
        .{ .wid = 3, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 7, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 },
    };
    const focused = [_]u32{7};
    try t.expect(isDimTarget(&entries, &focused, 3)); // 3 is inactive → dim
    try t.expect(!isDimTarget(&entries, &focused, 7)); // 7 is focused → no dim
    try t.expect(!isDimTarget(&entries, &focused, 9)); // 9 not visible → no dim
    try t.expect(!isDimTarget(&entries, &focused, 0)); // 0 is not a window
}

test "isDimTarget with per-display focus set" {
    const entries = [_]Entry{
        .{ .wid = 3, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 7, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .wid = 8, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 },
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
    const entries = [_]Entry{.{ .wid = 3, .pid = 1, .display_id = 1, .x = 0, .y = 0, .w = 10, .h = 10 }};
    const focused = [_]u32{7};
    apply(&focused, 0, &entries);
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

test "cgRectEql" {
    const a: CGRect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const b: CGRect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const c: CGRect = .{ .x = 1, .y = 2, .w = 3, .h = 5 };
    try t.expect(cgRectEql(a, b));
    try t.expect(!cgRectEql(a, c));
}

test "Batch lazily creates, commits once async, and releases" {
    const Mock = struct {
        var sentinel: u8 = 0;
        var create_calls: usize = 0;
        var move_calls: usize = 0;
        var order_calls: usize = 0;
        var commit_calls: usize = 0;
        var last_sync: c_int = -1;
        var release_calls: usize = 0;
        var last_move_wid: u32 = 0;
        var last_move_pt: CGPoint = .{ .x = 0, .y = 0 };
        var last_order: c_int = -1;
        var last_rel_wid: u32 = 0;

        fn reset() void {
            create_calls = 0;
            move_calls = 0;
            order_calls = 0;
            commit_calls = 0;
            last_sync = -1;
            release_calls = 0;
            last_move_wid = 0;
            last_move_pt = .{ .x = 0, .y = 0 };
            last_order = -1;
            last_rel_wid = 0;
        }

        fn conn() callconv(.c) c_int {
            return 42;
        }
        fn create(_: c_int) callconv(.c) ?SlsTransactionRef {
            create_calls += 1;
            return @ptrCast(&sentinel);
        }
        fn commit(_: SlsTransactionRef, sync: c_int) callconv(.c) void {
            commit_calls += 1;
            last_sync = sync;
        }
        fn move(_: SlsTransactionRef, wid: u32, pt: CGPoint) callconv(.c) void {
            move_calls += 1;
            last_move_wid = wid;
            last_move_pt = pt;
        }
        fn order(_: SlsTransactionRef, _: u32, ord: c_int, rel: u32) callconv(.c) void {
            order_calls += 1;
            last_order = ord;
            last_rel_wid = rel;
        }
        fn release(_: *const anyopaque) callconv(.c) void {
            release_calls += 1;
        }
    };

    const mock_api: SlsOps = .{
        .mainConnectionID = Mock.conn,
        .transactionCreate = Mock.create,
        .transactionCommit = Mock.commit,
        .transactionMoveWindow = Mock.move,
        .transactionOrderWindow = Mock.order,
        .release = Mock.release,
    };

    // Idle batch must not create, commit, or release a transaction.
    Mock.reset();
    var empty: Batch = .{ .api = mock_api };
    empty.commit();
    try t.expectEqual(@as(usize, 0), Mock.create_calls);
    try t.expectEqual(@as(usize, 0), Mock.commit_calls);
    try t.expectEqual(@as(usize, 0), Mock.release_calls);

    // Multiple moves and orders collapse into one async (sync=0) transaction.
    Mock.reset();
    var batch: Batch = .{ .api = mock_api };
    try t.expect(batch.moveWindow(101, 10, 20));
    try t.expect(batch.moveWindow(102, 30, 40));
    try t.expect(batch.orderWindow(101, sls_order_above, 999));
    batch.commit();
    try t.expectEqual(@as(usize, 1), Mock.create_calls);
    try t.expectEqual(@as(usize, 2), Mock.move_calls);
    try t.expectEqual(@as(usize, 1), Mock.order_calls);
    try t.expectEqual(@as(usize, 1), Mock.commit_calls);
    try t.expectEqual(@as(c_int, 0), Mock.last_sync);
    try t.expectEqual(@as(usize, 1), Mock.release_calls);
    try t.expectEqual(@as(u32, 102), Mock.last_move_wid);
    try t.expectEqual(@as(f64, 30), Mock.last_move_pt.x);
    try t.expectEqual(@as(f64, 40), Mock.last_move_pt.y);
    try t.expectEqual(sls_order_above, Mock.last_order);
    try t.expectEqual(@as(u32, 999), Mock.last_rel_wid);

    // Pure-move follow() on a backing-ready slot encodes directly via SLS and marks origin_sls_dirty.
    const saved_enabled = enabled;
    const saved_slot_count = slot_count;
    const saved_slot0 = slots[0];
    defer {
        enabled = saved_enabled;
        slot_count = saved_slot_count;
        slots[0] = saved_slot0;
    }

    Mock.reset();
    enabled = true;
    slot_count = 1;
    slots[0] = .{
        .panel = .{ .value = null },
        .panel_wid = 500,
        .wid = 77,
        .pid = 12,
        .display_id = 1,
        .shown = true,
        .backing_ready = true,
        .cg_frame = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
        .backing_w = 400,
        .backing_h = 300,
    };
    var follow_batch: Batch = .{ .api = mock_api };
    follow_batch.follow(77, 120, 80, 400, 300);
    follow_batch.follow(77, 120, 80, 400, 300); // unchanged frame is skipped
    follow_batch.commit();
    try t.expectEqual(@as(usize, 1), Mock.move_calls);
    try t.expectEqual(@as(u32, 500), Mock.last_move_wid);
    try t.expectEqual(@as(f64, 120), slots[0].cg_frame.x);
    try t.expectEqual(@as(f64, 80), slots[0].cg_frame.y);
    try t.expect(slots[0].origin_sls_dirty);
}
