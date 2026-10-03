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
const runtime_paths = @import("runtime_paths.zig");
const config = @import("config.zig");
const config_file = @import("config_file.zig");
const config_format = @import("config_format.zig");
const help_strings = @import("help_strings");
const Command = @import("command.zig").Command;

pub const std_options = std.Options{
    .log_level = log_options.level,
    // `show-config` loads the config in-process; keep its progress lines out
    // of the terminal but still surface parse and validation errors.
    .log_scope_levels = &.{.{ .scope = .config, .level = .warn }},
};

const log = std.log.scoped(.cli);

// Parse result

pub const Result = union(enum) {
    /// General help, or help for one command.
    help: ?Command,
    version,
    show_config: ShowConfigOptions,
    migrate_config,
    list_actions: ListActionsOptions,
    /// A flag a local command does not accept.
    invalid_flag: struct { command: Command, flag: []const u8 },
    /// Forward an IPC command string to the running daemon.
    ipc: []const u8,
};

pub const ShowConfigOptions = struct {
    default: bool = false,
    docs: bool = false,
};

pub const ListActionsOptions = struct {
    docs: bool = false,
};

/// Parse arguments, without the program name, into a CLI result. `args` is
/// anything with a `next() ?[]const u8`. `cmd_buf` is scratch space for
/// assembling the IPC command string from positional arguments.
pub fn parse(args: anytype, cmd_buf: []u8) Result {
    const first = args.next() orelse return .{ .help = null };
    if (isHelpFlag(first)) return .{ .help = null };
    if (std.mem.eql(u8, first, "--version")) return .version;
    if (Command.parse(first)) |command| return parseCommand(command, args);
    return parseIpc(first, args, cmd_buf);
}

fn parseCommand(command: Command, args: anytype) Result {
    var result: Result = switch (command) {
        .help => .{ .help = null },
        .version => .version,
        .@"show-config" => .{ .show_config = .{} },
        .@"migrate-config" => .migrate_config,
        .@"list-actions" => .{ .list_actions = .{} },
    };
    while (args.next()) |arg| {
        if (isHelpFlag(arg)) return .{ .help = command };
        const known = switch (result) {
            .show_config => |*opts| setFlag(ShowConfigOptions, opts, arg),
            .list_actions => |*opts| setFlag(ListActionsOptions, opts, arg),
            else => false,
        };
        if (!known) return .{ .invalid_flag = .{ .command = command, .flag = arg } };
    }
    return result;
}

/// Set the bool field named by a `--<field>` flag. Returns false for any
/// other argument.
fn setFlag(comptime Options: type, opts: *Options, arg: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, "--")) return false;
    inline for (@typeInfo(Options).@"struct".fields) |field| {
        if (std.mem.eql(u8, arg[2..], field.name)) {
            @field(opts, field.name) = true;
            return true;
        }
    }
    return false;
}

fn parseIpc(first: []const u8, args: anytype, cmd_buf: []u8) Result {
    var pos: usize = 0;
    var next: ?[]const u8 = first;
    while (next) |arg| : (next = args.next()) {
        if (isHelpFlag(arg)) return .{ .help = null };

        // Positional arg — accumulate into cmd_buf
        if (pos > 0 and pos < cmd_buf.len) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..copy_len], arg[0..copy_len]);
        pos += copy_len;
    }
    return .{ .ipc = cmd_buf[0..pos] };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

// Action dispatch

/// Run a parsed CLI result and return the process exit code.
pub fn run(result: Result) u8 {
    switch (result) {
        .help => |command| {
            if (command) |c| printCommandHelp(c) else printHelp();
            return 0;
        },
        .version => {
            printVersion();
            return 0;
        },
        .show_config => |opts| return showConfig(opts),
        .migrate_config => return migrateConfig(),
        .list_actions => |opts| return listActions(opts),
        .invalid_flag => |invalid| {
            var buf: [256]u8 = undefined;
            writeStderr(std.fmt.bufPrint(&buf, "error: unknown flag {s} for {s}; see bobrwm {s} --help\n", .{
                invalid.flag,
                @tagName(invalid.command),
                @tagName(invalid.command),
            }) catch "error: unknown flag\n");
            return 2;
        },
        .ipc => |cmd| return runClient(cmd),
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var cmd_buf: [512]u8 = undefined;
    var args = init.args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name
    const exit_code = run(parse(&args, &cmd_buf));
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

fn printStdout(comptime format: []const u8, args: anytype) void {
    printFd(std.posix.STDOUT_FILENO, format, args);
}

fn printStderr(comptime format: []const u8, args: anytype) void {
    printFd(std.posix.STDERR_FILENO, format, args);
}

fn printFd(fd: c_int, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {};
    writeFd(fd, writer.buffered());
}

fn printHelp() void {
    writeStdout(help_text);
}

fn printCommandHelp(command: Command) void {
    switch (command) {
        inline else => |c| writeStdout(@field(help_strings.Command, @tagName(c)) ++ "\n"),
    }
}

const help_text =
    \\Usage: bobrwm [command] [options]
    \\
    \\A tiling window manager for macOS.
    \\
    \\General Commands:
    \\  help                      Show this help message
    \\  version                   Show version information
    \\  show-config [--default] [--docs]
    \\                            Print your config changes, or every default
    \\  migrate-config            Convert an old config.zon to the current format
    \\  list-actions [--docs]     List keybind actions
    \\
    \\Window Commands (IPC):
    \\  retile                    Re-tile visible workspaces on all displays
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
    \\Configuration is read from $XDG_CONFIG_HOME/bobrwm/config or
    \\~/.config/bobrwm/config, one `key = value` per line. To see every
    \\option with its documentation, run:
    \\
    \\  bobrwm show-config --default --docs
    \\
    \\Run `bobrwm <command> --help` for details on show-config,
    \\migrate-config, list-actions, help, or version.
    \\
;

// Config and action reference

fn showConfig(opts: ShowConfigOptions) u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg: config.Config = if (opts.default) .{} else loadUserConfig(alloc) orelse return 1;
    var out: std.Io.Writer.Allocating = .init(alloc);
    const format: config_format.Options = .{ .changes_only = !opts.default };
    const written = if (opts.docs)
        config_format.write(&out.writer, &cfg, help_strings.Config, format)
    else
        config_format.write(&out.writer, &cfg, null, format);
    written catch {
        writeStderr("error: out of memory\n");
        return 1;
    };
    writeStdout(out.written());
    return 0;
}

/// The config the window manager would load. A missing file means defaults,
/// like the daemon; an invalid one is an error, since printing defaults then
/// would misrepresent what is running. `loadFromPath` logs the diagnostics.
fn loadUserConfig(alloc: std.mem.Allocator) ?config.Config {
    const path = config.resolvePath(alloc, null) catch {
        writeStderr("error: cannot resolve config path: HOME is not set\n");
        return null;
    };
    if (!osutil.pathExists(path)) {
        config.warnIfOnlyLegacyExists(alloc, path);
        return .{};
    }
    return config.loadFromPath(alloc, path) orelse {
        writeStderr("error: config file is invalid; see the errors above\n");
        return null;
    };
}

fn migrateConfig() u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = config.resolvePath(alloc, null) catch {
        writeStderr("error: cannot resolve config path: HOME is not set\n");
        return 1;
    };
    const legacy = config.legacyPath(alloc, path) catch return outOfMemory();
    if (osutil.pathExists(path)) {
        printStderr("error: {s} already exists; not overwriting it\n", .{path});
        return 1;
    }
    const source = osutil.readFileAllocSentinel(alloc, legacy, 1024 * 1024) orelse {
        printStderr("error: no config to migrate at {s}\n", .{legacy});
        return 1;
    };

    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const cfg = config_file.fromLegacyZon(alloc, source, &zon_diagnostics) catch |err| {
        if (err == error.OutOfMemory) return outOfMemory();
        printStderr("error: cannot read {s}:\n{f}\n", .{ legacy, zon_diagnostics });
        return 1;
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    out.writer.print("# Converted from {s} by `bobrwm migrate-config`.\n" ++
        "# Run `bobrwm show-config --default --docs` to see every option.\n\n", .{legacy}) catch return outOfMemory();
    config_format.write(&out.writer, &cfg, null, .{ .changes_only = true }) catch return outOfMemory();
    const path_z = alloc.dupeZ(u8, path) catch return outOfMemory();
    if (!osutil.writeFile(path_z, out.written())) {
        printStderr("error: cannot write {s}\n", .{path});
        return 1;
    }

    // Load what was written so any value the old format accepted but the
    // new checks reject shows up now, with its line, rather than at startup.
    if (config.loadFromPath(alloc, path) == null) {
        printStderr("Wrote {s}, but it has the errors above; fix them before reloading bobrwm.\n", .{path});
        return 1;
    }
    printStdout("Wrote {s}. bobrwm no longer reads {s}; delete it once the new config looks right.\n", .{ path, legacy });
    return 0;
}

fn outOfMemory() u8 {
    writeStderr("error: out of memory\n");
    return 1;
}

fn listActions(opts: ListActionsOptions) u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    writeActions(&out.writer, opts.docs) catch {
        writeStderr("error: out of memory\n");
        return 1;
    };
    writeStdout(out.written());
    return 0;
}

fn writeActions(writer: *std.Io.Writer, docs: bool) std.Io.Writer.Error!void {
    const Actions = help_strings.KeybindAction;
    inline for (Actions.keys) |key| {
        try writer.writeAll(key ++ "\n");
        if (docs) {
            var lines = std.mem.splitScalar(u8, @field(Actions, key), '\n');
            while (lines.next()) |line| {
                if (line.len == 0) try writer.writeAll("\n") else try writer.print("  {s}\n", .{line});
            }
            try writer.writeAll("\n");
        }
    }
}

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
    const path = runtime_paths.socketPathBuf(&path_buf) catch {
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
    if (path.len >= addr.path.len) {
        writeStderr("error: socket path too long\n");
        return 1;
    }
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    addr.path[path.len] = 0;

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

const SliceArgs = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceArgs) ?[]const u8 {
        if (self.index == self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

fn testParse(items: []const []const u8, cmd_buf: []u8) Result {
    var args: SliceArgs = .{ .items = items };
    return parse(&args, cmd_buf);
}

test "parse local commands and their flags" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Result{ .help = null }, testParse(&.{}, &buf));
    try std.testing.expectEqual(Result{ .help = null }, testParse(&.{"help"}, &buf));
    try std.testing.expectEqual(Result.version, testParse(&.{"--version"}, &buf));
    try std.testing.expectEqual(
        Result{ .show_config = .{ .default = true, .docs = true } },
        testParse(&.{ "show-config", "--docs", "--default" }, &buf),
    );
    try std.testing.expectEqual(
        Result{ .list_actions = .{ .docs = true } },
        testParse(&.{ "list-actions", "--docs" }, &buf),
    );
}

test "parse --help after a command asks for that command's help" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Result{ .help = .@"show-config" }, testParse(&.{ "show-config", "--default", "-h" }, &buf));
    try std.testing.expectEqual(Result{ .help = .version }, testParse(&.{ "version", "--help" }, &buf));
}

test "parse rejects unknown flags on local commands" {
    var buf: [64]u8 = undefined;
    const result = testParse(&.{ "list-actions", "--default" }, &buf);
    try std.testing.expectEqual(Command.@"list-actions", result.invalid_flag.command);
    try std.testing.expectEqualStrings("--default", result.invalid_flag.flag);
}

test "parse forwards everything else to the daemon" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("query windows --json", testParse(&.{ "query", "windows", "--json" }, &buf).ipc);
    try std.testing.expectEqual(Result{ .help = null }, testParse(&.{ "query", "--help" }, &buf));
}
