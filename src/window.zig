const std = @import("std");

pub const WindowId = u32;

pub const WindowMode = enum {
    tiled,
    floating,
};

pub const Window = struct {
    wid: WindowId,
    pid: i32,
    title: ?[]const u8,
    frame: Frame,
    is_minimized: bool,
    is_fullscreen: bool = false,
    mode: WindowMode = .tiled,
    workspace_id: u8,
    display_id: u32,

    /// Last on-screen frame of a floating window, captured before it is parked
    /// off-screen on workspace hide. Restored when the workspace is shown again;
    /// tiled windows get their geometry from BSP instead, so this stays null.
    float_frame: ?Frame = null,

    pub const Frame = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,

        /// 1px tolerance absorbs sub-pixel rounding from CG/AX, avoiding
        /// redundant AX SetAttributeValue calls.
        pub const tolerance: f64 = 1.0;

        /// Compare frames within a tolerance.
        pub fn approxEqual(self: Frame, other: Frame, tol: f64) bool {
            return @abs(self.x - other.x) <= tol and
                @abs(self.y - other.y) <= tol and
                @abs(self.width - other.width) <= tol and
                @abs(self.height - other.height) <= tol;
        }

        /// Compare only size within a tolerance. When true, a reposition needs
        /// no AXSize write, so callers can move without the resize flash.
        pub fn sizeApproxEqual(self: Frame, other: Frame, tol: f64) bool {
            return @abs(self.width - other.width) <= tol and
                @abs(self.height - other.height) <= tol;
        }
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
        std.debug.assert(window.wid > 0);
        std.debug.assert(window.pid > 0);
        std.debug.assert(window.workspace_id > 0);
        std.debug.assert(window.display_id > 0);
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
