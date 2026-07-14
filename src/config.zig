//! Configuration for bobrwm.
//! Reads a config.zon file from XDG_CONFIG_HOME/bobrwm/config.zon,
//! ~/.config/bobrwm/config.zon, or a path passed via CLI.

const std = @import("std");
const shim = @import("shim_api.zig");
const tiling = @import("tiling.zig");
const osutil = @import("osutil.zig");
const animation = @import("animation.zig");

const log = std.log.scoped(.config);

// Config types

pub const Config = struct {
    keybinds: []const Keybind = &default_keybinds,
    app_rules: []const AppRule = &.{},
    /// Deprecated alias for the workspace part of `app_rules`. Entries here are
    /// merged into the app-rule lookups after `app_rules`, so a matching
    /// `app_rules` entry wins.
    workspace_assignments: []const WorkspaceAssignment = &.{},
    workspace_names: []const []const u8 = &.{},
    swipe: SwipeConfig = .{},
    dimmed_inactive: DimConfig = .{},
    gaps: Gaps = .{},
    layout: tiling.LayoutKind = .bsp,
    bsp_split: tiling.SplitMode = .auto,
    bsp_insert_point: tiling.InsertionPointPolicy = .focused,
    bsp_split_ratio: f64 = 0.5,
    new_window_split: tiling.InsertChild = .second,
    animation: animation.AnimationConfig = .{},

    /// Look up the assigned workspace for a given bundle identifier. `app_rules`
    /// take precedence; `workspace_assignments` is a fallback alias.
    pub fn workspaceForApp(self: *const Config, bundle_id: []const u8) ?u8 {
        for (self.app_rules) |r| {
            if (std.mem.eql(u8, r.app_id, bundle_id)) {
                if (r.workspace) |ws| return ws;
            }
        }
        for (self.workspace_assignments) |a| {
            if (std.mem.eql(u8, a.app_id, bundle_id)) return a.workspace;
        }
        return null;
    }

    /// Whether windows of the given bundle identifier should open floating.
    pub fn shouldFloatApp(self: *const Config, bundle_id: []const u8) bool {
        for (self.app_rules) |r| {
            if (std.mem.eql(u8, r.app_id, bundle_id)) return r.float;
        }
        return false;
    }

    /// True when any source could assign an app to a workspace, so callers can
    /// skip the bundle-id lookup entirely when nothing is configured.
    pub fn hasAppWorkspaceRules(self: *const Config) bool {
        return self.app_rules.len > 0 or self.workspace_assignments.len > 0;
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
    toggle_dimming = 32,
    swap_left = 33,
    swap_right = 34,
    swap_up = 35,
    swap_down = 36,

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

/// Per-app behavior keyed by bundle identifier. Fields are optional so a rule
/// can set only what it cares about (float-only, workspace-only, or both).
pub const AppRule = struct {
    app_id: []const u8,
    workspace: ?u8 = null,
    float: bool = false,
};

pub const SwipeConfig = struct {
    enabled: bool = false,
    fingers: u8 = 3,
    distance_pct: f64 = 0.08,
    reverse: bool = false,
};

/// Inactive-window dimming via owned black overlay panels. When enabled, every
/// visible managed window except the focused one gets a click-through black
/// overlay at `level` opacity, giving a clean multiplicative darken with no
/// color shift. Works without SIP disabled.
pub const DimConfig = struct {
    enabled: bool = false,
    /// Overlay opacity in [0, 1] (0 = none, 1 = fully black).
    level: f32 = 0.35,
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

const default_keybinds = blk: {
    var binds: []const Keybind = &.{};

    // alt+1..9 → focus workspace
    for (1..10) |n| {
        binds = binds ++ &[_]Keybind{.{ .key = &[1]u8{'0' + @as(u8, @intCast(n))}, .mods = .{ .alt = true }, .action = .focus_workspace, .arg = @intCast(n) }};
    }
    // alt+shift+1..9 → move to workspace
    for (1..10) |n| {
        binds = binds ++ &[_]Keybind{.{ .key = &[1]u8{'0' + @as(u8, @intCast(n))}, .mods = .{ .alt = true, .shift = true }, .action = .move_to_workspace, .arg = @intCast(n) }};
    }
    binds = binds ++ &[_]Keybind{
        // alt+hjkl → focus direction
        .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left },
        .{ .key = "j", .mods = .{ .alt = true }, .action = .focus_down },
        .{ .key = "k", .mods = .{ .alt = true }, .action = .focus_up },
        .{ .key = "l", .mods = .{ .alt = true }, .action = .focus_right },
        // alt+return → toggle split
        .{ .key = "return", .mods = .{ .alt = true }, .action = .toggle_split },
        // ctrl+left/right → traverse workspaces, pass through at native Space edges
        .{ .key = "left", .mods = .{ .ctrl = true }, .action = .focus_previous_workspace },
        .{ .key = "right", .mods = .{ .ctrl = true }, .action = .focus_next_workspace },
        // alt+shift+hjkl → swap window with the neighbour in that direction
        .{ .key = "h", .mods = .{ .alt = true, .shift = true }, .action = .swap_left },
        .{ .key = "j", .mods = .{ .alt = true, .shift = true }, .action = .swap_down },
        .{ .key = "k", .mods = .{ .alt = true, .shift = true }, .action = .swap_up },
        .{ .key = "l", .mods = .{ .alt = true, .shift = true }, .action = .swap_right },
    };

    break :blk binds[0..binds.len].*;
};

const default_keybind_count = default_keybinds.len;

// Runs unconditionally at compile time; a bad default fails the build even
// if nothing in the current compilation references default_keybinds.
comptime {
    assertValidTriggers(&default_keybinds);
}

/// Comptime-only validation: every keybind must use a known key name and a
/// unique keycode+mods trigger. The event tap dispatches on first match, so
/// a duplicate trigger would silently shadow another binding.
fn assertValidTriggers(comptime binds: []const Keybind) void {
    // The comptime block forces a compile error if this is ever called in a
    // runtime context instead of silently generating runtime code.
    comptime {
        @setEvalBranchQuota(50_000);
        var keycodes: [binds.len]u16 = undefined;
        for (binds, 0..) |bind, i| {
            keycodes[i] = keyNameToCode(bind.key) orelse
                @compileError("keybind uses unknown key name: " ++ bind.key);
        }
        for (0..binds.len) |a| {
            for (a + 1..binds.len) |b| {
                if (keycodes[a] == keycodes[b] and std.meta.eql(binds[a].mods, binds[b].mods))
                    @compileError(std.fmt.comptimePrint(
                        "duplicate keybind trigger {s}{s}: {s} shadows {s}",
                        .{
                            modsLabel(binds[a].mods),
                            binds[a].key,
                            @tagName(binds[a].action),
                            @tagName(binds[b].action),
                        },
                    ));
            }
        }
    }
}

/// Comptime-only helper for validation diagnostics: renders mods as a
/// "ctrl+alt+" style prefix.
fn modsLabel(comptime mods: Mods) []const u8 {
    comptime {
        var label: []const u8 = "";
        if (mods.cmd) label = label ++ "cmd+";
        if (mods.ctrl) label = label ++ "ctrl+";
        if (mods.alt) label = label ++ "alt+";
        if (mods.shift) label = label ++ "shift+";
        return label;
    }
}

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

    log.info("loaded config: {d} keybind entries, {d} app rules, {d} workspace assignments", .{
        parsed.keybinds.len,
        parsed.app_rules.len,
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

test "app_rules: float and workspace lookups" {
    const cfg: Config = .{
        .app_rules = &.{
            .{ .app_id = "com.apple.systempreferences", .float = true },
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.foo.bar", .workspace = 3, .float = true },
        },
    };

    try t.expect(cfg.shouldFloatApp("com.apple.systempreferences"));
    try t.expect(!cfg.shouldFloatApp("com.apple.Safari"));
    try t.expect(cfg.shouldFloatApp("com.foo.bar"));
    try t.expect(!cfg.shouldFloatApp("com.unknown.App"));

    try t.expectEqual(@as(?u8, null), cfg.workspaceForApp("com.apple.systempreferences"));
    try t.expectEqual(@as(?u8, 2), cfg.workspaceForApp("com.apple.Safari"));
    try t.expectEqual(@as(?u8, 3), cfg.workspaceForApp("com.foo.bar"));
}

test "app_rules take precedence over workspace_assignments alias" {
    const cfg: Config = .{
        .app_rules = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 5 },
        },
        .workspace_assignments = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.apple.MobileSMS", .workspace = 3 },
        },
    };

    try t.expectEqual(@as(?u8, 5), cfg.workspaceForApp("com.apple.Safari"));
    try t.expectEqual(@as(?u8, 3), cfg.workspaceForApp("com.apple.MobileSMS"));
    try t.expect(cfg.hasAppWorkspaceRules());
}

test "default config" {
    const cfg: Config = .{};
    try t.expectEqual(@as(usize, default_keybind_count), cfg.keybinds.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(usize, 0), cfg.workspace_names.len);
    try t.expect(!cfg.swipe.enabled);
    try t.expectEqual(@as(u8, 3), cfg.swipe.fingers);
    try t.expectApproxEqAbs(@as(f64, 0.08), cfg.swipe.distance_pct, 0.0001);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
    try t.expectEqual(@as(u16, 0), cfg.gaps.outer.left);
    try t.expectEqual(tiling.LayoutKind.bsp, cfg.layout);
    try t.expectEqual(tiling.SplitMode.auto, cfg.bsp_split);
    try t.expectEqual(tiling.InsertionPointPolicy.focused, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.5), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(tiling.InsertChild.second, cfg.new_window_split);
    try t.expect(!cfg.animation.enabled);
    try t.expectEqual(@as(u64, 200), cfg.animation.duration_ms);
    try t.expectEqual(animation.Easing.ease_out, cfg.animation.easing);
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

    // alt+shift+hjkl directional swap
    const swap_dirs = [_]Action{ .swap_left, .swap_down, .swap_up, .swap_right };
    for (swap_dirs, keys, 25..) |action, key, i| {
        try t.expectEqual(action, default_keybinds[i].action);
        try t.expect(std.mem.eql(u8, key, default_keybinds[i].key));
        try t.expect(default_keybinds[i].mods.alt and default_keybinds[i].mods.shift);
    }
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

test "buildKeybinds: override matches on mods, not just key" {
    // alt+shift+1 (move_to_workspace, defaults index 9) overridden; alt+1
    // (focus_workspace, defaults index 0) must be untouched.
    const custom_keybinds: []const Keybind = &.{
        .{ .key = "1", .mods = .{ .alt = true, .shift = true }, .action = .toggle_fullscreen },
    };
    const cfg: Config = .{ .keybinds = custom_keybinds };
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const merged = cfg.buildKeybinds(&table);

    try t.expectEqual(@as(usize, default_keybind_count), merged.len);
    try t.expectEqual(@intFromEnum(Action.focus_workspace), merged[0].action);
    try t.expectEqual(@as(u32, 1), merged[0].arg);
    try t.expectEqual(shim.BW_MOD_ALT | shim.BW_MOD_SHIFT, merged[9].mods);
    try t.expectEqual(@intFromEnum(Action.toggle_fullscreen), merged[9].action);
}

test "buildKeybinds: duplicate config triggers collapse, last wins" {
    const custom_keybinds: []const Keybind = &.{
        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_split },
    };
    const cfg: Config = .{ .keybinds = custom_keybinds };
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const merged = cfg.buildKeybinds(&table);

    try t.expectEqual(@as(usize, default_keybind_count + 1), merged.len);
    try t.expectEqual(keyNameToCode("f").?, merged[default_keybind_count].keycode);
    try t.expectEqual(@intFromEnum(Action.toggle_split), merged[default_keybind_count].action);
}

test "buildKeybinds: unknown key name is skipped without consuming a slot" {
    // The unknown key deliberately triggers the warn log path; raise the
    // test log threshold so expected output does not pollute `zig build test`.
    std.testing.log_level = .err;
    const custom_keybinds: []const Keybind = &.{
        .{ .key = "hyper", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
    };
    const cfg: Config = .{ .keybinds = custom_keybinds };
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const merged = cfg.buildKeybinds(&table);

    try t.expectEqual(@as(usize, default_keybind_count + 1), merged.len);
    try t.expectEqual(keyNameToCode("f").?, merged[default_keybind_count].keycode);
}

test "loadFromPath: missing file" {
    try t.expectEqual(@as(?Config, null), loadFromPath(t.allocator, "/tmp/bobrwm_no_such_file.zon"));
}

test "loadFromPath: examples/config.zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const cfg = loadFromPath(arena.allocator(), "examples/config.zon") orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 30), cfg.keybinds.len);

    try t.expectEqual(Action.focus_workspace, cfg.keybinds[0].action);
    try t.expectEqual(@as(u8, 1), cfg.keybinds[0].arg);

    try t.expectEqual(Action.move_to_workspace, cfg.keybinds[9].action);
    try t.expect(cfg.keybinds[9].mods.shift);

    try t.expectEqual(Action.swap_left, cfg.keybinds[22].action);
    try t.expect(cfg.keybinds[22].mods.alt and cfg.keybinds[22].mods.shift);
    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[27].action);
    try t.expect(std.mem.eql(u8, "f", cfg.keybinds[27].key));
    try t.expectEqual(Action.focus_previous_workspace, cfg.keybinds[28].action);
    try t.expectEqual(Action.focus_next_workspace, cfg.keybinds[29].action);

    try t.expectEqual(@as(usize, 0), cfg.workspace_assignments.len);
    try t.expectEqual(@as(u16, 0), cfg.gaps.inner);
    try t.expectEqual(tiling.LayoutKind.bsp, cfg.layout);
    try t.expectEqual(tiling.SplitMode.auto, cfg.bsp_split);
    try t.expectEqual(tiling.InsertionPointPolicy.focused, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.5), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(tiling.InsertChild.second, cfg.new_window_split);
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
    try t.expectEqual(tiling.LayoutKind.monocle, cfg.layout);
    try t.expectEqual(tiling.SplitMode.vertical, cfg.bsp_split);
    try t.expectEqual(tiling.InsertionPointPolicy.last, cfg.bsp_insert_point);
    try t.expectApproxEqAbs(@as(f64, 0.6), cfg.bsp_split_ratio, 0.0001);
    try t.expectEqual(tiling.InsertChild.first, cfg.new_window_split);
}
