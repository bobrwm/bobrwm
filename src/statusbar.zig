//! macOS status bar (menu bar icon) via zig-objc.
//!
//! Displays the active workspace name/index and provides a menu
//! with Retile and Quit actions (handled by BWStatusBarDelegate in objc_classes.zig).

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

pub const DisplayWorkspace = struct {
    name: []const u8,
    id: u8,
    focused: bool,
};

/// Update the status bar title to show all active workspaces across displays.
/// Format: "ws1 | ws2 | ..." with the focused one marked with [brackets].
pub fn setTitleMulti(workspaces: []const DisplayWorkspace) void {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    for (workspaces, 0..) |ws, i| {
        if (i > 0) {
            if (pos + 3 <= buf.len) {
                @memcpy(buf[pos..][0..3], " | ");
                pos += 3;
            }
        }

        // Format numeric ID into a separate buffer to avoid aliasing
        // with `buf` when brackets are inserted for focused workspaces.
        var id_buf: [4]u8 = undefined;
        const label = if (ws.name.len > 0) ws.name else blk: {
            const s = std.fmt.bufPrint(&id_buf, "{d}", .{ws.id}) catch break :blk "";
            break :blk s;
        };

        if (ws.focused) {
            if (pos + 1 <= buf.len) {
                buf[pos] = '[';
                pos += 1;
            }
        }

        const n = @min(label.len, buf.len - pos);
        @memcpy(buf[pos..][0..n], label[0..n]);
        pos += n;

        if (ws.focused) {
            if (pos + 1 <= buf.len) {
                buf[pos] = ']';
                pos += 1;
            }
        }
    }

    if (pos == 0) return;
    if (pos >= buf.len) pos = buf.len - 1;
    buf[pos] = 0;

    g_button.msgSend(void, "setTitle:", .{
        nsString(@ptrCast(buf[0..pos :0])),
    });
}

/// Update the status bar title to reflect the active workspace.
pub fn setTitle(name: []const u8, id: u8) void {
    setTitleMulti(&.{.{ .name = name, .id = id, .focused = true }});
}

/// Temporarily replace the workspace title with a caller-managed status
/// message. AppKit copies the NSString, so the input need not outlive the call.
pub fn setMessage(message: [*:0]const u8) void {
    g_button.msgSend(void, "setTitle:", .{nsString(message)});
}

fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse
        @panic("NSString class not found");
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}
