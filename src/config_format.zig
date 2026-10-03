//! Writes a `Config` back out as `config.zon` source, optionally with each
//! option's documentation as comments. Backs `bobrwm show-config`, and with
//! `--default --docs` replaces a hand-maintained example config that drifted
//! from the real defaults.
//!
//! Every field is written, including ones at their default, so the output
//! doubles as a complete reference of what can be set.
//!
//! Modeled on ghostty's `+show-config --default --docs`.

const std = @import("std");
const config = @import("config.zig");

const Serializer = std.zon.Serializer;
const Writer = std.Io.Writer;

/// Write `cfg` as ZON. `Docs` is a `help_strings.Config`-shaped namespace
/// (a `keys` list plus one string decl per documented key), or null to omit
/// comments. It is a parameter rather than an import so tests can supply
/// their own docs.
pub fn write(writer: *Writer, cfg: *const config.Config, comptime Docs: ?type) Writer.Error!void {
    var serializer: Serializer = .{ .writer = writer };
    try writer.writeAll(".{\n");
    try writeFields(&serializer, config.Config, cfg.*, "", Docs, 1);
    try writer.writeAll("}\n");
}

/// Write each field of a struct on its own line at `depth`, recursing into
/// nested structs so their fields get their own comments too.
fn writeFields(
    s: *Serializer,
    comptime T: type,
    value: T,
    comptime prefix: []const u8,
    comptime Docs: ?type,
    depth: u8,
) Writer.Error!void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (field.name[0] == '_') continue;
        const key = prefix ++ field.name;
        const field_value = @field(value, field.name);
        if (Docs) |D| {
            if (i > 0) try s.writer.writeAll("\n");
            try writeDocs(s.writer, D, key, depth);
        }
        try indent(s.writer, depth);
        try s.writer.print(".{f} = ", .{std.zig.fmtId(field.name)});
        if (@typeInfo(field.type) == .@"struct") {
            try s.writer.writeAll(".{\n");
            try writeFields(s, field.type, field_value, key ++ ".", Docs, depth + 1);
            try indent(s.writer, depth);
            try s.writer.writeAll("}");
        } else if (comptime std.mem.eql(u8, key, "keybinds")) {
            try writeKeybinds(s, field_value, depth);
        } else if (comptime isStructSlice(field.type)) {
            try writeStructSlice(s, field_value, depth);
        } else {
            try writeCompact(s, field_value);
        }
        try s.writer.writeAll(",\n");
    }
}

/// Explicit keybinds are validated against the workspace count while the
/// built-in ones are not, and the built-ins apply anyway unless
/// `disable_default_keybinds` is set. Writing them out would turn a config
/// that later trims `workspace_names` invalid, so they are listed as a
/// comment and the field is left empty.
fn writeKeybinds(s: *Serializer, keybinds: []const config.Keybind, depth: u8) Writer.Error!void {
    if (!config.isDefaultKeybindSlice(keybinds)) return writeStructSlice(s, keybinds, depth);
    try s.writer.writeAll(".{\n");
    try indent(s.writer, depth + 1);
    try s.writer.writeAll("// Built-in defaults, active unless disable_default_keybinds is set:\n");
    for (keybinds) |keybind| {
        try indent(s.writer, depth + 1);
        try s.writer.writeAll("// ");
        try writeCompact(s, keybind);
        try s.writer.writeAll(",\n");
    }
    try indent(s.writer, depth);
    try s.writer.writeAll("}");
}

/// One element per line, so long lists like `keybinds` stay scannable.
fn writeStructSlice(s: *Serializer, items: anytype, depth: u8) Writer.Error!void {
    if (items.len == 0) return s.writer.writeAll(".{}");
    try s.writer.writeAll(".{\n");
    for (items) |item| {
        try indent(s.writer, depth + 1);
        try writeCompact(s, item);
        try s.writer.writeAll(",\n");
    }
    try indent(s.writer, depth);
    try s.writer.writeAll("}");
}

/// Write a value on one line. Struct fields left at their default are
/// omitted, which keeps `keybinds` entries readable: `.mods = .{ .alt = true }`
/// instead of spelling out all four modifiers.
fn writeCompact(s: *Serializer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var container = try s.beginStruct(.{ .whitespace_style = .{ .wrap = false } });
            inline for (info.fields) |field| {
                const field_value = @field(value, field.name);
                const is_default = if (field.defaultValue()) |default|
                    std.meta.eql(field_value, default)
                else
                    false;
                if (!is_default) {
                    try container.fieldPrefix(field.name);
                    try writeCompact(s, field_value);
                }
            }
            try container.end();
        },
        .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8) {
            var tuple = try s.beginTuple(.{ .whitespace_style = .{ .wrap = false } });
            for (value) |item| {
                try tuple.fieldPrefix();
                try writeCompact(s, item);
            }
            try tuple.end();
        } else {
            try s.value(value, .{});
        },
        .optional => if (value) |child| try writeCompact(s, child) else try s.writer.writeAll("null"),
        else => try s.value(value, .{}),
    }
}

/// Emit the doc comment for `key`. For a slice of structs, also emit the docs
/// of the element fields, since each element is written on one line with no
/// room for per-field comments.
fn writeDocs(writer: *Writer, comptime Docs: type, comptime key: []const u8, depth: u8) Writer.Error!void {
    if (@hasDecl(Docs, key)) try writeComment(writer, @field(Docs, key), depth, "");
    const element_prefix = key ++ "[].";
    inline for (Docs.keys) |element_key| {
        if (comptime std.mem.startsWith(u8, element_key, element_prefix) and @hasDecl(Docs, element_key)) {
            try indent(writer, depth);
            try writer.writeAll("//\n");
            try indent(writer, depth);
            try writer.writeAll("// ." ++ element_key[element_prefix.len..] ++ "\n");
            try writeComment(writer, @field(Docs, element_key), depth, "  ");
        }
    }
}

fn writeComment(writer: *Writer, text: []const u8, depth: u8, comptime pad: []const u8) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try indent(writer, depth);
        if (line.len == 0) {
            try writer.writeAll("//\n");
        } else {
            try writer.print("// " ++ pad ++ "{s}\n", .{line});
        }
    }
}

fn indent(writer: *Writer, depth: u8) Writer.Error!void {
    try writer.splatByteAll(' ', 4 * @as(usize, depth));
}

fn isStructSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and @typeInfo(p.child) == .@"struct",
        else => false,
    };
}

fn render(alloc: std.mem.Allocator, cfg: *const config.Config, comptime Docs: ?type) ![:0]const u8 {
    var out: Writer.Allocating = .init(alloc);
    try write(&out.writer, cfg, Docs);
    return out.toOwnedSliceSentinel(0);
}

test "default config round-trips through ZON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    const source = try render(alloc, &defaults, null);
    var parsed = try std.zon.parse.fromSliceAlloc(config.Config, alloc, source, null, .{});
    try config.validate(&parsed);

    // Built-in keybinds are listed as comments and still apply through the
    // merge, so the parsed config binds nothing explicitly.
    try std.testing.expectEqual(@as(usize, 0), parsed.keybinds.len);
    try std.testing.expect(std.mem.indexOf(u8, source, "// .{ .key = \"h\", .mods = .{ .alt = true }, .action = .focus_left },") != null);
    try std.testing.expectEqual(defaults.gaps, parsed.gaps);
    try std.testing.expectEqual(defaults.bsp_split_ratio, parsed.bsp_split_ratio);
    try std.testing.expectEqual(defaults.dimmed_inactive, parsed.dimmed_inactive);
    try std.testing.expectEqual(defaults.swipe, parsed.swipe);

    // Trimming the workspace count must not invalidate the generated config.
    parsed.workspace_names = &.{ "a", "b" };
    try config.validate(&parsed);
}

test "user values round-trip, including strings and optionals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg: config.Config = .{
        .workspace_names = &.{ "term", "we\"b" },
        .keybinds = &.{.{ .key = "h", .mods = .{ .alt = true, .shift = true }, .action = .swap_left }},
        .app_rules = &.{
            .{ .app_id = "com.apple.Safari", .workspace = 2 },
            .{ .app_id = "com.apple.systempreferences", .float = true },
        },
        .gaps = .{ .inner = 8, .outer = .{ .top = 30 } },
    };
    const source = try render(alloc, &cfg, null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".{ .app_id = \"com.apple.Safari\", .workspace = 2 },") != null);

    const parsed = try std.zon.parse.fromSliceAlloc(config.Config, alloc, source, null, .{});
    try std.testing.expectEqualStrings("we\"b", parsed.workspace_names[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.keybinds.len);
    try std.testing.expectEqual(cfg.keybinds[0].mods, parsed.keybinds[0].mods);
    try std.testing.expectEqual(@as(?u8, 2), parsed.app_rules[0].workspace);
    try std.testing.expectEqual(@as(?u8, null), parsed.app_rules[1].workspace);
    try std.testing.expect(parsed.app_rules[1].float);
    try std.testing.expectEqual(cfg.gaps, parsed.gaps);
}

test "docs are written as comments and the output still parses" {
    const Docs = struct {
        pub const keys = [_][]const u8{ "gaps", "gaps.inner", "keybinds", "keybinds[].key" };
        pub const gaps: [:0]const u8 = "Gap docs.\n\nSecond paragraph.";
        pub const @"gaps.inner": [:0]const u8 = "Inner docs.";
        pub const @"keybinds[].key": [:0]const u8 = "Key docs.";
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    const source = try render(alloc, &defaults, Docs);
    try std.testing.expect(std.mem.indexOf(u8, source, "    // Gap docs.\n    //\n    // Second paragraph.\n    .gaps = .{\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "        // Inner docs.\n        .inner = 0,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    //\n    // .key\n    //   Key docs.\n    .keybinds = .{\n") != null);
    _ = try std.zon.parse.fromSliceAlloc(config.Config, alloc, source, null, .{});
}

test "generated docs produce a parseable config" {
    const help_strings = @import("help_strings");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults: config.Config = .{};
    const source = try render(alloc, &defaults, help_strings.Config);
    _ = try std.zon.parse.fromSliceAlloc(config.Config, alloc, source, null, .{});
}
