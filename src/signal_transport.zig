//! Async-signal-safe bridge from POSIX termination signals to the main queue.
//!
//! The process signal handler only writes one byte to a nonblocking pipe. A
//! dispatch read source drains it and invokes application shutdown on the main
//! queue, where AppKit and window restoration are safe.

const std = @import("std");
const posix = std.posix;
const c = @import("c");
const cg_extra = @import("cg_extra");

const StopFn = *const fn () void;

var g_source: c.dispatch_source_t = null;
var g_read_fd: c_int = -1;
var g_write_fd: c_int = -1;
var g_stop: ?StopFn = null;

const graceful_signals = [_]posix.SIG{
    posix.SIG.INT, posix.SIG.TERM,
    posix.SIG.HUP, posix.SIG.QUIT,
};

/// Create the self-pipe, attach its main-queue reader, and install handlers.
pub fn init(stop: StopFn) !void {
    std.debug.assert(g_source == null);
    std.debug.assert(g_read_fd < 0 and g_write_fd < 0);
    std.debug.assert(g_stop == null);

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SignalPipeCreateFailed;
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
    try configurePipeFd(fds[0]);
    try configurePipeFd(fds[1]);

    const source = c.dispatch_source_create(
        cg_extra.DISPATCH_SOURCE_TYPE_READ(),
        @intCast(fds[0]),
        0,
        cg_extra.dispatch_get_main_queue(),
    ) orelse return error.SignalSourceCreateFailed;

    g_read_fd = fds[0];
    g_write_fd = fds[1];
    g_stop = stop;
    g_source = source;
    c.dispatch_source_set_event_handler_f(source, sourceReady);
    c.dispatch_resume(.{ ._ds = source });
    installHandlers();
}

/// Restore default handlers, release the dispatch source, and close the pipe.
pub fn deinit() void {
    uninstallHandlers();

    if (g_source) |source| {
        c.dispatch_source_cancel(source);
        c.dispatch_release(.{ ._ds = source });
        g_source = null;
    }
    if (g_read_fd >= 0) {
        const fd = g_read_fd;
        g_read_fd = -1;
        _ = std.c.close(fd);
    }
    if (g_write_fd >= 0) {
        const fd = g_write_fd;
        g_write_fd = -1;
        _ = std.c.close(fd);
    }
    g_stop = null;
}

fn configurePipeFd(fd: c_int) !void {
    if (c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK) < 0) return error.SignalPipeConfigureFailed;
    if (c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0) return error.SignalPipeConfigureFailed;
}

fn gracefulSignalHandler(sig: posix.SIG) callconv(.c) void {
    const byte: u8 = @intCast(@intFromEnum(sig));
    _ = c.write(g_write_fd, &byte, 1);
}

fn sourceReady(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    if (g_read_fd < 0) return;

    var buf: [64]u8 = undefined;
    while (c.read(g_read_fd, &buf, buf.len) > 0) {}
    g_stop.?();
}

fn installHandlers() void {
    for (graceful_signals) |sig| {
        var action: posix.Sigaction = .{
            .handler = .{ .handler = gracefulSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(sig, &action, null);
    }
}

fn uninstallHandlers() void {
    for (graceful_signals) |sig| {
        var action: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig, &action, null);
    }
}
