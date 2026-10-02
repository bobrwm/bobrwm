//! macOS status bar (menu bar icon).
//!
//! The status item and its menu live in the Swift application in macos/.
//! This module owns the Zig half of the C ABI declared in
//! macos/include/bobrwm_ui.h and the conversion from workspace
//! and keybind state into rows. The ABI structs below mirror that header;
//! changing one means changing both.

const std = @import("std");

const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const workspace_mod = @import("workspace.zig");

const log = std.log.scoped(.statusbar);

pub const Settings = extern struct {
    layout: u8,
    bsp_split: u8,
    bsp_insert_point: u8,
    bsp_split_ratio: f64,
    new_window_split: u8,
    dimming_enabled: bool,
    dimming_level: f32,
    inner_gap: u16,
    outer_gap_left: u16,
    outer_gap_right: u16,
    outer_gap_top: u16,
    outer_gap_bottom: u16,
    animation_enabled: bool,
    animation_duration_ms: u64,
    animation_easing: u8,
    start_at_login: bool,
};

/// Application-owned actions invoked by the Swift menu bar on the main thread.
pub const Callbacks = extern struct {
    retile: *const fn () callconv(.c) void,
    open_config: *const fn () callconv(.c) void,
    reload_config: *const fn () callconv(.c) bool,
    set_settings: *const fn (*const Settings) callconv(.c) bool,
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
    process_ids: ?[*]const i32,
    process_count: usize,
    window_count: u32,
    id: u8,
    is_active: bool,
    is_focused: bool,
    display_order: u8,
};

/// Visible workspace and its display origin in global screen coordinates.
pub const ActiveWorkspace = struct {
    workspace_id: u8,
    display_id: u32,
    x: f64,
    y: f64,
};

/// Managed application processes for one logical workspace.
pub const WorkspaceProcesses = struct {
    workspace_id: u8,
    process_ids: []const i32,
};

const ActionShortcuts = extern struct {
    previous_workspace: ?[*:0]const u8,
    next_workspace: ?[*:0]const u8,
};

extern fn bw_menubar_init(callbacks: Callbacks, config_path: ?[*:0]const u8) void;
extern fn bw_menubar_deinit() void;
extern fn bw_menubar_set_workspaces(
    workspaces: ?[*]const Workspace,
    count: usize,
    shortcuts: ActionShortcuts,
) void;
extern fn bw_menubar_set_state(states: ?[*]const WorkspaceState, count: usize) void;
extern fn bw_menubar_set_settings(settings: Settings) void;
extern fn bw_menubar_set_message(message: [*:0]const u8) void;
extern fn bw_menubar_set_config_status(success: bool, message: [*:0]const u8) void;

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

/// Create the Swift menu bar and publish the initial workspace identity rows.
pub fn init(
    workspace_count: u8,
    config: *const config_mod.Config,
    config_path: ?[*:0]const u8,
    callbacks: Callbacks,
) void {
    std.debug.assert(!g_initialized);
    std.debug.assert(workspace_count > 0 and workspace_count <= workspace_mod.max_workspaces);

    bw_menubar_init(callbacks, config_path);
    g_initialized = true;

    updateWorkspaceMenu(workspace_count, config);
    updateSettings(config);
    log.info("status bar created", .{});
}

/// Publish the editable configuration snapshot to the native app.
pub fn updateSettings(config: *const config_mod.Config) void {
    if (!g_initialized) return;
    bw_menubar_set_settings(.{
        .layout = @intFromEnum(config.layout),
        .bsp_split = @intFromEnum(config.bsp_split),
        .bsp_insert_point = @intFromEnum(config.bsp_insert_point),
        .bsp_split_ratio = config.bsp_split_ratio,
        .new_window_split = @intFromEnum(config.new_window_split),
        .dimming_enabled = config.dimmed_inactive.enabled,
        .dimming_level = config.dimmed_inactive.level,
        .inner_gap = config.gaps.inner,
        .outer_gap_left = config.gaps.outer.left,
        .outer_gap_right = config.gaps.outer.right,
        .outer_gap_top = config.gaps.outer.top,
        .outer_gap_bottom = config.gaps.outer.bottom,
        .animation_enabled = config.animation.enabled,
        .animation_duration_ms = config.animation.duration_ms,
        .animation_easing = @intFromEnum(config.animation.easing),
        .start_at_login = config.start_at_login,
    });
}

pub fn deinit() void {
    if (!g_initialized) return;

    bw_menubar_deinit();
    g_initialized = false;
}

/// Rebuild the workspace rows. Call when names or keybinds change, not when
/// focus moves; `updateState` carries everything that moves.
pub fn updateWorkspaceMenu(
    workspace_count: u8,
    config: *const config_mod.Config,
) void {
    if (!g_initialized) return;
    std.debug.assert(workspace_count > 0 and workspace_count <= workspace_mod.max_workspaces);

    var rows: [workspace_mod.max_workspaces]Workspace = undefined;
    for (0..workspace_count) |index| {
        const workspace_id: u8 = @intCast(index + 1);
        const name = if (index < config.workspace_names.len) config.workspace_names[index] else "";

        const name_storage = &g_name_storage[index];
        _ = encodeWorkspaceName(name, name_storage);

        const keybind = config.findKeybind(.focus_workspace, workspace_id);
        rows[index] = .{
            .name = @ptrCast(name_storage),
            .shortcut = shortcutPtr(keybind, &g_shortcut_storage[index]),
            .id = workspace_id,
        };
    }

    bw_menubar_set_workspaces(&rows, workspace_count, .{
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

/// Publish reducer-derived logical workspace state.
pub fn updateState(
    summaries: []const state_mod.WorkspaceSummary,
    active_workspaces: []const ActiveWorkspace,
    workspace_processes: []const WorkspaceProcesses,
) void {
    if (!g_initialized) return;
    std.debug.assert(summaries.len > 0 and summaries.len <= workspace_mod.max_workspaces);
    std.debug.assert(active_workspaces.len <= workspace_mod.max_displays);
    std.debug.assert(workspace_processes.len == summaries.len);

    var ordered: [workspace_mod.max_displays]ActiveWorkspace = undefined;
    @memcpy(ordered[0..active_workspaces.len], active_workspaces);
    sortActiveWorkspaces(ordered[0..active_workspaces.len]);

    var states: [workspace_mod.max_workspaces]WorkspaceState = undefined;
    for (summaries, 0..) |summary, index| {
        const processes = workspace_processes[index];
        std.debug.assert(processes.workspace_id == summary.workspace_id);
        var display_order: u8 = std.math.maxInt(u8);
        for (ordered[0..active_workspaces.len], 0..) |active, order| {
            if (active.workspace_id != summary.workspace_id) continue;
            display_order = @intCast(order);
            break;
        }
        states[index] = .{
            .process_ids = if (processes.process_ids.len == 0) null else processes.process_ids.ptr,
            .process_count = processes.process_ids.len,
            .window_count = summary.window_count,
            .id = summary.workspace_id,
            .is_active = summary.is_active,
            .is_focused = summary.is_focused,
            .display_order = display_order,
        };
    }

    bw_menubar_set_state(&states, summaries.len);
}

/// Temporarily replace the menu bar chips with a status message. The UI copies
/// the string, so the input need not outlive the call.
pub fn setMessage(message: [*:0]const u8) void {
    if (!g_initialized) return;
    bw_menubar_set_message(message);
}

/// Publish the last configuration reload outcome for Settings.
pub fn setConfigStatus(success: bool, message: [*:0]const u8) void {
    if (!g_initialized) return;
    bw_menubar_set_config_status(success, message);
}

/// Adapt a keybind to the sentinel pointer the ABI expects. Null means
/// unbound, which the UI renders as no hint at all.
fn shortcutPtr(keybind: ?config_mod.Keybind, storage: []u8) ?[*:0]const u8 {
    const bind = keybind orelse return null;
    const rendered = bind.displayForm(storage) orelse return null;
    return rendered.ptr;
}

fn sortActiveWorkspaces(active_workspaces: []ActiveWorkspace) void {
    std.mem.sortUnstable(ActiveWorkspace, active_workspaces, {}, struct {
        fn lessThan(_: void, lhs: ActiveWorkspace, rhs: ActiveWorkspace) bool {
            if (lhs.x != rhs.x) return lhs.x < rhs.x;
            if (lhs.y != rhs.y) return lhs.y < rhs.y;
            return lhs.display_id < rhs.display_id;
        }
    }.lessThan);
}

/// Copy a workspace name into the sentinel-terminated representation consumed
/// by the menu bar library.
fn encodeWorkspaceName(name: []const u8, storage: []u8) [:0]const u8 {
    std.debug.assert(storage.len > 0);

    var length = @min(name.len, storage.len - 1);
    // Cutting mid-sequence hands the UI invalid UTF-8, which NSString renders
    // as a replacement glyph, so drop the whole truncated codepoint.
    while (length > 0 and length < name.len and name[length] & 0xC0 == 0x80) length -= 1;

    @memcpy(storage[0..length], name[0..length]);
    storage[length] = 0;
    return storage[0..length :0];
}

test "workspace ABI name truncation preserves valid UTF-8" {
    var name: [66]u8 = undefined;
    @memset(name[0..62], 'a');
    @memcpy(name[62..], "😀");

    var storage: [max_name_bytes]u8 = undefined;
    const encoded = encodeWorkspaceName(&name, &storage);

    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded));
    try std.testing.expectEqual(@as(usize, 62), encoded.len);
    try std.testing.expectEqualSlices(u8, name[0..62], encoded);
}

test "status chips follow display geometry rather than workspace or enumeration order" {
    var active = [_]ActiveWorkspace{
        .{ .workspace_id = 1, .display_id = 2, .x = 0, .y = 0 },
        .{ .workspace_id = 7, .display_id = 5, .x = -1920, .y = 0 },
        .{ .workspace_id = 4, .display_id = 9, .x = 0, .y = -1080 },
    };
    sortActiveWorkspaces(&active);
    try std.testing.expectEqual(@as(u8, 7), active[0].workspace_id);
    try std.testing.expectEqual(@as(u8, 4), active[1].workspace_id);
    try std.testing.expectEqual(@as(u8, 1), active[2].workspace_id);

    active[0].x = 1920;
    sortActiveWorkspaces(&active);
    try std.testing.expectEqual(@as(u8, 4), active[0].workspace_id);
    try std.testing.expectEqual(@as(u8, 1), active[1].workspace_id);
    try std.testing.expectEqual(@as(u8, 7), active[2].workspace_id);
}
