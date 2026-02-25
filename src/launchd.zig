//! Manage bobrwm as a launchd user agent.
//!
//! Provides install, uninstall, start, stop, and restart operations
//! using the modern launchctl bootstrap/bootout API.

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

            const plist = generatePlist(exe_path);
            const home = std.posix.getenv("HOME") orelse {
                stderr.writeAll("error: HOME not set\n") catch {};
                return;
            };

            var path_buf: [1024]u8 = undefined;
            const plist_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, plist_rel }) catch {
                stderr.writeAll("error: path too long\n") catch {};
                return;
            };

            // Ensure LaunchAgents directory exists
            var dir_buf: [1024]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/Library/LaunchAgents", .{home}) catch {
                stderr.writeAll("error: path too long\n") catch {};
                return;
            };

            std.fs.cwd().makePath(dir_path) catch {};
            const file = std.fs.cwd().createFile(plist_path, .{}) catch {
                stderr.writeAll("error: could not create plist\n") catch {};
                return;
            };

            defer file.close();
            file.writeAll(plist) catch {
                stderr.writeAll("error: could not write plist\n") catch {};
                return;
            };

            // Bootstrap the service
            var uid_buf: [32]u8 = undefined;
            const domain = std.fmt.bufPrint(&uid_buf, "gui/{d}", .{std.c.getuid()}) catch return;
            exec_launchctl(&.{ "launchctl", "bootstrap", domain, plist_path });

            stdout.writeAll("installed and loaded " ++ label ++ "\n") catch {};
        },
        .uninstall => {
            // Bootout the service
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
            var path_buf: [1024]u8 = undefined;
            const plist_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, plist_rel }) catch return;
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

/// Generic harness to execute launchctl commands
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

const plist_template = @embedFile("launchd_plist");
const exe_path_placeholder = "{exe_path}";

fn generatePlist(exe_path: []const u8) []const u8 {
    const alloc = std.heap.page_allocator;
    const idx = std.mem.indexOf(u8, plist_template, exe_path_placeholder) orelse return plist_template;
    const before = plist_template[0..idx];
    const after = plist_template[idx + exe_path_placeholder.len ..];
    return std.mem.concat(alloc, u8, &.{ before, exe_path, after }) catch plist_template;
}
