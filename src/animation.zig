//! Animates window frame changes by stepping AX frame sets from a 16ms
//! main-queue timer. AX writes are synchronous IPC to the target app, so
//! every animating window costs main-thread time each tick, and an
//! unresponsive app can stall the window manager for the AX messaging
//! timeout. To keep the per-tick cost down, each animation resolves and
//! retains the window's AX element once up front (bw_ax_animation_begin)
//! and intermediate ticks issue a single-pass position(+size) write; only
//! the final frame goes through the full three-pass clamping-safe
//! bw_ax_set_window_frame. Alpha until animation is moved off the main
//! thread.

const std = @import("std");
const shim = @import("shim_api.zig");
const window_mod = @import("window.zig");
const osutil = @import("osutil.zig");

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    spring,
};

pub const AnimationConfig = struct {
    enabled: bool = false,
    duration_ms: u64 = 200,
    easing: Easing = .ease_out,
};

const WindowAnimation = struct {
    wid: u32,
    pid: i32,
    start_frame: window_mod.Window.Frame,
    end_frame: window_mod.Window.Frame,
    last_displayed_frame: window_mod.Window.Frame,
    start_time_ns: i128,
    /// AX element retained for the animation's lifetime so ticks skip the
    /// per-call window-list lookup. Released via bw_ax_animation_end.
    ax_ref: *anyopaque,
    /// Whether bw_ax_animation_begin disabled AXEnhancedUserInterface and
    /// bw_ax_animation_end must restore it.
    restore_enhanced_ui: bool,

    fn end(self: *const WindowAnimation) void {
        shim.bw_ax_animation_end(self.pid, self.ax_ref, self.restore_enhanced_ui);
    }
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

    pub fn deinit(self: *Animator) void {
        self.finishAll();
    }

    /// Start or update an animation for a window.
    /// If the window is already animating, the animation is redirected to
    /// the new target from its current displayed position.
    pub fn animate(
        self: *Animator,
        pid: i32,
        wid: u32,
        current_frame: window_mod.Window.Frame,
        target_frame: window_mod.Window.Frame,
    ) void {
        const now_ns = osutil.nanoTimestamp();

        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                const a = &self.animations[i];
                a.start_frame = a.last_displayed_frame;
                a.end_frame = target_frame;
                a.start_time_ns = now_ns;
                return;
            }
        }

        if (self.count >= max_animations) {
            setFrame(pid, wid, target_frame);
            return;
        }

        var restore_enhanced_ui = false;
        const ax_ref = shim.bw_ax_animation_begin(pid, wid, &restore_enhanced_ui) orelse {
            // Window can't be resolved — place it directly instead.
            setFrame(pid, wid, target_frame);
            return;
        };

        self.animations[self.count] = .{
            .wid = wid,
            .pid = pid,
            .start_frame = current_frame,
            .end_frame = target_frame,
            .last_displayed_frame = current_frame,
            .start_time_ns = now_ns,
            .ax_ref = ax_ref,
            .restore_enhanced_ui = restore_enhanced_ui,
        };
        self.count += 1;
    }

    /// Advance all active animations by one frame. Moves each animated window
    /// to its interpolated position. Removes completed animations.
    pub fn tick(self: *Animator) void {
        if (self.count == 0) return;

        const now_ns = osutil.nanoTimestamp();

        var j: usize = 0;
        for (0..self.count) |i| {
            const a = &self.animations[i];

            const elapsed_ns = now_ns - a.start_time_ns;
            const t_raw = if (self.duration_ns == 0)
                @as(f64, 1)
            else
                @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(self.duration_ns));
            const t = @min(@max(t_raw, 0), 1);

            if (t >= 1) {
                // Final tick: full clamping-safe set at the exact target —
                // easings like .spring do not evaluate to exactly 1.0 at
                // t == 1, and the single-pass steps may have accumulated
                // clamping drift.
                setFrame(a.pid, a.wid, a.end_frame);
                a.end();
                continue;
            }

            const tol = window_mod.Window.Frame.tolerance;
            const frame = interpolateFrame(a.start_frame, a.end_frame, easeValue(self.easing, t));
            if (!a.last_displayed_frame.approxEqual(frame, tol)) {
                // Pure moves skip the size write, halving the per-tick IPC.
                const resizing = @abs(a.end_frame.width - a.start_frame.width) > tol or
                    @abs(a.end_frame.height - a.start_frame.height) > tol;
                shim.bw_ax_animation_step(a.ax_ref, frame.x, frame.y, frame.width, frame.height, resizing);
                a.last_displayed_frame = frame;
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
            setFrame(a.pid, a.wid, a.end_frame);
            a.end();
        }
        self.count = 0;
    }

    /// Drop the animation for a window without moving it. Used when the
    /// window is destroyed or minimized and its frame no longer matters.
    pub fn cancel(self: *Animator, wid: u32) void {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                self.animations[i].end();
                self.count -= 1;
                if (i < self.count) {
                    self.animations[i] = self.animations[self.count];
                }
                return;
            }
        }
    }

    /// Complete animation for a specific window, placing it at its target.
    pub fn finish(self: *Animator, wid: u32) void {
        for (0..self.count) |i| {
            if (self.animations[i].wid == wid) {
                const a = self.animations[i];
                setFrame(a.pid, a.wid, a.end_frame);
                a.end();
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

    pub fn isAnimating(self: *const Animator) bool {
        return self.count > 0;
    }
};

fn setFrame(pid: i32, wid: u32, frame: window_mod.Window.Frame) void {
    _ = shim.bw_ax_set_window_frame(
        pid,
        wid,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
    );
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
