//! Window value types shared by the reducer and platform adapters.

pub const WindowId = u32;

pub const WindowMode = enum {
    tiled,
    floating,
};

pub const Window = struct {
    wid: WindowId,
    pid: i32,
    /// Last geometry bobrwm deliberately accepted: either a successful AX
    /// target or a user/external frame admitted by the ownership coordinator.
    /// This is not an unconditionally live WindowServer observation.
    frame: Frame,
    is_fullscreen: bool = false,
    mode: WindowMode = .tiled,

    /// Last non-fullscreen frame of a floating window. Used to restore user
    /// geometry after fullscreen or off-display drift.
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
