/// Domain events that flow through the event loop.
/// The ObjC shim serializes these as tagged bytes over the notification pipe.
pub const EventKind = enum(u8) {
    window_created = 1,
    window_destroyed = 2,
    window_focused = 3,
    window_moved = 4,
    window_resized = 5,
    window_minimized = 6,
    window_deminimized = 7,
    app_launched = 8,
    app_terminated = 9,
    space_changed = 10,
    display_changed = 11,
    focused_window_changed = 12,

    hk_focus_workspace = 20,
    hk_move_to_workspace = 21,
    hk_focus_left = 22,
    hk_focus_right = 23,
    hk_focus_up = 24,
    hk_focus_down = 25,
    hk_toggle_split = 26,
};

pub const Event = extern struct {
    kind: EventKind,
    pid: i32,
    wid: u32,
};
