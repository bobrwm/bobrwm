//! macOS status bar (menu bar icon) via zig-objc.
//!
//! Displays the active workspace name/index and provides a menu
//! with Retile and Quit actions (handled by BWStatusBarDelegate in shim.m).

const std = @import("std");
const objc = @import("objc");

const log = std.log.scoped(.statusbar);

var g_button: objc.Object = undefined;

pub fn init() void {
    const NSStatusBar = objc.getClass("NSStatusBar") orelse return;
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const BWDelegate = objc.getClass("BWStatusBarDelegate") orelse return;

    const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
    // NSVariableStatusItemLength = -1
    const item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)});
    g_button = item.msgSend(objc.Object, "button", .{});

    const delegate = BWDelegate.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    const menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    const empty = nsString("");

    // Retile
    const retile_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        nsString("Retile"), objc.sel("retile:"), empty,
    });
    retile_item.msgSend(void, "setTarget:", .{delegate});
    menu.msgSend(void, "addItem:", .{retile_item});

    // Separator
    menu.msgSend(void, "addItem:", .{
        NSMenuItem.msgSend(objc.Object, "separatorItem", .{}),
    });

    // Quit
    const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        nsString("Quit bobrwm"), objc.sel("quit:"), empty,
    });
    quit_item.msgSend(void, "setTarget:", .{delegate});
    menu.msgSend(void, "addItem:", .{quit_item});

    item.msgSend(void, "setMenu:", .{menu});

    log.info("status bar created", .{});
}

/// Update the status bar title to reflect the active workspace.
pub fn setTitle(name: []const u8, id: u8) void {
    var buf: [64]u8 = undefined;
    const title: []const u8 = if (name.len > 0) name else
        std.fmt.bufPrint(&buf, "{d}", .{id}) catch return;

    // Null-terminate for stringWithUTF8String:
    var z: [65]u8 = undefined;
    const n = @min(title.len, z.len - 1);
    @memcpy(z[0..n], title[0..n]);
    z[n] = 0;

    g_button.msgSend(void, "setTitle:", .{
        nsString(@ptrCast(z[0..n :0])),
    });
}

fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse
        @panic("NSString class not found");
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}
