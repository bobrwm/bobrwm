//! macOS status bar (menu bar icon).
//!
//! The status item and its menu live in the Swift UI library under
//! packages/bobrwm-ui. This module owns the Zig half of the C ABI declared in
//! packages/bobrwm-ui/include/bobrwm_ui.h and the conversion from workspace
//! state into rows. The ABI structs below mirror that header; changing one
//! means changing both.

const std = @import("std");
const objc = @import("objc");

const main = @import("main.zig");
const workspace_mod = @import("workspace.zig");

const log = std.log.scoped(.statusbar);

const MenuBarCallbacks = extern struct {
    retile: *const fn () callconv(.c) void,
    open_config: *const fn () callconv(.c) void,
    previous_workspace: *const fn () callconv(.c) void,
    next_workspace: *const fn () callconv(.c) void,
    switch_to_workspace: *const fn (u8) callconv(.c) void,
    quit: *const fn () callconv(.c) void,
};

const WorkspaceRow = extern struct {
    name: ?[*:0]const u8,
    window_count: u32,
    id: u8,
    is_focused: bool,
};

extern fn bw_menubar_init(callbacks: MenuBarCallbacks) void;
extern fn bw_menubar_deinit() void;
extern fn bw_menubar_set_workspaces(rows: ?[*]const WorkspaceRow, count: usize) void;
extern fn bw_menubar_set_active_workspaces(workspace_ids: ?[*]const u8, count: usize) void;
extern fn bw_menubar_set_title(title: [*:0]const u8) void;

/// Workspace names are borrowed by the UI only for the duration of the call,
/// but the row array needs NUL-terminated copies to hand across, and this
/// module has no allocator.
const max_name_bytes = 64;
var g_name_storage: [workspace_mod.max_workspaces][max_name_bytes]u8 = undefined;

var g_initialized = false;

pub fn init(workspaces: []const workspace_mod.Workspace) void {
    std.debug.assert(!g_initialized);
    std.debug.assert(workspaces.len > 0 and workspaces.len <= workspace_mod.max_workspaces);

    bw_menubar_init(.{
        .retile = onRetile,
        .open_config = onOpenConfig,
        .previous_workspace = onPreviousWorkspace,
        .next_workspace = onNextWorkspace,
        .switch_to_workspace = onSwitchToWorkspace,
        .quit = onQuit,
    });
    g_initialized = true;

    updateWorkspaceMenu(workspaces);
    log.info("status bar created", .{});
}

pub fn deinit() void {
    if (!g_initialized) return;

    bw_menubar_deinit();
    g_initialized = false;
}

/// Rebuild the workspace rows. Call when the workspace set changes, not when
/// focus moves; `setTitleMulti` carries focus.
pub fn updateWorkspaceMenu(workspaces: []const workspace_mod.Workspace) void {
    if (!g_initialized) return;
    std.debug.assert(workspaces.len > 0 and workspaces.len <= workspace_mod.max_workspaces);

    var rows: [workspace_mod.max_workspaces]WorkspaceRow = undefined;
    for (workspaces, 0..) |workspace, index| {
        std.debug.assert(workspace.id > 0 and workspace.id <= workspace_mod.max_workspaces);

        const storage = &g_name_storage[index];
        const length = @min(workspace.name.len, storage.len - 1);
        @memcpy(storage[0..length], workspace.name[0..length]);
        storage[length] = 0;

        rows[index] = .{
            .name = @ptrCast(storage),
            .window_count = std.math.lossyCast(u32, workspace.windows.items.len),
            .id = workspace.id,
            .is_focused = false,
        };
    }

    bw_menubar_set_workspaces(&rows, workspaces.len);
}

pub const DisplayWorkspace = struct {
    name: []const u8,
    id: u8,
    focused: bool,
};

/// Update the status bar title to show all active workspaces across displays.
/// Format: "ws1 | ws2 | ..." with the focused one marked with [brackets].
pub fn setTitleMulti(workspaces: []const DisplayWorkspace) void {
    if (!g_initialized) return;
    std.debug.assert(workspaces.len <= workspace_mod.max_displays);

    var active_ids: [workspace_mod.max_displays]u8 = undefined;
    for (workspaces, 0..) |workspace, index| {
        active_ids[index] = workspace.id;
    }
    bw_menubar_set_active_workspaces(&active_ids, workspaces.len);

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

    bw_menubar_set_title(@ptrCast(buf[0..pos :0]));
}

/// Update the status bar title to reflect the active workspace.
pub fn setTitle(name: []const u8, id: u8) void {
    setTitleMulti(&.{.{ .name = name, .id = id, .focused = true }});
}

/// Temporarily replace the workspace title with a caller-managed status
/// message. The UI copies the string, so the input need not outlive the call.
pub fn setMessage(message: [*:0]const u8) void {
    if (!g_initialized) return;
    bw_menubar_set_title(message);
}

// Menu callbacks. These run on the main thread while the menu dismisses, so
// they can mutate Bobrwm state directly.

fn onRetile() callconv(.c) void {
    main.bw_retile();
}

fn onOpenConfig() callconv(.c) void {
    main.bw_status_bar_action(.open_config);
}

fn onPreviousWorkspace() callconv(.c) void {
    main.bw_status_bar_action(.previous_workspace);
}

fn onNextWorkspace() callconv(.c) void {
    main.bw_status_bar_action(.next_workspace);
}

fn onSwitchToWorkspace(workspace_id: u8) callconv(.c) void {
    if (workspace_id == 0 or workspace_id > workspace_mod.max_workspaces) return;
    main.bw_status_bar_action(.{ .workspace = workspace_id });
}

/// Shutdown stays on the Zig side so window restoration keeps running before
/// AppKit tears the process down; the UI library is presentation only.
fn onQuit() callconv(.c) void {
    main.bw_will_quit();

    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "terminate:", .{@as(objc.Object, .{ .value = null })});
}
