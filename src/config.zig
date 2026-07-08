//! Configuration for bobrwm.
//! Reads a config.zon file from XDG_CONFIG_HOME/bobrwm/config.zon,
//! ~/.config/bobrwm/config.zon, or a path passed via CLI.

const std = @import("std");
const shim = @import("shim_api.zig");
const layout_mod = @import("layout.zig");
const osutil = @import("osutil.zig");

const log = std.log.scoped(.config);

// Config types

pub const Config = struct {
    keybinds: []const Keybind = &default_keybinds,
    workspace_assignments: []const WorkspaceAssignment = &.{},
    workspace_names: []const []const u8 = &.{},
    swipe: SwipeConfig = .{},
    gaps: Gaps = .{},
    layout: layout_mod.LayoutKind = .bsp,
    bsp_split: layout_mod.SplitMode = .auto,
    bsp_insert_mode: layout_mod.InsertMode = .split,
    bsp_insert_point: layout_mod.InsertionPointPolicy = .focused,
    bsp_split_ratio: f64 = 0.5,
    new_window_split: layout_mod.InsertChild = .second,

    /// Look up the assigned workspace for a given bundle identifier.
    pub fn workspaceForApp(self: *const Config, bundle_id: []const u8) ?u8 {
        for (self.workspace_assignments) |a| {
            if (std.mem.eql(u8, a.app_id, bundle_id)) return a.workspace;
        }
        return null;
    }

    /// Build the effective keybind table without allocating. Defaults are
    /// applied first; config entries with the same trigger replace them.
    fn buildKeybinds(self: *const Config, table: *KeybindTable) []const shim.bw_keybind {
        var count: usize = 0;
        mergeKeybinds(default_keybinds[0..], table.storage, &count);
        if (!isDefaultKeybindSlice(self.keybinds)) {
            mergeKeybinds(self.keybinds, table.storage, &count);
        }
        return table.storage[0..count];
    }

    /// Push the keybind table into the hotkey shim so the CGEventTap
    /// matches against it instead of hardcoded binds. The shim keeps a
    /// reference to the table (no copy), so `table` must stay alive for as
    /// long as the event tap can fire.
    pub fn applyKeybinds(self: *const Config, table: *KeybindTable) void {
        const binds = self.buildKeybinds(table);
        shim.bw_set_keybinds(binds.ptr, @intCast(binds.len));
        log.info("applied {d} keybinds", .{binds.len});
    }
};

/// Caller-owned storage for the compiled keybind table referenced by the
/// hotkey shim. Capacity is computed from the config instead of using a fixed
/// cap. Must outlive the hotkey event tap; deinit only after the run loop
/// has exited.
pub const KeybindTable = struct {
    storage: []shim.bw_keybind,

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !KeybindTable {
        const configured_count: usize = if (isDefaultKeybindSlice(config.keybinds)) 0 else config.keybinds.len;
        return .{
            .storage = try allocator.alloc(shim.bw_keybind, default_keybind_count + configured_count),
        };
    }

    pub fn deinit(self: *KeybindTable, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
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
    move_workspace_to_display = 29,
    focus_previous_workspace = 30,
    focus_next_workspace = 31,

    // Every Action must map 1:1 to an EventKind (hk_ prefixed).
    comptime {
        // stringToEnum builds a StaticStringMap whose pdq sort blows past
        // the default branch quota when the enum has many fields.
        @setEvalBranchQuota(20_000);
        const event = @import("event.zig").EventKind;
        for (@typeInfo(Action).@"enum".fields) |f| {
            // Verify each Action.<name> has a matching EventKind.hk_<name>;
            // a missing tag triggers a clear comptime error.
            if (std.meta.stringToEnum(event, "hk_" ++ f.name) == null) {
                @compileError("missing EventKind.hk_" ++ f.name ++ " for Action." ++ f.name);
            }
        }
    }
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

pub const SwipeConfig = struct {
    enabled: bool = false,
    fingers: u8 = 3,
    distance_pct: f64 = 0.08,
    reverse: bool = false,
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

// Default keybinds (matches the previously hardcoded behaviour)

const default_keybind_count = 25;

const default_keybinds: [default_keybind_count]Keybind = blk: {
    var binds: [default_keybind_count]Keybind = undefined;
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
    i += 1;
    // ctrl+left/right → traverse workspaces, pass through at native Space edges
    binds[i] = .{ .key = "left", .mods = .{ .ctrl = true }, .action = .focus_previous_workspace };
    i += 1;
    binds[i] = .{ .key = "right", .mods = .{ .ctrl = true }, .action = .focus_next_workspace };
    i += 1;

    if (i != default_keybind_count) @compileError("default_keybind_count does not match initialized keybinds");

    break :blk binds;
};

fn keybindToShim(keybind: Keybind) ?shim.bw_keybind {
    const keycode = keyNameToCode(keybind.key) orelse {
        log.warn("unknown key name: {s}", .{keybind.key});
        return null;
    };
    var mods: u8 = 0;
    if (keybind.mods.alt) mods |= shim.BW_MOD_ALT;
    if (keybind.mods.shift) mods |= shim.BW_MOD_SHIFT;
    if (keybind.mods.cmd) mods |= shim.BW_MOD_CMD;
    if (keybind.mods.ctrl) mods |= shim.BW_MOD_CTRL;

    return .{
        .keycode = keycode,
        .mods = mods,
        .action = @intFromEnum(keybind.action),
        .arg = keybind.arg,
    };
}

fn mergeKeybinds(keybinds: []const Keybind, storage: []shim.bw_keybind, count: *usize) void {
    for (keybinds) |keybind| {
        const c_bind = keybindToShim(keybind) orelse continue;
        if (keybindIndex(storage[0..count.*], c_bind)) |i| {
            storage[i] = c_bind;
            continue;
        }

        std.debug.assert(count.* < storage.len);
        storage[count.*] = c_bind;
        count.* += 1;
    }
}

fn keybindIndex(bindings: []const shim.bw_keybind, target: shim.bw_keybind) ?usize {
    for (bindings, 0..) |keybind, i| {
        if (keybind.keycode == target.keycode and keybind.mods == target.mods) return i;
    }
    return null;
}

fn isDefaultKeybindSlice(keybinds: []const Keybind) bool {
    const defaults = default_keybinds[0..];
    return keybinds.len == defaults.len and keybinds.ptr == defaults.ptr;
}

// Loading

pub fn load(allocator: std.mem.Allocator, explicit_path: ?[]const u8) Config {
    if (explicit_path) |p| {
        return loadFromPath(allocator, p) orelse {
            log.err("failed to load config from {s}, using defaults", .{p});
            return .{};
        };
    }

    // XDG_CONFIG_HOME / ~/.config
    var path_buf: [2048]u8 = undefined;
    const path = blk: {
        if (osutil.getenv("XDG_CONFIG_HOME")) |config_home| {
            break :blk std.fmt.bufPrint(&path_buf, "{s}/bobrwm/config.zon", .{config_home}) catch return .{};
        }

        const home = osutil.getenv("HOME") orelse return .{};
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.config/bobrwm/config.zon", .{home}) catch return .{};
    };
    std.debug.assert(path.len > 0);

    return loadFromPath(allocator, path) orelse {
        log.info("no config file found, using defaults", .{});
        return .{};
    };
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Config {
    log.info("loading config from {s}", .{path});

    // libc-based read; std.fs.cwd was removed in Zig 0.16. Caller paths
    // come from CLI / env so they fit easily in PATH_MAX.
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    // Source is intentionally not freed here: zon.parse may retain references
    // into it for string fields. Caller passes an arena allocator whose
    // deinit handles cleanup.
    const source = osutil.readFileAllocSentinel(allocator, path_z, 1024 * 1024) orelse return null;

    // Config holds slice/pointer fields, so we need fromSliceAlloc; fromSlice
    // asserts at comptime that T contains no allocator-managed types.
    const parsed = std.zon.parse.fromSliceAlloc(Config, allocator, source, null, .{}) catch |err| {
        log.err("failed to parse {s}: {}", .{ path, err });
        return null;
    };

    log.info("loaded config: {d} keybind entries, {d} workspace assignments", .{
        parsed.keybinds.len,
        parsed.workspace_assignments.len,
    });
    return parsed;
}

// Bundle ID helper

pub fn getAppBundleId(pid: i32, buf: *[256]u8) ?[]const u8 {
    const len = shim.bw_get_app_bundle_id(pid, buf, 256);
    if (len == 0) return null;
    return buf[0..len];
}

// macOS virtual key code mapping

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
    try t.expectEqual(@as(usize, 25), cfg.keybinds.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_names.len);
    try t.expect(!cfg.swipe.enabled);
    try t.expectEqual(@as(u8, 3), cfg.swipe.fingers);
    try t.expectApproxEqAbs(@as(f64, 0.08), cfg.swipe.distance_pct, 0.0001);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
    try t.expectEqual(@as(u16, 0), cfg.gaps.outer.left);
    try t.expectEqual(layout_mod.LayoutKind.bsp, cfg.layout);
    try t.expectEqual(layout_mod.SplitMode.auto, cfg.bsp_split);
    try t.expectEqual(layout_mod.InsertMode.split, cfg.bsp_insert_mode);
    try t.expectEqual(layout_mod.InsertionPointPolicy.focused, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.5), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(layout_mod.InsertChild.second, cfg.new_window_split);
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

    // ctrl+left/right workspace traversal
    try t.expectEqual(Action.focus_previous_workspace, default_keybinds[23].action);
    try t.expect(default_keybinds[23].mods.ctrl);
    try t.expect(std.mem.eql(u8, "left", default_keybinds[23].key));
    try t.expectEqual(Action.focus_next_workspace, default_keybinds[24].action);
    try t.expect(default_keybinds[24].mods.ctrl);
    try t.expect(std.mem.eql(u8, "right", default_keybinds[24].key));
}

test "buildKeybinds merges custom keybinds with defaults" {
    const custom_keybinds: []const Keybind = &.{
        .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 9 },
        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
    };
    const cfg: Config = .{ .keybinds = custom_keybinds };
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const merged = cfg.buildKeybinds(&table);

    try t.expectEqual(@as(usize, default_keybind_count + custom_keybinds.len), table.storage.len);
    try t.expectEqual(@as(usize, default_keybind_count + 1), merged.len);
    try t.expectEqual(keyNameToCode("1").?, merged[0].keycode);
    try t.expectEqual(shim.BW_MOD_ALT, merged[0].mods);
    try t.expectEqual(@intFromEnum(Action.focus_workspace), merged[0].action);
    try t.expectEqual(@as(u32, 9), merged[0].arg);
    try t.expectEqual(keyNameToCode("f").?, merged[default_keybind_count].keycode);
    try t.expectEqual(@intFromEnum(Action.toggle_fullscreen), merged[default_keybind_count].action);
}

test "loadFromPath: missing file" {
    try t.expectEqual(@as(?Config, null), loadFromPath(t.allocator, "/tmp/bobrwm_no_such_file.zon"));
}

test "loadFromPath: examples/config.zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const cfg = loadFromPath(arena.allocator(), "examples/config.zon") orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 26), cfg.keybinds.len);

    try t.expectEqual(Action.focus_workspace, cfg.keybinds[0].action);
    try t.expectEqual(@as(u8, 1), cfg.keybinds[0].arg);

    try t.expectEqual(Action.move_to_workspace, cfg.keybinds[9].action);
    try t.expect(cfg.keybinds[9].mods.shift);

    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[23].action);
    try t.expect(std.mem.eql(u8, "f", cfg.keybinds[23].key));
    try t.expectEqual(Action.focus_previous_workspace, cfg.keybinds[24].action);
    try t.expectEqual(Action.focus_next_workspace, cfg.keybinds[25].action);

    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
    try t.expectEqual(layout_mod.LayoutKind.bsp, cfg.layout);
    try t.expectEqual(layout_mod.SplitMode.auto, cfg.bsp_split);
    try t.expectEqual(layout_mod.InsertMode.split, cfg.bsp_insert_mode);
    try t.expectEqual(layout_mod.InsertionPointPolicy.focused, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.5), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(layout_mod.InsertChild.second, cfg.new_window_split);
}

test "loadFromPath: custom zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const zon =
        \\.{
        \\    .keybinds = .{
        \\        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
        \\        .{ .key = "space", .mods = .{ .alt = true, .shift = true }, .action = .toggle_float },
        \\    },
        \\    .workspace_assignments = .{
        \\        .{ .app_id = "com.test.App", .workspace = 3 },
        \\    },
        \\    .swipe = .{ .enabled = true, .fingers = 4, .distance_pct = 0.1 },
        \\    .gaps = .{ .inner = 8, .outer = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 } },
        \\    .layout = .monocle,
        \\    .bsp_split = .vertical,
        \\    .bsp_insert_mode = .stack,
        \\    .bsp_insert_point = .last,
        \\    .bsp_split_ratio = 0.6,
        \\    .new_window_split = .first,
        \\}
    ;

    // tmpDir.writeFile / realpathAlloc now require an Io instance which we
    // don't thread through tests. Write to a deterministic /tmp path with
    // libc instead.
    const path: [:0]const u8 = "/tmp/bobrwm_test_custom_config.zon";
    if (!osutil.writeFile(path.ptr, zon)) return error.TestUnexpectedResult;
    defer osutil.deleteFile(path.ptr);

    const cfg = loadFromPath(allocator, path) orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 2), cfg.keybinds.len);
    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[0].action);
    try t.expectEqual(Action.toggle_float, cfg.keybinds[1].action);

    try t.expectEqual(@as(usize, 1), cfg.workspace_assignments.len);
    try t.expect(std.mem.eql(u8, "com.test.App", cfg.workspace_assignments[0].app_id));
    try t.expectEqual(@as(u8, 3), cfg.workspace_assignments[0].workspace);
    try t.expect(cfg.swipe.enabled);
    try t.expectEqual(@as(u8, 4), cfg.swipe.fingers);
    try t.expectApproxEqAbs(@as(f64, 0.1), cfg.swipe.distance_pct, 0.0001);

    try t.expectEqual(@as(u16, 8), cfg.gaps.inner);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.left);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.right);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.top);
    try t.expectEqual(@as(u16, 4), cfg.gaps.outer.bottom);
    try t.expectEqual(layout_mod.LayoutKind.monocle, cfg.layout);
    try t.expectEqual(layout_mod.SplitMode.vertical, cfg.bsp_split);
    try t.expectEqual(layout_mod.InsertMode.stack, cfg.bsp_insert_mode);
    try t.expectEqual(layout_mod.InsertionPointPolicy.last, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.6), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(layout_mod.InsertChild.first, cfg.new_window_split);
}
