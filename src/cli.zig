//! The `bobrwm` client CLI.
//!
//! This is the root module of a binary separate from the window manager
//! itself: it parses arguments, prints help and version, dispatches service
//! management, and forwards everything else to the running daemon over the
//! IPC socket. Keeping it out of the daemon binary means the client links
//! none of AppKit, ApplicationServices or Carbon, so a `bobrwm query windows`
//! does not pay to load the framework graph the window manager needs.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const log_options = @import("log_options.zig");
const osutil = @import("osutil.zig");

pub const std_options = std.Options{
    .log_level = log_options.level,
};

const log = std.log.scoped(.cli);

// Parse result

pub const Result = union(enum) {
    help,
    version,
    /// Forward an IPC command string to the running daemon.
    ipc: []const u8,
};

/// Parse process arguments into a CLI result.
/// `cmd_buf` is scratch space for assembling the IPC command string from
/// positional arguments.
pub fn parse(process_args: std.process.Args, cmd_buf: []u8) Result {
    var pos: usize = 0;
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        // Flags: --help / -h
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }

        // Flags: --version
        if (std.mem.eql(u8, arg, "--version")) {
            return .version;
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

    // A bare invocation no longer starts the window manager; that is the app
    // bundle's job.
    if (pos == 0) return .help;

    const command = cmd_buf[0..pos];

    // Check for known local commands
    if (std.mem.eql(u8, command, "help")) {
        return .help;
    }
    if (std.mem.eql(u8, command, "version")) {
        return .version;
    }

    // Everything else is an IPC command
    return .{ .ipc = command };
}

// Action dispatch

/// Run a parsed CLI result and return the process exit code.
pub fn run(result: Result) u8 {
    switch (result) {
        .help => {
            printHelp();
            return 0;
        },
        .version => {
            printVersion();
            return 0;
        },
        .ipc => |cmd| return runClient(cmd),
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var cmd_buf: [512]u8 = undefined;
    const exit_code = run(parse(init.args, &cmd_buf));
    if (exit_code != 0) std.process.exit(exit_code);
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
    \\Window Commands (IPC):
    \\  retile                    Re-tile all windows on the active workspace
    \\  reload-config             Reload config, keeping current config on failure
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
    \\  -h, --help                Show this help message
    \\  --version                 Show version information
    \\
    \\Configuration is read from $XDG_CONFIG_HOME/bobrwm/config.zon
    \\or ~/.config/bobrwm/config.zon by default.
    \\
;

// Version

fn printVersion() void {
    writeStdout("bobrwm " ++ build_options.version ++ "\n");
}

// IPC client (sends command to running daemon)

fn runClient(cmd: []const u8) u8 {
    const started_ns = osutil.nanoTimestamp();
    var response_bytes: usize = 0;
    var response_is_error = false;
    var transport_failed = false;

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}, 0) catch {
        writeStderr("error: socket path too long\n");
        return 1;
    };

    // Zig 0.16 removed the std.posix.{socket,connect,write,close,shutdown}
    // wrappers as part of "posix and os.windows removals"; the release notes
    // direct callers to "go higher" (std.Io) or "go lower" (libc). Going
    // lower keeps this CLI client self-contained without an Io instance.
    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) {
        writeStderr("error: could not create socket\n");
        return 1;
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
        return 1;
    }

    if (std.c.write(fd, cmd.ptr, cmd.len) < 0) {
        writeStderr("error: write failed\n");
        return 1;
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
            transport_failed = true;
            break;
        };
        if (ready == 0) {
            writeStderr("error: IPC response timeout\n");
            log.warn("ipc client timeout waiting for response cmd={s}", .{cmd});
            transport_failed = true;
            break;
        }

        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch {
            writeStderr("error: IPC response read failed\n");
            transport_failed = true;
            break;
        };
        if (n == 0) break;
        if (response_bytes == 0) response_is_error = std.mem.startsWith(u8, buf[0..n], "err:");
        response_bytes += n;
        if (response_is_error) {
            writeStderr(buf[0..n]);
        } else {
            writeStdout(buf[0..n]);
        }
    }

    const elapsed_ms = @divTrunc(osutil.nanoTimestamp() - started_ns, std.time.ns_per_ms);
    log.debug("[trace] ipc client completed bytes={} elapsed_ms={}", .{ response_bytes, elapsed_ms });
    return if (transport_failed or response_is_error) 1 else 0;
}
