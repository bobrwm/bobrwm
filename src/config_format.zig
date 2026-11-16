//! Writes a `Config` as `init.lua` source, optionally with each option's
//! documentation as comments. Backs `bobrwm show-config`, and migrates a
//! `config.zon` by writing out the config it parsed to.
//!
//! Modeled on ghostty's `+show-config --default --docs`.

const std = @import("std");
const config = @import("config.zig");
const config_layer = @import("config_layer.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    /// Write settings still at their default too, so the output is a complete
    /// reference. Off, the output holds only what differs from the defaults.
    all_settings: bool = true,
};

/// Write `cfg` as Lua. `Docs` is a `help_strings.Config`-shaped namespace
/// (a `keys` list plus one string decl per documented key), or null to omit
/// comments. It is a parameter rather than an import so tests can supply
/// their own docs.
pub fn write(writer: *Writer, cfg: *const config.Config, comptime Docs: ?type, options: Options) Writer.Error!void {
    const defaults: config.Config = .{};
    if (options.all_settings or !sameSettings(config.Config, cfg.*, defaults)) {
        try writer.writeAll("bobrwm.settings.set{\n");
        try writeSettings(writer, config.Config, cfg.*, defaults, "", Docs, 1, options);
        try writer.writeAll("}\n");
    }
    try writeKeybinds(writer, cfg, Docs, options);
    try writeRules(writer, cfg, Docs);
}

/// One `key = value,` line per setting, recursing into groups. Groups with
/// nothing to write are skipped.
fn writeSettings(
    writer: *Writer,
    comptime T: type,
    value: T,
    default: T,
    comptime prefix: []const u8,
    comptime Docs: ?type,
    depth: u8,
    options: Options,
) Writer.Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime !config_layer.isSetting(T, name)) continue;
        const key = prefix ++ name;
        const field = @field(value, name);
        const field_default = @field(default, name);
        const Field = @TypeOf(field);
        if (options.all_settings or !sameSettings(Field, field, field_default)) {
            if (Docs) |D| try writeDocs(writer, D, key, depth);
            try indent(writer, depth);
            if (@typeInfo(Field) == .@"struct") {
                try writer.print("{s} = {{\n", .{name});
                try writeSettings(writer, Field, field, field_default, key ++ ".", Docs, depth + 1, options);
                try indent(writer, depth);
                try writer.writeAll("},\n");
            } else {
                try writer.print("{s} = ", .{name});
                try writeValue(writer, field);
                try writer.writeAll(",\n");
            }
        }
    }
}

fn writeValue(writer: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool, .int => try writer.print("{}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .@"enum" => try writeString(writer, @tagName(value)),
        .pointer => {
            comptime std.debug.assert(T == []const []const u8);
            try writer.writeAll("{");
            for (value, 0..) |string, i| {
                try writer.writeAll(if (i == 0) " " else ", ");
                try writeString(writer, string);
            }
            try writer.writeAll(if (value.len == 0) "}" else " }");
        },
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    }
}

/// A Lua string literal. Bytes outside printable ASCII are written as
/// decimal escapes so any workspace name survives the round trip.
fn writeString(writer: *Writer, string: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (string) |byte| {
        if (byte == '"' or byte == '\\') {
            try writer.print("\\{c}", .{byte});
        } else if (std.ascii.isPrint(byte)) {
            try writer.writeByte(byte);
        } else {
            try writer.print("\\{d:0>3}", .{byte});
        }
    }
    try writer.writeByte('"');
}

fn writeKeybinds(writer: *Writer, cfg: *const config.Config, comptime Docs: ?type, options: Options) Writer.Error!void {
    const explicit = !config.isDefaultKeybindSlice(cfg.keybinds);
    if (!explicit and !cfg.disable_default_keybinds) {
        if (!options.all_settings) return;
        // As a reference, list the built-in keybinds without rebinding them.
        try writer.writeAll("\n");
        if (Docs) |D| try writeDocs(writer, D, "keybinds", 0);
        try writer.writeAll("-- Built in:\n");
        for (cfg.keybinds) |keybind| {
            try writer.writeAll("-- ");
            try writeBind(writer, keybind);
        }
        return;
    }
    try writer.writeAll("\n");
    if (Docs) |D| try writeDocs(writer, D, "keybinds", 0);
    if (cfg.disable_default_keybinds) try writer.writeAll("bobrwm.keymap.clear()\n");
    if (explicit) for (cfg.keybinds) |keybind| {
        // Merged defaults retain inert shortcuts for nonexistent workspaces.
        // Exporting those as authored binds would make a valid config fail
        // validation on reload; they have no effective action to preserve.
        if (cfg.workspace_names.len > 0 and keybind.arg > cfg.workspace_names.len and
            (keybind.action == .focus_workspace or keybind.action == .move_to_workspace)) continue;
        try writeBind(writer, keybind);
    };
}

fn writeBind(writer: *Writer, keybind: config.Keybind) Writer.Error!void {
    try writer.writeAll("bobrwm.keymap.set(\"");
    if (keybind.mods.ctrl) try writer.writeAll("ctrl+");
    if (keybind.mods.alt) try writer.writeAll("alt+");
    if (keybind.mods.shift) try writer.writeAll("shift+");
    if (keybind.mods.cmd) try writer.writeAll("cmd+");
    try writer.print("{s}\", \"{t}\"", .{ keybind.key, keybind.action });
    switch (keybind.action) {
        .focus_workspace, .move_to_workspace => try writer.print(", {{ workspace = {d} }}", .{keybind.arg}),
        .move_workspace_to_display => switch (keybind.arg) {
            config.next_display_arg => try writer.writeAll(", { display = \"next\" }"),
            config.previous_display_arg => try writer.writeAll(", { display = \"previous\" }"),
            else => try writer.print(", {{ display = {d} }}", .{keybind.arg}),
        },
        else => {},
    }
    try writer.writeAll(")\n");
}

/// One `bobrwm.app_rules.add` per app. A `workspace_assignments` entry (the deprecated
/// alias) supplies the workspace of an app rule that has none, matching how
/// `Config.workspaceForApp` falls through to it.
fn writeRules(writer: *Writer, cfg: *const config.Config, comptime Docs: ?type) Writer.Error!void {
    if (cfg.app_rules.len == 0 and cfg.workspace_assignments.len == 0) return;
    try writer.writeAll("\n");
    if (Docs) |D| try writeDocs(writer, D, "app_rules", 0);
    for (cfg.app_rules) |rule| {
        var merged = rule;
        if (merged.workspace == null) merged.workspace = assignedWorkspace(cfg, rule.app_id);
        try writeRule(writer, merged);
    }
    for (cfg.workspace_assignments) |assignment| {
        if (hasRule(cfg, assignment.app_id)) continue;
        try writeRule(writer, .{ .app_id = assignment.app_id, .workspace = assignment.workspace });
    }
}

fn writeRule(writer: *Writer, rule: config.AppRule) Writer.Error!void {
    try writer.writeAll("bobrwm.app_rules.add{ app = ");
    try writeString(writer, rule.app_id);
    if (rule.workspace) |workspace| try writer.print(", workspace = {d}", .{workspace});
    if (rule.float) try writer.writeAll(", float = true");
    try writer.writeAll(" }\n");
}

fn assignedWorkspace(cfg: *const config.Config, app_id: []const u8) ?u8 {
    for (cfg.workspace_assignments) |assignment| {
        if (std.mem.eql(u8, assignment.app_id, app_id)) return assignment.workspace;
    }
    return null;
}

fn hasRule(cfg: *const config.Config, app_id: []const u8) bool {
    for (cfg.app_rules) |rule| {
        if (std.mem.eql(u8, rule.app_id, app_id)) return true;
    }
    return false;
}

pub fn sameSettings(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                if (comptime !config_layer.isSetting(T, name)) continue;
                if (!sameSettings(@FieldType(T, name), @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .pointer => {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

fn writeDocs(writer: *Writer, comptime Docs: type, comptime key: []const u8, depth: u8) Writer.Error!void {
    if (!@hasDecl(Docs, key)) return;
    var lines = std.mem.splitScalar(u8, @field(Docs, key), '\n');
    while (lines.next()) |line| {
        try indent(writer, depth);
        if (line.len == 0) {
            try writer.writeAll("--\n");
        } else {
            try writer.print("-- {s}\n", .{line});
        }
    }
}

fn indent(writer: *Writer, depth: u8) Writer.Error!void {
    try writer.splatByteAll(' ', 2 * @as(usize, depth));
}

fn render(alloc: std.mem.Allocator, cfg: *const config.Config, comptime Docs: ?type, options: Options) ![]const u8 {
    var out: Writer.Allocating = .init(alloc);
    try write(&out.writer, cfg, Docs, options);
    return out.written();
}

/// Loads `source` the way the daemon would, failing on any diagnostic.
fn reload(arena: std.mem.Allocator, source: []const u8) !config.Config {
    const config_load = @import("config_load.zig");
    var diagnostics: std.ArrayList(config_layer.Diagnostic) = .empty;
    const merged = config_load.loadSources(std.testing.allocator, arena, .{ .lua = source }, &diagnostics) catch |err| {
        for (diagnostics.items) |d| std.debug.print("{f}{s}\n", .{ config_load.fmtLocation(d.location), d.message });
        return err;
    };
    if (diagnostics.items.len > 0) {
        for (diagnostics.items) |d| std.debug.print("{f}{s}\n", .{ config_load.fmtLocation(d.location), d.message });
        return error.TestUnexpectedResult;
    }
    return merged.config;
}

test "default config round-trips through Lua" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: config.Config = .{};
    const source = try render(arena.allocator(), &defaults, null, .{});
    const loaded = try reload(arena.allocator(), source);

    try std.testing.expect(std.mem.indexOf(u8, source, "-- bobrwm.keymap.set(\"alt+h\", \"focus_left\")\n") != null);
    try std.testing.expectEqual(config.default_keybinds.len, loaded.keybinds.len);
    try std.testing.expectEqual(defaults.gaps, loaded.gaps);
    try std.testing.expectEqual(defaults.bsp_split_ratio, loaded.bsp_split_ratio);
    try std.testing.expectEqual(defaults.dimmed_inactive, loaded.dimmed_inactive);
    try std.testing.expectEqual(defaults.animation, loaded.animation);
}

test "merged reduced workspaces export a loadable effective config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const original = try reload(arena.allocator(),
        \\bobrwm.settings.set('workspace_names', {'one', 'two', 'three'})
        \\bobrwm.keymap.set('alt+f', 'focus_workspace', {workspace=1})
        \\bobrwm.keymap.del('alt+h')
    );
    for ([_]bool{ false, true }) |all_settings| {
        const source = try render(arena.allocator(), &original, null, .{ .all_settings = all_settings });
        const loaded = try reload(arena.allocator(), source);
        try std.testing.expect(sameSettings(config.Config, original, loaded));
        try std.testing.expectEqualStrings("f", loaded.findKeybind(.focus_workspace, 1).?.key);
        try std.testing.expectEqual(@as(?config.Keybind, null), loaded.findKeybind(.focus_left, 0));
        var active_count: usize = 0;
        for (original.keybinds) |keybind| {
            if ((keybind.action == .focus_workspace or keybind.action == .move_to_workspace) and keybind.arg > 3) continue;
            active_count += 1;
            var found = false;
            for (loaded.keybinds) |candidate| {
                if (!std.mem.eql(u8, keybind.key, candidate.key) or !std.meta.eql(keybind.mods, candidate.mods)) continue;
                try std.testing.expectEqual(keybind.action, candidate.action);
                try std.testing.expectEqual(keybind.arg, candidate.arg);
                found = true;
            }
            try std.testing.expect(found);
        }
        try std.testing.expectEqual(active_count, loaded.keybinds.len);
    }
}

test "loaded Lua custom shortcut is preferred for menu display" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const loaded = try reload(arena.allocator(), "bobrwm.keymap.set('alt+f', 'focus_workspace', {workspace=1})");
    try std.testing.expectEqualStrings("f", loaded.findKeybind(.focus_workspace, 1).?.key);
    // Adding a display preference does not remove the original shortcut.
    var found_default = false;
    for (loaded.keybinds) |keybind| {
        if (std.mem.eql(u8, keybind.key, "1") and keybind.mods.alt and keybind.action == .focus_workspace and keybind.arg == 1) found_default = true;
    }
    try std.testing.expect(found_default);
}

test "user values round-trip and only changes are written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cfg: config.Config = .{
        .workspace_names = &.{ "term", "we\"b", "caf\xc3\xa9" },
        .keybinds = &.{
            .{ .key = "h", .mods = .{ .alt = true, .shift = true }, .action = .swap_left },
            .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 },
            .{ .key = "right", .mods = .{ .ctrl = true }, .action = .move_workspace_to_display, .arg = config.previous_display_arg },
        },
        .app_rules = &.{
            .{ .app_id = "com.apple.Safari", .float = true },
            .{ .app_id = "com.apple.systempreferences", .float = true },
        },
        .workspace_assignments = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.tinyspeck.slackmacgap", .workspace = 3 },
        },
        .gaps = .{ .inner = 8, .outer = .{ .top = 30 } },
        .layout = .monocle,
    };
    const source = try render(arena.allocator(), &cfg, null, .{ .all_settings = false });
    try std.testing.expectEqualStrings(
        \\bobrwm.settings.set{
        \\  workspace_names = { "term", "we\"b", "caf\195\169" },
        \\  gaps = {
        \\    inner = 8,
        \\    outer = {
        \\      top = 30,
        \\    },
        \\  },
        \\  layout = "monocle",
        \\}
        \\
        \\bobrwm.keymap.set("alt+shift+h", "swap_left")
        \\bobrwm.keymap.set("alt+1", "focus_workspace", { workspace = 1 })
        \\bobrwm.keymap.set("ctrl+right", "move_workspace_to_display", { display = "previous" })
        \\
        \\bobrwm.app_rules.add{ app = "com.apple.Safari", workspace = 2, float = true }
        \\bobrwm.app_rules.add{ app = "com.apple.systempreferences", float = true }
        \\bobrwm.app_rules.add{ app = "com.tinyspeck.slackmacgap", workspace = 3 }
        \\
    , source);

    const loaded = try reload(arena.allocator(), source);
    try std.testing.expectEqualStrings("caf\xc3\xa9", loaded.workspace_names[2]);
    try std.testing.expectEqual(cfg.gaps, loaded.gaps);
    try std.testing.expectEqual(2, loaded.workspaceForApp("com.apple.Safari").?);
    try std.testing.expect(loaded.shouldFloatApp("com.apple.Safari"));
    try std.testing.expectEqual(3, loaded.workspaceForApp("com.tinyspeck.slackmacgap").?);
}

test "disabled defaults become unbind_all" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cfg: config.Config = .{
        .disable_default_keybinds = true,
        .keybinds = &.{.{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left }},
    };
    const source = try render(arena.allocator(), &cfg, null, .{ .all_settings = false });
    try std.testing.expectEqualStrings("\nbobrwm.keymap.clear()\nbobrwm.keymap.set(\"alt+h\", \"focus_left\")\n", source);
    const loaded = try reload(arena.allocator(), source);
    try std.testing.expectEqual(1, loaded.keybinds.len);
}

test "docs are written as comments and the output still loads" {
    const Docs = struct {
        pub const keys = [_][]const u8{ "gaps", "gaps.inner" };
        pub const gaps: [:0]const u8 = "Gap docs.\n\nSecond paragraph.";
        pub const @"gaps.inner": [:0]const u8 = "Inner docs.";
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: config.Config = .{};
    const source = try render(arena.allocator(), &defaults, Docs, .{});
    try std.testing.expect(std.mem.indexOf(u8, source, "  -- Gap docs.\n  --\n  -- Second paragraph.\n  gaps = {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    -- Inner docs.\n    inner = 0,\n") != null);
    _ = try reload(arena.allocator(), source);
}

test "generated docs produce a loadable config" {
    const help_strings = @import("help_strings");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const defaults: config.Config = .{};
    const source = try render(arena.allocator(), &defaults, help_strings.Config, .{});
    _ = try reload(arena.allocator(), source);
}
