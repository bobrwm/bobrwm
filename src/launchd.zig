//! Manage bobrwm as a launchd user agent.
//!
//! The Info.plist is embedded in the binary's __TEXT,__info_plist section
//! so macOS binds accessibility grants to CFBundleIdentifier rather than
//! the binary path — no app bundle needed.

const std = @import("std");
const posix = std.posix;
const osutil = @import("osutil.zig");

const log = std.log.scoped(.launchd);

const label = "com.bobrwm.bobrwm";
const plist_rel = "Library/LaunchAgents/" ++ label ++ ".plist";
const plist_template = @embedFile("launchd_plist");

// Zig 0.16 reworked std.process.Child to require an Io instance for spawn
// and wait. The release notes explicitly endorse "go lower" (libc) as an
// alternative to "go higher" (std.Io); std.c re-exports the libc syscalls
// we need. execvp is not surfaced by std.c, so declare just that locally.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const Error = error{
    HomeNotSet,
    PathTooLong,
    ExePath,
    PlistWrite,
    LaunchctlFailed,
    AlreadyInstalled,
    NotInstalled,
    StillRunning,
};

pub const Command = enum {
    install,
    uninstall,
    start,
    stop,
    restart,
};

fn writeFd(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return;
        remaining = remaining[@intCast(n)..];
    }
}

pub fn run(cmd: Command) void {
    const result: Error!void = switch (cmd) {
        .install => serviceInstall(),
        .uninstall => serviceUninstall(),
        .start => serviceStart(),
        .stop => serviceStop(),
        .restart => serviceRestart(),
    };

    if (result) |_| {
        const msg = switch (cmd) {
            .install => "service installed.\n",
            .uninstall => "service uninstalled.\n",
            .start => "service started.\n",
            .stop => "service stopped.\n",
            .restart => "service restarted.\n",
        };
        writeFd(posix.STDOUT_FILENO, msg);
    } else |err| {
        const msg = switch (err) {
            error.HomeNotSet => "error: HOME not set\n",
            error.PathTooLong => "error: path too long\n",
            error.ExePath => "error: could not determine executable path\n",
            error.PlistWrite => "error: could not write launchd plist\n",
            error.LaunchctlFailed => "error: launchctl command failed\n",
            error.AlreadyInstalled => "error: service is already installed\n",
            error.NotInstalled => "error: service is not installed\n",
            error.StillRunning => "error: service is still running; stop it first\n",
        };
        writeFd(posix.STDERR_FILENO, msg);
    }
}

// Service commands

fn serviceInstall() Error!void {
    const home = osutil.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (fileExists(path)) return error.AlreadyInstalled;

    try installPlist(path, home);

    var uid_buf: [32]u8 = undefined;
    const domain = domainTarget(&uid_buf) orelse return error.PathTooLong;
    runLaunchctl(&.{ "launchctl", "bootstrap", domain, path });
}

fn serviceUninstall() Error!void {
    const home = osutil.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (!fileExists(path)) return error.NotInstalled;
    if (serviceIsRunning()) return error.StillRunning;

    deleteFile(path);
}

fn serviceStart() Error!void {
    const home = osutil.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    // Auto-install if missing
    if (!fileExists(path)) {
        try installPlist(path, home);
    } else {
        // Update plist if stale
        ensurePlistUpToDate(path);
    }

    var tbuf: [128]u8 = undefined;
    const target = serviceTarget(&tbuf) orelse return error.PathTooLong;
    var uid_buf: [32]u8 = undefined;
    const domain = domainTarget(&uid_buf) orelse return error.PathTooLong;

    if (!serviceIsRunning()) {
        runLaunchctl(&.{ "launchctl", "enable", target });
        runLaunchctl(&.{ "launchctl", "bootstrap", domain, path });
    }

    runLaunchctl(&.{ "launchctl", "kickstart", target });
}

fn serviceStop() Error!void {
    const home = osutil.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (!fileExists(path)) return error.NotInstalled;

    var tbuf: [128]u8 = undefined;
    const target = serviceTarget(&tbuf) orelse return error.PathTooLong;
    var uid_buf: [32]u8 = undefined;
    const domain = domainTarget(&uid_buf) orelse return error.PathTooLong;

    if (serviceIsRunning()) {
        runLaunchctl(&.{ "launchctl", "bootout", domain, path });
        runLaunchctl(&.{ "launchctl", "disable", target });
    } else {
        runLaunchctl(&.{ "launchctl", "kill", "SIGTERM", target });
    }
}

fn serviceRestart() Error!void {
    var path_buf: [1024]u8 = undefined;
    const home = osutil.getenv("HOME") orelse return error.HomeNotSet;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (!fileExists(path)) return error.NotInstalled;

    var tbuf: [128]u8 = undefined;
    const target = serviceTarget(&tbuf) orelse return error.PathTooLong;

    runLaunchctl(&.{ "launchctl", "kickstart", "-k", target });
}

// Helpers

fn plistPath(buf: *[1024]u8, home: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, plist_rel }) catch null;
}

fn serviceTarget(buf: *[128]u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "gui/{d}/{s}", .{ std.c.getuid(), label }) catch null;
}

fn domainTarget(buf: *[32]u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "gui/{d}", .{std.c.getuid()}) catch null;
}

fn serviceIsRunning() bool {
    var tbuf: [128]u8 = undefined;
    const target = serviceTarget(&tbuf) orelse return false;
    // Suppress launchctl print's noisy output by redirecting both fds to
    // /dev/null in the child.
    return runProcess(&.{ "launchctl", "print", target }, .silent) == 0;
}

fn fileExists(path: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const path_z = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(path_z);
    return osutil.pathExists(path_z);
}

fn deleteFile(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const path_z = alloc.dupeZ(u8, path) catch return;
    defer alloc.free(path_z);
    osutil.deleteFile(path_z);
}

fn writeFile(path: []const u8, data: []const u8) Error!void {
    const alloc = std.heap.page_allocator;
    const path_z = alloc.dupeZ(u8, path) catch return error.PlistWrite;
    defer alloc.free(path_z);
    if (!osutil.writeFile(path_z, data)) return error.PlistWrite;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const path_z = alloc.dupeZ(u8, path) catch return null;
    defer alloc.free(path_z);
    return osutil.readFileAlloc(alloc, path_z, max);
}

fn fileSize(path: []const u8) ?usize {
    const alloc = std.heap.page_allocator;
    const data = readFile(alloc, path, 1024 * 64) orelse return null;
    defer alloc.free(data);
    return data.len;
}

fn installPlist(path: []const u8, home: []const u8) Error!void {
    // Ensure LaunchAgents directory exists
    const alloc = std.heap.page_allocator;
    var agents_buf: [1024]u8 = undefined;
    const agents_dir = std.fmt.bufPrint(&agents_buf, "{s}/Library/LaunchAgents", .{home}) catch
        return error.PathTooLong;
    _ = osutil.makePath(alloc, agents_dir);

    const plist = generatePlist(alloc) orelse return error.PlistWrite;
    defer alloc.free(plist);
    try writeFile(path, plist);
}

fn ensurePlistUpToDate(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const desired = generatePlist(alloc) orelse return;
    defer alloc.free(desired);

    const existing = readFile(alloc, path, 1024 * 64) orelse {
        writeFile(path, desired) catch {};
        return;
    };
    defer alloc.free(existing);

    if (!std.mem.eql(u8, existing, desired)) {
        writeFile(path, desired) catch {};
    }
}

fn selfExePathAlloc(alloc: std.mem.Allocator) ?[]u8 {
    var buf: [4096]u8 = undefined;
    var n: u32 = buf.len;
    if (std.c._NSGetExecutablePath(&buf, &n) != 0) return null;
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse return null;
    const out = alloc.alloc(u8, len) catch return null;
    @memcpy(out, buf[0..len]);
    return out;
}

fn generatePlist(alloc: std.mem.Allocator) ?[]u8 {
    const exe_path = selfExePathAlloc(alloc) orelse return null;
    defer alloc.free(exe_path);

    const env_path = osutil.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    const user = osutil.getenv("USER") orelse "unknown";

    var result = std.mem.replaceOwned(u8, alloc, plist_template, "{exe_path}", exe_path) catch return null;
    errdefer alloc.free(result);

    const with_env = std.mem.replaceOwned(u8, alloc, result, "{env_path}", env_path) catch return null;
    alloc.free(result);
    result = with_env;

    const with_user = std.mem.replaceOwned(u8, alloc, result, "{user}", user) catch return null;
    alloc.free(result);
    result = with_user;

    std.debug.assert(result.len > 0);
    return result;
}

const StdioMode = enum { inherit, silent };

/// Spawn `argv[0]` with `argv` via fork+execvp+waitpid. Returns the child's
/// exit status, or a non-zero sentinel on failure.
fn runProcess(argv: []const []const u8, stdio: StdioMode) c_int {
    std.debug.assert(argv.len >= 1);
    std.debug.assert(argv.len < 32);

    // Build a NUL-terminated argv array on the stack.
    const alloc = std.heap.page_allocator;
    var z_args: [32]?[*:0]const u8 = undefined;
    var dup_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < dup_count) : (i += 1) {
            if (z_args[i]) |p| alloc.free(std.mem.span(p));
        }
    }
    for (argv, 0..) |a, i| {
        const z = alloc.dupeZ(u8, a) catch return -1;
        z_args[i] = z.ptr;
        dup_count += 1;
    }
    z_args[argv.len] = null;

    const pid = std.c.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        // Child
        if (stdio == .silent) {
            const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
            if (devnull >= 0) {
                _ = std.c.dup2(devnull, posix.STDOUT_FILENO);
                _ = std.c.dup2(devnull, posix.STDERR_FILENO);
                _ = std.c.close(devnull);
            }
        }
        _ = execvp(z_args[0].?, @ptrCast(&z_args));
        std.c._exit(127);
    }

    // Parent
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    // POSIX exit status: low 7 bits = signal, bit 7 = core, next 8 = exit code.
    // Match WEXITSTATUS for normal termination; non-normal exit returns the
    // raw status which is non-zero.
    if ((status & 0x7f) == 0) {
        return (status >> 8) & 0xff;
    }
    return status;
}

fn runLaunchctl(argv: []const []const u8) void {
    const rc = runProcess(argv, .inherit);
    if (rc != 0) {
        log.err("launchctl exited rc={d}", .{rc});
    }
}
