//! macOS status bar (menu bar icon) via zig-objc.
//!
//! Displays active workspaces and provides workspace, configuration, Retile,
//! and Quit actions through BWStatusBarDelegate in objc_classes.zig.

const std = @import("std");
const objc = @import("objc");

const workspace_mod = @import("workspace.zig");

const log = std.log.scoped(.statusbar);

var g_status_item: ?objc.Object = null;
var g_button: ?objc.Object = null;
var g_delegate: ?objc.Object = null;
var g_workspace_menu: ?objc.Object = null;

pub fn init(workspaces: []const workspace_mod.Workspace) void {
    std.debug.assert(g_status_item == null);
    std.debug.assert(workspaces.len > 0 and workspaces.len <= workspace_mod.max_workspaces);

    const NSStatusBar = objc.getClass("NSStatusBar") orelse return;
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const BWDelegate = objc.getClass("BWStatusBarDelegate") orelse return;

    const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
    // NSVariableStatusItemLength = -1
    const item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)});
    // NSStatusBar does not retain status items; this module owns it until deinit.
    g_status_item = item.retain();
    g_button = item.msgSend(objc.Object, "button", .{});

    const delegate = BWDelegate.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    g_delegate = delegate;

    const menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer menu.msgSend(void, "release", .{});

    addActionItem(menu, NSMenuItem, delegate, "Retile", "retile:");
    addActionItem(menu, NSMenuItem, delegate, "Open Config File", "openConfigFile:");
    addSeparator(menu, NSMenuItem);
    addActionItem(menu, NSMenuItem, delegate, "Previous Workspace", "previousWorkspace:");
    addActionItem(menu, NSMenuItem, delegate, "Next Workspace", "nextWorkspace:");

    const workspaces_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        nsString("Workspaces"), @as(?*anyopaque, null), nsString(""),
    });
    defer workspaces_item.msgSend(void, "release", .{});

    const workspace_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:", .{nsString("Workspaces")});
    defer workspace_menu.msgSend(void, "release", .{});
    populateWorkspaceMenu(workspace_menu, NSMenuItem, delegate, workspaces);

    workspaces_item.msgSend(void, "setSubmenu:", .{workspace_menu});
    menu.msgSend(void, "addItem:", .{workspaces_item});
    g_workspace_menu = workspace_menu;

    addSeparator(menu, NSMenuItem);
    addActionItem(menu, NSMenuItem, delegate, "Quit bobrwm", "quit:");

    item.msgSend(void, "setMenu:", .{menu});

    log.info("status bar created", .{});
}

pub fn deinit() void {
    g_workspace_menu = null;
    g_button = null;

    if (g_status_item) |item| {
        if (objc.getClass("NSStatusBar")) |NSStatusBar| {
            const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
            bar.msgSend(void, "removeStatusItem:", .{item});
        }
        item.release();
        g_status_item = null;
    }

    if (g_delegate) |delegate| {
        delegate.msgSend(void, "release", .{});
        g_delegate = null;
    }
}

/// Refresh workspace labels after a configuration reload.
pub fn updateWorkspaceMenu(workspaces: []const workspace_mod.Workspace) void {
    std.debug.assert(workspaces.len > 0 and workspaces.len <= workspace_mod.max_workspaces);
    const menu = g_workspace_menu orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const delegate = g_delegate orelse return;

    menu.msgSend(void, "removeAllItems", .{});
    populateWorkspaceMenu(menu, NSMenuItem, delegate, workspaces);
}

fn addActionItem(
    menu: objc.Object,
    NSMenuItem: objc.Class,
    delegate: objc.Object,
    title: [*:0]const u8,
    action: [:0]const u8,
) void {
    const item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        nsString(title), objc.sel(action), nsString(""),
    });
    defer item.msgSend(void, "release", .{});

    item.msgSend(void, "setTarget:", .{delegate});
    menu.msgSend(void, "addItem:", .{item});
}

fn addSeparator(menu: objc.Object, NSMenuItem: objc.Class) void {
    menu.msgSend(void, "addItem:", .{
        NSMenuItem.msgSend(objc.Object, "separatorItem", .{}),
    });
}

fn populateWorkspaceMenu(
    menu: objc.Object,
    NSMenuItem: objc.Class,
    delegate: objc.Object,
    workspaces: []const workspace_mod.Workspace,
) void {
    for (workspaces) |workspace| {
        std.debug.assert(workspace.id > 0 and workspace.id <= workspace_mod.max_workspaces);

        var label_buffer: [128]u8 = undefined;
        const label = if (workspace.name.len > 0)
            std.fmt.bufPrintZ(&label_buffer, "Workspace {d}: {s}", .{ workspace.id, workspace.name }) catch
                std.fmt.bufPrintZ(&label_buffer, "Workspace {d}", .{workspace.id}) catch unreachable
        else
            std.fmt.bufPrintZ(&label_buffer, "Workspace {d}", .{workspace.id}) catch unreachable;

        const item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            nsString(label.ptr), objc.sel("switchToWorkspace:"), nsString(""),
        });
        defer item.msgSend(void, "release", .{});

        item.msgSend(void, "setTarget:", .{delegate});
        item.msgSend(void, "setTag:", .{@as(i64, workspace.id)});
        menu.msgSend(void, "addItem:", .{item});
    }
}

pub const DisplayWorkspace = struct {
    name: []const u8,
    id: u8,
    focused: bool,
};

/// Update the status bar title to show all active workspaces across displays.
/// Format: "ws1 | ws2 | ..." with the focused one marked with [brackets].
pub fn setTitleMulti(workspaces: []const DisplayWorkspace) void {
    const button = g_button orelse return;
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

    button.msgSend(void, "setTitle:", .{
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
    const button = g_button orelse return;
    button.msgSend(void, "setTitle:", .{nsString(message)});
}

fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse
        @panic("NSString class not found");
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}
