//! Live tiling destination preview overlay via zig-objc.
//!
//! The window manager computes preview frames in CG coordinates (top-left origin),
//! while AppKit expects NS coordinates (bottom-left origin). This module performs
//! that conversion and owns a lazily created borderless panel. AppKit animates
//! the panel independently of AX window writes so a slow app cannot stall it.

const std = @import("std");
const objc = @import("objc");
const c = @import("c");

const NSPoint = extern struct {
    x: f64,
    y: f64,
};

const NSSize = extern struct {
    width: f64,
    height: f64,
};

const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

const preview_frame_default: NSRect = .{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 100, .height = 100 },
};
const preview_corner_radius: f64 = 10;
const preview_border_width: f64 = 1.5;
const preview_move_duration: f64 = 0.12;
const preview_fade_duration: f64 = 0.12;
const ns_window_style_mask_borderless: usize = 0;
const ns_backing_store_buffered: usize = 2;
const ns_window_collection_behavior_can_join_all_spaces: usize = 1 << 0;
const ns_window_collection_behavior_transient: usize = 1 << 3;
const ns_window_collection_behavior_full_screen_auxiliary: usize = 1 << 8;

var g_tile_preview_panel: ?objc.Object = null;
var g_visible = false;
// A fade-out completion must not hide a preview shown again in the meantime.
var g_generation: u64 = 0;
const HideCompletion = objc.Block(struct { generation: u64 }, .{}, void);

pub fn show(x: f64, y: f64, width: f64, height: f64) void {
    if (width <= 0 or height <= 0) return;

    const panel = ensurePanel() orelse return;
    const frame = nsRectFromCg(x, y, width, height);
    g_generation +%= 1;
    // A hide request leaves the panel visible until its fade completes.
    // Crossing a gap must retarget that visible frame, not teleport to a
    // fresh entry at the next target and reset its opacity to zero.
    const was_visible = panel.msgSend(bool, "isVisible", .{});
    g_visible = true;
    const reduce_motion = reduceMotion();
    if (!was_visible) {
        // Start locally, not at the last drag's destination (possibly on
        // another display). The small expansion makes entry feel immediate.
        const inset = if (reduce_motion) 0 else @min(@as(f64, 6), @min(width, height) / 4);
        const initial: NSRect = .{
            .origin = .{ .x = frame.origin.x + inset, .y = frame.origin.y + inset },
            .size = .{ .width = width - 2 * inset, .height = height - 2 * inset },
        };
        panel.msgSend(void, "setFrame:display:", .{ initial, true });
        panel.msgSend(void, "setAlphaValue:", .{@as(f64, 0)});
        panel.msgSend(void, "orderFront:", .{objc.Object{ .value = null }});
    }

    _ = beginAnimation(if (reduce_motion) 0 else preview_move_duration);
    const animator = panel.msgSend(objc.Object, "animator", .{});
    animator.msgSend(void, "setFrame:display:", .{ frame, true });
    animator.msgSend(void, "setAlphaValue:", .{@as(f64, 1)});
    objc.getClass("NSAnimationContext").?.msgSend(void, "endGrouping", .{});
}

pub fn hide() void {
    if (!g_visible) return;
    const panel = g_tile_preview_panel orelse return;
    g_visible = false;
    g_generation +%= 1;
    if (reduceMotion()) {
        panel.msgSend(void, "orderOut:", .{objc.Object{ .value = null }});
        return;
    }
    const context = beginAnimation(preview_fade_duration);
    var completion = HideCompletion.init(.{ .generation = g_generation }, finishHide);
    context.msgSend(void, "setCompletionHandler:", .{&completion});
    panel.msgSend(objc.Object, "animator", .{}).msgSend(void, "setAlphaValue:", .{@as(f64, 0)});
    objc.getClass("NSAnimationContext").?.msgSend(void, "endGrouping", .{});
}

fn finishHide(completion: *const HideCompletion.Context) callconv(.c) void {
    if (completion.generation != g_generation or g_visible) return;
    if (g_tile_preview_panel) |panel| {
        panel.msgSend(void, "orderOut:", .{objc.Object{ .value = null }});
    }
}

fn reduceMotion() bool {
    const workspace = objc.getClass("NSWorkspace").?.msgSend(objc.Object, "sharedWorkspace", .{});
    return workspace.msgSend(bool, "accessibilityDisplayShouldReduceMotion", .{});
}

fn beginAnimation(duration: f64) objc.Object {
    const NSAnimationContext = objc.getClass("NSAnimationContext").?;
    NSAnimationContext.msgSend(void, "beginGrouping", .{});
    const context = NSAnimationContext.msgSend(objc.Object, "currentContext", .{});
    context.msgSend(void, "setDuration:", .{duration});
    const timing = objc.getClass("CAMediaTimingFunction").?.msgSend(
        objc.Object,
        "functionWithControlPoints::::",
        .{ @as(f32, 0.22), @as(f32, 1), @as(f32, 0.36), @as(f32, 1) },
    );
    context.msgSend(void, "setTimingFunction:", .{timing});
    return context;
}

fn ensurePanel() ?objc.Object {
    if (g_tile_preview_panel) |panel| return panel;

    const NSPanel = objc.getClass("NSPanel") orelse return null;
    const NSColor = objc.getClass("NSColor") orelse return null;

    const panel = NSPanel.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            preview_frame_default,
            ns_window_style_mask_borderless,
            ns_backing_store_buffered,
            false,
        },
    );
    if (panel.value == null) return null;

    panel.msgSend(void, "setOpaque:", .{false});
    panel.msgSend(void, "setHasShadow:", .{false});
    panel.msgSend(void, "setIgnoresMouseEvents:", .{true});
    panel.msgSend(void, "setHidesOnDeactivate:", .{false});

    const clear_color = NSColor.msgSend(objc.Object, "clearColor", .{});
    if (clear_color.value != null) {
        panel.msgSend(void, "setBackgroundColor:", .{clear_color});
    }

    const panel_level = @as(i64, @intCast(c.CGWindowLevelForKey(c.kCGStatusWindowLevelKey))) + 1;
    panel.msgSend(void, "setLevel:", .{panel_level});

    const collection_behavior =
        ns_window_collection_behavior_can_join_all_spaces |
        ns_window_collection_behavior_full_screen_auxiliary |
        ns_window_collection_behavior_transient;
    panel.msgSend(void, "setCollectionBehavior:", .{collection_behavior});

    const content = panel.msgSend(objc.Object, "contentView", .{});
    if (content.value != null) {
        content.msgSend(void, "setWantsLayer:", .{true});

        const layer = content.msgSend(objc.Object, "layer", .{});
        if (layer.value != null) {
            layer.msgSend(void, "setCornerRadius:", .{preview_corner_radius});
            layer.msgSend(void, "setBorderWidth:", .{preview_border_width});

            const border_color = NSColor.msgSend(
                objc.Object,
                "colorWithSRGBRed:green:blue:alpha:",
                .{ @as(f64, 0.13), @as(f64, 0.62), @as(f64, 1.0), @as(f64, 0.75) },
            );
            if (border_color.value != null) {
                if (border_color.msgSend(?*anyopaque, "CGColor", .{})) |cg_color| {
                    layer.msgSend(void, "setBorderColor:", .{cg_color});
                }
            }

            const background_color = NSColor.msgSend(
                objc.Object,
                "colorWithSRGBRed:green:blue:alpha:",
                .{ @as(f64, 0.13), @as(f64, 0.62), @as(f64, 1.0), @as(f64, 0.06) },
            );
            if (background_color.value != null) {
                if (background_color.msgSend(?*anyopaque, "CGColor", .{})) |cg_color| {
                    layer.msgSend(void, "setBackgroundColor:", .{cg_color});
                }
            }
        }
    }

    g_tile_preview_panel = panel;
    return panel;
}

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
