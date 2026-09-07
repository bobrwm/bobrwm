//! macOS status bar (menu bar icon).
//!
//! The status item and its menu live in the Swift UI library under
//! packages/bobrwm-ui. This module owns the Zig half of the C ABI declared in
//! packages/bobrwm-ui/include/bobrwm_ui.h and the conversion from workspace
//! and keybind state into rows. The ABI structs below mirror that header;
//! changing one means changing both.

const std = @import("std");

const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const workspace_mod = @import("workspace.zig");

const log = std.log.scoped(.statusbar);

/// Application-owned actions invoked by the Swift menu bar on the main thread.
pub const Callbacks = extern struct {
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

extern fn bw_menubar_init(callbacks: Callbacks) void;
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

/// Create the Swift menu bar and publish the initial workspace identity rows.
pub fn init(
    workspace_count: u8,
    config: *const config_mod.Config,
    callbacks: Callbacks,
) void {
    std.debug.assert(!g_initialized);
    std.debug.assert(workspace_count > 0 and workspace_count <= workspace_mod.max_workspaces);

    bw_menubar_init(callbacks);
    g_initialized = true;

    updateWorkspaceMenu(workspace_count, config);
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
) void {
    if (!g_initialized) return;
    std.debug.assert(summaries.len > 0 and summaries.len <= workspace_mod.max_workspaces);

    var states: [workspace_mod.max_workspaces]WorkspaceState = undefined;
    for (summaries, 0..) |summary, index| {
        states[index] = .{
            .window_count = summary.window_count,
            .id = summary.workspace_id,
            .is_active = summary.is_active,
            .is_focused = summary.is_focused,
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

/// Adapt a keybind to the sentinel pointer the ABI expects. Null means
/// unbound, which the UI renders as no hint at all.
fn shortcutPtr(keybind: ?config_mod.Keybind, storage: []u8) ?[*:0]const u8 {
    const bind = keybind orelse return null;
    const rendered = bind.displayForm(storage) orelse return null;
    return rendered.ptr;
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
