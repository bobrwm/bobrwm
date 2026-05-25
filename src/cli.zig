//! Unified CLI for bobrwm.
//!
//! Handles argument parsing, help/version output, service management dispatch,
//! and IPC client communication with the running daemon. All CLI concerns live
//! here so main.zig only needs to call `cli.run()`.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const launchd = @import("launchd.zig");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.cli);

// Action — locally handled commands (everything else is IPC)

const Action = enum {
    help,
    version,
    service,
};

// Parse result

pub const Result = union(enum) {
    /// Start the daemon, optionally with an explicit config path.
    daemon: struct { config_path: ?[]const u8 = null },
    /// Run a local action (help, version, service) and exit.
    action: struct { kind: Action, tail: ?[]const u8 = null, config_path: ?[]const u8 = null },
    /// Forward an IPC command string to the running daemon.
    ipc: []const u8,
};

/// Parse process arguments into a CLI result.
/// `cmd_buf` is scratch space for assembling the IPC command string from
/// positional arguments.
pub fn parse(process_args: std.process.Args, cmd_buf: []u8) Result {
    var config_path: ?[]const u8 = null;
    var pos: usize = 0;
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        // Flags: -c / --config
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
            continue;
        }

        // Flags: --help / -h
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{ .action = .{ .kind = .help, .config_path = config_path } };
        }

        // Flags: --version
        if (std.mem.eql(u8, arg, "--version")) {
            return .{ .action = .{ .kind = .version } };
        }

        // Positional arg — accumulate into cmd_buf
        if (pos > 0 and pos < cmd_buf.len) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..copy_len], arg[0..copy_len]);
        pos += copy_len;
    }

    if (pos == 0) {
        return .{ .daemon = .{ .config_path = config_path } };
    }

    const command = cmd_buf[0..pos];

    // Check for known local commands
    if (std.mem.eql(u8, command, "help")) {
        return .{ .action = .{ .kind = .help, .config_path = config_path } };
    }
    if (std.mem.eql(u8, command, "version")) {
        return .{ .action = .{ .kind = .version } };
    }
    if (std.mem.eql(u8, command, "service") or std.mem.startsWith(u8, command, "service ")) {
        const tail: ?[]const u8 = if (command.len > "service ".len)
            command["service ".len..]
        else
            null;
        return .{ .action = .{ .kind = .service, .tail = tail, .config_path = config_path } };
    }

    // Everything else is an IPC command
    return .{ .ipc = command };
}

// Action dispatch

/// Run a parsed CLI result. Returns `true` if main should exit (action or
/// IPC handled), `false` if the daemon should start.
pub fn run(result: Result) bool {
    switch (result) {
        .daemon => return false,
        .action => |a| {
            switch (a.kind) {
                .help => printHelp(),
                .version => printVersion(),
                .service => runService(a.tail),
            }
            return true;
        },
        .ipc => |cmd| {
            runClient(cmd);
            return true;
        },
    }
}

/// Extract the config path from any result variant.
pub fn configPath(result: Result) ?[]const u8 {
    return switch (result) {
        .daemon => |d| d.config_path,
        .action => |a| a.config_path,
        .ipc => null,
    };
}

// Help

/// Write to a fixed file descriptor via libc; `std.fs.File`'s writer-based
/// API in Zig 0.16 requires an `Io` instance which we don't thread through
/// CLI helpers.
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

fn printHelp() void {
    writeStdout(help_text);
}

const help_text =
    \\Usage: bobrwm [command] [options]
    \\
    \\A tiling window manager for macOS.
    \\
    \\General Commands:
    \\  help                     Show this help message
    \\  version                  Show version information
    \\
    \\Service Commands:
    \\  service install           Install the launchd agent
    \\  service uninstall         Uninstall the launchd agent
    \\  service start             Start the service
    \\  service stop              Stop the service
    \\  service restart           Restart the service
    \\
    \\Window Commands (IPC):
    \\  retile                    Re-tile all windows on the active workspace
    \\  toggle-split              Cycle BSP split mode (auto, horizontal, vertical)
    \\  focus <direction>         Focus window in direction (left, right, up, down)
    \\  focus-workspace <n|prev|next>
    \\                            Focus workspace by number or adjacent direction
    \\  move-to-workspace <n>     Move focused window to workspace
    \\  move-to-display <n>       Move focused window to display
    \\  move-workspace-to-display <n|next|prev>
    \\                            Move active workspace to another display
    \\
    \\BSP Layout Commands (IPC):
    \\  bsp ratio rel <delta>     Adjust focused split ratio relatively
    \\  bsp ratio abs <ratio>     Set focused split ratio absolutely
    \\  bsp insert-mode <mode>    Set insert mode (split, stack)
    \\  bsp insert-point <point>  Set insertion point (focused, first, last, min_depth)
    \\  bsp mirror <axis>         Mirror layout (horizontal, vertical)
    \\  bsp equalize              Reset all split ratios to default
    \\  bsp balance               Balance the BSP tree
    \\  bsp rotate <degrees>      Rotate layout (90, 180, 270)
    \\
    \\Query Commands (IPC):
    \\  query windows [--json]    List windows on the active workspace
    \\  query workspaces [--json] List all workspaces
    \\  query displays [--json]   List connected displays
    \\  query apps [--json]       List managed applications
    \\
    \\Options:
    \\  -c, --config <path>       Use a specific config file
    \\  -h, --help                Show this help message
    \\  --version                 Show version information
    \\
    \\Running without arguments starts the daemon.
    \\Configuration is read from $XDG_CONFIG_HOME/bobrwm/config.zon
    \\or ~/.config/bobrwm/config.zon by default.
    \\
;

// Version

fn printVersion() void {
    writeStdout("bobrwm " ++ build_options.version ++ "\n");
}

// Service

fn runService(tail: ?[]const u8) void {
    const sub = tail orelse {
        writeStderr(
            \\Usage: bobrwm service <action>
            \\
            \\Actions:
            \\  install      Install the launchd agent
            \\  uninstall    Uninstall the launchd agent
            \\  start        Start the service
            \\  stop         Stop the service
            \\  restart      Restart the service
            \\
        );
        return;
    };

    const cmd = std.meta.stringToEnum(launchd.Command, sub) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown service action '{s}'\n", .{sub}) catch return;
        writeStderr(msg);
        return;
    };

    launchd.run(cmd);
}

// IPC client (sends command to running daemon)

fn runClient(cmd: []const u8) void {
    const started_ns = osutil.nanoTimestamp();
    var response_bytes: usize = 0;

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0) catch {
        writeStderr("error: socket path too long\n");
        return;
    };

    // Zig 0.16 removed the std.posix.{socket,connect,write,close,shutdown}
    // wrappers as part of "posix and os.windows removals"; the release notes
    // direct callers to "go higher" (std.Io) or "go lower" (libc). Going
    // lower keeps this CLI client self-contained without an Io instance.
    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) {
        writeStderr("error: could not create socket\n");
        return;
    }
    defer _ = std.c.close(fd);
    const no_sigpipe: i32 = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&no_sigpipe)) catch |err| {
        log.warn("ipc client SO_NOSIGPIPE failed: {}", .{err});
    };

    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    if (path.len < addr.path.len) addr.path[path.len] = 0;

    log.debug("[trace] ipc client connecting path={s} cmd={s}", .{ path, cmd });

    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) {
        writeStderr("error: bobrwm is not running\n");
        return;
    }

    if (std.c.write(fd, cmd.ptr, cmd.len) < 0) {
        writeStderr("error: write failed\n");
        return;
    }
    _ = std.c.shutdown(fd, std.c.SHUT.WR);

    while (true) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, 2000) catch {
            writeStderr("error: IPC poll failed\n");
            break;
        };
        if (ready == 0) {
            writeStderr("error: IPC response timeout\n");
            log.warn("ipc client timeout waiting for response cmd={s}", .{cmd});
            break;
        }

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        response_bytes += n;
        writeStdout(buf[0..n]);
    }

    const elapsed_ms = @divTrunc(osutil.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] ipc client completed bytes={} elapsed_ms={}", .{ response_bytes, elapsed_ms });
}
