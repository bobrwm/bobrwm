//! Manage bobrwm as a launchd user agent.
//!
//! The Info.plist is embedded in the binary's __TEXT,__info_plist section
//! so macOS binds accessibility grants to CFBundleIdentifier rather than
//! the binary path — no app bundle needed.

const std = @import("std");

const log = std.log.scoped(.launchd);

const label = "com.bobrwm.bobrwm";
const plist_rel = "Library/LaunchAgents/" ++ label ++ ".plist";

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

    switch (cmd) {
        .install => {
            const exe_path = std.fs.selfExePathAlloc(std.heap.page_allocator) catch {
                stderr.writeAll("error: could not determine executable path\n") catch {};
                return;
            };

            const home = std.posix.getenv("HOME") orelse {
                stderr.writeAll("error: HOME not set\n") catch {};
                return;
            };

            // Write launchd plist
            const plist = generatePlist(exe_path);
            var plist_buf: [1024]u8 = undefined;
            const plist_path = std.fmt.bufPrint(&plist_buf, "{s}/{s}", .{ home, plist_rel }) catch {
                stderr.writeAll("error: path too long\n") catch {};
                return;
            };

            var agents_buf: [1024]u8 = undefined;
            const agents_dir = std.fmt.bufPrint(&agents_buf, "{s}/Library/LaunchAgents", .{home}) catch return;
            std.fs.cwd().makePath(agents_dir) catch {};

            writeFile(plist_path, plist) catch {
                stderr.writeAll("error: could not write launchd plist\n") catch {};
                return;
            };

            // Bootstrap the service
            var uid_buf: [32]u8 = undefined;
            const domain = std.fmt.bufPrint(&uid_buf, "gui/{d}", .{std.c.getuid()}) catch return;
            exec_launchctl(&.{ "launchctl", "bootstrap", domain, plist_path });

            stdout.writeAll("installed and loaded " ++ label ++ "\n") catch {};
        },
        .uninstall => {
            var tbuf: [128]u8 = undefined;
            const target = uid_target(&tbuf) orelse {
                stderr.writeAll("error: could not determine launchd target\n") catch {};
                return;
            };

            exec_launchctl(&.{ "launchctl", "bootout", target });

            const home = std.posix.getenv("HOME") orelse {
                stderr.writeAll("error: HOME not set\n") catch {};
                return;
            };

            var plist_buf: [1024]u8 = undefined;
            const plist_path = std.fmt.bufPrint(&plist_buf, "{s}/{s}", .{ home, plist_rel }) catch return;
            std.fs.cwd().deleteFile(plist_path) catch {};

            stdout.writeAll("uninstalled " ++ label ++ "\n") catch {};
        },
        .start => {
            var tbuf: [128]u8 = undefined;
            const target = uid_target(&tbuf) orelse {
                stderr.writeAll("error: could not determine launchd target\n") catch {};
                return;
            };

            exec_launchctl(&.{ "launchctl", "kickstart", target });
            stdout.writeAll("started " ++ label ++ "\n") catch {};
        },
        .stop => {
            var tbuf: [128]u8 = undefined;
            const target = uid_target(&tbuf) orelse {
                stderr.writeAll("error: could not determine launchd target\n") catch {};
                return;
            };

            exec_launchctl(&.{ "launchctl", "kill", "SIGTERM", target });
            stdout.writeAll("stopped " ++ label ++ "\n") catch {};
        },
        .restart => {
            var tbuf: [128]u8 = undefined;
            const target = uid_target(&tbuf) orelse {
                stderr.writeAll("error: could not determine launchd target\n") catch {};
                return;
            };

            exec_launchctl(&.{ "launchctl", "kickstart", "-k", target });
            stdout.writeAll("restarted " ++ label ++ "\n") catch {};
        },
    }
}

fn uid_target(buf: *[128]u8) ?[]const u8 {
    const s = std.fmt.bufPrint(buf, "gui/{d}/{s}", .{ std.c.getuid(), label }) catch return null;
    return s;
}

fn exec_launchctl(argv: []const []const u8) void {
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

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

const plist_template = @embedFile("launchd_plist");

fn generatePlist(exe_path: []const u8) []const u8 {
    const alloc = std.heap.page_allocator;
    const env_path = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    const user = std.posix.getenv("USER") orelse "unknown";

    var result: []const u8 = plist_template;
    result = replace(alloc, result, "{exe_path}", exe_path) orelse return plist_template;
    result = replace(alloc, result, "{env_path}", env_path) orelse return result;
    result = replace(alloc, result, "{user}", user) orelse return result;
    return result;
}

fn replace(alloc: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ?[]const u8 {
    var result = haystack;
    while (std.mem.indexOf(u8, result, needle)) |idx| {
        const before = result[0..idx];
        const after = result[idx + needle.len ..];
        result = std.mem.concat(alloc, u8, &.{ before, replacement, after }) catch return null;
    }
    return result;
}
