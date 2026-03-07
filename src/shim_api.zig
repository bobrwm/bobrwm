//! Zig-side shim bindings and shared ABI types/constants.
//!
//! This keeps C/ObjC headers focused on Objective-C selector callbacks while
//! Zig modules share a single typed interface for event constants and exports.

const event_mod = @import("event.zig");

pub const BW_EVENT_WINDOW_CREATED: u8 = @intFromEnum(event_mod.EventKind.window_created);
pub const BW_EVENT_WINDOW_DESTROYED: u8 = @intFromEnum(event_mod.EventKind.window_destroyed);
pub const BW_EVENT_WINDOW_FOCUSED: u8 = @intFromEnum(event_mod.EventKind.window_focused);
pub const BW_EVENT_WINDOW_MOVED: u8 = @intFromEnum(event_mod.EventKind.window_moved);
pub const BW_EVENT_WINDOW_RESIZED: u8 = @intFromEnum(event_mod.EventKind.window_resized);
pub const BW_EVENT_WINDOW_MINIMIZED: u8 = @intFromEnum(event_mod.EventKind.window_minimized);
pub const BW_EVENT_WINDOW_DEMINIMIZED: u8 = @intFromEnum(event_mod.EventKind.window_deminimized);
pub const BW_EVENT_APP_LAUNCHED: u8 = @intFromEnum(event_mod.EventKind.app_launched);
pub const BW_EVENT_APP_TERMINATED: u8 = @intFromEnum(event_mod.EventKind.app_terminated);
pub const BW_EVENT_SPACE_CHANGED: u8 = @intFromEnum(event_mod.EventKind.space_changed);
pub const BW_EVENT_DISPLAY_CHANGED: u8 = @intFromEnum(event_mod.EventKind.display_changed);
pub const BW_EVENT_FOCUSED_WINDOW_CHANGED: u8 = @intFromEnum(event_mod.EventKind.focused_window_changed);
pub const BW_EVENT_MOUSE_DOWN: u8 = @intFromEnum(event_mod.EventKind.mouse_down);
pub const BW_EVENT_MOUSE_UP: u8 = @intFromEnum(event_mod.EventKind.mouse_up);
pub const BW_EVENT_ROLE_POLL_TICK: u8 = @intFromEnum(event_mod.EventKind.role_poll_tick);

pub const BW_HK_FOCUS_WORKSPACE: u8 = @intFromEnum(event_mod.EventKind.hk_focus_workspace);
pub const BW_HK_MOVE_TO_WORKSPACE: u8 = @intFromEnum(event_mod.EventKind.hk_move_to_workspace);
pub const BW_HK_FOCUS_LEFT: u8 = @intFromEnum(event_mod.EventKind.hk_focus_left);
pub const BW_HK_FOCUS_RIGHT: u8 = @intFromEnum(event_mod.EventKind.hk_focus_right);
pub const BW_HK_FOCUS_UP: u8 = @intFromEnum(event_mod.EventKind.hk_focus_up);
pub const BW_HK_FOCUS_DOWN: u8 = @intFromEnum(event_mod.EventKind.hk_focus_down);
pub const BW_HK_TOGGLE_SPLIT: u8 = @intFromEnum(event_mod.EventKind.hk_toggle_split);
pub const BW_HK_TOGGLE_FULLSCREEN: u8 = @intFromEnum(event_mod.EventKind.hk_toggle_fullscreen);
pub const BW_HK_TOGGLE_FLOAT: u8 = @intFromEnum(event_mod.EventKind.hk_toggle_float);

pub const BW_MOD_ALT: u8 = 1 << 0;
pub const BW_MOD_SHIFT: u8 = 1 << 1;
pub const BW_MOD_CMD: u8 = 1 << 2;
pub const BW_MOD_CTRL: u8 = 1 << 3;

pub const BW_MANAGE_REJECT: u8 = 0;
pub const BW_MANAGE_READY: u8 = 1;
pub const BW_MANAGE_PENDING: u8 = 2;

pub const bw_keybind = extern struct {
    keycode: u16,
    mods: u8,
    action: u8,
    arg: u32,
};

pub const bw_window_info = extern struct {
    wid: u32,
    pid: i32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const bw_frame = extern struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub extern fn bw_emit_event(kind: u8, pid: i32, wid: u32) void;

pub extern fn bw_drain_events() void;
pub extern fn bw_handle_ipc_client(server_fd: i32) void;
pub extern fn bw_will_quit() void;
pub extern fn bw_retile() void;
pub extern fn bw_workspace_app_launched(pid: i32) void;
pub extern fn bw_workspace_app_terminated(pid: i32) void;
pub extern fn bw_workspace_active_app_changed(pid: i32) void;
pub extern fn bw_workspace_space_changed() void;
pub extern fn bw_workspace_display_changed() void;
pub extern fn bw_hotkey_mouse_down() void;
pub extern fn bw_hotkey_mouse_up() void;
pub extern fn bw_hotkey_handle_keydown(keycode: u16, mods: u8) bool;

pub extern fn bw_ax_is_trusted() bool;
pub extern fn bw_signal_waker() void;
pub extern fn bw_discover_windows(out: ?[*]bw_window_info, max_count: u32) u32;
pub extern fn bw_get_display_frame() bw_frame;
pub extern fn bw_ax_set_window_frame(
    pid: i32,
    wid: u32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) bool;
pub extern fn bw_ax_focus_window(pid: i32, wid: u32) bool;
pub extern fn bw_ax_get_focused_window(pid: i32) u32;
pub extern fn bw_should_manage_window(pid: i32, wid: u32) bool;
pub extern fn bw_window_manage_state(pid: i32, wid: u32) u8;
pub extern fn bw_set_role_polling(enabled: bool) void;
pub extern fn bw_is_window_on_screen(wid: u32) bool;
pub extern fn bw_get_app_window_ids(pid: i32, out: ?[*]u32, max_count: u32) u32;
pub extern fn bw_set_keybinds(binds: ?[*]const bw_keybind, count: u32) void;
pub extern fn bw_get_app_bundle_id(pid: i32, out: ?[*]u8, max_len: u32) u32;
