//! Generates the `help_strings` module from the `///` doc comments on
//! config fields and keybind actions, so the CLI, docs, and website can all
//! render the same text instead of maintaining copies that drift.
//!
//! The field lists come from comptime reflection over the real types, so the
//! output always covers exactly what `config.zon` parses. The doc text comes
//! from parsing each type's source file with `std.zig.Ast`, since doc comments
//! are not available through `@typeInfo`.
//!
//! Adapted from ghostty-org/ghostty `src/helpgen.zig` @ b1c264163.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! MIT License, see LICENSES/ghostty.txt.

const std = @import("std");
const config = @import("config.zig");

/// One documentable config key: the dotted path a user writes, and the
/// container and field whose doc comment describes it.
const KeyEntry = struct {
    key: []const u8,
    Container: type,
    field: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\// THIS FILE IS AUTO GENERATED
        \\
        \\
    );

    const alloc = init.arena.allocator();
    var sources: SourceCache = .{ .alloc = alloc };
    try genEntries(alloc, &sources, writer, "Config", comptime configEntries(config.Config, ""));
    try genEntries(alloc, &sources, writer, "KeybindAction", comptime enumEntries(config.Action));
    try stdout.end();
}

/// Emit one namespace with a decl per documented key, plus the full ordered
/// key list. Undocumented keys are still listed so consumers can render every
/// option before its docs are written.
fn genEntries(
    alloc: std.mem.Allocator,
    sources: *SourceCache,
    writer: *std.Io.Writer,
    comptime namespace: []const u8,
    comptime entries: []const KeyEntry,
) !void {
    try writer.writeAll("pub const " ++ namespace ++ " = struct {\n");
    try writer.writeAll("    pub const keys = [_][]const u8{\n");
    inline for (entries) |entry| {
        try writer.writeAll("        \"" ++ entry.key ++ "\",\n");
    }
    try writer.writeAll("    };\n\n");

    inline for (entries) |entry| {
        const ast = try sources.get(comptime sourceFile(entry.Container));
        const container = comptime containerName(entry.Container);
        if (try fieldDoc(alloc, ast, container, entry.field)) |comment| {
            try writer.writeAll("    pub const @\"" ++ entry.key ++ "\": [:0]const u8 =\n");
            try writer.writeAll(comment);
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("};\n\n");
}

/// Flatten a config struct into dotted keys, descending into nested structs
/// and the element structs of slices (`keybinds[].key`) since users write
/// those fields in `config.zon` too.
fn configEntries(comptime T: type, comptime prefix: []const u8) []const KeyEntry {
    comptime {
        @setEvalBranchQuota(50_000);
        var out: []const KeyEntry = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            if (field.name[0] == '_') continue;
            const key = prefix ++ field.name;
            out = out ++ &[_]KeyEntry{.{ .key = key, .Container = T, .field = field.name }};
            if (nestedStruct(field.type)) |nested| {
                out = out ++ configEntries(nested.T, key ++ nested.separator);
            }
        }
        return out;
    }
}

fn enumEntries(comptime T: type) []const KeyEntry {
    comptime {
        var out: []const KeyEntry = &.{};
        for (@typeInfo(T).@"enum".fields) |field| {
            out = out ++ &[_]KeyEntry{.{ .key = field.name, .Container = T, .field = field.name }};
        }
        return out;
    }
}

const Nested = struct { T: type, separator: []const u8 };

fn nestedStruct(comptime T: type) ?Nested {
    return switch (@typeInfo(T)) {
        .@"struct" => .{ .T = T, .separator = "." },
        .optional => |o| nestedStruct(o.child),
        .pointer => |p| if (p.size == .slice and @typeInfo(p.child) == .@"struct")
            .{ .T = p.child, .separator = "[]." }
        else
            null,
        else => null,
    };
}

/// Source path, relative to this file, of the file declaring `T`. Relies on
/// `@typeName` being `<file>.<Decl>` for top-level declarations of files
/// imported by path from `src/`.
fn sourceFile(comptime T: type) []const u8 {
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        @compileError("helpgen: cannot locate source file for " ++ name);
    const file = name[0..dot];
    if (std.mem.indexOfScalar(u8, file, '.') != null) {
        @compileError("helpgen: only top-level declarations are supported, got " ++ name);
    }
    return file ++ ".zig";
}

fn containerName(comptime T: type) []const u8 {
    const name = @typeName(T);
    return name[std.mem.lastIndexOfScalar(u8, name, '.').? + 1 ..];
}

/// Parsed ASTs keyed by source path. Each file is parsed once even though
/// many keys live in it.
const SourceCache = struct {
    alloc: std.mem.Allocator,
    asts: std.StringHashMapUnmanaged(std.zig.Ast) = .empty,

    fn get(self: *SourceCache, comptime path: []const u8) !std.zig.Ast {
        const gop = try self.asts.getOrPut(self.alloc, path);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.zig.Ast.parse(self.alloc, @embedFile(path), .zig);
        }
        return gop.value_ptr.*;
    }
};

/// Doc comment on `container.field` as a multiline string literal body, or
/// null when the field is undocumented. Scoping the lookup to the container
/// matters: field names like `enabled` repeat across config structs.
fn fieldDoc(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    container: []const u8,
    field: []const u8,
) !?[]const u8 {
    const init_node = findContainer(ast, container) orelse return error.ContainerNotFound;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const decl = ast.fullContainerDecl(&buffer, init_node) orelse return error.ContainerNotFound;
    const tokens = ast.tokens.items(.tag);

    for (decl.ast.members) |member| {
        const container_field = ast.fullContainerField(member) orelse continue;
        const name_token = container_field.ast.main_token;
        const name = ast.tokenSlice(name_token);
        // Identifier may have @"" so we strip that.
        const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
        if (!std.mem.eql(u8, key, field)) continue;

        if (name_token == 0 or tokens[name_token - 1] != .doc_comment) return null;
        return try extractDocComments(alloc, ast, name_token - 1, tokens);
    }
    return error.FieldNotFound;
}

/// Init node of the top-level `const <name> = ...` declaration.
fn findContainer(ast: std.zig.Ast, name: []const u8) ?std.zig.Ast.Node.Index {
    for (ast.rootDecls()) |node| {
        const var_decl = ast.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(var_decl.ast.mut_token + 1), name)) continue;
        return var_decl.ast.init_node.unwrap();
    }
    return null;
}

fn extractDocComments(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    index: std.zig.Ast.TokenIndex,
    tokens: []std.zig.Token.Tag,
) ![]const u8 {
    // Find the first index of the doc comments. The doc comments are
    // always stacked on top of each other so we can just go backwards.
    const start_idx: usize = start_idx: for (0..index) |i| {
        const reverse_i = index - i - 1;
        const token = tokens[reverse_i];
        if (token != .doc_comment) break :start_idx reverse_i + 1;
    } else unreachable;

    // Go through and build up the lines.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    for (start_idx..index + 1) |i| {
        const token = tokens[i];
        if (token != .doc_comment) break;
        try lines.append(alloc, ast.tokenSlice(@intCast(i))[3..]);
    }

    // Convert the lines to a multiline string.
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    const prefix = findCommonPrefix(lines);
    for (lines.items) |line| {
        try buffer.writer.writeAll("    \\\\");
        try buffer.writer.writeAll(line[@min(prefix, line.len)..]);
        try buffer.writer.writeAll("\n");
    }
    try buffer.writer.writeAll(";\n");

    return buffer.toOwnedSlice();
}

fn findCommonPrefix(lines: std.ArrayList([]const u8)) usize {
    var m: usize = std.math.maxInt(usize);
    for (lines.items) |line| {
        var n: usize = std.math.maxInt(usize);
        for (line, 0..) |c, i| {
            if (c != ' ') {
                n = i;
                break;
            }
        }
        m = @min(m, n);
    }
    return m;
}

test "fieldDoc scopes lookup to the named container" {
    const source =
        \\const A = struct {
        \\    /// A's flag.
        \\    ///   Indented detail.
        \\    enabled: bool = false,
        \\    plain: u8 = 0,
        \\};
        \\const B = struct {
        \\    /// B's flag.
        \\    enabled: bool = false,
        \\};
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ast = try std.zig.Ast.parse(alloc, source, .zig);

    try std.testing.expectEqualStrings(
        "    \\\\A's flag.\n    \\\\  Indented detail.\n;\n",
        (try fieldDoc(alloc, ast, "A", "enabled")).?,
    );
    try std.testing.expectEqualStrings(
        "    \\\\B's flag.\n;\n",
        (try fieldDoc(alloc, ast, "B", "enabled")).?,
    );
    try std.testing.expectEqual(null, try fieldDoc(alloc, ast, "A", "plain"));
    try std.testing.expectError(error.FieldNotFound, fieldDoc(alloc, ast, "A", "missing"));
}

test "configEntries flattens nested and slice-element structs" {
    const Inner = struct { x: u8 = 0 };
    const Outer = struct {
        inner: Inner = .{},
        list: []const Inner = &.{},
        maybe: ?Inner = null,
        _private: u8 = 0,
    };
    const keys = comptime blk: {
        var out: []const []const u8 = &.{};
        for (configEntries(Outer, "")) |entry| out = out ++ &[_][]const u8{entry.key};
        break :blk out;
    };
    const expected = [_][]const u8{ "inner", "inner.x", "list", "list[].x", "maybe", "maybe.x" };
    try std.testing.expectEqual(expected.len, keys.len);
    for (expected, keys) |e, k| try std.testing.expectEqualStrings(e, k);
}
