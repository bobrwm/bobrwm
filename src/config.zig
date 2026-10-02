//! Configuration for bobrwm: the `Config` type, keybind tables, and
//! semantic validation. Reads the file at XDG_CONFIG_HOME/bobrwm/config,
//! ~/.config/bobrwm/config, or a path passed via CLI; `config_file` owns the
//! file syntax.

const std = @import("std");
const shim = @import("shim_api.zig");
const tiling = @import("tiling.zig");
const osutil = @import("osutil.zig");
const animation = @import("animation.zig");
const workspace = @import("workspace.zig");
const config_file = @import("config_file.zig");

const log = std.log.scoped(.config);

// Config types

pub const Config = struct {
    /// Use only your own `keybind` lines instead of adding them to the
    /// built-in defaults. With no `keybind` lines, no shortcuts are
    /// registered.
    ///
    /// This also drops the default `reload_config` shortcut, so use
    /// `bobrwm reload-config` unless you bind `reload_config` yourself.
    disable_default_keybinds: bool = false,
    /// Bind a key and modifiers to an action, as `trigger=action`, or
    /// `trigger=action:argument` for actions that take one. Repeat the line
    /// for each shortcut.
    ///
    ///     keybind = alt+h=focus_left
    ///     keybind = alt+shift+1=move_to_workspace:1
    ///     keybind = ctrl+alt+n=move_workspace_to_display:next
    ///
    /// The trigger is any of `ctrl`, `alt`, `shift`, and `cmd` joined with
    /// `+`, then the key: a lowercase letter, a digit, `=`, `-`, `return`,
    /// `tab`, `space`, `delete`, `escape`, `left`, `right`, `up`, or `down`.
    /// `opt`, `option`, `control`, `command`, and `super` also work as
    /// modifier names.
    ///
    /// Run `bobrwm list-actions --docs` for the actions. Workspace actions
    /// take a workspace number; `move_workspace_to_display` takes a display
    /// number, `next`, or `prev`.
    ///
    /// Your keybinds are added to the built-in defaults. One with the same
    /// trigger as a default replaces it. See `disable-default-keybinds` to
    /// drop the defaults. An empty `keybind =` clears the keybinds set above
    /// it.
    keybinds: []const Keybind = &default_keybinds,
    /// Per-app behavior keyed by bundle identifier, as comma-separated
    /// `field:value` pairs. Repeat the line for each app; at most one rule per
    /// app.
    ///
    ///     app-rule = app-id:com.apple.Safari,workspace:2
    ///     app-rule = app-id:com.apple.systempreferences,float:true
    ///
    /// Fields:
    ///
    ///   app-id     Bundle identifier of the app. Required. Find one with
    ///              `osascript -e 'id of app "Safari"'`.
    ///   workspace  Workspace number the app's windows open on.
    ///   float      `true` to open the app's windows floating.
    app_rules: []const AppRule = &.{},
    /// Name of a managed workspace. Repeat the line once per workspace, in
    /// order: the number of names is the workspace count. With no names,
    /// bobrwm manages 10 unnamed workspaces. At most 10.
    ///
    ///     workspace-name = term
    ///     workspace-name = web
    ///     workspace-name = code
    ///
    /// Workspace numbers stay 1-based, so three names create workspaces 1
    /// through 3, and keybinds and app rules must reference workspaces in
    /// that range.
    ///
    /// Note: changing the number of workspaces requires a restart. Other
    /// settings reload live.
    workspace_names: []const []const u8 = &.{},
    // Read by the optional `bobrwm-swipe` companion; bobrwm itself only
    // parses these.
    swipe: SwipeConfig = .{},
    // Owned black overlay panels; see `DimConfig`.
    dimmed_inactive: DimConfig = .{},
    gaps: Gaps = .{},
    /// Tiling algorithm: `bsp` for binary space partitioning, or `monocle`
    /// to show each window fullscreen.
    layout: tiling.LayoutKind = .bsp,
    /// Axis used when a BSP tile splits. `auto` picks the axis from the
    /// target tile's shape, `horizontal` always splits left/right, and
    /// `vertical` always splits top/bottom.
    bsp_split: tiling.SplitMode = .auto,
    /// Which tile a new window splits: `focused`, `first`, `last`, or
    /// `min_depth` (the shallowest leaf).
    bsp_insert_point: tiling.InsertionPointPolicy = .focused,
    /// Ratio for newly created BSP splits. Must be a finite value from 0.1
    /// through 0.9.
    bsp_split_ratio: f64 = 0.5,
    /// Side a new window takes when it splits a tile: `second` is
    /// right/bottom, `first` is left/top.
    new_window_split: tiling.InsertChild = .second,
    animation: animation.AnimationConfig = .{},
    /// Register Bobrwm.app as a login item. Reconciled against
    /// ServiceManagement on startup and on every reload.
    ///
    /// macOS may hold the first registration for approval in System Settings
    /// under General > Login Items; bobrwm logs a warning while it waits.
    /// While registered, launchd restarts bobrwm if it crashes, but not after
    /// you quit it from the menu bar.
    start_at_login: bool = false,

    /// Look up the assigned workspace for a given bundle identifier.
    pub fn workspaceForApp(self: *const Config, bundle_id: []const u8) ?u8 {
        for (self.app_rules) |r| {
            if (std.mem.eql(u8, r.app_id, bundle_id)) return r.workspace;
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

    /// True when any rule could assign an app to a workspace, so callers can
    /// skip the bundle-id lookup entirely when nothing is configured.
    pub fn hasAppWorkspaceRules(self: *const Config) bool {
        return self.app_rules.len > 0;
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
    alt: bool = false,
    shift: bool = false,
    cmd: bool = false,
    ctrl: bool = false,
};

pub const Action = enum(u8) {
    /// Switch to the workspace with the given number.
    focus_workspace = 20,
    /// Move the focused window to the workspace with the given number.
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
    /// Move the active workspace to a display: a display number from 1
    /// through 8, `next`, or `prev`.
    move_workspace_to_display = 29,
    /// Switch to the previous workspace. At the first workspace, the key
    /// passes through so native Spaces can handle it.
    focus_previous_workspace = 30,
    /// Switch to the next workspace. At the last workspace, the key passes
    /// through so native Spaces can handle it.
    focus_next_workspace = 31,
    /// Toggle inactive-window dimming, regardless of `dimmed-inactive-enabled`.
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
        for (@typeInfo(Action).@"enum".fields) |f| {
            // Verify each Action.<name> has a matching EventKind.hk_<name>;
            // a missing tag triggers a clear comptime error.
            if (std.meta.stringToEnum(event, "hk_" ++ f.name) == null) {
                @compileError("missing EventKind.hk_" ++ f.name ++ " for Action." ++ f.name);
            }
        }
    }
};

/// Sentinel arguments for relative display movement in keybinds.
pub const next_display_arg: u8 = 0;
pub const previous_display_arg: u8 = std.math.maxInt(u8);

pub const Keybind = struct {
    key: []const u8,
    mods: Mods = .{},
    action: Action,
    /// Workspace or display number for the actions in `takesArg`; ignored
    /// by the rest.
    arg: u8 = 0,

    /// Whether the action reads `arg`, so the config writer knows to spell
    /// it out.
    pub fn takesArg(action: Action) bool {
        return switch (action) {
            .focus_workspace, .move_to_workspace, .move_workspace_to_display => true,
            else => false,
        };
    }

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

/// Per-app behavior keyed by bundle identifier. Fields are optional so a rule
/// can set only what it cares about (float-only, workspace-only, or both).
/// User docs live on `Config.app_rules`, since a rule is written on one line.
pub const AppRule = struct {
    app_id: []const u8,
    workspace: ?u8 = null,
    float: bool = false,
};

pub const SwipeConfig = struct {
    /// Let the optional `bobrwm-swipe` companion switch workspaces on
    /// horizontal swipes. At the first or last workspace the gesture passes
    /// through to native Spaces. bobrwm itself only reads these settings;
    /// they take effect while `bobrwm-swipe` runs.
    ///
    /// Note: macOS grants Accessibility per executable, so `bobrwm-swipe`
    /// needs its own grant even when bobrwm is already trusted.
    enabled: bool = false,
    /// Number of fingers in the swipe, from 1 through 16.
    fingers: u8 = 3,
    /// Average horizontal travel before a swipe fires, as a fraction of the
    /// trackpad width: `0.08` is roughly 8%. Greater than 0 and at most 1.
    distance_pct: f64 = 0.08,
    /// Reverse the swipe direction.
    reverse: bool = false,
};

pub const max_swipe_fingers: u8 = 16;

/// Inactive-window dimming via owned black overlay panels. When enabled, every
/// visible managed window except the focused one gets a click-through black
/// overlay at `level` opacity, giving a clean multiplicative darken with no
/// color shift. Works without SIP disabled.
pub const DimConfig = struct {
    /// Dim every visible window except the focused one with a click-through
    /// black overlay. Works without disabling SIP. The `toggle_dimming`
    /// keybind action flips it at runtime.
    ///
    /// Warning: alpha.
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

/// Reject values that parse but violate runtime invariants. Validation
/// happens before a config becomes visible to the main loop, so a bad reload
/// leaves the last known-good config intact.
pub fn validate(config: *const Config) !void {
    const diagnostic = Validation.firstDiagnostic(config) orelse return;
    return diagnostic.kind.asError();
}

/// Semantic checks on a parsed config. Reports which option is wrong and
/// why; `config_file` maps that back to a source line.
pub const Validation = struct {
    pub const Kind = enum {
        too_many_workspaces,
        invalid_workspace_name,
        invalid_bsp_split_ratio,
        invalid_dim_level,
        invalid_swipe_finger_count,
        invalid_swipe_distance,
        unknown_key_name,
        invalid_keybind_workspace,
        invalid_keybind_display,
        empty_app_rule_id,
        invalid_app_rule_workspace,
        duplicate_app_rule,

        fn asError(self: Kind) anyerror {
            return switch (self) {
                .too_many_workspaces => error.TooManyWorkspaces,
                .invalid_workspace_name => error.InvalidWorkspaceName,
                .invalid_bsp_split_ratio => error.InvalidBspSplitRatio,
                .invalid_dim_level => error.InvalidDimLevel,
                .invalid_swipe_finger_count => error.InvalidSwipeFingerCount,
                .invalid_swipe_distance => error.InvalidSwipeDistance,
                .unknown_key_name => error.UnknownKeyName,
                .invalid_keybind_workspace => error.InvalidKeybindWorkspace,
                .invalid_keybind_display => error.InvalidKeybindDisplay,
                .empty_app_rule_id => error.EmptyAppId,
                .invalid_app_rule_workspace => error.InvalidAppRuleWorkspace,
                .duplicate_app_rule => error.DuplicateAppRule,
            };
        }

        /// The config file option the problem is written in. Repeatable
        /// options pair this with the diagnostic's index.
        pub fn option(self: Kind) []const u8 {
            return switch (self) {
                .too_many_workspaces, .invalid_workspace_name => "workspace-name",
                .invalid_bsp_split_ratio => "bsp-split-ratio",
                .invalid_dim_level => "dimmed-inactive-level",
                .invalid_swipe_finger_count => "swipe-fingers",
                .invalid_swipe_distance => "swipe-distance-pct",
                .unknown_key_name, .invalid_keybind_workspace, .invalid_keybind_display => "keybind",
                .empty_app_rule_id, .invalid_app_rule_workspace, .duplicate_app_rule => "app-rule",
            };
        }
    };

    pub const Diagnostic = struct {
        kind: Kind,
        /// Entry of a repeatable option, counted from 0.
        index: ?usize = null,
    };

    /// Receives each problem in source order. Returning false stops the walk.
    pub const Sink = struct {
        context: *anyopaque,
        emitFn: *const fn (*anyopaque, Diagnostic) bool,

        fn emit(self: Sink, diagnostic: Diagnostic) bool {
            return self.emitFn(self.context, diagnostic);
        }
    };

    fn captureFirst(context: *anyopaque, diagnostic: Diagnostic) bool {
        const first: *?Diagnostic = @ptrCast(@alignCast(context));
        first.* = diagnostic;
        return false;
    }

    fn firstDiagnostic(config: *const Config) ?Diagnostic {
        var first: ?Diagnostic = null;
        const sink: Sink = .{ .context = &first, .emitFn = captureFirst };
        visit(config, &sink);
        return first;
    }

    fn workspaceCountForChecks(config: *const Config) usize {
        return if (config.workspace_names.len == 0)
            workspace.max_workspaces
        else
            @min(config.workspace_names.len, workspace.max_workspaces);
    }

    pub fn visit(config: *const Config, sink: *const Sink) void {
        if (config.workspace_names.len > workspace.max_workspaces) {
            // Point at the first name past the limit.
            if (!sink.emit(.{ .kind = .too_many_workspaces, .index = workspace.max_workspaces })) return;
        }
        const workspace_count = workspaceCountForChecks(config);

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
        if (config.swipe.fingers == 0 or config.swipe.fingers > max_swipe_fingers) {
            if (!sink.emit(.{ .kind = .invalid_swipe_finger_count })) return;
        }
        if (!std.math.isFinite(config.swipe.distance_pct) or
            config.swipe.distance_pct <= 0 or config.swipe.distance_pct > 1)
        {
            if (!sink.emit(.{ .kind = .invalid_swipe_distance })) return;
        }

        if (!visitKeybinds(config.keybinds, workspace_count, sink)) return;
        _ = visitAppRules(config.app_rules, workspace_count, sink);
    }

    fn visitKeybinds(
        keybinds: []const Keybind,
        workspace_count: usize,
        sink: *const Sink,
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

    fn visitAppRules(
        rules: []const AppRule,
        workspace_count: usize,
        sink: *const Sink,
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

    pub fn writeMessage(writer: *std.Io.Writer, config: *const Config, diagnostic: Diagnostic) !void {
        switch (diagnostic.kind) {
            .too_many_workspaces => try writer.print("expected at most {d} workspaces, found {d}", .{
                workspace.max_workspaces,
                config.workspace_names.len,
            }),
            .invalid_workspace_name => try writer.writeAll("workspace names must be valid UTF-8 and contain no NUL bytes"),
            .invalid_bsp_split_ratio => try writer.print("expected a finite value from 0.1 through 0.9, found {d}", .{config.bsp_split_ratio}),
            .invalid_dim_level => try writer.print("expected a finite value from 0 through 1, found {d}", .{config.dimmed_inactive.level}),
            .invalid_swipe_finger_count => try writer.print("expected a value from 1 through {d}, found {d}", .{
                max_swipe_fingers,
                config.swipe.fingers,
            }),
            .invalid_swipe_distance => try writer.print("expected a finite value greater than 0 and at most 1, found {d}", .{config.swipe.distance_pct}),
            .unknown_key_name => try writer.print("unknown key \"{s}\"; expected a lowercase letter, a digit, or a named key such as return or left", .{
                config.keybinds[diagnostic.index.?].key,
            }),
            .invalid_keybind_workspace => try writer.print("workspace must be from 1 through {d}, found {d}", .{
                workspaceCountForChecks(config),
                config.keybinds[diagnostic.index.?].arg,
            }),
            .invalid_keybind_display => try writer.print("display must be next, prev, or from 1 through {d}; found {d}", .{
                workspace.max_displays,
                config.keybinds[diagnostic.index.?].arg,
            }),
            .empty_app_rule_id => try writer.writeAll("app-id must not be empty"),
            .invalid_app_rule_workspace => try writer.print("workspace must be from 1 through {d}, found {d}", .{
                workspaceCountForChecks(config),
                config.app_rules[diagnostic.index.?].workspace.?,
            }),
            .duplicate_app_rule => try writer.print("duplicate rule for app-id \"{s}\"", .{config.app_rules[diagnostic.index.?].app_id}),
        }
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
    if (explicit_path) |path| return allocator.dupeZ(u8, path);

    if (osutil.getenv("XDG_CONFIG_HOME")) |config_home| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/bobrwm/config", .{config_home}, 0);
    }

    const home = osutil.getenv("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrintSentinel(allocator, "{s}/.config/bobrwm/config", .{home}, 0);
}

/// Where the ZON config that preceded the current format lived, next to the
/// current one. Only `bobrwm migrate-config` reads it.
pub fn legacyPath(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}.zon", .{path}, 0);
}

/// Load and validate the config at `path`, logging every problem found.
/// Returns null when the file is missing or has any error; unknown options
/// are warnings and do not reject the file. `allocator` must be an arena:
/// the config borrows strings from the source it reads.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Config {
    log.info("loading config from {s}", .{path});

    // libc-based read; std.fs.cwd was removed in Zig 0.16. Caller paths
    // come from CLI / env so they fit easily in PATH_MAX.
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    const source = osutil.readFileAllocSentinel(allocator, path_z, 1024 * 1024) orelse {
        warnIfOnlyLegacyExists(allocator, path);
        return null;
    };

    // Diagnostics are only rendered and logged, never kept, so they get their
    // own arena instead of growing the config's.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var diagnostics: config_file.Diagnostics = .{ .allocator = scratch.allocator() };
    const parsed = config_file.parseAndValidate(allocator, source, &diagnostics) catch {
        log.err("out of memory while loading config {s}", .{path});
        return null;
    };
    diagnostics.log(path, source);
    if (diagnostics.has_errors) return null;

    log.info("loaded config: {d} keybind entries, {d} app rules", .{
        parsed.keybinds.len,
        parsed.app_rules.len,
    });
    return parsed;
}

/// An upgrade otherwise looks like bobrwm silently forgot its config.
pub fn warnIfOnlyLegacyExists(allocator: std.mem.Allocator, path: []const u8) void {
    const legacy = legacyPath(allocator, path) catch return;
    defer allocator.free(legacy);
    if (!osutil.pathExists(legacy)) return;
    log.warn("{s} is no longer read; run `bobrwm migrate-config` to convert it to {s}", .{ legacy, path });
}

// Bundle ID helper

pub fn getAppBundleId(pid: i32, buf: *[256]u8) ?[]const u8 {
    return osutil.appBundleId(pid, buf);
}

// macOS virtual key code mapping

pub fn keyNameToCode(name: []const u8) ?u16 {
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
        .app_rules = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.apple.MobileSMS", .workspace = 3 },
        },
    };
    try t.expectEqual(@as(?u8, 2), cfg.workspaceForApp("com.apple.Safari"));
    try t.expectEqual(@as(?u8, 3), cfg.workspaceForApp("com.apple.MobileSMS"));
    try t.expectEqual(@as(?u8, null), cfg.workspaceForApp("com.apple.Terminal"));
    try t.expect(cfg.hasAppWorkspaceRules());

    const empty: Config = .{};
    try t.expectEqual(@as(?u8, null), empty.workspaceForApp("com.apple.Safari"));
    try t.expect(!empty.hasAppWorkspaceRules());
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

test "default config" {
    const cfg: Config = .{};
    try t.expectEqual(@as(usize, default_keybind_count), cfg.keybinds.len);
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

test "validate accepts defaults and a reduced workspace set" {
    const defaults: Config = .{};
    try validate(&defaults);
    try t.expectEqual(workspace.max_workspaces, workspaceCount(&defaults));

    const reduced: Config = .{ .workspace_names = &.{ "term", "web", "code", "chat" } };
    try validate(&reduced);
    try t.expectEqual(@as(u8, 4), workspaceCount(&reduced));
}

test "validate rejects geometry and gesture values that are not finite or bounded" {
    var cfg: Config = .{};

    cfg.bsp_split_ratio = std.math.inf(f64);
    try t.expectError(error.InvalidBspSplitRatio, validate(&cfg));

    cfg = .{};
    cfg.dimmed_inactive.level = std.math.nan(f32);
    try t.expectError(error.InvalidDimLevel, validate(&cfg));

    cfg = .{};
    cfg.swipe.fingers = max_swipe_fingers + 1;
    try t.expectError(error.InvalidSwipeFingerCount, validate(&cfg));

    cfg = .{};
    cfg.swipe.distance_pct = std.math.nan(f64);
    try t.expectError(error.InvalidSwipeDistance, validate(&cfg));
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

    const bad_rule: Config = .{
        .workspace_names = &.{ "1", "2" },
        .app_rules = &.{.{ .app_id = "com.example.App", .workspace = 0 }},
    };
    try t.expectError(error.InvalidAppRuleWorkspace, validate(&bad_rule));

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

test "disabled default keybinds retain only explicit bindings from the config file" {
    const source =
        \\disable-default-keybinds = true
        \\keybind = alt+1=focus_workspace:3
        \\keybind = ctrl+f=toggle_float
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diagnostics: config_file.Diagnostics = .{ .allocator = arena.allocator() };
    const cfg = try config_file.parseAndValidate(arena.allocator(), source, &diagnostics);
    try t.expect(!diagnostics.has_errors);
    var table = try KeybindTable.init(t.allocator, &cfg);
    defer table.deinit(t.allocator);

    const binds = cfg.buildKeybinds(&table);
    try t.expectEqual(@as(usize, 2), binds.len);
    try t.expectEqual(keyNameToCode("1").?, binds[0].keycode);
    try t.expectEqual(shim.BW_MOD_ALT, binds[0].mods);
    try t.expectEqual(@intFromEnum(Action.focus_workspace), binds[0].action);
    try t.expectEqual(@as(u32, 3), binds[0].arg);
    try t.expectEqual(keyNameToCode("f").?, binds[1].keycode);
    try t.expectEqual(shim.BW_MOD_CTRL, binds[1].mods);
    try t.expectEqual(@intFromEnum(Action.toggle_float), binds[1].action);
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
    try t.expectEqual(@as(?Config, null), loadFromPath(t.allocator, "/tmp/bobrwm_no_such_file"));
}

test "loadFromPath: config file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The unknown option logs a warning; keep it out of the test output.
    std.testing.log_level = .err;
    const source =
        \\# comment
        \\unknown-root = ignored
        \\keybind = alt+f=toggle_fullscreen
        \\keybind = alt+shift+space=toggle_float
        \\app-rule = app-id:com.test.App,workspace:3
        \\swipe-enabled = true
        \\swipe-fingers = 4
        \\swipe-distance-pct = 0.1
        \\gaps-inner = 8
        \\gaps-outer-left = 4
        \\gaps-outer-right = 4
        \\gaps-outer-top = 4
        \\gaps-outer-bottom = 4
        \\layout = monocle
        \\bsp-split = vertical
        \\bsp-insert-point = last
        \\bsp-split-ratio = 0.6
        \\new-window-split = first
    ;

    // tmpDir.writeFile / realpathAlloc now require an Io instance which we
    // don't thread through tests. Write to a deterministic /tmp path with
    // libc instead.
    const path: [:0]const u8 = "/tmp/bobrwm_test_custom_config";
    if (!osutil.writeFile(path.ptr, source)) return error.TestUnexpectedResult;
    defer osutil.deleteFile(path.ptr);

    const cfg = loadFromPath(allocator, path) orelse
        return error.TestUnexpectedResult;

    try t.expectEqual(@as(usize, 2), cfg.keybinds.len);
    try t.expectEqual(Action.toggle_fullscreen, cfg.keybinds[0].action);
    try t.expectEqual(Action.toggle_float, cfg.keybinds[1].action);

    try t.expectEqual(@as(usize, 1), cfg.app_rules.len);
    try t.expectEqualStrings("com.test.App", cfg.app_rules[0].app_id);
    try t.expectEqual(@as(?u8, 3), cfg.app_rules[0].workspace);
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
