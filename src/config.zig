//! Configuration for bobrwm.
//! Reads a config.zon file from XDG_CONFIG_HOME/bobrwm/config.zon,
//! ~/.config/bobrwm/config.zon, or a path passed via CLI.

const std = @import("std");
const shim = @import("shim_api.zig");
const tiling = @import("tiling.zig");
const osutil = @import("osutil.zig");
const animation = @import("animation.zig");
const workspace = @import("workspace.zig");

const log = std.log.scoped(.config);

// Config types

pub const Config = struct {
    /// Use only the explicit `keybinds` entries instead of merging them with
    /// the built-in defaults. If `keybinds` is omitted or empty, no shortcuts
    /// are registered.
    ///
    /// This also drops the default `reload_config` shortcut, so use
    /// `bobrwm reload-config` unless you bind `reload_config` yourself.
    disable_default_keybinds: bool = false,
    /// Map a key and modifiers to an action.
    ///
    /// Entries are merged with the built-in defaults. An entry with the same
    /// key and modifiers as a default replaces it; any other entry adds a new
    /// shortcut. See `disable_default_keybinds` to drop the defaults entirely.
    ///
    ///     .keybinds = .{
    ///         .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 },
    ///         .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left },
    ///         .{ .key = "return", .mods = .{ .alt = true }, .action = .toggle_split },
    ///     },
    keybinds: []const Keybind = &default_keybinds,
    /// Per-app behavior keyed by bundle identifier. Each rule sets only what
    /// it needs: a workspace, floating, or both. At most one rule per app.
    ///
    ///     .app_rules = .{
    ///         .{ .app_id = "com.apple.Safari", .workspace = 2 },
    ///         .{ .app_id = "com.apple.systempreferences", .float = true },
    ///     },
    app_rules: []const AppRule = &.{},
    /// Deprecated alias for the workspace part of `app_rules`. Entries here are
    /// merged into the app-rule lookups after `app_rules`, so a matching
    /// `app_rules` entry wins.
    workspace_assignments: []const WorkspaceAssignment = &.{},
    /// Names for the managed workspaces. The number of names is the workspace
    /// count; when omitted, bobrwm manages 10 unnamed workspaces. At most 10.
    ///
    /// Workspace IDs stay 1-based, so four names create workspaces 1 through
    /// 4, and keybinds and app rules must reference workspaces in that range.
    ///
    ///     .workspace_names = .{ "term", "web", "code", "chat" },
    ///
    /// Note: changing the number of workspaces requires a restart. Other
    /// settings reload live.
    workspace_names: []const []const u8 = &.{},
    /// Trackpad swipe settings for the optional `bobrwm-swipe` companion.
    /// bobrwm itself only parses these; they take effect when `bobrwm-swipe`
    /// is running.
    ///
    /// Note: macOS grants Accessibility per executable, so `bobrwm-swipe`
    /// needs its own grant even when bobrwm is already trusted.
    swipe: SwipeConfig = .{},
    /// Dim every visible window except the focused one with a click-through
    /// black overlay. Works without disabling SIP. The `toggle_dimming`
    /// keybind action flips it at runtime.
    ///
    /// Warning: alpha.
    dimmed_inactive: DimConfig = .{},
    /// Spacing in pixels between and around tiled windows.
    ///
    ///     .gaps = .{
    ///         .inner = 4,
    ///         .outer = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
    ///     },
    gaps: Gaps = .{},
    /// Tiling algorithm: `.bsp` for binary space partitioning, or `.monocle`
    /// to show each window fullscreen.
    layout: tiling.LayoutKind = .bsp,
    /// Axis used when a BSP tile splits. `.auto` picks the axis from the
    /// target tile's shape, `.horizontal` always splits left/right, and
    /// `.vertical` always splits top/bottom.
    bsp_split: tiling.SplitMode = .auto,
    /// Which tile a new window splits: `.focused`, `.first`, `.last`, or
    /// `.min_depth` (the shallowest leaf).
    bsp_insert_point: tiling.InsertionPointPolicy = .focused,
    /// Ratio for newly created BSP splits. Must be a finite value from 0.1
    /// through 0.9.
    bsp_split_ratio: f64 = 0.5,
    /// Side a new window takes when it splits a tile: `.second` is
    /// right/bottom, `.first` is left/top.
    new_window_split: tiling.InsertChild = .second,
    /// Animate window movement during layout changes.
    ///
    /// Warning: alpha. Animations run on the window manager's main thread,
    /// so a slow or unresponsive app can make animations, and bobrwm itself,
    /// stutter.
    animation: animation.AnimationConfig = .{},
    /// Register Bobrwm.app as a login item. Reconciled against
    /// ServiceManagement on startup and on every reload.
    ///
    /// macOS may hold the first registration for approval in System Settings
    /// under General > Login Items; bobrwm logs a warning while it waits.
    /// While registered, launchd restarts bobrwm if it crashes, but not after
    /// you quit it from the menu bar.
    start_at_login: bool = false,

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
    /// applied first unless disabled; config entries with the same trigger replace them.
    fn buildKeybinds(self: *const Config, table: *KeybindTable) []const shim.bw_keybind {
        var count: usize = 0;
        if (!self.disable_default_keybinds) {
            mergeKeybinds(default_keybinds[0..], table.storage, &count);
        }
        if (!isDefaultKeybindSlice(self.keybinds)) {
            mergeKeybinds(self.keybinds, table.storage, &count);
        }
        return table.storage[0..count];
    }

    /// Effective keybind for an action, for display in the menu bar UI.
    ///
    /// Config entries win over defaults, matching what a user reading the menu
    /// expects to see. This searches by action rather than by trigger, so when
    /// a config bind does not displace the default both stay live in the event
    /// tap and only the config one is shown. A default whose trigger a config
    /// entry took over is not live at all, so it is reported as unbound rather
    /// than advertising a shortcut that now does something else.
    pub fn findKeybind(self: *const Config, action: Action, arg: u8) ?Keybind {
        const has_overrides = !isDefaultKeybindSlice(self.keybinds);
        if (has_overrides) {
            for (self.keybinds) |keybind| {
                if (keybind.action == action and keybind.arg == arg) return keybind;
            }
        }

        if (self.disable_default_keybinds) return null;
        for (default_keybinds) |keybind| {
            if (keybind.action != action or keybind.arg != arg) continue;
            if (has_overrides and self.isTriggerReassigned(keybind)) continue;
            return keybind;
        }
        return null;
    }

    /// Whether a config entry claims this bind's trigger. `buildKeybinds`
    /// merges by trigger, so such a default never reaches the event tap.
    fn isTriggerReassigned(self: *const Config, keybind: Keybind) bool {
        const target = keybindToShim(keybind) orelse return false;
        for (self.keybinds) |override| {
            const candidate = keybindToShim(override) orelse continue;
            if (candidate.keycode == target.keycode and candidate.mods == target.mods) return true;
        }
        return false;
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
        const defaults_count: usize = if (config.disable_default_keybinds) 0 else default_keybind_count;
        return .{
            .storage = try allocator.alloc(shim.bw_keybind, defaults_count + configured_count),
        };
    }

    pub fn deinit(self: *KeybindTable, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const Mods = struct {
    /// Option (⌥).
    alt: bool = false,
    /// Shift (⇧).
    shift: bool = false,
    /// Command (⌘).
    cmd: bool = false,
    /// Control (⌃).
    ctrl: bool = false,
};

pub const Action = enum(u8) {
    /// Switch to the workspace numbered `arg`.
    focus_workspace = 20,
    /// Move the focused window to the workspace numbered `arg`.
    move_to_workspace = 21,
    /// Focus the window to the left.
    focus_left = 22,
    /// Focus the window to the right.
    focus_right = 23,
    /// Focus the window above.
    focus_up = 24,
    /// Focus the window below.
    focus_down = 25,
    /// Cycle the BSP split mode used for the next split: auto, horizontal,
    /// vertical.
    toggle_split = 26,
    /// Toggle the focused window fullscreen.
    toggle_fullscreen = 27,
    /// Toggle the focused window between tiled and floating.
    toggle_float = 28,
    /// Move the active workspace to display `arg` (1 through 8). `arg = 0`
    /// moves it to the next display and `arg = 255` to the previous one.
    move_workspace_to_display = 29,
    /// Switch to the previous workspace. At the first workspace, the key
    /// passes through so native Spaces can handle it.
    focus_previous_workspace = 30,
    /// Switch to the next workspace. At the last workspace, the key passes
    /// through so native Spaces can handle it.
    focus_next_workspace = 31,
    /// Toggle inactive-window dimming, regardless of `dimmed_inactive.enabled`.
    toggle_dimming = 32,
    /// Swap the focused tiled window with its neighbor to the left.
    swap_left = 33,
    /// Swap the focused tiled window with its neighbor to the right.
    swap_right = 34,
    /// Swap the focused tiled window with its neighbor above.
    swap_up = 35,
    /// Swap the focused tiled window with its neighbor below.
    swap_down = 36,
    /// Center the focused floating window on its display. No effect on tiled
    /// or fullscreen windows.
    center_float = 37,
    /// Reload the config file, keeping the current config if the new one is
    /// invalid.
    reload_config = 38,
    /// Grow the focused tiled window by moving its nearest BSP split 5
    /// percentage points, within the 10–90% split limits. No effect on
    /// floating or fullscreen windows, monocle layouts, or a workspace with
    /// one tiled window.
    resize_grow = 39,
    /// Shrink the focused tiled window by moving its nearest BSP split 5
    /// percentage points. Same limits as `resize_grow`.
    resize_shrink = 40,

    // Every Action must map 1:1 to an EventKind (hk_ prefixed).
    comptime {
        // stringToEnum builds a StaticStringMap whose pdq sort blows past
        // the default branch quota when the enum has many fields.
        @setEvalBranchQuota(40_000);
        const event = @import("event.zig").EventKind;
        for (@typeInfo(Action).@"enum".field_names) |name| {
            // Verify each Action.<name> has a matching EventKind.hk_<name>;
            // a missing tag triggers a clear comptime error.
            if (std.meta.stringToEnum(event, "hk_" ++ name) == null) {
                @compileError("missing EventKind.hk_" ++ name ++ " for Action." ++ name);
            }
        }
    }
};

/// Sentinel arguments for relative display movement in keybinds.
pub const next_display_arg: u8 = 0;
pub const previous_display_arg: u8 = std.math.maxInt(u8);

pub const Keybind = struct {
    /// Key name: a lowercase letter, a digit, `=`, `-`, `return`, `tab`,
    /// `space`, `delete`, `escape`, `left`, `right`, `up`, or `down`.
    key: []const u8,
    /// Modifiers that must be held with `key`.
    mods: Mods = .{},
    /// Action to run.
    action: Action,
    /// Argument for actions that take one, such as a workspace or display
    /// number. Ignored by other actions.
    arg: u8 = 0,

    /// Render the bind the way macOS menus write it: ⌃⌥⇧⌘ in that order, then
    /// the key. Writes into caller storage because the menu bar passes a whole
    /// row array across the C ABI at once and has no allocator. Returns null
    /// when the result would not fit, which the UI renders as no hint at all.
    pub fn displayForm(self: Keybind, storage: []u8) ?[:0]const u8 {
        var pos: usize = 0;
        const modifiers = [_]struct { bool, []const u8 }{
            .{ self.mods.ctrl, "⌃" },
            .{ self.mods.alt, "⌥" },
            .{ self.mods.shift, "⇧" },
            .{ self.mods.cmd, "⌘" },
        };
        for (modifiers) |modifier| {
            if (!modifier[0]) continue;
            if (pos + modifier[1].len >= storage.len) return null;
            @memcpy(storage[pos..][0..modifier[1].len], modifier[1]);
            pos += modifier[1].len;
        }

        const key = keyGlyph(self.key);
        if (pos + key.len >= storage.len) return null;
        // toUpper only touches ASCII a-z, so multi-byte glyphs pass through.
        for (key, 0..) |char, offset| storage[pos + offset] = std.ascii.toUpper(char);
        pos += key.len;

        storage[pos] = 0;
        return storage[0..pos :0];
    }
};

fn keyGlyph(key: []const u8) []const u8 {
    const glyphs = [_]struct { []const u8, []const u8 }{
        .{ "return", "↩" },
        .{ "tab", "⇥" },
        .{ "space", "␣" },
        .{ "delete", "⌫" },
        .{ "escape", "⎋" },
        .{ "left", "←" },
        .{ "right", "→" },
        .{ "up", "↑" },
        .{ "down", "↓" },
    };
    for (glyphs) |glyph| {
        if (std.mem.eql(u8, key, glyph[0])) return glyph[1];
    }
    return key;
}

test "displayForm renders modifiers in macOS order" {
    var storage: [24]u8 = undefined;

    const alt_one: Keybind = .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace };
    try std.testing.expectEqualStrings("⌥1", alt_one.displayForm(&storage).?);

    const all_mods: Keybind = .{
        .key = "r",
        .mods = .{ .alt = true, .shift = true, .cmd = true, .ctrl = true },
        .action = .reload_config,
    };
    try std.testing.expectEqualStrings("⌃⌥⇧⌘R", all_mods.displayForm(&storage).?);
}

test "displayForm maps named keys to glyphs and uppercases letters" {
    var storage: [24]u8 = undefined;

    const ctrl_left: Keybind = .{
        .key = "left",
        .mods = .{ .ctrl = true },
        .action = .focus_previous_workspace,
    };
    try std.testing.expectEqualStrings("⌃←", ctrl_left.displayForm(&storage).?);

    const alt_a: Keybind = .{ .key = "a", .mods = .{ .alt = true }, .action = .focus_workspace };
    try std.testing.expectEqualStrings("⌥A", alt_a.displayForm(&storage).?);
}

test "displayForm returns null when the result would not fit" {
    var tiny: [2]u8 = undefined;
    const alt_one: Keybind = .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace };
    try std.testing.expectEqual(@as(?[:0]const u8, null), alt_one.displayForm(&tiny));
}

test "findKeybind prefers config entries over defaults" {
    const overrides = [_]Keybind{
        .{ .key = "a", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 5 },
    };
    const config: Config = .{ .keybinds = &overrides };

    const workspace_five = config.findKeybind(.focus_workspace, 5).?;
    try std.testing.expectEqualStrings("a", workspace_five.key);
    try std.testing.expect(workspace_five.mods.alt);

    // Untouched by the override, so it still resolves from the defaults.
    const workspace_one = config.findKeybind(.focus_workspace, 1).?;
    try std.testing.expectEqualStrings("1", workspace_one.key);
    try std.testing.expect(workspace_one.mods.alt);
}

test "findKeybind omits a default whose trigger was reassigned" {
    const overrides = [_]Keybind{
        .{ .key = "1", .mods = .{ .alt = true }, .action = .toggle_float },
    };
    const config: Config = .{ .keybinds = &overrides };

    try std.testing.expectEqual(
        @as(?Keybind, null),
        config.findKeybind(.focus_workspace, 1),
    );
}

pub const WorkspaceAssignment = struct {
    /// Bundle identifier of the app.
    app_id: []const u8,
    /// Workspace number the app's windows open on.
    workspace: u8,
};

/// Per-app behavior keyed by bundle identifier. Fields are optional so a rule
/// can set only what it cares about (float-only, workspace-only, or both).
pub const AppRule = struct {
    /// Bundle identifier of the app. Find one with
    /// `osascript -e 'id of app "Safari"'`.
    app_id: []const u8,
    /// Workspace number the app's windows open on.
    workspace: ?u8 = null,
    /// Open the app's windows floating instead of tiled.
    float: bool = false,
};

pub const SwipeConfig = struct {
    /// Switch workspaces on horizontal native Space swipes. Gestures at the
    /// first or last workspace are consumed without switching.
    enabled: bool = false,
    /// Reverse the swipe direction.
    reverse: bool = false,
};

/// Inactive-window dimming via owned black overlay panels. When enabled, every
/// visible managed window except the focused one gets a click-through black
/// overlay at `level` opacity, giving a clean multiplicative darken with no
/// color shift. Works without SIP disabled.
pub const DimConfig = struct {
    /// Dim inactive windows at startup. `toggle_dimming` flips it at runtime.
    enabled: bool = false,
    /// Overlay opacity from 0 through 1 (0 = none, 1 = fully black).
    level: f32 = 0.35,
};

pub const OuterGaps = struct {
    /// Gap in pixels at the display's left edge.
    left: u16 = 0,
    /// Gap in pixels at the display's right edge.
    right: u16 = 0,
    /// Gap in pixels at the display's top edge.
    top: u16 = 0,
    /// Gap in pixels at the display's bottom edge.
    bottom: u16 = 0,
};

pub const Gaps = struct {
    /// Gap in pixels between adjacent tiled windows.
    inner: u16 = 0,
    /// Gaps in pixels between tiled windows and the display edges.
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
        // alt+shift+r → reload config
        .{ .key = "r", .mods = .{ .alt = true, .shift = true }, .action = .reload_config },
        // alt+=/- → grow/shrink the focused tiled window
        .{ .key = "=", .mods = .{ .alt = true }, .action = .resize_grow },
        .{ .key = "-", .mods = .{ .alt = true }, .action = .resize_shrink },
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
        .action = @backingInt(keybind.action),
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

pub fn isDefaultKeybindSlice(keybinds: []const Keybind) bool {
    const defaults = default_keybinds[0..];
    return keybinds.len == defaults.len and keybinds.ptr == defaults.ptr;
}

// Loading

/// Number of workspaces this configuration creates at startup. An omitted
/// name list selects the full default set rather than zero workspaces.
pub fn workspaceCount(config: *const Config) u8 {
    std.debug.assert(config.workspace_names.len <= workspace.max_workspaces);
    return if (config.workspace_names.len == 0)
        workspace.max_workspaces
    else
        @intCast(config.workspace_names.len);
}

/// Reject values that parse as valid ZON but violate runtime invariants.
/// Validation happens before a config becomes visible to the main loop, so a
/// bad reload leaves the last known-good config intact.
pub fn validate(config: *const Config) !void {
    const diagnostic = ConfigDiagnostics.validationDiagnostic(config) orelse return;
    return diagnostic.kind.asError();
}

/// Owns config-specific validation, source mapping, and ZON parse recovery.
/// The normal load path only enters this machinery after parsing or validation
/// fails; successful loads allocate no diagnostic state.
const ConfigDiagnostics = struct {
    const ValidationKind = enum {
        too_many_workspaces,
        invalid_workspace_name,
        invalid_bsp_split_ratio,
        invalid_dim_level,
        unknown_key_name,
        invalid_keybind_workspace,
        invalid_keybind_display,
        empty_app_rule_id,
        invalid_app_rule_workspace,
        duplicate_app_rule,
        empty_workspace_assignment_id,
        invalid_workspace_assignment,
        duplicate_workspace_assignment,

        fn asError(self: ValidationKind) anyerror {
            return switch (self) {
                .too_many_workspaces => error.TooManyWorkspaces,
                .invalid_workspace_name => error.InvalidWorkspaceName,
                .invalid_bsp_split_ratio => error.InvalidBspSplitRatio,
                .invalid_dim_level => error.InvalidDimLevel,
                .unknown_key_name => error.UnknownKeyName,
                .invalid_keybind_workspace => error.InvalidKeybindWorkspace,
                .invalid_keybind_display => error.InvalidKeybindDisplay,
                .empty_app_rule_id, .empty_workspace_assignment_id => error.EmptyAppId,
                .invalid_app_rule_workspace => error.InvalidAppRuleWorkspace,
                .duplicate_app_rule => error.DuplicateAppRule,
                .invalid_workspace_assignment => error.InvalidWorkspaceAssignment,
                .duplicate_workspace_assignment => error.DuplicateWorkspaceAssignment,
            };
        }

        fn parentField(self: ValidationKind) ?[]const u8 {
            return switch (self) {
                .invalid_dim_level => "dimmed_inactive",
                .unknown_key_name, .invalid_keybind_workspace, .invalid_keybind_display => "keybinds",
                .empty_app_rule_id, .invalid_app_rule_workspace, .duplicate_app_rule => "app_rules",
                .empty_workspace_assignment_id,
                .invalid_workspace_assignment,
                .duplicate_workspace_assignment,
                => "workspace_assignments",
                else => null,
            };
        }

        fn field(self: ValidationKind) []const u8 {
            return switch (self) {
                .too_many_workspaces, .invalid_workspace_name => "workspace_names",
                .invalid_bsp_split_ratio => "bsp_split_ratio",
                .invalid_dim_level => "level",
                .unknown_key_name => "key",
                .invalid_keybind_workspace, .invalid_keybind_display => "arg",
                .empty_app_rule_id,
                .duplicate_app_rule,
                .empty_workspace_assignment_id,
                .duplicate_workspace_assignment,
                => "app_id",
                .invalid_app_rule_workspace, .invalid_workspace_assignment => "workspace",
            };
        }
    };

    const ValidationDiagnostic = struct {
        kind: ValidationKind,
        index: ?usize = null,
    };

    const ValidationSink = struct {
        context: *anyopaque,
        emitFn: *const fn (*anyopaque, ValidationDiagnostic) bool,

        fn emit(self: ValidationSink, diagnostic: ValidationDiagnostic) bool {
            return self.emitFn(self.context, diagnostic);
        }
    };

    fn captureFirstDiagnostic(context: *anyopaque, diagnostic: ValidationDiagnostic) bool {
        const first: *?ValidationDiagnostic = @ptrCast(@alignCast(context));
        first.* = diagnostic;
        return false;
    }

    fn validationDiagnostic(config: *const Config) ?ValidationDiagnostic {
        var first: ?ValidationDiagnostic = null;
        var sink: ValidationSink = .{ .context = &first, .emitFn = captureFirstDiagnostic };
        visitValidationDiagnostics(config, &sink);
        return first;
    }

    fn validationWorkspaceCount(config: *const Config) usize {
        return if (config.workspace_names.len == 0)
            workspace.max_workspaces
        else
            @min(config.workspace_names.len, workspace.max_workspaces);
    }

    fn visitValidationDiagnostics(config: *const Config, sink: *const ValidationSink) void {
        if (config.workspace_names.len > workspace.max_workspaces) {
            if (!sink.emit(.{ .kind = .too_many_workspaces })) return;
        }
        const workspace_count = validationWorkspaceCount(config);

        for (config.workspace_names, 0..) |name, i| {
            if (!std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) {
                if (!sink.emit(.{ .kind = .invalid_workspace_name, .index = i })) return;
            }
        }
        if (!std.math.isFinite(config.bsp_split_ratio) or
            config.bsp_split_ratio < 0.1 or config.bsp_split_ratio > 0.9)
        {
            if (!sink.emit(.{ .kind = .invalid_bsp_split_ratio })) return;
        }
        if (!std.math.isFinite(config.dimmed_inactive.level) or
            config.dimmed_inactive.level < 0 or config.dimmed_inactive.level > 1)
        {
            if (!sink.emit(.{ .kind = .invalid_dim_level })) return;
        }

        if (!visitKeybindDiagnostics(config.keybinds, workspace_count, sink)) return;
        if (!visitAppRuleDiagnostics(config.app_rules, workspace_count, sink)) return;
        _ = visitWorkspaceAssignmentDiagnostics(config.workspace_assignments, workspace_count, sink);
    }

    fn visitKeybindDiagnostics(
        keybinds: []const Keybind,
        workspace_count: usize,
        sink: *const ValidationSink,
    ) bool {
        const validate_targets = !isDefaultKeybindSlice(keybinds);
        for (keybinds, 0..) |keybind, i| {
            if (keyNameToCode(keybind.key) == null) {
                if (!sink.emit(.{ .kind = .unknown_key_name, .index = i })) return false;
            }
            if (!validate_targets) continue;
            switch (keybind.action) {
                .focus_workspace, .move_to_workspace => {
                    if (keybind.arg == 0 or @as(usize, keybind.arg) > workspace_count) {
                        if (!sink.emit(.{ .kind = .invalid_keybind_workspace, .index = i })) return false;
                    }
                },
                .move_workspace_to_display => {
                    const is_relative = keybind.arg == next_display_arg or
                        keybind.arg == previous_display_arg;
                    const is_explicit = keybind.arg > 0 and keybind.arg <= workspace.max_displays;
                    if (!is_relative and !is_explicit) {
                        if (!sink.emit(.{ .kind = .invalid_keybind_display, .index = i })) return false;
                    }
                },
                else => {},
            }
        }
        return true;
    }

    fn visitAppRuleDiagnostics(
        rules: []const AppRule,
        workspace_count: usize,
        sink: *const ValidationSink,
    ) bool {
        for (rules, 0..) |rule, i| {
            if (rule.app_id.len == 0 and !sink.emit(.{ .kind = .empty_app_rule_id, .index = i })) return false;
            if (rule.workspace) |workspace_id| {
                if (workspace_id == 0 or @as(usize, workspace_id) > workspace_count) {
                    if (!sink.emit(.{ .kind = .invalid_app_rule_workspace, .index = i })) return false;
                }
            }
            for (rules[0..i]) |previous| {
                if (!std.mem.eql(u8, previous.app_id, rule.app_id)) continue;
                if (!sink.emit(.{ .kind = .duplicate_app_rule, .index = i })) return false;
                break;
            }
        }
        return true;
    }

    fn visitWorkspaceAssignmentDiagnostics(
        assignments: []const WorkspaceAssignment,
        workspace_count: usize,
        sink: *const ValidationSink,
    ) bool {
        for (assignments, 0..) |assignment, i| {
            if (assignment.app_id.len == 0) {
                if (!sink.emit(.{ .kind = .empty_workspace_assignment_id, .index = i })) return false;
            }
            if (assignment.workspace == 0 or @as(usize, assignment.workspace) > workspace_count) {
                if (!sink.emit(.{ .kind = .invalid_workspace_assignment, .index = i })) return false;
            }
            for (assignments[0..i]) |previous| {
                if (!std.mem.eql(u8, previous.app_id, assignment.app_id)) continue;
                if (!sink.emit(.{ .kind = .duplicate_workspace_assignment, .index = i })) return false;
                break;
            }
        }
        return true;
    }

    const SourceLocation = struct {
        line: usize,
        column: usize,
        line_start: usize,
        line_end: usize,
    };

    fn sourceLocation(source: []const u8, offset: usize) SourceLocation {
        var line: usize = 0;
        var line_start: usize = 0;
        for (source[0..@min(offset, source.len)], 0..) |char, i| {
            if (char != '\n') continue;
            line += 1;
            line_start = i + 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        return .{ .line = line, .column = offset - line_start, .line_start = line_start, .line_end = line_end };
    }

    /// Find a field token rather than searching bytes, so examples in comments and
    /// field-looking text inside strings cannot steal the diagnostic underline.
    fn findFieldOffset(source: [:0]const u8, diagnostic: ValidationDiagnostic) ?usize {
        const parent_field = diagnostic.kind.parentField();
        const field = diagnostic.kind.field();
        var tokenizer = std.zig.Tokenizer.init(source);
        var previous_tag: std.zig.Token.Tag = .invalid;
        var found_parent = parent_field == null;
        var parent_depth: usize = 0;
        var depth: usize = 0;
        var item: usize = 0;
        var in_target_item = diagnostic.index == null;

        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) return null;

            if (token.tag == .identifier and previous_tag == .period) {
                const name = source[token.loc.start..token.loc.end];
                if (!found_parent and std.mem.eql(u8, name, parent_field.?)) {
                    found_parent = true;
                } else if (found_parent and in_target_item and std.mem.eql(u8, name, field)) {
                    return token.loc.start - 1;
                } else if (parent_field == null and std.mem.eql(u8, name, field)) {
                    return token.loc.start - 1;
                }
            }

            if (found_parent and parent_depth == 0 and token.tag == .l_brace) {
                parent_depth = depth + 1;
            } else if (parent_depth > 0 and diagnostic.index != null and
                token.tag == .l_brace and depth == parent_depth and previous_tag == .period)
            {
                in_target_item = item == diagnostic.index.?;
                item += 1;
            }

            if (token.tag == .l_brace) depth += 1;
            if (token.tag == .r_brace) {
                if (depth == parent_depth + 1) in_target_item = false;
                depth -= 1;
            }
            previous_tag = token.tag;
        }
    }

    fn writeSourceExcerpt(
        writer: *std.Io.Writer,
        path: []const u8,
        source: []const u8,
        location: SourceLocation,
        underline_len: usize,
    ) !void {
        const line_number = location.line + 1;
        try writer.print("  --> {s}:{d}:{d}\n", .{ path, line_number, location.column + 1 });
        try writer.writeAll("   |\n");
        try writer.print("{d: >3} | {s}\n", .{ line_number, source[location.line_start..location.line_end] });
        try writer.writeAll("   | ");
        try writer.splatByteAll(' ', location.column);
        try writer.splatByteAll('^', @max(underline_len, 1));
        try writer.writeByte('\n');
    }

    fn writeDiagnosticPath(writer: *std.Io.Writer, diagnostic: ValidationDiagnostic) !void {
        if (diagnostic.kind.parentField()) |parent| {
            try writer.print(".{s}", .{parent});
            if (diagnostic.index) |index| try writer.print("[{d}]", .{index});
            try writer.print(".{s}", .{diagnostic.kind.field()});
        } else {
            try writer.print(".{s}", .{diagnostic.kind.field()});
            if (diagnostic.index) |index| try writer.print("[{d}]", .{index});
        }
    }

    fn writeValidationMessage(writer: *std.Io.Writer, config: *const Config, diagnostic: ValidationDiagnostic) !void {
        switch (diagnostic.kind) {
            .too_many_workspaces => try writer.print("expected at most {d} workspaces, found {d}", .{
                workspace.max_workspaces,
                config.workspace_names.len,
            }),
            .invalid_workspace_name => try writer.writeAll("workspace names must be valid UTF-8 and contain no NUL bytes"),
            .invalid_bsp_split_ratio => try writer.print("expected a finite value from 0.1 through 0.9, found {d}", .{config.bsp_split_ratio}),
            .invalid_dim_level => try writer.print("expected a finite value from 0 through 1, found {d}", .{config.dimmed_inactive.level}),
            .unknown_key_name => try writer.print("unknown key name \"{s}\"; expected a letter, digit, or named navigation key", .{
                config.keybinds[diagnostic.index.?].key,
            }),
            .invalid_keybind_workspace => try writer.print("workspace must be from 1 through {d}, found {d}", .{
                validationWorkspaceCount(config),
                config.keybinds[diagnostic.index.?].arg,
            }),
            .invalid_keybind_display => try writer.print("display must be next (0), previous (255), or from 1 through {d}; found {d}", .{
                workspace.max_displays,
                config.keybinds[diagnostic.index.?].arg,
            }),
            .empty_app_rule_id, .empty_workspace_assignment_id => try writer.writeAll("app_id must not be empty"),
            .invalid_app_rule_workspace => try writer.print("workspace must be from 1 through {d}, found {d}", .{
                validationWorkspaceCount(config),
                config.app_rules[diagnostic.index.?].workspace.?,
            }),
            .duplicate_app_rule => try writer.print("duplicate rule for app_id \"{s}\"", .{config.app_rules[diagnostic.index.?].app_id}),
            .invalid_workspace_assignment => try writer.print("workspace must be from 1 through {d}, found {d}", .{
                validationWorkspaceCount(config),
                config.workspace_assignments[diagnostic.index.?].workspace,
            }),
            .duplicate_workspace_assignment => try writer.print("duplicate assignment for app_id \"{s}\"", .{
                config.workspace_assignments[diagnostic.index.?].app_id,
            }),
        }
    }

    fn writeValidationDiagnostic(
        writer: *std.Io.Writer,
        path: []const u8,
        source: [:0]const u8,
        config: *const Config,
        diagnostic: ValidationDiagnostic,
    ) !void {
        try writer.writeAll("error: invalid value for `");
        try writeDiagnosticPath(writer, diagnostic);
        try writer.writeAll("`\n");

        if (findFieldOffset(source, diagnostic)) |offset| {
            try writeSourceExcerpt(writer, path, source, sourceLocation(source, offset), diagnostic.kind.field().len + 1);
        } else {
            try writer.print("  --> {s}\n", .{path});
        }
        try writer.writeAll("   = ");
        try writeValidationMessage(writer, config, diagnostic);
        try writer.writeByte('\n');
    }

    fn writeParseDiagnostic(
        writer: *std.Io.Writer,
        path: []const u8,
        source: []const u8,
        _: *const std.zon.parse.Diagnostics,
        parse_error: std.zon.parse.Diagnostics.Error,
    ) !void {
        switch (parseDiagnosticKind(parse_error)) {
            .invalid_field => try writer.writeAll("warning: invalid field ignored\n"),
            .invalid_value => try writer.writeAll("error: invalid value\n"),
            .invalid_syntax => try writer.writeAll("error: invalid ZON syntax\n"),
        }
        try writeSourceExcerpt(writer, path, source, .{
            .line = parse_error.loc.line,
            .column = parse_error.loc.column,
            .line_start = parse_error.loc.line_start,
            .line_end = parse_error.loc.line_end,
        }, 1);
        try writer.print("   = {s}\n", .{parse_error.msg});

        for (parse_error.notes) |note| {
            try writer.print("   = note: {s}\n", .{note.msg});
            // This supported-field list identifies SwipeConfig. The same names
            // in other config objects should retain only the generic warning.
            if (!std.mem.eql(u8, note.msg, "supported: 'enabled', 'reverse'")) continue;
            if (std.mem.eql(u8, parse_error.msg, "unexpected field 'fingers'")) {
                try writer.writeAll("   = note: swipe.fingers was removed; configure finger count in macOS System Settings > Trackpad > More Gestures > Swipe between full-screen applications\n");
            } else if (std.mem.eql(u8, parse_error.msg, "unexpected field 'distance_pct'")) {
                try writer.writeAll("   = note: swipe.distance_pct was removed; workspace switching now uses native gesture direction rather than a configured distance threshold\n");
            }
        }
    }

    const ParseDiagnosticKind = enum {
        invalid_field,
        invalid_value,
        invalid_syntax,
    };

    fn parseDiagnosticKind(parse_error: std.zon.parse.Diagnostics.Error) ParseDiagnosticKind {
        if (isUnexpectedField(parse_error)) return .invalid_field;
        if (std.mem.indexOf(u8, parse_error.msg, "after initializer") != null) return .invalid_syntax;
        return .invalid_value;
    }

    fn isUnexpectedField(parse_error: std.zon.parse.Diagnostics.Error) bool {
        return std.mem.startsWith(u8, parse_error.msg, "unexpected field '");
    }

    fn blankSourceRange(source: []u8, start: usize, end: usize) void {
        for (source[start..end]) |*char| {
            if (char.* != '\n' and char.* != '\r') char.* = ' ';
        }
    }

    /// Remove one unknown field initializer while preserving every byte offset, so
    /// reparsing can reveal the next typed error without moving source locations.
    fn maskUnknownField(source: [:0]u8, identifier_offset: usize) bool {
        var tokenizer = std.zig.Tokenizer.init(source);
        var found_identifier = false;
        var found_equal = false;
        var braces: usize = 0;
        var brackets: usize = 0;
        var parens: usize = 0;
        const start = if (identifier_offset > 0 and source[identifier_offset - 1] == '.')
            identifier_offset - 1
        else
            identifier_offset;

        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) return false;
            if (!found_identifier) {
                found_identifier = token.tag == .identifier and token.loc.start == identifier_offset;
                continue;
            }
            if (!found_equal) {
                found_equal = token.tag == .equal;
                continue;
            }

            const at_value_depth = braces == 0 and brackets == 0 and parens == 0;
            if (at_value_depth and token.tag == .comma) {
                blankSourceRange(source, start, token.loc.end);
                return true;
            }
            if (at_value_depth and token.tag == .r_brace) {
                blankSourceRange(source, start, token.loc.start);
                return true;
            }
            switch (token.tag) {
                .l_brace => braces += 1,
                .r_brace => braces -= 1,
                .l_bracket => brackets += 1,
                .r_bracket => brackets -= 1,
                .l_paren => parens += 1,
                .r_paren => parens -= 1,
                else => {},
            }
        }
    }

    const ParseRecovery = enum {
        valid,
        ignored_unknown_fields,
        fatal,
    };

    const ParseDiagnosticSink = struct {
        context: *anyopaque,
        emitFn: *const fn (*anyopaque, *const std.zon.parse.Diagnostics, std.zon.parse.Diagnostics.Error) bool,

        fn emit(
            self: ParseDiagnosticSink,
            diagnostics: *const std.zon.parse.Diagnostics,
            parse_error: std.zon.parse.Diagnostics.Error,
        ) bool {
            return self.emitFn(self.context, diagnostics, parse_error);
        }
    };

    fn visitRecoveredParseDiagnostics(
        source: [:0]const u8,
        sink: *const ParseDiagnosticSink,
    ) !ParseRecovery {
        const allocator = std.heap.c_allocator;
        const recovery_source = try allocator.dupeSentinel(u8, source, 0);
        defer allocator.free(recovery_source);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ignored_unknown_fields = false;

        while (true) {
            _ = arena.reset(.retain_capacity);
            const parse_allocator = arena.allocator();
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            _ = std.zon.parse.fromSlice(Config, .{
                .gpa = parse_allocator,
                .arena = parse_allocator,
                .source = recovery_source,
                .diagnostics = &diagnostics,
            }) catch |err| {
                if (err != error.ParseZon) {
                    return err;
                }
                var unknown_field_offset: ?usize = null;
                var error_count: usize = 0;
                for (diagnostics.errors) |parse_error| {
                    error_count += 1;
                    const offset = parse_error.loc.line_start + parse_error.loc.column;
                    if (error_count == 1 and isUnexpectedField(parse_error)) {
                        unknown_field_offset = offset;
                    }
                    if (!sink.emit(&diagnostics, parse_error)) {
                        return error.DiagnosticAborted;
                    }
                }
                if (error_count == 0) {
                    return error.ParseZon;
                }
                if (error_count == 1) {
                    if (unknown_field_offset) |offset| {
                        if (maskUnknownField(recovery_source, offset)) {
                            ignored_unknown_fields = true;
                            continue;
                        }
                    }
                }
                return .fatal;
            };
            return if (ignored_unknown_fields) .ignored_unknown_fields else .valid;
        }
    }

    const WriteParseContext = struct {
        writer: *std.Io.Writer,
        path: []const u8,
        source: [:0]const u8,
        failure: ?anyerror = null,

        fn emit(
            context: *anyopaque,
            diagnostics: *const std.zon.parse.Diagnostics,
            parse_error: std.zon.parse.Diagnostics.Error,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            writeParseDiagnostic(self.writer, self.path, self.source, diagnostics, parse_error) catch |err| {
                self.failure = err;
                return false;
            };
            return true;
        }
    };

    fn writeRecoveredParseDiagnostics(
        writer: *std.Io.Writer,
        path: []const u8,
        source: [:0]const u8,
    ) !ParseRecovery {
        var context: WriteParseContext = .{ .writer = writer, .path = path, .source = source };
        const sink: ParseDiagnosticSink = .{ .context = &context, .emitFn = WriteParseContext.emit };
        const recovery = visitRecoveredParseDiagnostics(source, &sink) catch |err| {
            if (err == error.DiagnosticAborted) return context.failure orelse err;
            return err;
        };
        return recovery;
    }

    const LogValidationContext = struct {
        path: []const u8,
        source: [:0]const u8,
        config: *const Config,
    };

    fn logValidationDiagnostic(context: *anyopaque, diagnostic: ValidationDiagnostic) bool {
        const diagnostic_context: *const LogValidationContext = @ptrCast(@alignCast(context));
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        writeValidationDiagnostic(
            &writer,
            diagnostic_context.path,
            diagnostic_context.source,
            diagnostic_context.config,
            diagnostic,
        ) catch {
            log.err("invalid configuration (diagnostic was too large to display)", .{});
            return true;
        };
        log.err("{s}", .{writer.buffered()});
        return true;
    }

    fn logValidationDiagnostics(path: []const u8, source: [:0]const u8, config: *const Config) void {
        var context: LogValidationContext = .{ .path = path, .source = source, .config = config };
        const sink: ValidationSink = .{ .context = &context, .emitFn = logValidationDiagnostic };
        visitValidationDiagnostics(config, &sink);
    }

    const LogParseContext = struct {
        path: []const u8,
        source: [:0]const u8,

        fn emit(
            context: *anyopaque,
            diagnostics: *const std.zon.parse.Diagnostics,
            parse_error: std.zon.parse.Diagnostics.Error,
        ) bool {
            const self: *const @This() = @ptrCast(@alignCast(context));
            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            writeParseDiagnostic(&writer, self.path, self.source, diagnostics, parse_error) catch {
                log.err("config diagnostic at {s} was too large to display", .{self.path});
                return true;
            };
            switch (parseDiagnosticKind(parse_error)) {
                .invalid_field => log.warn("{s}", .{writer.buffered()}),
                .invalid_value, .invalid_syntax => log.err("{s}", .{writer.buffered()}),
            }
            return true;
        }
    };

    fn logParseDiagnostics(path: []const u8, source: [:0]const u8) ParseRecovery {
        var context: LogParseContext = .{ .path = path, .source = source };
        const sink: ParseDiagnosticSink = .{ .context = &context, .emitFn = LogParseContext.emit };
        return visitRecoveredParseDiagnostics(source, &sink) catch |err| {
            log.err("failed to produce config diagnostic for {s}: {}", .{ path, err });
            return .fatal;
        };
    }
};

pub fn load(allocator: std.mem.Allocator, explicit_path: ?[]const u8) Config {
    const path = resolvePath(allocator, explicit_path) catch return .{};
    defer allocator.free(path);

    return loadFromPath(allocator, path) orelse {
        if (explicit_path != null) {
            log.err("failed to load config from {s}, using defaults", .{path});
        } else {
            log.info("no config file found, using defaults", .{});
        }
        return .{};
    };
}

/// Resolve the configured path even when it does not exist yet, allowing the
/// daemon to notice a config file created after startup.
pub fn resolvePath(allocator: std.mem.Allocator, explicit_path: ?[]const u8) ![:0]u8 {
    if (explicit_path) |path| return allocator.dupeSentinel(u8, path, 0);

    if (osutil.getenv("XDG_CONFIG_HOME")) |config_home| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/bobrwm/config.zon", .{config_home}, 0);
    }

    const home = osutil.getenv("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrintSentinel(allocator, "{s}/.config/bobrwm/config.zon", .{home}, 0);
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Config {
    log.info("loading config from {s}", .{path});

    // libc-based read; std.fs.cwd was removed in Zig 0.16. Caller paths
    // come from CLI / env so they fit easily in PATH_MAX.
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(path_z);

    // Source is intentionally not freed here: zon.parse may retain references
    // into it for string fields. Caller passes an arena allocator whose
    // deinit handles cleanup.
    const source = osutil.readFileAllocSentinel(allocator, path_z, 1024 * 1024) orelse return null;

    // Parse strictly first so unknown fields are diagnosed. Only that error
    // class gets a tolerant retry; invalid values and syntax remain fatal.
    // Config holds slices, so both passes require the allocating parser.
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = parse: {
        break :parse std.zon.parse.fromSlice(Config, .{
            .gpa = allocator,
            .arena = allocator,
            .source = source,
            .diagnostics = &diagnostics,
        }) catch |err| {
            if (err != error.ParseZon) {
                log.err("failed to parse config {s}: {}", .{ path, err });
                return null;
            }
            if (ConfigDiagnostics.logParseDiagnostics(path, source) != .ignored_unknown_fields) return null;

            break :parse std.zon.parse.fromSlice(Config, .{
                .gpa = allocator,
                .arena = allocator,
                .source = source,
                .diagnostics = &diagnostics,
                .ignore_unknown_fields = true,
            }) catch |recovery_err| {
                log.err("failed to recover config {s} after ignoring invalid fields: {}", .{ path, recovery_err });
                return null;
            };
        };
    };
    if (ConfigDiagnostics.validationDiagnostic(&parsed) != null) {
        ConfigDiagnostics.logValidationDiagnostics(path, source, &parsed);
        return null;
    }

    log.info("loaded config: {d} keybind entries, {d} app rules, {d} workspace assignments", .{
        parsed.keybinds.len,
        parsed.app_rules.len,
        parsed.workspace_assignments.len,
    });
    return parsed;
}

// Bundle ID helper

pub fn getAppBundleId(pid: i32, buf: *[256]u8) ?[]const u8 {
    return osutil.appBundleId(pid, buf);
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
        .{ "=", 0x18 },      .{ "-", 0x1B },
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
    try t.expect(!cfg.swipe.reverse);
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

test "validate accepts defaults and a reduced workspace set" {
    const defaults: Config = .{};
    try validate(&defaults);
    try t.expectEqual(workspace.max_workspaces, workspaceCount(&defaults));

    const reduced: Config = .{ .workspace_names = &.{ "term", "web", "code", "chat" } };
    try validate(&reduced);
    try t.expectEqual(@as(u8, 4), workspaceCount(&reduced));
}

test "validate rejects geometry values that are not bounded" {
    var cfg: Config = .{};

    cfg.bsp_split_ratio = std.math.inf(f64);
    try t.expectError(error.InvalidBspSplitRatio, validate(&cfg));

    cfg = .{};
    cfg.dimmed_inactive.level = std.math.nan(f32);
    try t.expectError(error.InvalidDimLevel, validate(&cfg));
}

test "semantic validation renders every invalid field" {
    const source: [:0]const u8 =
        \\.{
        \\    .bsp_split_ratio = 1.0,
        \\    .dimmed_inactive = .{ .level = -0.1 },
        \\    .keybinds = .{
        \\        .{ .key = "F1", .action = .focus_left },
        \\        .{ .key = "F2", .action = .focus_right },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromSlice(Config, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });
    const RenderContext = struct {
        writer: *std.Io.Writer,
        source: [:0]const u8,
        config: *const Config,
        failed: bool = false,

        fn emit(context: *anyopaque, diagnostic: ConfigDiagnostics.ValidationDiagnostic) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            ConfigDiagnostics.writeValidationDiagnostic(
                self.writer,
                "/tmp/config.zon",
                self.source,
                self.config,
                diagnostic,
            ) catch {
                self.failed = true;
                return false;
            };
            return true;
        }
    };
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var context: RenderContext = .{ .writer = &writer, .source = source, .config = &config };
    const sink: ConfigDiagnostics.ValidationSink = .{ .context = &context, .emitFn = RenderContext.emit };

    ConfigDiagnostics.visitValidationDiagnostics(&config, &sink);
    try t.expect(!context.failed);
    const rendered = writer.buffered();

    try t.expectEqual(@as(usize, 4), std.mem.count(u8, rendered, "error: invalid value for `"));
    try t.expect(std.mem.indexOf(u8, rendered, "`.bsp_split_ratio`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "`.dimmed_inactive.level`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "`.keybinds[0].key`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "`.keybinds[1].key`") != null);
}

test "validate rejects invalid workspace references and duplicate rules" {
    const too_many_names: Config = .{
        .workspace_names = &.{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" },
    };
    try t.expectError(error.TooManyWorkspaces, validate(&too_many_names));

    const invalid_keybinds = [_]Keybind{
        .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 5 },
    };
    const bad_keybind: Config = .{
        .workspace_names = &.{ "1", "2", "3", "4" },
        .keybinds = &invalid_keybinds,
    };
    try t.expectError(error.InvalidKeybindWorkspace, validate(&bad_keybind));

    const bad_assignment: Config = .{
        .workspace_names = &.{ "1", "2" },
        .workspace_assignments = &.{.{ .app_id = "com.example.App", .workspace = 0 }},
    };
    try t.expectError(error.InvalidWorkspaceAssignment, validate(&bad_assignment));

    const duplicate_rules: Config = .{
        .app_rules = &.{
            .{ .app_id = "com.example.App", .float = true },
            .{ .app_id = "com.example.App", .workspace = 2 },
        },
    };
    try t.expectError(error.DuplicateAppRule, validate(&duplicate_rules));
}

test "validate accepts relative display keybind targets" {
    const keybinds = [_]Keybind{
        .{ .key = "n", .action = .move_workspace_to_display, .arg = next_display_arg },
        .{ .key = "p", .action = .move_workspace_to_display, .arg = previous_display_arg },
        .{ .key = "1", .action = .move_workspace_to_display, .arg = 1 },
    };
    const cfg: Config = .{ .keybinds = &keybinds };
    try validate(&cfg);

    const invalid_keybinds = [_]Keybind{
        .{ .key = "9", .action = .move_workspace_to_display, .arg = workspace.max_displays + 1 },
    };
    const invalid: Config = .{ .keybinds = &invalid_keybinds };
    try t.expectError(error.InvalidKeybindDisplay, validate(&invalid));
}

test "validate rejects unknown keys and invalid workspace name text" {
    const keybinds = [_]Keybind{
        .{ .key = "F1", .mods = .{ .alt = true }, .action = .focus_left },
    };
    const unknown_key: Config = .{ .keybinds = &keybinds };
    try t.expectError(error.UnknownKeyName, validate(&unknown_key));

    const invalid_utf8 = [_]u8{0xff};
    const invalid_name: Config = .{ .workspace_names = &.{invalid_utf8[0..]} };
    try t.expectError(error.InvalidWorkspaceName, validate(&invalid_name));
}

test "parse recovery reports unknown fields at every nesting level" {
    const source: [:0]const u8 =
        \\.{
        \\    .your_mom = "fat",
        \\    .monster = "locco",
        \\    .swipe = .{
        \\        .nonsense = true,
        \\        .also_bad = 12,
        \\    },
        \\    .gaps = .{
        \\        .outer = .{ .wat = 1, .nope = 2 },
        \\    },
        \\}
    ;
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const recovery = try ConfigDiagnostics.writeRecoveredParseDiagnostics(&writer, "/tmp/config.zon", source);
    const rendered = writer.buffered();

    try t.expectEqual(ConfigDiagnostics.ParseRecovery.ignored_unknown_fields, recovery);
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, rendered, "warning: invalid field ignored"));
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'your_mom'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'monster'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'nonsense'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'also_bad'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'wat'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'nope'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:5:") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "|         .nonsense = true,") != null);
}

test "parse recovery explains removed swipe settings only in swipe config" {
    const source: [:0]const u8 =
        \\.{
        \\    .fingers = 3,
        \\    .swipe = .{
        \\        .enabled = true,
        \\        .fingers = 4,
        \\        .distance_pct = 10,
        \\    },
        \\    .gaps = .{ .distance_pct = 5 },
        \\}
    ;
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const recovery = try ConfigDiagnostics.writeRecoveredParseDiagnostics(&writer, "/tmp/config.zon", source);
    const rendered = writer.buffered();

    try t.expectEqual(ConfigDiagnostics.ParseRecovery.ignored_unknown_fields, recovery);
    try t.expectEqual(@as(usize, 4), std.mem.count(u8, rendered, "warning: invalid field ignored"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "swipe.fingers was removed"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "swipe.distance_pct was removed"));
    try t.expect(std.mem.indexOf(u8, rendered, "macOS System Settings > Trackpad > More Gestures") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "native gesture direction rather than a configured distance threshold") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:5:") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:6:") != null);
}

test "parse recovery continues from an unknown field to a typed error" {
    const source: [:0]const u8 =
        \\.{
        \\    .unknown = .{ .nested = true },
        \\    .layout = "bsp",
        \\}
    ;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const recovery = try ConfigDiagnostics.writeRecoveredParseDiagnostics(&writer, "/tmp/config.zon", source);
    const rendered = writer.buffered();

    try t.expectEqual(ConfigDiagnostics.ParseRecovery.fatal, recovery);
    try t.expect(std.mem.indexOf(u8, rendered, "warning: invalid field ignored") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "error: invalid value") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "|     .layout = \"bsp\",") != null);
}

test "parse recovery masks a final nested initializer without a comma" {
    const source: [:0]const u8 =
        \\.{
        \\    .swipe = .{
        \\        .enabled = true,
        \\        .unknown = .{
        \\            .nested = true,
        \\        }
        \\    }
        \\}
    ;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const recovery = try ConfigDiagnostics.writeRecoveredParseDiagnostics(&writer, "/tmp/config.zon", source);
    const rendered = writer.buffered();

    try t.expectEqual(ConfigDiagnostics.ParseRecovery.ignored_unknown_fields, recovery);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "warning: invalid field ignored"));
    try t.expect(std.mem.indexOf(u8, rendered, "unexpected field 'unknown'") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:4:") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "|         .unknown = .{") != null);
}

test "validation diagnostic identifies an indexed field and its source line" {
    const source: [:0]const u8 =
        \\.{
        \\    .workspace_names = .{ "one", "two" },
        \\    .keybinds = .{
        \\        .{ .key = "h", .action = .focus_left },
        \\        .{ .key = "3", .action = .focus_workspace, .arg = 3 },
        \\    },
        \\}
    ;
    const keybinds = [_]Keybind{
        .{ .key = "h", .action = .focus_left },
        .{ .key = "3", .action = .focus_workspace, .arg = 3 },
    };
    const config: Config = .{
        .workspace_names = &.{ "one", "two" },
        .keybinds = &keybinds,
    };
    const diagnostic = ConfigDiagnostics.validationDiagnostic(&config).?;

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try ConfigDiagnostics.writeValidationDiagnostic(&writer, "/tmp/config.zon", source, &config, diagnostic);
    const rendered = writer.buffered();

    try t.expect(std.mem.indexOf(u8, rendered, "error: invalid value for `.keybinds[1].arg`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:5:52") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "|         .{ .key = \"3\", .action = .focus_workspace, .arg = 3 },") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "workspace must be from 1 through 2, found 3") != null);
}

test "parse diagnostics report syntax errors without repairing the source" {
    const source: [:0]const u8 =
        \\.{
        \\    .layout = .bsp
        \\    .bsp_split = .auto,
        \\    .gaps = .{
        \\        .inner = 8
        \\        .outer = .{},
        \\    },
        \\}
    ;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const recovery = try ConfigDiagnostics.writeRecoveredParseDiagnostics(&writer, "/tmp/config.zon", source);
    const rendered = writer.buffered();

    try t.expectEqual(ConfigDiagnostics.ParseRecovery.fatal, recovery);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "error: invalid ZON syntax"));
    try t.expect(std.mem.indexOf(u8, rendered, "expected ',' after initializer") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config.zon:") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "|     .bsp_split = .auto,") != null);
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

    try t.expectEqual(Action.reload_config, default_keybinds[29].action);
    try t.expect(std.mem.eql(u8, "r", default_keybinds[29].key));
    try t.expect(default_keybinds[29].mods.alt and default_keybinds[29].mods.shift);

    const cfg: Config = .{};
    const grow = cfg.findKeybind(.resize_grow, 0).?;
    const shrink = cfg.findKeybind(.resize_shrink, 0).?;
    try t.expectEqual(@as(u16, 0x18), keybindToShim(grow).?.keycode);
    try t.expectEqual(@as(u16, 0x1B), keybindToShim(shrink).?.keycode);
    try t.expectEqual(shim.BW_MOD_ALT, keybindToShim(grow).?.mods);
    try t.expectEqual(shim.BW_MOD_ALT, keybindToShim(shrink).?.mods);
}

test "disabled default keybinds leave omitted and empty keybinds unbound" {
    for ([_]Config{
        .{ .disable_default_keybinds = true },
        .{ .disable_default_keybinds = true, .keybinds = &.{} },
    }) |cfg| {
        var table = try KeybindTable.init(t.allocator, &cfg);
        defer table.deinit(t.allocator);

        try t.expectEqual(@as(usize, 0), cfg.buildKeybinds(&table).len);
        try t.expectEqual(@as(?Keybind, null), cfg.findKeybind(.focus_workspace, 1));
    }
}

test "disabled default keybinds retain only explicit bindings parsed from ZON" {
    const source =
        \\.{
        \\    .disable_default_keybinds = true,
        \\    .keybinds = .{
        \\        .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 3 },
        \\        .{ .key = "f", .mods = .{ .ctrl = true }, .action = .toggle_float },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const cfg = try std.zon.parse.fromSlice(Config, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const binds = cfg.buildKeybinds(&table);
    try t.expectEqual(@as(usize, 2), binds.len);
    try t.expectEqual(keyNameToCode("1").?, binds[0].keycode);
    try t.expectEqual(shim.BW_MOD_ALT, binds[0].mods);
    try t.expectEqual(@backingInt(Action.focus_workspace), binds[0].action);
    try t.expectEqual(@as(u32, 3), binds[0].arg);
    try t.expectEqual(keyNameToCode("f").?, binds[1].keycode);
    try t.expectEqual(shim.BW_MOD_CTRL, binds[1].mods);
    try t.expectEqual(@backingInt(Action.toggle_float), binds[1].action);
    try t.expectEqualStrings("1", cfg.findKeybind(.focus_workspace, 3).?.key);
    try t.expectEqualStrings("f", cfg.findKeybind(.toggle_float, 0).?.key);
    try t.expectEqual(@as(?Keybind, null), cfg.findKeybind(.focus_workspace, 2));
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

    try t.expectEqual(@as(usize, default_keybind_count + 1), merged.len);
    try t.expectEqual(keyNameToCode("1").?, merged[0].keycode);
    try t.expectEqual(shim.BW_MOD_ALT, merged[0].mods);
    try t.expectEqual(@backingInt(Action.focus_workspace), merged[0].action);
    try t.expectEqual(@as(u32, 9), merged[0].arg);
    try t.expectEqual(keyNameToCode("f").?, merged[default_keybind_count].keycode);
    try t.expectEqual(@backingInt(Action.toggle_fullscreen), merged[default_keybind_count].action);
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
    try t.expectEqual(@backingInt(Action.focus_workspace), merged[0].action);
    try t.expectEqual(@as(u32, 1), merged[0].arg);
    try t.expectEqual(shim.BW_MOD_ALT | shim.BW_MOD_SHIFT, merged[9].mods);
    try t.expectEqual(@backingInt(Action.toggle_fullscreen), merged[9].action);
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
    try t.expectEqual(@backingInt(Action.toggle_split), merged[default_keybind_count].action);
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

test "loadFromPath: custom zon" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const zon =
        \\.{
        \\    .unknown_root = "ignored",
        \\    .keybinds = .{
        \\        .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_fullscreen },
        \\        .{ .key = "space", .mods = .{ .alt = true, .shift = true }, .action = .toggle_float },
        \\    },
        \\    .workspace_assignments = .{
        \\        .{ .app_id = "com.test.App", .workspace = 3 },
        \\    },
        \\    .swipe = .{ .enabled = true, .reverse = true, .fingres = 5 },
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
    try t.expect(cfg.swipe.reverse);

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
