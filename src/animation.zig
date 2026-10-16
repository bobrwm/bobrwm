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
};

pub const AnimationConfig = struct {
    /// Animate window movement during layout changes.
    enabled: bool = false,
    /// Animation length in milliseconds.
    duration_ms: u64 = 200,
    /// Easing curve: `.linear`, `.ease_in`, `.ease_out`, `.ease_in_out`, or
    /// `.spring`.
    easing: Easing = .ease_out,
};

pub const WindowAnimation = struct {
    wid: u32,
    pid: i32,
    /// Display whose refresh drives this animation: the target's display.
    display_id: u32,
    start_frame: window_mod.Window.Frame,
    end_frame: window_mod.Window.Frame,
    last_displayed_frame: window_mod.Window.Frame,
    /// On the display_link.nowNs clock, which frame target times share.
    start_time_ns: i128,
};

const max_animations = 64;

pub const Animator = struct {
    animations: [max_animations]WindowAnimation = undefined,
    count: usize = 0,
    duration_ns: i128 = 200 * std.time.ns_per_ms,
    easing: Easing = .ease_out,

    pub fn init(self: *Animator, config: AnimationConfig) void {
        self.count = 0;
        self.duration_ns = @as(i128, config.duration_ms) * std.time.ns_per_ms;
        self.easing = config.easing;
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
        now_ns: i128,
    ) bool {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                const a = &self.animations[i];
                a.display_id = display_id;
                a.start_frame = a.last_displayed_frame;
                a.end_frame = target_frame;
                a.start_time_ns = now_ns;
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
            .start_time_ns = now_ns,
        };
        self.count += 1;
        return true;
    }

    /// Advance the animations on `display_id` to the frame shown at
    /// `target_ns`. Moves each animated window to its interpolated position.
    /// Removes completed animations.
    pub fn tick(self: *Animator, display_id: u32, target_ns: i128) void {
        var j: usize = 0;
        for (0..self.count) |i| {
            const a = &self.animations[i];
            if (a.display_id != display_id) {
                if (i != j) self.animations[j] = self.animations[i];
                j += 1;
                continue;
            }

            const elapsed_ns = target_ns - a.start_time_ns;
            const t_raw = if (self.duration_ns == 0)
                @as(f64, 1)
            else
                @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(self.duration_ns));
            const t = @min(@max(t_raw, 0), 1);

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
            const frame = interpolateFrame(a.start_frame, a.end_frame, easeValue(self.easing, t));
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

fn easeValue(easing: Easing, t: f64) f64 {
    return switch (easing) {
        .linear => t,
        .ease_in => easeInCubic(t),
        .ease_out => easeOutCubic(t),
        .ease_in_out => easeInOutCubic(t),
        .spring => easeSpring(t),
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

fn easeSpring(t: f64) f64 {
    return 1.0 - std.math.exp(-6.0 * t) * std.math.cos(10.0 * t);
}
