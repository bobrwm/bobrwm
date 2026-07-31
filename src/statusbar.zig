//! macOS status bar (menu bar icon).
//!
//! The status item and its menu live in the Swift UI library under
//! packages/bobrwm-ui. This module owns the Zig half of the C ABI declared in
//! packages/bobrwm-ui/include/bobrwm_ui.h and the conversion from workspace
//! and keybind state into rows. The ABI structs below mirror that header;
//! changing one means changing both.

const std = @import("std");
const objc = @import("objc");

const config_mod = @import("config.zig");
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

const Workspace = extern struct {
    name: ?[*:0]const u8,
    shortcut: ?[*:0]const u8,
    id: u8,
};

const WorkspaceState = extern struct {
    window_count: u32,
    id: u8,
    is_active: bool,
    is_focused: bool,
};

const ActionShortcuts = extern struct {
    previous_workspace: ?[*:0]const u8,
    next_workspace: ?[*:0]const u8,
};

extern fn bw_menubar_init(callbacks: MenuBarCallbacks) void;
extern fn bw_menubar_deinit() void;
extern fn bw_menubar_set_workspaces(
    workspaces: ?[*]const Workspace,
    count: usize,
    shortcuts: ActionShortcuts,
) void;
extern fn bw_menubar_set_state(states: ?[*]const WorkspaceState, count: usize) void;
extern fn bw_menubar_set_message(message: [*:0]const u8) void;

/// Strings handed across the ABI are borrowed for the duration of the call,
/// but a whole row array is passed at once, so every name and shortcut in it
/// has to be alive simultaneously. This module has no allocator, and both are
/// bounded, so they live in static storage.
const max_name_bytes = 64;
/// Four modifier glyphs at 3 bytes each, plus a key glyph, plus the sentinel.
const max_shortcut_bytes = 24;

var g_name_storage: [workspace_mod.max_workspaces][max_name_bytes]u8 = undefined;
var g_shortcut_storage: [workspace_mod.max_workspaces][max_shortcut_bytes]u8 = undefined;
var g_nav_shortcut_storage: [2][max_shortcut_bytes]u8 = undefined;

var g_initialized = false;

pub fn init(
    workspaces: []const workspace_mod.Workspace,
    config: *const config_mod.Config,
) void {
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

    updateWorkspaceMenu(workspaces, config);
    log.info("status bar created", .{});
}

pub fn deinit() void {
    if (!g_initialized) return;

    bw_menubar_deinit();
    g_initialized = false;
}

/// Rebuild the workspace rows. Call when names or keybinds change, not when
/// focus moves; `updateState` carries everything that moves.
pub fn updateWorkspaceMenu(
    workspaces: []const workspace_mod.Workspace,
    config: *const config_mod.Config,
) void {
    if (!g_initialized) return;
    std.debug.assert(workspaces.len > 0 and workspaces.len <= workspace_mod.max_workspaces);

    var rows: [workspace_mod.max_workspaces]Workspace = undefined;
    for (workspaces, 0..) |workspace, index| {
        std.debug.assert(workspace.id > 0 and workspace.id <= workspace_mod.max_workspaces);

        const name_storage = &g_name_storage[index];
        const length = @min(workspace.name.len, name_storage.len - 1);
        @memcpy(name_storage[0..length], workspace.name[0..length]);
        name_storage[length] = 0;

        const keybind = config.findKeybind(.focus_workspace, workspace.id);
        rows[index] = .{
            .name = @ptrCast(name_storage),
            .shortcut = shortcutPtr(keybind, &g_shortcut_storage[index]),
            .id = workspace.id,
        };
    }

    bw_menubar_set_workspaces(&rows, workspaces.len, .{
        .previous_workspace = shortcutPtr(
            config.findKeybind(.focus_previous_workspace, 0),
            &g_nav_shortcut_storage[0],
        ),
        .next_workspace = shortcutPtr(
            config.findKeybind(.focus_next_workspace, 0),
            &g_nav_shortcut_storage[1],
        ),
    });
}

/// Push window counts and which workspaces are visible where.
pub fn updateState(
    workspaces: []const workspace_mod.Workspace,
    active_ids: []const u8,
    focused_id: u8,
) void {
    if (!g_initialized) return;
    std.debug.assert(workspaces.len <= workspace_mod.max_workspaces);
    std.debug.assert(active_ids.len <= workspace_mod.max_displays);

    var states: [workspace_mod.max_workspaces]WorkspaceState = undefined;
    for (workspaces, 0..) |workspace, index| {
        states[index] = .{
            .window_count = std.math.lossyCast(u32, workspace.windows.items.len),
            .id = workspace.id,
            .is_active = std.mem.indexOfScalar(u8, active_ids, workspace.id) != null,
            .is_focused = workspace.id == focused_id,
        };
    }

    bw_menubar_set_state(&states, workspaces.len);
}

/// Temporarily replace the menu bar chips with a status message. The UI copies
/// the string, so the input need not outlive the call.
pub fn setMessage(message: [*:0]const u8) void {
    if (!g_initialized) return;
    bw_menubar_set_message(message);
}

/// Adapt a keybind to the sentinel pointer the ABI expects. Null means
/// unbound, which the UI renders as no hint at all.
fn shortcutPtr(keybind: ?config_mod.Keybind, storage: []u8) ?[*:0]const u8 {
    const bind = keybind orelse return null;
    const rendered = bind.displayForm(storage) orelse return null;
    return rendered.ptr;
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
