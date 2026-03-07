//! Live tiling destination preview overlay via zig-objc.
//!
//! The window manager computes preview frames in CG coordinates (top-left origin),
//! while AppKit expects NS coordinates (bottom-left origin). This module performs
//! that conversion and owns a lazily created borderless panel.

const std = @import("std");
const objc = @import("objc");
const c = @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
});

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
const preview_border_width: f64 = 3;
const ns_window_style_mask_borderless: usize = 0;
const ns_backing_store_buffered: usize = 2;
const ns_window_collection_behavior_can_join_all_spaces: usize = 1 << 0;
const ns_window_collection_behavior_transient: usize = 1 << 3;
const ns_window_collection_behavior_full_screen_auxiliary: usize = 1 << 8;

var g_tile_preview_panel: ?objc.Object = null;

pub fn show(x: f64, y: f64, width: f64, height: f64) void {
    if (width <= 0 or height <= 0) return;

    const panel = ensurePanel() orelse return;
    const frame = nsRectFromCg(x, y, width, height);
    panel.msgSend(void, "setFrame:display:", .{ frame, true });

    const nil_object: objc.Object = .{ .value = null };
    panel.msgSend(void, "orderFront:", .{nil_object});
}

pub fn hide() void {
    if (g_tile_preview_panel) |panel| {
        const nil_object: objc.Object = .{ .value = null };
        panel.msgSend(void, "orderOut:", .{nil_object});
    }
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
                .{ @as(f64, 0.13), @as(f64, 0.62), @as(f64, 1.0), @as(f64, 0.95) },
            );
            if (border_color.value != null) {
                if (border_color.msgSend(?*anyopaque, "CGColor", .{})) |cg_color| {
                    layer.msgSend(void, "setBorderColor:", .{cg_color});
                }
            }

            const background_color = NSColor.msgSend(
                objc.Object,
                "colorWithSRGBRed:green:blue:alpha:",
                .{ @as(f64, 0.13), @as(f64, 0.62), @as(f64, 1.0), @as(f64, 0.18) },
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
