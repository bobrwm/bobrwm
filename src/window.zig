const std = @import("std");

pub const WindowId = u32;

pub const Window = struct {
    wid: WindowId,
    pid: i32,
    title: ?[]const u8,
    frame: Frame,
    is_minimized: bool,
    is_fullscreen: bool,
    workspace_id: u8,

    pub const Frame = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    };
};

/// Window store — maps window IDs to Window structs.
pub const WindowStore = struct {
    windows: std.AutoHashMap(WindowId, Window),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WindowStore {
        return .{
            .windows = std.AutoHashMap(WindowId, Window).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WindowStore) void {
        self.windows.deinit();
    }

    pub fn put(self: *WindowStore, window: Window) !void {
        try self.windows.put(window.wid, window);
    }

    pub fn get(self: *const WindowStore, wid: WindowId) ?Window {
        return self.windows.get(wid);
    }

    pub fn remove(self: *WindowStore, wid: WindowId) void {
        _ = self.windows.remove(wid);
    }

    pub fn count(self: *const WindowStore) usize {
        return self.windows.count();
    }
};
