//! Optional trackpad swipe companion for bobrwm.

const std = @import("std");
const objc = @import("objc");
const c = @import("c");
const cg_extra = @import("cg_extra");
const config_mod = @import("bobrwm_config");

const log = std.log.scoped(.bobrwm_swipe);

const max_touches: usize = 16;
const nsevent_type_gesture: c.CGEventType = 29;
const touch_phase_ended: u32 = 1 << 3;
const touch_phase_cancelled: u32 = 1 << 4;

const RuntimeConfig = struct {
    fingers: usize = 3,
    distance_pct: f64 = 0.08,
};

const IpcResult = enum {
    handled,
    pass_through,
    failed,
};

const Direction = enum {
    previous,
    next,

    fn command(self: Direction) []const u8 {
        return switch (self) {
            .previous => "focus-workspace prev",
            .next => "focus-workspace next",
        };
    }
};

const TouchSample = struct {
    id: usize,
    x: f64,
    y: f64,
};

const GestureState = struct {
    active: bool = false,
    fired: bool = false,
    consuming: bool = false,
    count: usize = 0,
    ids: [max_touches]usize = [_]usize{0} ** max_touches,
    start_x: [max_touches]f64 = [_]f64{0} ** max_touches,
    start_y: [max_touches]f64 = [_]f64{0} ** max_touches,

    fn reset(self: *GestureState) void {
        self.active = false;
        self.fired = false;
        self.consuming = false;
        self.count = 0;
    }

    fn begin(self: *GestureState, samples: []const TouchSample) void {
        std.debug.assert(samples.len > 0);
        std.debug.assert(samples.len <= max_touches);

        self.active = true;
        self.fired = false;
        self.consuming = false;
        self.count = samples.len;
        for (samples, 0..) |sample, i| {
            self.ids[i] = sample.id;
            self.start_x[i] = sample.x;
            self.start_y[i] = sample.y;
        }
    }

    fn update(self: *GestureState, samples: []const TouchSample, runtime: RuntimeConfig) ?Direction {
        std.debug.assert(self.active);
        std.debug.assert(self.count > 0);
        std.debug.assert(self.count <= max_touches);
        std.debug.assert(samples.len == self.count);

        var dx_sum: f64 = 0;
        var dy_sum: f64 = 0;
        for (0..self.count) |i| {
            const sample = findSample(samples, self.ids[i]) orelse {
                self.reset();
                return null;
            };
            dx_sum += sample.x - self.start_x[i];
            dy_sum += sample.y - self.start_y[i];
        }

        if (self.fired) return null;

        const denom: f64 = @floatFromInt(self.count);
        const avg_dx = dx_sum / denom;
        const avg_dy = dy_sum / denom;
        if (@abs(avg_dx) < runtime.distance_pct) return null;
        if (@abs(avg_dx) <= @abs(avg_dy)) return null;

        self.fired = true;
        return if (avg_dx < 0) .previous else .next;
    }
};

var g_runtime: RuntimeConfig = .{};
var g_gesture: GestureState = .{};
var g_tap_port: c.CFMachPortRef = null;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const cli = parseCli(init.args);
    if (cli.help) {
        writeStdout(help_text);
        return;
    }

    const config = config_mod.load(arena.allocator(), cli.config_path);
    if (!config.swipe.enabled) {
        writeStderr("bobrwm-swipe: .swipe.enabled is false; exiting\n");
        return;
    }
    g_runtime = validateSwipeConfig(config.swipe) catch |err| {
        log.err("invalid swipe config: {}", .{err});
        return err;
    };

    initAppKit();
    if (c.AXIsProcessTrusted() == 0) {
        log.warn("accessibility is not trusted; prompting user", .{});
        log.warn("after granting access, restart bobrwm-swipe", .{});
        axPrompt();
        return error.AccessibilityNotTrusted;
    }

    try setupGestureTap();
    log.info("listening for {d}-finger workspace swipes", .{g_runtime.fingers});
    c.CFRunLoopRun();
}

const Cli = struct {
    help: bool = false,
    config_path: ?[]const u8 = null,
};

fn parseCli(process_args: std.process.Args) Cli {
    var cli: Cli = .{};
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.help = true;
            return cli;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            cli.config_path = args.next();
        }
    }
    return cli;
}

fn validateSwipeConfig(config: config_mod.SwipeConfig) !RuntimeConfig {
    if (config.fingers == 0 or config.fingers > max_touches) return error.InvalidFingerCount;
    if (config.distance_pct <= 0 or config.distance_pct > 1) return error.InvalidDistancePct;
    return .{
        .fingers = config.fingers,
        .distance_pct = config.distance_pct,
    };
}

fn initAppKit() void {
    const NSApplication = objc.getClass("NSApplication") orelse
        @panic("NSApplication class not found");
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == null) @panic("NSApplication sharedApplication failed");
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 1)});
}

fn setupGestureTap() !void {
    const mask: c.CGEventMask = @as(c.CGEventMask, 1) << @intCast(nsevent_type_gesture);

    g_tap_port = cg_extra.CGEventTapCreate(
        c.kCGHIDEventTap,
        c.kCGHeadInsertEventTap,
        c.kCGEventTapOptionDefault,
        mask,
        gestureTapCallback,
        null,
    );
    const tap = g_tap_port orelse return error.GestureTapCreateFailed;

    const tap_source = c.CFMachPortCreateRunLoopSource(null, tap, 0) orelse
        return error.GestureTapSourceFailed;
    defer c.CFRelease(@ptrCast(tap_source));

    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), tap_source, c.kCFRunLoopCommonModes);
    cg_extra.CGEventTapEnable(tap, true);
}

fn gestureTapCallback(
    proxy: c.CGEventTapProxy,
    event_type: c.CGEventType,
    event: c.CGEventRef,
    refcon: ?*anyopaque,
) callconv(.c) c.CGEventRef {
    _ = proxy;
    _ = refcon;

    if (event_type == c.kCGEventTapDisabledByTimeout or event_type == c.kCGEventTapDisabledByUserInput) {
        if (g_tap_port) |tap| cg_extra.CGEventTapEnable(tap, true);
        return event;
    }
    if (event_type != nsevent_type_gesture) return event;

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSEvent = objc.getClass("NSEvent") orelse return event;
    const ns_event = NSEvent.msgSend(objc.Object, "eventWithCGEvent:", .{event});
    if (ns_event.value == null) return event;
    const touches = ns_event.msgSend(objc.Object, "allTouches", .{});
    if (touches.value == null) return event;

    var sample_buf: [max_touches]TouchSample = undefined;
    const sample_count = collectTouchSamples(touches, &sample_buf);
    const samples = sample_buf[0..sample_count];
    const was_consuming = g_gesture.consuming;
    if (processGestureFrame(samples)) |direction| {
        switch (sendIpcCommand(direction.command())) {
            .handled => {
                g_gesture.consuming = true;
                return null;
            },
            .pass_through => return event,
            .failed => {
                log.warn("failed to send bobrwm IPC command: {s}", .{direction.command()});
                return event;
            },
        }
    }
    if (g_gesture.consuming or was_consuming) return null;
    return event;
}

fn collectTouchSamples(touches: objc.Object, out: *[max_touches]TouchSample) usize {
    var count: usize = 0;
    var iter = touches.iterate();
    while (iter.next()) |touch| {
        if (count >= max_touches) break;

        const phase_raw = touch.msgSend(c_ulong, "phase", .{});
        if (phase_raw > std.math.maxInt(u32)) continue;
        const phase: u32 = @intCast(phase_raw);
        if ((phase & (touch_phase_ended | touch_phase_cancelled)) != 0) continue;

        const identity = touch.msgSend(objc.Object, "identity", .{});
        if (identity.value == null) continue;
        const position = touch.msgSend(c.CGPoint, "normalizedPosition", .{});

        out[count] = .{
            .id = @intFromPtr(identity.value),
            .x = position.x,
            .y = position.y,
        };
        count += 1;
    }
    return count;
}

fn processGestureFrame(samples: []const TouchSample) ?Direction {
    if (samples.len != g_runtime.fingers) {
        g_gesture.reset();
        return null;
    }
    if (!g_gesture.active) {
        g_gesture.begin(samples);
        return null;
    }
    return g_gesture.update(samples, g_runtime);
}

fn findSample(samples: []const TouchSample, id: usize) ?TouchSample {
    for (samples) |sample| {
        if (sample.id == id) return sample;
    }
    return null;
}

fn sendIpcCommand(cmd: []const u8) IpcResult {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0) catch return .failed;

    const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return .failed;
    defer _ = std.c.close(fd);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    if (path.len < addr.path.len) addr.path[path.len] = 0;

    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) != 0) return .failed;
    if (!writeAll(fd, cmd)) return .failed;
    _ = std.c.shutdown(fd, std.c.SHUT.WR);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, 80) catch return .failed;
    if (ready == 0) return .failed;

    var response: [128]u8 = undefined;
    const n = std.posix.read(fd, &response) catch return .failed;
    if (n == 0) return .failed;
    const body = std.mem.trim(u8, response[0..n], &.{ '\n', '\r', ' ', 0 });
    if (std.mem.eql(u8, body, "ok")) return .handled;
    if (std.mem.eql(u8, body, "pass")) return .pass_through;
    log.warn("bobrwm IPC rejected command '{s}': {s}", .{ cmd, body });
    return .failed;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return false;
        remaining = remaining[@intCast(n)..];
    }
    return true;
}

fn axPrompt() void {
    const NSDictionary = objc.getClass("NSDictionary") orelse {
        _ = c.AXIsProcessTrustedWithOptions(null);
        return;
    };
    const NSNumber = objc.getClass("NSNumber") orelse {
        _ = c.AXIsProcessTrustedWithOptions(null);
        return;
    };

    const enabled = NSNumber.msgSend(objc.Object, "numberWithBool:", .{true});
    const options = NSDictionary.msgSend(objc.Object, "dictionaryWithObject:forKey:", .{
        enabled,
        nsString("AXTrustedCheckOptionPrompt"),
    });
    const options_value = options.value;
    if (options_value == null) return;
    _ = c.AXIsProcessTrustedWithOptions(@ptrCast(options_value));
}

fn nsString(str: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString") orelse
        @panic("NSString class not found");
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str});
}

fn writeFd(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

fn writeStdout(bytes: []const u8) void {
    writeFd(std.posix.STDOUT_FILENO, bytes);
}

fn writeStderr(bytes: []const u8) void {
    writeFd(std.posix.STDERR_FILENO, bytes);
}

const help_text =
    \\Usage: bobrwm-swipe [options]
    \\
    \\Optional trackpad swipe companion for bobrwm.
    \\
    \\Options:
    \\  -c, --config <path>       Use a specific bobrwm config file
    \\  -h, --help                Show this help message
    \\
    \\Configuration is read from the main bobrwm config. Enable it with:
    \\
    \\  .swipe = .{ .enabled = true }
    \\
    \\When bobrwm has an adjacent workspace, the listener consumes the matching
    \\macOS gesture. At the first or last bobrwm workspace, it passes the gesture
    \\through so native Spaces can handle it.
    \\
;

test "validate swipe config" {
    const t = std.testing;

    const valid = try validateSwipeConfig(.{ .enabled = true, .fingers = 4, .distance_pct = 0.1 });
    try t.expectEqual(@as(usize, 4), valid.fingers);
    try t.expectApproxEqAbs(@as(f64, 0.1), valid.distance_pct, 0.0001);
    try t.expectError(error.InvalidFingerCount, validateSwipeConfig(.{ .fingers = 0 }));
    try t.expectError(error.InvalidFingerCount, validateSwipeConfig(.{ .fingers = 17 }));
    try t.expectError(error.InvalidDistancePct, validateSwipeConfig(.{ .distance_pct = 0 }));
    try t.expectError(error.InvalidDistancePct, validateSwipeConfig(.{ .distance_pct = 1.1 }));
}

test "gesture frame fires once without wrapping policy" {
    const t = std.testing;

    var state: GestureState = .{};
    const runtime: RuntimeConfig = .{ .fingers = 3, .distance_pct = 0.08 };
    const start = [_]TouchSample{
        .{ .id = 1, .x = 0.5, .y = 0.5 },
        .{ .id = 2, .x = 0.6, .y = 0.5 },
        .{ .id = 3, .x = 0.7, .y = 0.5 },
    };
    state.begin(&start);

    const moved = [_]TouchSample{
        .{ .id = 1, .x = 0.4, .y = 0.51 },
        .{ .id = 2, .x = 0.5, .y = 0.51 },
        .{ .id = 3, .x = 0.6, .y = 0.51 },
    };
    try t.expectEqual(Direction.previous, state.update(&moved, runtime).?);
    try t.expectEqual(@as(?Direction, null), state.update(&moved, runtime));
}
