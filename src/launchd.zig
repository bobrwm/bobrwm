//! Manage bobrwm as a launchd user agent.
//!
//! The Info.plist is embedded in the binary's __TEXT,__info_plist section
//! so macOS binds accessibility grants to CFBundleIdentifier rather than
//! the binary path — no app bundle needed.

const std = @import("std");

const log = std.log.scoped(.launchd);

const label = "com.bobrwm.bobrwm";
const plist_rel = "Library/LaunchAgents/" ++ label ++ ".plist";
const plist_template = @embedFile("launchd_plist");

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

pub fn run(cmd: Command) void {
    const stderr = std.fs.File.stderr();
    const stdout = std.fs.File.stdout();

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
        stdout.writeAll(msg) catch {};
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
        stderr.writeAll(msg) catch {};
    }
}

// ---------------------------------------------------------------------------
// Service commands
// ---------------------------------------------------------------------------

fn serviceInstall() Error!void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (fileExists(path)) return error.AlreadyInstalled;

    try installPlist(path, home);

    var uid_buf: [32]u8 = undefined;
    const domain = domainTarget(&uid_buf) orelse return error.PathTooLong;
    runLaunchctl(&.{ "launchctl", "bootstrap", domain, path });
}

fn serviceUninstall() Error!void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (!fileExists(path)) return error.NotInstalled;
    if (serviceIsRunning()) return error.StillRunning;

    std.fs.cwd().deleteFile(path) catch {};
}

fn serviceStart() Error!void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
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
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
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
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const path = plistPath(&path_buf, home) orelse return error.PathTooLong;

    if (!fileExists(path)) return error.NotInstalled;

    var tbuf: [128]u8 = undefined;
    const target = serviceTarget(&tbuf) orelse return error.PathTooLong;

    runLaunchctl(&.{ "launchctl", "kickstart", "-k", target });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
    var child = std.process.Child.init(
        &.{ "launchctl", "print", target },
        std.heap.page_allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term.Exited == 0;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn installPlist(path: []const u8, home: []const u8) Error!void {
    // Ensure LaunchAgents directory exists
    var agents_buf: [1024]u8 = undefined;
    const agents_dir = std.fmt.bufPrint(&agents_buf, "{s}/Library/LaunchAgents", .{home}) catch
        return error.PathTooLong;
    std.fs.cwd().makePath(agents_dir) catch {};

    const alloc = std.heap.page_allocator;
    const plist = generatePlist(alloc) orelse return error.PlistWrite;
    defer alloc.free(plist);
    writeFile(path, plist) catch return error.PlistWrite;
}

fn ensurePlistUpToDate(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const desired = generatePlist(alloc) orelse return;
    defer alloc.free(desired);

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    if (stat.size != desired.len) {
        writeFile(path, desired) catch {};
        return;
    }

    // Read existing and compare
    const existing = file.readToEndAlloc(alloc, 1024 * 64) catch return;
    defer alloc.free(existing);
    if (!std.mem.eql(u8, existing, desired)) {
        writeFile(path, desired) catch {};
    }
}

fn generatePlist(alloc: std.mem.Allocator) ?[]u8 {
    const exe_path = std.fs.selfExePathAlloc(alloc) catch return null;
    defer alloc.free(exe_path);

    const env_path = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    const user = std.posix.getenv("USER") orelse "unknown";

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

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn runLaunchctl(argv: []const []const u8) void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.spawn() catch |err| {
        log.err("failed to spawn launchctl: {}", .{err});
        return;
    };
    _ = child.wait() catch |err| {
        log.err("failed to wait for launchctl: {}", .{err});
    };
}
