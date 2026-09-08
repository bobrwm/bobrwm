//! Native Space gesture protocol shared by the reducer and OS adapter.

pub const phase_delay_ms: u64 = 10;

pub const Direction = enum {
    left,
    right,

    pub fn sign(self: Direction) f64 {
        return if (self == .right) 1.0 else -1.0;
    }
};

pub const Phase = enum(i64) { began = 1, changed = 2, ended = 4 };

pub const Plan = struct {
    direction: Direction,
    steps: u8,
    velocity: f64,
    is_paced: bool,
};

pub const Delivery = struct {
    plan: Plan,
    phase: Phase = .began,
    steps_remaining: u8,
    due_at_ms: ?u64 = null,
};
