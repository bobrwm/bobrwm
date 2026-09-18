//! `std.log` sinks for the window manager.
//!
//! Three destinations, one per kind of reader:
//!
//! - A log file under the runtime directory. Launched from LaunchServices the
//!   process has no useful stderr, so this is what survives every launch path
//!   — Finder, `open`, the LaunchAgent, `zig build run` — and keeps the tail
//!   that explains a crash. The durable sink.
//! - Unified logging (`os_log`), for `log stream`. Every level goes here,
//!   debug included, because it is the one sink that is safe at debug volume
//!   from the main thread: a line lands in a shared-memory ring that logd
//!   drains, and a level nobody is streaming costs a single enabled check.
//! - stderr, for the terminal you launched from. Debug is never sent here
//!   outside a Debug build. A pty absorbs about 1 KiB — ten lines — before
//!   `write(2)` blocks, and bobrwm manages the terminal it logs into: a drag
//!   that stalled that terminal's render loop stalled bobrwm's main thread on
//!   its next debug line, and the trace spans then measured the logging that
//!   reported them.
//!
//! `BOBRWM_LOG` overrides the sink defaults with a comma-separated list of
//! `stderr`, `macos`, or their `no-` forms: `BOBRWM_LOG=no-stderr`.
//!
//! Only the window manager uses this. The client is short-lived and its output
//! belongs on the terminal.

const std = @import("std");
const builtin = @import("builtin");
const log_options = @import("log_options.zig");
const osutil = @import("osutil.zig");
const runtime_paths = @import("runtime_paths.zig");

const log = std.log.scoped(.filelog);

/// Truncate at startup past this size so months of restarts cannot fill the
/// disk. launchd never rotated the old log either, but it also never ran
/// unattended for as long as a login item does.
const size_limit_bytes: u64 = 8 << 20;

/// Matches CFBundleIdentifier in build.zig, so
/// `log stream --predicate 'subsystem == "com.bobrwm.bobrwm"'` shows these
/// lines next to AppKit's own about the process.
const subsystem: [*:0]const u8 = "com.bobrwm.bobrwm";

/// Where lines go besides the file. Written once by `init` before any thread
/// starts and only read afterwards, so it needs no synchronisation.
pub const Sinks = struct {
    stderr: bool = true,
    macos: bool = true,
};

var g_sinks: Sinks = .{};

/// -1 until `init` succeeds, so logging before init skips the file.
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

const OsLog = opaque {};

/// `os_log_type_t`. Warn maps to error and err to fault, as Ghostty does:
/// unified logging persists default and above and drops info and debug unless
/// someone is streaming, so a warning filed at info would be gone by the time
/// anyone came looking for it.
const OsLogType = enum(u8) {
    default = 0x00,
    info = 0x01,
    debug = 0x02,
    err = 0x10,
    fault = 0x11,

    fn from(level: std.log.Level) OsLogType {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };
    }
};

extern "c" fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) *OsLog;
extern "c" fn os_log_type_enabled(logger: *OsLog, kind: OsLogType) bool;
extern "c" fn os_release(object: *anyopaque) void;
/// src/c/oslog.c — `os_log_with_type` is a compiler macro with no symbol.
extern "c" fn bw_os_log(logger: *OsLog, kind: OsLogType, message: [*:0]const u8) void;

/// Read `BOBRWM_LOG` and open the log file. Call once from the main thread
/// before any observer thread starts, so `logFn` never races on either.
pub fn init() void {
    if (osutil.getenv("BOBRWM_LOG")) |value| g_sinks = parseSinks(value);

    runtime_paths.ensureRuntimeDir(std.heap.c_allocator) catch |err| {
        log.warn("could not secure runtime directory: {}; no log file", .{err});
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = runtime_paths.logPathBuf(&path_buf) catch |err| {
        log.warn("could not resolve log path: {}; no log file", .{err});
        return;
    };

    // Appending keeps the tail that explains a crash, which matters now that
    // launchd restarts the agent on one.
    const flags: std.c.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
    const fd = std.c.open(path, flags, @as(std.c.mode_t, 0o600));
    if (fd < 0) {
        log.warn("could not open {s}; no log file", .{path});
        return;
    }

    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0 or
        !std.c.S.ISREG(stat.mode) or
        stat.uid != std.c.getuid() or
        stat.nlink != 1)
    {
        log.warn("refusing unsafe log path {s}; no log file", .{path});
        _ = std.c.close(fd);
        return;
    }
    if (std.c.fchmod(fd, 0o600) != 0) {
        log.warn("could not secure {s}; no log file", .{path});
        _ = std.c.close(fd);
        return;
    }

    // O_APPEND leaves the offset at end-of-file, so this doubles as the size.
    if (std.c.lseek(fd, 0, std.c.SEEK.END) > size_limit_bytes) {
        _ = std.c.ftruncate(fd, 0);
    }

    g_fd.store(fd, .release);
    log.info("logging to {s}", .{path});
}

pub fn deinit() void {
    const fd = g_fd.swap(-1, .acq_rel);
    if (fd >= 0) _ = std.c.close(fd);
}

/// `std.Options.logFn`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime @intFromEnum(level) > @intFromEnum(log_options.level)) return;

    // Least to most likely to block, so a stalled terminal delays nothing but
    // itself.
    logMacos(level, scope, format, args);
    logFile(level, scope, format, args);
    logStderr(level, scope, format, args);
}

fn logMacos(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!g_sinks.macos) return;

    const logger = scopeLogger(scope);
    const kind = OsLogType.from(level);
    // A level nobody is streaming makes the line free: no formatting, no call.
    // This is what lets debug stay on at ReleaseFast volume.
    if (!os_log_type_enabled(logger, kind)) return;

    // Unified logging stamps time, process, and category itself, so the body
    // goes alone. Truncate rather than split; the last byte is the terminator.
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
    writer.print(format, args) catch {};
    const len = writer.buffered().len;
    buf[len] = 0;
    bw_os_log(logger, kind, buf[0..len :0]);
}

/// One `os_log_t` per scope, created on first use and kept for the life of
/// the process: Apple's guidance is to create loggers once, and the category
/// is what `log stream` filters on. Each comptime scope gets its own static.
/// Observer threads can race the first call; the loser releases its copy.
fn scopeLogger(comptime scope: @EnumLiteral()) *OsLog {
    const Slot = struct {
        var logger: std.atomic.Value(?*OsLog) = .init(null);
    };
    if (Slot.logger.load(.acquire)) |logger| return logger;

    const fresh = os_log_create(subsystem, @tagName(scope).ptr);
    if (Slot.logger.cmpxchgStrong(null, fresh, .acq_rel, .acquire)) |existing| {
        os_release(fresh);
        return existing.?;
    }
    return fresh;
}

fn logFile(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
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

fn logStderr(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Debug is where the volume is. In a Debug build the terminal is the
    // workflow and a stall there is an accepted cost; in every other mode
    // debug goes to the file and unified logging only.
    if (comptime builtin.mode != .Debug and level == .debug) return;
    if (!g_sinks.stderr) return;
    std.log.defaultLog(level, scope, format, args);
}

/// Parse `BOBRWM_LOG`. Unknown names are ignored rather than rejected: a typo
/// must not silence the logging you would then need to find it with.
fn parseSinks(value: []const u8) Sinks {
    var sinks: Sinks = .{};
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " ");
        const enable = !std.mem.startsWith(u8, token, "no-");
        const name = if (enable) token else token["no-".len..];
        inline for (@typeInfo(Sinks).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) @field(sinks, field.name) = enable;
        }
    }
    return sinks;
}

/// Second resolution is useless for the problem these logs exist to solve.
/// A slow window is a few hundred milliseconds of main-thread work, so a whole
/// event drain lands inside one second and its steps become unorderable.
/// strftime has no millisecond conversion, so append the field by hand.
fn writeTimestamp(writer: *std.Io.Writer) void {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return;

    const now: i64 = @intCast(ts.sec);
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return;

    var stamp: [32]u8 = undefined;
    const n = strftime(&stamp, stamp.len, "%Y-%m-%d %H:%M:%S", &tm);
    if (n == 0) return;

    writer.writeAll(stamp[0..n]) catch {};
    writer.print(".{d:0>3} ", .{@as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms}) catch {};
}

test "BOBRWM_LOG toggles sinks by name and leaves the rest at their defaults" {
    try std.testing.expectEqual(Sinks{}, parseSinks(""));
    try std.testing.expectEqual(Sinks{ .stderr = false }, parseSinks("no-stderr"));
    try std.testing.expectEqual(Sinks{ .stderr = false, .macos = false }, parseSinks("no-stderr,no-macos"));
    try std.testing.expectEqual(Sinks{ .macos = false }, parseSinks("no-macos, stderr"));
}

test "BOBRWM_LOG ignores names it does not know" {
    try std.testing.expectEqual(Sinks{}, parseSinks("verbose,no-file"));
}

test "warnings and errors land in the tiers unified logging persists" {
    try std.testing.expectEqual(OsLogType.err, OsLogType.from(.warn));
    try std.testing.expectEqual(OsLogType.fault, OsLogType.from(.err));
    try std.testing.expectEqual(OsLogType.debug, OsLogType.from(.debug));
}
