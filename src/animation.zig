//! Animates window frame changes by interpolating frames once per display
//! refresh (see display_link.zig) and handing each one to ax_writer, which
//! applies it on the app's own queue. A slow app coalesces the frames it
//! cannot keep up with instead of stalling the tick. Intermediate ticks are
//! single-pass position(+size) writes; only the final frame of a resizing
//! animation is the clamping-safe size-position-size write. Pure moves
//! finish with a position-only write, since an AXSize write would flash and
//! reflow size-sensitive apps.

const std = @import("std");
const ax_writer = @import("ax_writer.zig");
const window_mod = @import("window.zig");

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    spring,
    bezier,
    snappy,
    natural,
    smooth,
};

/// Control points for a CSS-style cubic Bezier curve from `(0, 0)` to `(1, 1)`.
/// `x1` and `x2` must be between 0 and 1; `y1` and `y2` may overshoot.
pub const CubicBezier = struct {
    /// Fast launch with a crisp, bounce-free settle.
    pub const snappy: CubicBezier = .{ .x1 = 0.22, .y1 = 1.0, .x2 = 0.36, .y2 = 1.0 };
    /// macOS CoreAnimation `ease`: slight ease-in and balanced deceleration.
    pub const natural: CubicBezier = .{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 };
    /// Softer ease-in-out glide with a clean finite-time stop.
    pub const smooth: CubicBezier = .{ .x1 = 0.30, .y1 = 0.0, .x2 = 0.40, .y2 = 1.0 };

    /// X coordinate of the first control point (0 to 1).
    x1: f64 = snappy.x1,
    /// Y coordinate of the first control point. Values outside 0 to 1 overshoot.
    y1: f64 = snappy.y1,
    /// X coordinate of the second control point (0 to 1).
    x2: f64 = snappy.x2,
    /// Y coordinate of the second control point. Values outside 0 to 1 overshoot.
    y2: f64 = snappy.y2,

    pub fn isValid(self: CubicBezier) bool {
        return std.math.isFinite(self.x1) and std.math.isFinite(self.y1) and
            std.math.isFinite(self.x2) and std.math.isFinite(self.y2) and
            self.x1 >= 0.0 and self.x1 <= 1.0 and
            self.x2 >= 0.0 and self.x2 <= 1.0;
    }

    /// Evaluate `y` at progress `x` in `[0, 1]`. Solves `B_x(u) = x` using
    /// bracketed Newton-Raphson with bisection fallback so vertical tangents
    /// (`x1 == 0` or `x2 == 1`) always converge monotonically.
    pub fn evaluate(self: CubicBezier, x: f64) f64 {
        if (x <= 0.0) return 0.0;
        if (x >= 1.0) return 1.0;
        if (self.x1 == self.y1 and self.x2 == self.y2) return x;

        var lo: f64 = 0.0;
        var hi: f64 = 1.0;
        var u: f64 = x;
        for (0..12) |_| {
            const bx = sampleAxis(self.x1, self.x2, u);
            const err = bx - x;
            if (@abs(err) < 1e-6) break;
            if (err < 0.0) lo = u else hi = u;

            const slope = sampleSlope(self.x1, self.x2, u);
            const next = if (@abs(slope) > 1e-6) u - err / slope else 0.5 * (lo + hi);
            u = if (next > lo and next < hi) next else 0.5 * (lo + hi);
        }
        return sampleAxis(self.y1, self.y2, u);
    }

    fn sampleAxis(p1: f64, p2: f64, u: f64) f64 {
        // Horner form of 3*(1-u)^2*u*p1 + 3*(1-u)*u^2*p2 + u^3.
        const a = 1.0 - 3.0 * p2 + 3.0 * p1;
        const b = 3.0 * p2 - 6.0 * p1;
        const c = 3.0 * p1;
        return ((a * u + b) * u + c) * u;
    }

    fn sampleSlope(p1: f64, p2: f64, u: f64) f64 {
        const a = 1.0 - 3.0 * p2 + 3.0 * p1;
        const b = 3.0 * p2 - 6.0 * p1;
        const c = 3.0 * p1;
        return (3.0 * a * u + 2.0 * b) * u + c;
    }
};

pub const AnimationConfig = struct {
    /// Animate window movement during layout changes.
    enabled: bool = false,
    /// Animation length in milliseconds.
    duration_ms: u64 = 200,
    /// Easing curve: presets `"snappy"`, `"natural"`, or `"smooth"`; standard
    /// curves `"linear"`, `"ease_in"`, `"ease_out"`, `"ease_in_out"`, or
    /// `"spring"`; or `"bezier"` for custom `animation.bezier` control points.
    easing: Easing = .ease_out,
    /// Control points used when `easing` is `"bezier"`. Defaults to the
    /// `"snappy"` curve (`0.22, 1.0, 0.36, 1.0`).
    bezier: CubicBezier = .{},
};

pub const WindowAnimation = struct {
    wid: u32,
    pid: i32,
    /// Display whose refresh drives this animation: the target's display.
    display_id: u32,
    start_frame: window_mod.Window.Frame,
    end_frame: window_mod.Window.Frame,
    last_displayed_frame: window_mod.Window.Frame,
    /// Anchored on the first display-link tick (`anchor_ns`, one refresh before
    /// `target_ns`) so animations do not lose opening frames to link unpause or
    /// vsync phase. Null until the first tick runs.
    start_time_ns: ?i128 = null,
};

const max_animations = 64;

pub const Animator = struct {
    animations: [max_animations]WindowAnimation = undefined,
    count: usize = 0,
    duration_ns: i128 = 200 * std.time.ns_per_ms,
    easing: Easing = .ease_out,
    bezier: CubicBezier = .{},

    pub fn init(self: *Animator, config: AnimationConfig) void {
        self.count = 0;
        self.duration_ns = @as(i128, config.duration_ms) * std.time.ns_per_ms;
        self.easing = config.easing;
        self.bezier = config.bezier;
    }

    /// Start or update an animation for a window.
    /// If the window is already animating, the animation is redirected to
    /// the new target from its current displayed position.
    /// Returns whether the target was accepted: an animation was scheduled
    /// or redirected (it converges on the target on its own), or the direct
    /// placement fallback was queued. Callers must not record the target
    /// frame when this returns false.
    pub fn animate(
        self: *Animator,
        display_id: u32,
        pid: i32,
        wid: u32,
        current_frame: window_mod.Window.Frame,
        target_frame: window_mod.Window.Frame,
    ) bool {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                const a = &self.animations[i];
                a.display_id = display_id;
                a.start_frame = a.last_displayed_frame;
                a.end_frame = target_frame;
                a.start_time_ns = null;
                return true;
            }
        }

        if (self.count >= max_animations) {
            return placeFinal(pid, wid, current_frame, target_frame);
        }

        self.animations[self.count] = .{
            .wid = wid,
            .pid = pid,
            .display_id = display_id,
            .start_frame = current_frame,
            .end_frame = target_frame,
            .last_displayed_frame = current_frame,
            .start_time_ns = null,
        };
        self.count += 1;
        return true;
    }

    /// Advance the animations on `display_id` to the frame shown at
    /// `target_ns`, anchoring any newly started animation to `anchor_ns`.
    /// Moves each animated window to its interpolated position and removes
    /// completed animations.
    pub fn tick(self: *Animator, display_id: u32, anchor_ns: i128, target_ns: i128) void {
        var j: usize = 0;
        for (0..self.count) |i| {
            const a = &self.animations[i];
            if (a.display_id != display_id) {
                if (i != j) self.animations[j] = self.animations[i];
                j += 1;
                continue;
            }

            const t = advanceProgress(&a.start_time_ns, anchor_ns, target_ns, self.duration_ns);

            if (t >= 1) {
                // Final tick: place at the exact target — easings like
                // .spring do not evaluate to exactly 1.0 at t == 1, and
                // resizing single-pass steps may have accumulated clamping
                // drift. Pure moves never wrote a size, so they finish with
                // a position-only write.
                _ = placeFinal(a.pid, a.wid, a.start_frame, a.end_frame);
                continue;
            }

            const tol = window_mod.Window.Frame.tolerance;
            const frame = interpolateFrame(a.start_frame, a.end_frame, easeValue(self.easing, self.bezier, t));
            if (!a.last_displayed_frame.approxEqual(frame, tol)) {
                // Pure moves skip the size write, halving the per-tick IPC.
                const resizing = @abs(a.end_frame.width - a.start_frame.width) > tol or
                    @abs(a.end_frame.height - a.start_frame.height) > tol;
                const step: ax_writer.Write = .{ .position = true, .size = resizing, .quiet = true };
                if (ax_writer.write(a.pid, a.wid, frame, step)) a.last_displayed_frame = frame;
            }

            if (i != j) self.animations[j] = self.animations[i];
            j += 1;
        }
        self.count = j;
    }

    /// Immediately complete all active animations, placing windows at
    /// their target frames.
    pub fn finishAll(self: *Animator) void {
        for (0..self.count) |i| {
            const a = self.animations[i];
            _ = placeFinal(a.pid, a.wid, a.start_frame, a.end_frame);
        }
        self.count = 0;
    }

    /// Drop the animation for a window without moving it. Used when the
    /// window is destroyed or minimized and its frame no longer matters.
    pub fn cancel(self: *Animator, wid: u32) void {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                self.count -= 1;
                if (i < self.count) {
                    self.animations[i] = self.animations[self.count];
                }
                return;
            }
        }
    }

    pub fn isAnimatingWindow(self: *const Animator, wid: u32) bool {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) return true;
        }
        return false;
    }

    pub fn isAnimatingOnDisplay(self: *const Animator, display_id: u32) bool {
        for (self.active()) |a| {
            if (a.display_id == display_id) return true;
        }
        return false;
    }

    /// Frame last written to `wid`, or null when it is not animating. Retile
    /// records the target frame up front, so this is where the window is.
    pub fn displayedFrame(self: *const Animator, wid: u32) ?window_mod.Window.Frame {
        for (self.active()) |a| {
            if (a.wid == wid) return a.last_displayed_frame;
        }
        return null;
    }

    /// In-flight animations; invalidated by the next tick.
    pub fn active(self: *const Animator) []const WindowAnimation {
        return self.animations[0..self.count];
    }
};

/// Place a window at its animation target. A pure move (size unchanged
/// between the animation's endpoints) finishes with a position-only write:
/// intermediate ticks never wrote a size, so there is no size drift to heal,
/// and an AXSize write would flash and reflow size-sensitive apps. Resizing
/// animations keep the full clamping-safe frame write. Returns whether the
/// write was queued.
fn placeFinal(pid: i32, wid: u32, from: window_mod.Window.Frame, to: window_mod.Window.Frame) bool {
    const kind: ax_writer.Write = if (from.sizeApproxEqual(to, window_mod.Window.Frame.tolerance))
        .position_only
    else
        .frame;
    return ax_writer.write(pid, wid, to, kind);
}

fn interpolateFrame(
    start: window_mod.Window.Frame,
    end: window_mod.Window.Frame,
    t: f64,
) window_mod.Window.Frame {
    return .{
        .x = start.x + (end.x - start.x) * t,
        .y = start.y + (end.y - start.y) * t,
        .width = @max(start.width + (end.width - start.width) * t, 1),
        .height = @max(start.height + (end.height - start.height) * t, 1),
    };
}

fn easeValue(easing: Easing, bezier: CubicBezier, t: f64) f64 {
    return switch (easing) {
        .linear => t,
        .ease_in => easeInCubic(t),
        .ease_out => easeOutCubic(t),
        .ease_in_out => easeInOutCubic(t),
        .spring => easeSpring(t),
        .bezier => bezier.evaluate(t),
        .snappy => CubicBezier.snappy.evaluate(t),
        .natural => CubicBezier.natural.evaluate(t),
        .smooth => CubicBezier.smooth.evaluate(t),
    };
}

fn easeInCubic(t: f64) f64 {
    return t * t * t;
}

fn easeOutCubic(t: f64) f64 {
    return 1.0 - std.math.pow(f64, 1.0 - t, 3);
}

fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) return 4.0 * t * t * t;
    return 1.0 - std.math.pow(f64, -2.0 * t + 2.0, 3) / 2.0;
}

fn advanceProgress(start_time_ns: *?i128, anchor_ns: i128, target_ns: i128, duration_ns: i128) f64 {
    const start_ns = start_time_ns.* orelse blk: {
        start_time_ns.* = anchor_ns;
        break :blk anchor_ns;
    };
    if (duration_ns == 0) return 1.0;
    const elapsed_ns = target_ns - start_ns;
    const t_raw = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(duration_ns));
    return @min(@max(t_raw, 0.0), 1.0);
}

fn easeSpring(t: f64) f64 {
    return 1.0 - std.math.exp(-6.0 * t) * std.math.cos(10.0 * t);
}

test "advanceProgress anchors on first tick and finishes cleanly" {
    const testing = std.testing;
    const duration_ns: i128 = 200 * std.time.ns_per_ms;
    const frame_ns: i128 = 10 * std.time.ns_per_ms;

    var start: ?i128 = null;
    // First tick anchors to `anchor_ns` so progress is exactly 1 frame in.
    const t1 = advanceProgress(&start, 1_000 * std.time.ns_per_ms, 1_000 * std.time.ns_per_ms + frame_ns, duration_ns);
    try testing.expectEqual(@as(?i128, 1_000 * std.time.ns_per_ms), start);
    try testing.expectApproxEqAbs(@as(f64, 0.05), t1, 1e-9);

    // Subsequent tick preserves the original anchor.
    const t2 = advanceProgress(&start, 1_010 * std.time.ns_per_ms, 1_020 * std.time.ns_per_ms, duration_ns);
    try testing.expectEqual(@as(?i128, 1_000 * std.time.ns_per_ms), start);
    try testing.expectApproxEqAbs(@as(f64, 0.10), t2, 1e-9);

    // Fallback landing when display link fails to start (`anchor = 0, target = maxInt`).
    var unstarted: ?i128 = null;
    try testing.expectEqual(@as(f64, 1.0), advanceProgress(&unstarted, 0, std.math.maxInt(i128), duration_ns));
}

test "cubic bezier matches endpoints, linear identity, and snappy default curve" {
    const testing = std.testing;

    const linear: CubicBezier = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };
    try testing.expectApproxEqAbs(@as(f64, 0.0), linear.evaluate(0.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.35), linear.evaluate(0.35), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), linear.evaluate(1.0), 1e-6);

    // Default (0.22, 1.0, 0.36, 1.0) launches fast and finishes monotonically.
    const default_curve: CubicBezier = .{};
    try testing.expect(default_curve.isValid());
    try testing.expectEqual(@as(f64, 0.0), default_curve.evaluate(0.0));
    try testing.expectEqual(@as(f64, 1.0), default_curve.evaluate(1.0));
    var prev: f64 = 0.0;
    for (1..20) |step| {
        const x = @as(f64, @floatFromInt(step)) / 20.0;
        const y = default_curve.evaluate(x);
        try testing.expect(y > prev);
        try testing.expect(y <= 1.0);
        prev = y;
    }
    try testing.expect(default_curve.evaluate(0.25) > 0.65);

    // Zero-slope endpoint (x1 = 1, x2 = 0) and overshoot y values still converge.
    const steep: CubicBezier = .{ .x1 = 1.0, .y1 = -0.2, .x2 = 0.0, .y2 = 1.2 };
    try testing.expect(steep.isValid());
    try testing.expectApproxEqAbs(@as(f64, 0.5), steep.evaluate(0.5), 1e-3);
    try testing.expect(steep.evaluate(0.9) > 1.0);
}

test "cubic bezier validation rejects out-of-range x and non-finite points" {
    const testing = std.testing;
    try testing.expect(!(CubicBezier{ .x1 = -0.01 }).isValid());
    try testing.expect(!(CubicBezier{ .x1 = 1.01 }).isValid());
    try testing.expect(!(CubicBezier{ .x2 = -0.1 }).isValid());
    try testing.expect(!(CubicBezier{ .x2 = 1.5 }).isValid());
    try testing.expect(!(CubicBezier{ .y1 = std.math.nan(f64) }).isValid());
    try testing.expect(!(CubicBezier{ .y2 = std.math.inf(f64) }).isValid());
    // Overshoot on y is valid.
    try testing.expect((CubicBezier{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1.0 }).isValid());
}

test "bezier presets are valid, monotonic, and ordered from snappy to smooth" {
    const testing = std.testing;
    const presets = [_]Easing{ .snappy, .natural, .smooth };
    for (presets) |preset| {
        try testing.expectEqual(@as(f64, 0.0), easeValue(preset, .{}, 0.0));
        try testing.expectEqual(@as(f64, 1.0), easeValue(preset, .{}, 1.0));
        var prev: f64 = 0.0;
        for (1..20) |step| {
            const x = @as(f64, @floatFromInt(step)) / 20.0;
            const y = easeValue(preset, .{}, x);
            try testing.expect(y > prev);
            try testing.expect(y <= 1.0);
            prev = y;
        }
    }

    // Early in the curve, snappy launches fastest, natural is balanced, smooth is gentlest.
    const snappy_early = easeValue(.snappy, .{}, 0.25);
    const natural_early = easeValue(.natural, .{}, 0.25);
    const smooth_early = easeValue(.smooth, .{}, 0.25);
    try testing.expect(snappy_early > natural_early);
    try testing.expect(natural_early > smooth_early);
}
