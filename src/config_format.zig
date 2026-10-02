//! Writes a `Config` back out in the config file format, optionally with
//! each option's documentation as comments. Backs `bobrwm show-config` and
//! `bobrwm migrate-config`.
//!
//! Modeled on ghostty's `+show-config`: by default only options that differ
//! from the defaults are written, and `--default --docs` doubles as a
//! complete, documented reference of every option.

const std = @import("std");
const config = @import("config.zig");
const config_file = @import("config_file.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    /// Skip options left at their default.
    changes_only: bool = false,
};

/// Write `cfg`. `Docs` is a `help_strings.Config`-shaped namespace (one
/// string decl per documented option key), or null to omit comments. It is a
/// parameter rather than an import so tests can supply their own docs.
pub fn write(writer: *Writer, cfg: *const config.Config, comptime Docs: ?type, opts: Options) Writer.Error!void {
    var first = true;
    inline for (config_file.options) |option| {
        const value = config_file.fieldPtr(config.Config, option.path, @constCast(cfg)).*;
        if (!opts.changes_only or !isDefault(option, value)) {
            if (Docs) |D| {
                if (!first) try writer.writeByte('\n');
                if (@hasDecl(D, option.key)) try writeComment(writer, @field(D, option.key));
            }
            first = false;
            try writeOption(writer, option, value);
        }
    }
}

fn writeOption(writer: *Writer, comptime option: config_file.Option, value: anytype) Writer.Error!void {
    if (!option.repeatable) return writeLine(writer, option.key, value);

    if (comptime std.mem.eql(u8, option.key, "keybind")) {
        if (config.isDefaultKeybindSlice(value)) return writeDefaultKeybinds(writer, value);
    }
    // An empty value clears the list, so writing one keeps the output
    // complete without changing behavior.
    if (value.len == 0) return writer.writeAll(option.key ++ " =\n");
    for (value) |item| try writeLine(writer, option.key, item);
}

fn writeLine(writer: *Writer, comptime key: []const u8, value: anytype) Writer.Error!void {
    try writer.writeAll(key ++ " = ");
    try config_file.writeValue(writer, value);
    try writer.writeByte('\n');
}

/// Explicit keybinds are validated against the workspace count while the
/// built-in ones are not, and the built-ins apply anyway unless
/// `disable-default-keybinds` is set. Writing them as live lines would turn a
/// config that later trims `workspace-name` invalid, so they are comments.
fn writeDefaultKeybinds(writer: *Writer, keybinds: []const config.Keybind) Writer.Error!void {
    try writer.writeAll("# Built-in defaults, active unless disable-default-keybinds is set:\n");
    for (keybinds) |keybind| {
        try writer.writeAll("# keybind = ");
        try config_file.writeValue(writer, keybind);
        try writer.writeByte('\n');
    }
}

fn writeComment(writer: *Writer, text: []const u8) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try writer.writeAll("#\n");
        } else {
            try writer.print("# {s}\n", .{line});
        }
    }
}

fn isDefault(comptime option: config_file.Option, value: anytype) bool {
    if (option.repeatable) {
        if (comptime std.mem.eql(u8, option.key, "keybind")) return config.isDefaultKeybindSlice(value);
        return value.len == 0;
    }
    const defaults: option.Container = .{};
    return std.meta.eql(value, @field(defaults, option.field));
}

fn render(alloc: std.mem.Allocator, cfg: *const config.Config, comptime Docs: ?type, opts: Options) ![]const u8 {
    var out: Writer.Allocating = .init(alloc);
    try write(&out.writer, cfg, Docs, opts);
    return out.written();
}

fn parse(alloc: std.mem.Allocator, source: []const u8) !config.Config {
    var diagnostics: config_file.Diagnostics = .{ .allocator = alloc };
    const cfg = try config_file.parseAndValidate(alloc, source, &diagnostics);
    if (diagnostics.items.items.len != 0) return error.TestUnexpectedResult;
    return cfg;
}

test "default config round-trips and survives a trimmed workspace count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    const source = try render(alloc, &defaults, null, .{});
    try std.testing.expect(std.mem.indexOf(u8, source, "# keybind = alt+h=focus_left\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "# keybind = alt+1=focus_workspace:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "gaps-outer-left = 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "workspace-name =\n") != null);

    const parsed = try parse(alloc, source);
    // The defaults are comments, so the parsed config keeps the built-in
    // list rather than binding them explicitly.
    try std.testing.expect(config.isDefaultKeybindSlice(parsed.keybinds));
    try std.testing.expectEqual(defaults.gaps, parsed.gaps);
    try std.testing.expectEqual(defaults.dimmed_inactive, parsed.dimmed_inactive);
    try std.testing.expectEqual(defaults.swipe, parsed.swipe);
    try std.testing.expectEqual(defaults.animation, parsed.animation);

    const trimmed = try std.mem.concat(alloc, u8, &.{ source, "workspace-name = a\nworkspace-name = b\n" });
    _ = try parse(alloc, trimmed);
}

test "changes-only writes just what differs from the defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cfg: config.Config = .{
        .workspace_names = &.{ "term", "web" },
        .keybinds = &.{.{ .key = "h", .mods = .{ .alt = true, .shift = true }, .action = .swap_left }},
        .app_rules = &.{.{ .app_id = "com.apple.Safari", .workspace = 2 }},
    };
    cfg.gaps.outer.top = 30;
    cfg.animation.easing = .spring;

    try std.testing.expectEqualStrings(
        \\keybind = alt+shift+h=swap_left
        \\app-rule = app-id:com.apple.Safari,workspace:2
        \\workspace-name = term
        \\workspace-name = web
        \\gaps-outer-top = 30
        \\animation-easing = spring
        \\
    , try render(alloc, &cfg, null, .{ .changes_only = true }));

    const defaults: config.Config = .{};
    try std.testing.expectEqualStrings("", try render(alloc, &defaults, null, .{ .changes_only = true }));
}

test "docs are written as comments above their option" {
    const Docs = struct {
        pub const @"gaps-inner": [:0]const u8 = "Inner docs.\n\nSecond paragraph.";
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    const source = try render(alloc, &defaults, Docs, .{});
    try std.testing.expect(std.mem.indexOf(u8, source, "\n# Inner docs.\n#\n# Second paragraph.\ngaps-inner = 0\n") != null);
    _ = try parse(alloc, source);
}

test "generated docs produce a parseable config" {
    const help_strings = @import("help_strings");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    _ = try parse(alloc, try render(alloc, &defaults, help_strings.Config, .{}));
}
