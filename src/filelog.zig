//! Tee `std.log` output to a file.
//!
//! Launched from LaunchServices the process has no useful stderr, so the log
//! the old launchd `StandardErrorPath` used to capture went nowhere. Writing
//! the file from inside the process instead means logs survive every launch
//! path — Finder, `open`, the registered LaunchAgent, or `zig build run`.
//!
//! Only the window manager uses this. The client is short-lived and its output
//! belongs on the terminal.

const std = @import("std");
const osutil = @import("osutil.zig");
const log_options = @import("log_options.zig");

const log = std.log.scoped(.filelog);

/// Truncate at startup past this size so months of restarts cannot fill the
/// disk. launchd never rotated the old log either, but it also never ran
/// unattended for as long as a login item does.
const size_limit_bytes: u64 = 8 << 20;

/// -1 until `init` succeeds, so logging before init just goes to stderr.
var g_fd: std.atomic.Value(c_int) = .init(-1);

extern "c" fn strftime(
    buf: [*]u8,
    maxsize: usize,
    format: [*:0]const u8,
    timeptr: *const Tm,
) usize;
extern "c" fn localtime_r(clock: *const i64, result: *Tm) ?*Tm;

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

/// Open the log file. Call once from the main thread before any observer
/// threads start, so `logFn` never races on the descriptor.
pub fn init() void {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(
        &path_buf,
        "/tmp/bobrwm_{d}.log",
        .{std.c.getuid()},
        0,
    ) catch return;

    // Appending keeps the tail that explains a crash, which matters now that
    // launchd restarts the agent on one.
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = std.c.open(path, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) {
        log.warn("could not open {s}; logging to stderr only", .{path});
        return;
    }

    // O_APPEND leaves the offset at end-of-file, so this doubles as the size.
    if (std.c.lseek(fd, 0, std.c.SEEK.END) > size_limit_bytes) {
        _ = std.c.ftruncate(fd, 0);
    }

    g_fd.store(fd, .release);
    log.info("logging to {s}", .{path});
}

/// `std.Options.logFn`. Writes to stderr as usual, then appends a plain-text
/// copy to the log file.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);

    if (comptime @intFromEnum(level) > @intFromEnum(log_options.level)) return;

    const fd = g_fd.load(.acquire);
    if (fd < 0) return;

    // One buffer, one write: O_APPEND makes a single write atomic, so
    // background AX observer threads cannot interleave mid-line and no lock is
    // needed. Long messages are truncated rather than split.
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    writeTimestamp(&writer);
    writer.print(
        if (scope == .default) "{s}: " else "{s}(" ++ @tagName(scope) ++ "): ",
        .{level.asText()},
    ) catch {};
    writer.print(format, args) catch {};

    // Reserve the newline: a truncated line is still readable, an unterminated
    // one runs into the next.
    const body = writer.buffered();
    const end = @min(body.len, buf.len - 1);
    buf[end] = '\n';

    _ = std.c.write(fd, &buf, end + 1);
}

fn writeTimestamp(writer: *std.Io.Writer) void {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return;

    const now: i64 = @intCast(ts.sec);
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return;

    var stamp: [32]u8 = undefined;
    const n = strftime(&stamp, stamp.len, "%Y-%m-%d %H:%M:%S ", &tm);
    if (n == 0) return;

    writer.writeAll(stamp[0..n]) catch {};
}
