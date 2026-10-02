//! Generates the `help_strings` module from the `///` doc comments on
//! config fields, keybind actions, and client commands, so the CLI and the
//! website render the same text instead of maintaining copies that drift.
//!
//! The key lists come from comptime reflection over the real types, so the
//! output always covers exactly what the config file parses. The doc text comes
//! from parsing each type's source file with `std.zig.Ast`, since doc comments
//! are not available through `@typeInfo`.
//!
//! Every key must be documented. A missing doc comment fails the build, with
//! every gap listed by file and line, so options never ship without docs.
//!
//! Adapted from ghostty-org/ghostty `src/helpgen.zig` @ b1c264163.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! MIT License, see LICENSES/ghostty.txt.

const std = @import("std");
const config = @import("config.zig");
const config_file = @import("config_file.zig");
const command = @import("command.zig");

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
    var missing: std.ArrayList([]const u8) = .empty;
    try genEntries(alloc, &sources, &missing, writer, "Config", comptime configEntries());
    try genEntries(alloc, &sources, &missing, writer, "KeybindAction", comptime enumEntries(config.Action));
    try genEntries(alloc, &sources, &missing, writer, "Command", comptime enumEntries(command.Command));

    if (missing.items.len > 0) {
        for (missing.items) |line| std.debug.print("{s}\n", .{line});
        std.debug.print("helpgen: {d} user-facing keys have no /// doc comment\n", .{missing.items.len});
        std.process.exit(1);
    }
    try stdout.end();
}

/// Emit one namespace with a decl per key, plus the ordered key list. A key
/// without a doc comment is recorded in `missing` instead, so the caller can
/// report every gap at once rather than failing on the first.
fn genEntries(
    alloc: std.mem.Allocator,
    sources: *SourceCache,
    missing: *std.ArrayList([]const u8),
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
        const path = comptime sourceFile(entry.Container);
        const ast = try sources.get(path);
        const container = comptime containerName(entry.Container);
        const field = try fieldDoc(alloc, ast, container, entry.field);
        if (field.doc) |comment| {
            try writer.writeAll("    pub const @\"" ++ entry.key ++ "\": [:0]const u8 =\n");
            try writer.writeAll(comment);
            try writer.writeAll("\n");
        } else {
            try missing.append(alloc, try std.fmt.allocPrint(
                alloc,
                "src/{s}:{d}: " ++ namespace ++ " key `" ++ entry.key ++ "` has no /// doc comment",
                .{ path, field.line },
            ));
        }
    }
    try writer.writeAll("};\n\n");
}

/// One entry per config file option, keyed the way users write it, so the
/// docs and the parser cannot disagree on names.
fn configEntries() []const KeyEntry {
    comptime {
        var out: []const KeyEntry = &.{};
        for (config_file.options) |option| {
            out = out ++ &[_]KeyEntry{.{ .key = option.key, .Container = option.Container, .field = option.field }};
        }
        return out;
    }
}

fn enumEntries(comptime T: type) []const KeyEntry {
    comptime {
        var out: []const KeyEntry = &.{};
        for (@typeInfo(T).@"enum".field_names) |name| {
            out = out ++ &[_]KeyEntry{.{ .key = name, .Container = T, .field = name }};
        }
        return out;
    }
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
            gop.value_ptr.* = try std.zig.Ast.parse(self.alloc, @embedFile(path), .{ .mode = .zig });
        }
        return gop.value_ptr.*;
    }
};

const FieldDoc = struct {
    /// Multiline string literal body, or null when undocumented.
    doc: ?[]const u8,
    /// 1-based line of the field, for reporting a missing doc.
    line: usize,
};

/// Doc comment on `container.field`. Scoping the lookup to the container
/// matters: field names like `enabled` repeat across config structs.
fn fieldDoc(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    container: []const u8,
    field: []const u8,
) !FieldDoc {
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

        const line = ast.tokenLocation(0, name_token).line + 1;
        if (name_token == 0 or tokens[name_token - 1] != .doc_comment) return .{ .doc = null, .line = line };
        return .{ .doc = try extractDocComments(alloc, ast, name_token - 1, tokens), .line = line };
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
    const ast = try std.zig.Ast.parse(alloc, source, .{ .mode = .zig });

    try std.testing.expectEqualStrings(
        "    \\\\A's flag.\n    \\\\  Indented detail.\n;\n",
        (try fieldDoc(alloc, ast, "A", "enabled")).doc.?,
    );
    try std.testing.expectEqualStrings(
        "    \\\\B's flag.\n;\n",
        (try fieldDoc(alloc, ast, "B", "enabled")).doc.?,
    );
    const plain = try fieldDoc(alloc, ast, "A", "plain");
    try std.testing.expectEqual(null, plain.doc);
    try std.testing.expectEqual(@as(usize, 5), plain.line);
    try std.testing.expectError(error.FieldNotFound, fieldDoc(alloc, ast, "A", "missing"));
}
