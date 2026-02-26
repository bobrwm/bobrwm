//! Configuration for bobrwm.
//! Reads a config.zon file from XDG_CONFIG_HOME/bobrwm/config.zon,
//! ~/.config/bobrwm/config.zon, or a path passed via CLI.

const std = @import("std");
const shim = @cImport({
    @cInclude("shim.h");
});

const log = std.log.scoped(.config);

// ---------------------------------------------------------------------------
// Config types
// ---------------------------------------------------------------------------

pub const Config = struct {
    keybinds: []const Keybind = &default_keybinds,
    workspace_assignments: []const WorkspaceAssignment = &.{},
    workspace_names: []const []const u8 = &.{},
    gaps: Gaps = .{},

    /// Look up the assigned workspace for a given bundle identifier.
    pub fn workspaceForApp(self: *const Config, bundle_id: []const u8) ?u8 {
        for (self.workspace_assignments) |a| {
            if (std.mem.eql(u8, a.app_id, bundle_id)) return a.workspace;
        }
        return null;
    }

    /// Push the keybind table into the ObjC shim so the CGEventTap
    /// matches against it instead of hardcoded binds.
    pub fn applyKeybinds(self: *const Config) void {
        const max = 128;
        var c_binds: [max]shim.bw_keybind = undefined;
        var count: u32 = 0;

        for (self.keybinds) |kb| {
            const keycode = keyNameToCode(kb.key) orelse {
                log.warn("unknown key name: {s}", .{kb.key});
                continue;
            };
            var mods: u8 = 0;
            if (kb.mods.alt) mods |= shim.BW_MOD_ALT;
            if (kb.mods.shift) mods |= shim.BW_MOD_SHIFT;
            if (kb.mods.cmd) mods |= shim.BW_MOD_CMD;
            if (kb.mods.ctrl) mods |= shim.BW_MOD_CTRL;

            c_binds[count] = .{
                .keycode = keycode,
                .mods = mods,
                .action = @intFromEnum(kb.action),
                .arg = kb.arg,
            };
            count += 1;
            if (count >= max) break;
        }

        shim.bw_set_keybinds(&c_binds, count);
        log.info("applied {d} keybinds", .{count});
    }
};

pub const Mods = struct {
    alt: bool = false,
    shift: bool = false,
    cmd: bool = false,
    ctrl: bool = false,
};

pub const Action = enum(u8) {
    focus_workspace = 20,
    move_to_workspace = 21,
    focus_left = 22,
    focus_right = 23,
    focus_up = 24,
    focus_down = 25,
    toggle_split = 26,
    toggle_fullscreen = 27,
    toggle_float = 28,
};

pub const Keybind = struct {
    key: []const u8,
    mods: Mods = .{},
    action: Action,
    arg: u8 = 0,
};

pub const WorkspaceAssignment = struct {
    app_id: []const u8,
    workspace: u8,
};

pub const OuterGaps = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
};

pub const Gaps = struct {
    inner: u16 = 0,
    outer: OuterGaps = .{},
};

// ---------------------------------------------------------------------------
// Default keybinds (matches the previously hardcoded behaviour)
// ---------------------------------------------------------------------------

const default_keybinds: [23]Keybind = blk: {
    var binds: [23]Keybind = undefined;
    var i: usize = 0;

    // alt+1..9 → focus workspace
    for (1..10) |n| {
        binds[i] = .{ .key = &[1]u8{'0' + @as(u8, @intCast(n))}, .mods = .{ .alt = true }, .action = .focus_workspace, .arg = @intCast(n) };
        i += 1;
    }
    // alt+shift+1..9 → move to workspace
    for (1..10) |n| {
        binds[i] = .{ .key = &[1]u8{'0' + @as(u8, @intCast(n))}, .mods = .{ .alt = true, .shift = true }, .action = .move_to_workspace, .arg = @intCast(n) };
        i += 1;
    }
    // alt+hjkl → focus direction
    binds[i] = .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left };
    i += 1;
    binds[i] = .{ .key = "j", .mods = .{ .alt = true }, .action = .focus_down };
    i += 1;
    binds[i] = .{ .key = "k", .mods = .{ .alt = true }, .action = .focus_up };
    i += 1;
    binds[i] = .{ .key = "l", .mods = .{ .alt = true }, .action = .focus_right };
    i += 1;
    // alt+return → toggle split
    binds[i] = .{ .key = "return", .mods = .{ .alt = true }, .action = .toggle_split };

    break :blk binds;
};

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

pub fn load(allocator: std.mem.Allocator, explicit_path: ?[]const u8) Config {
    if (explicit_path) |p| {
        return loadFromPath(allocator, p) orelse {
            log.err("failed to load config from {s}, using defaults", .{p});
            return .{};
        };
    }

    // XDG_CONFIG_HOME / ~/.config
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return .{};
        break :blk std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch return .{};
    };

    const path = std.fmt.allocPrint(allocator, "{s}/bobrwm/config.zon", .{config_home}) catch return .{};
    return loadFromPath(allocator, path) orelse {
        log.info("no config file found, using defaults", .{});
        return .{};
    };
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Config {
    log.info("loading config from {s}", .{path});

    // Open file — if it doesn't exist, that's fine
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const source = file.readToEndAllocOptions(
        allocator,
        1024 * 1024,
        @intCast(stat.size),
        .@"1",
        0,
    ) catch |err| {
        log.err("failed to read {s}: {}", .{ path, err });
        return null;
    };

    const parsed = std.zon.parse.fromSlice(Config, allocator, source, null, .{}) catch |err| {
        log.err("failed to parse {s}: {}", .{ path, err });
        return null;
    };

    log.info("loaded config: {d} keybinds, {d} workspace assignments", .{
        parsed.keybinds.len,
        parsed.workspace_assignments.len,
    });
    return parsed;
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

pub const Args = struct {
    config_path: ?[]const u8 = null,
    /// IPC command assembled from positional args (written into caller buffer).
    command: ?[]const u8 = null,
};

/// Parse process arguments.
/// Positional args (anything that isn't `-c`/`--config` and its value) are
/// joined with spaces into `cmd_buf` and returned as `command`.
pub fn parseArgs(cmd_buf: []u8) Args {
    var result: Args = .{};
    var args = std.process.args();
    _ = args.skip(); // program name
    var pos: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            result.config_path = args.next();
            continue;
        }
        // Positional arg → part of the IPC command
        if (pos > 0 and pos < cmd_buf.len) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..copy_len], arg[0..copy_len]);
        pos += copy_len;
    }

    if (pos > 0) {
        result.command = cmd_buf[0..pos];
    }
    return result;
}

// ---------------------------------------------------------------------------
// Bundle ID helper
// ---------------------------------------------------------------------------

pub fn getAppBundleId(pid: i32, buf: *[256]u8) ?[]const u8 {
    const len = shim.bw_get_app_bundle_id(pid, buf, 256);
    if (len == 0) return null;
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// macOS virtual key code mapping
// ---------------------------------------------------------------------------

fn keyNameToCode(name: []const u8) ?u16 {
    const Map = struct { []const u8, u16 };
    const table: []const Map = &.{
        .{ "a", 0x00 },      .{ "s", 0x01 },      .{ "d", 0x02 },
        .{ "f", 0x03 },      .{ "h", 0x04 },      .{ "g", 0x05 },
        .{ "z", 0x06 },      .{ "x", 0x07 },      .{ "c", 0x08 },
        .{ "v", 0x09 },      .{ "b", 0x0B },      .{ "q", 0x0C },
        .{ "w", 0x0D },      .{ "e", 0x0E },      .{ "r", 0x0F },
        .{ "y", 0x10 },      .{ "t", 0x11 },      .{ "1", 0x12 },
        .{ "2", 0x13 },      .{ "3", 0x14 },      .{ "4", 0x15 },
        .{ "6", 0x16 },      .{ "5", 0x17 },      .{ "9", 0x19 },
        .{ "7", 0x1A },      .{ "8", 0x1C },      .{ "0", 0x1D },
        .{ "o", 0x1F },      .{ "u", 0x20 },      .{ "i", 0x22 },
        .{ "p", 0x23 },      .{ "l", 0x25 },      .{ "j", 0x26 },
        .{ "k", 0x28 },      .{ "n", 0x2D },      .{ "m", 0x2E },
        .{ "return", 0x24 }, .{ "tab", 0x30 },    .{ "space", 0x31 },
        .{ "delete", 0x33 }, .{ "escape", 0x35 }, .{ "left", 0x7B },
        .{ "right", 0x7C },  .{ "down", 0x7D },   .{ "up", 0x7E },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}
const t = std.testing;

test "keyNameToCode" {
    // letters
    try t.expectEqual(@as(u16, 0x00), keyNameToCode("a").?);
    try t.expectEqual(@as(u16, 0x04), keyNameToCode("h").?);
    try t.expectEqual(@as(u16, 0x26), keyNameToCode("j").?);
    try t.expectEqual(@as(u16, 0x28), keyNameToCode("k").?);
    try t.expectEqual(@as(u16, 0x25), keyNameToCode("l").?);

    // digits
    try t.expectEqual(@as(u16, 0x12), keyNameToCode("1").?);
    try t.expectEqual(@as(u16, 0x1D), keyNameToCode("0").?);

    // special + arrows
    try t.expectEqual(@as(u16, 0x24), keyNameToCode("return").?);
    try t.expectEqual(@as(u16, 0x31), keyNameToCode("space").?);
    try t.expectEqual(@as(u16, 0x35), keyNameToCode("escape").?);
    try t.expectEqual(@as(u16, 0x7B), keyNameToCode("left").?);
    try t.expectEqual(@as(u16, 0x7E), keyNameToCode("up").?);

    // unknown
    try t.expectEqual(@as(?u16, null), keyNameToCode("F1"));
    try t.expectEqual(@as(?u16, null), keyNameToCode(""));
}

test "workspaceForApp" {
    const cfg: Config = .{
        .workspace_assignments = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.apple.MobileSMS", .workspace = 3 },
        },
    };
    try t.expectEqual(@as(?u8, 2), cfg.workspaceForApp("com.apple.Safari"));
    try t.expectEqual(@as(?u8, 3), cfg.workspaceForApp("com.apple.MobileSMS"));
    try t.expectEqual(@as(?u8, null), cfg.workspaceForApp("com.apple.Terminal"));

    const empty: Config = .{};
    try t.expectEqual(@as(?u8, null), empty.workspaceForApp("com.apple.Safari"));
}

test "default config" {
    const cfg: Config = .{};
    try t.expectEqual(@as(usize, 23), cfg.keybinds.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_names.len);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
    try t.expectEqual(@as(u16, 0), cfg.gaps.outer.left);
}

test "default_keybinds" {
    // alt+1..9 focus workspace
    for (0..9) |i| {
        const kb = default_keybinds[i];
        try t.expectEqual(Action.focus_workspace, kb.action);
        try t.expect(kb.mods.alt);
        try t.expect(!kb.mods.shift);
        try t.expectEqual(@as(u8, @intCast(i + 1)), kb.arg);
    }

    // alt+shift+1..9 move to workspace
    for (9..18) |i| {
        const kb = default_keybinds[i];
        try t.expectEqual(Action.move_to_workspace, kb.action);
        try t.expect(kb.mods.alt and kb.mods.shift);
        try t.expectEqual(@as(u8, @intCast(i - 8)), kb.arg);
    }

    // hjkl
    const dirs = [_]Action{ .focus_left, .focus_down, .focus_up, .focus_right };
    const keys = [_][]const u8{ "h", "j", "k", "l" };
    for (dirs, keys, 18..) |action, key, i| {
        try t.expectEqual(action, default_keybinds[i].action);
        try t.expect(std.mem.eql(u8, key, default_keybinds[i].key));
    }

    // alt+return toggle split
    try t.expectEqual(Action.toggle_split, default_keybinds[22].action);
    try t.expect(std.mem.eql(u8, "return", default_keybinds[22].key));
}

test "loadFromPath: missing file" {
    try t.expectEqual(@as(?Config, null), loadFromPath(t.allocator, "/tmp/bobrwm_no_such_file.zon"));
}

test "loadFromPath: examples/config.zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const cfg = loadFromPath(arena.allocator(), "examples/config.zon") orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 24), cfg.keybinds.len);

    try t.expectEqual(Action.focus_workspace, cfg.keybinds[0].action);
    try t.expectEqual(@as(u8, 1), cfg.keybinds[0].arg);

    try t.expectEqual(Action.move_to_workspace, cfg.keybinds[9].action);
    try t.expect(cfg.keybinds[9].mods.shift);

    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[23].action);
    try t.expect(std.mem.eql(u8, "f", cfg.keybinds[23].key));

    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
}

test "loadFromPath: custom zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const zon =
        \\.{
        \\    .keybinds = .{
        \\        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
        \\        .{ .key = "space", .mods = .{ .alt = true, .shift = true }, .action = .toggle_float },
        \\    },
        \\    .workspace_assignments = .{
        \\        .{ .app_id = "com.test.App", .workspace = 3 },
        \\    },
        \\    .gaps = .{ .inner = 8, .outer = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 } },
        \\}
    ;

    tmp.dir.writeFile(.{ .sub_path = "config.zon", .data = zon }) catch
        return error.TestUnexpectedResult;
    const path = tmp.dir.realpathAlloc(allocator, "config.zon") catch
        return error.TestUnexpectedResult;

    const cfg = loadFromPath(allocator, path) orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 2), cfg.keybinds.len);
    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[0].action);
    try t.expectEqual(Action.toggle_float, cfg.keybinds[1].action);

    try t.expectEqual(@as(usize, 1), cfg.workspace_assignments.len);
    try t.expect(std.mem.eql(u8, "com.test.App", cfg.workspace_assignments[0].app_id));
    try t.expectEqual(@as(u8, 3), cfg.workspace_assignments[0].workspace);

    try t.expectEqual(@as(u16, 8), cfg.gaps.inner);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.left);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.right);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.top);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.bottom);
}
