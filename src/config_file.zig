//! The config file format, modeled on ghostty's: one `key = value` per line,
//! `#` comments, and list options written by repeating the key.
//!
//!     # Workspaces
//!     workspace-name = term
//!     workspace-name = web
//!     gaps-inner = 8
//!     keybind = alt+shift+h=swap_left
//!     app-rule = app-id:com.apple.Safari,workspace:2
//!
//! Keys are derived from `Config` by reflection, so a new field is a new
//! option with no parser changes: nested structs flatten into dashed keys
//! (`gaps.outer.left` is `gaps-outer-left`) and slices become repeatable
//! keys named in the singular (`keybinds` is `keybind`).
//!
//! Parsing never stops at the first problem. Every line is checked, every
//! problem is collected with its source span, and the caller decides what to
//! do: the loader rejects the file on any error but only warns on unknown
//! options, so a typo cannot silently drop a setting, and the config written
//! by a newer bobrwm still loads in an older one.

const std = @import("std");
const config = @import("config.zig");

const Config = config.Config;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// One settable option: the key users write and where it lands in `Config`.
pub const Option = struct {
    key: []const u8,
    /// Field names from `Config` down to the value.
    path: []const []const u8,
    /// The struct declaring the field, so docs can be found on it.
    Container: type,
    field: []const u8,
    /// Each line appends to a list instead of replacing the value.
    repeatable: bool,
};

/// Every option, in `Config` declaration order.
pub const options: []const Option = collectOptions(Config, "", &.{});

/// Parse `source` and check the result, collecting every problem in
/// `diagnostics`. The returned config is only meaningful when
/// `diagnostics.has_errors` is false. Strings in it borrow from `source`, so
/// both must live in `allocator`'s arena.
pub fn parseAndValidate(allocator: Allocator, source: []const u8, diagnostics: *Diagnostics) Allocator.Error!Config {
    var parser: Parser = .{ .allocator = allocator, .source = source, .diagnostics = diagnostics };
    var cfg: Config = .{};
    try parser.parse(&cfg);
    try parser.validate(&cfg);
    diagnostics.sortBySource();
    return cfg;
}

/// Convert the ZON config that preceded this format. The deprecated
/// `workspace_assignments` list becomes app rules, after any existing rule
/// for the same app.
pub fn fromLegacyZon(allocator: Allocator, source: [:0]const u8, zon_diagnostics: *std.zon.parse.Diagnostics) !Config {
    var cfg = try std.zon.parse.fromSliceAlloc(Config, allocator, source, zon_diagnostics, .{
        .ignore_unknown_fields = true,
    });
    const Legacy = struct {
        workspace_assignments: []const struct { app_id: []const u8, workspace: u8 } = &.{},
    };
    // The first pass already reported any syntax error in this source.
    const legacy = try std.zon.parse.fromSliceAlloc(Legacy, allocator, source, null, .{
        .ignore_unknown_fields = true,
    });

    var rules: std.ArrayList(config.AppRule) = .empty;
    try rules.appendSlice(allocator, cfg.app_rules);
    for (legacy.workspace_assignments) |assignment| {
        const ruled = for (cfg.app_rules) |rule| {
            if (std.mem.eql(u8, rule.app_id, assignment.app_id)) break true;
        } else false;
        if (!ruled) try rules.append(allocator, .{ .app_id = assignment.app_id, .workspace = assignment.workspace });
    }
    cfg.app_rules = rules.items;
    return cfg;
}

// Diagnostics

/// Problems found in a config file, in source order, each with the span it
/// points at. Rendered rustc-style so the line and the offending text are
/// visible without opening the file.
pub const Diagnostics = struct {
    allocator: Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    has_errors: bool = false,

    pub const Severity = enum { warning, @"error" };

    pub const Diagnostic = struct {
        severity: Severity,
        title: []const u8,
        /// Byte range in the source; null when the problem has no line, such
        /// as a value set outside the file.
        span: ?Span,
        note: []const u8,
    };

    fn add(self: *Diagnostics, severity: Severity, span: ?Span, title: []const u8, note: []const u8) Allocator.Error!void {
        try self.items.append(self.allocator, .{ .severity = severity, .title = title, .span = span, .note = note });
        if (severity == .@"error") self.has_errors = true;
    }

    /// Validation runs after parsing, so its findings arrive late; report
    /// everything top to bottom instead.
    fn sortBySource(self: *Diagnostics) void {
        std.sort.insertion(Diagnostic, self.items.items, {}, struct {
            fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
                const a_start = if (a.span) |span| span.start else std.math.maxInt(usize);
                const b_start = if (b.span) |span| span.start else std.math.maxInt(usize);
                return a_start < b_start;
            }
        }.lessThan);
    }

    pub fn write(self: *const Diagnostics, writer: *Writer, path: []const u8, source: []const u8) Writer.Error!void {
        for (self.items.items) |diagnostic| try writeDiagnostic(writer, path, source, diagnostic);
    }

    /// Log each diagnostic at its severity: errors as `err`, unknown options
    /// as `warn`.
    pub fn log(self: *const Diagnostics, path: []const u8, source: []const u8) void {
        const scoped = std.log.scoped(.config);
        for (self.items.items) |diagnostic| {
            var buffer: [4096]u8 = undefined;
            var writer: Writer = .fixed(&buffer);
            writeDiagnostic(&writer, path, source, diagnostic) catch {
                scoped.err("config diagnostic at {s} was too large to display", .{path});
                continue;
            };
            switch (diagnostic.severity) {
                .warning => scoped.warn("{s}", .{writer.buffered()}),
                .@"error" => scoped.err("{s}", .{writer.buffered()}),
            }
        }
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

fn writeDiagnostic(writer: *Writer, path: []const u8, source: []const u8, diagnostic: Diagnostics.Diagnostic) Writer.Error!void {
    try writer.print("{t}: {s}\n", .{ diagnostic.severity, diagnostic.title });
    if (diagnostic.span) |span| {
        const location: Location = .of(source, span.start);
        const line_number = location.line + 1;
        const line = source[location.line_start..location.line_end];
        try writer.print("  --> {s}:{d}:{d}\n", .{ path, line_number, location.column + 1 });
        try writer.writeAll("   |\n");
        try writer.print("{d: >3} | {s}\n", .{ line_number, line });
        try writer.writeAll("   | ");
        try writer.splatByteAll(' ', location.column);
        // An empty value still gets a caret, and a span never runs past its
        // line.
        const width = @min(span.end, location.line_end) -| span.start;
        try writer.splatByteAll('^', @max(width, 1));
        try writer.writeByte('\n');
    } else {
        try writer.print("  --> {s}\n", .{path});
    }
    try writer.print("   = {s}\n", .{diagnostic.note});
}

const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,

    fn of(source: []const u8, offset: usize) Location {
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
        var line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
        if (line_end > line_start and source[line_end - 1] == '\r') line_end -= 1;
        return .{
            .line = std.mem.count(u8, source[0..line_start], "\n"),
            .column = offset - line_start,
            .line_start = line_start,
            .line_end = line_end,
        };
    }
};

// Parsing

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
    /// Where each value was written, so validation can point at it.
    spans: std.ArrayList(Located) = .empty,
    /// Repeatable options seen so far. The first line of one replaces the
    /// default list instead of appending to it.
    explicit: [options.len]bool = @splat(false),
    /// Explanation for the most recent `error.Invalid`.
    note: []const u8 = "",

    const Located = struct {
        key: []const u8,
        /// Entry of a repeatable option; null for single values.
        index: ?usize,
        span: Span,
    };

    const Error = error{ Invalid, OutOfMemory };

    fn parse(self: *Parser, cfg: *Config) Allocator.Error!void {
        var start: usize = 0;
        while (start <= self.source.len) {
            const end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
            try self.parseLine(cfg, start, end);
            start = end + 1;
        }
    }

    fn parseLine(self: *Parser, cfg: *Config, line_start: usize, line_end: usize) Allocator.Error!void {
        const line = trimmed(self.source, line_start, line_end);
        if (line.start == line.end or self.source[line.start] == '#') return;

        const equals = std.mem.indexOfScalarPos(u8, self.source[0..line.end], line.start, '=') orelse
            return self.diagnostics.add(.@"error", line, "invalid syntax", "expected `key = value`");
        const key_span = trimmed(self.source, line.start, equals);
        const value_span = trimmed(self.source, equals + 1, line.end);
        if (key_span.start == key_span.end) {
            return self.diagnostics.add(.@"error", line, "invalid syntax", "missing option name before `=`");
        }

        const key = self.source[key_span.start..key_span.end];
        inline for (options, 0..) |option, i| {
            if (std.mem.eql(u8, key, option.key)) return self.apply(option, i, cfg, value_span);
        }
        try self.unknownOption(key, key_span);
    }

    fn unknownOption(self: *Parser, key: []const u8, span: Span) Allocator.Error!void {
        const alloc = self.diagnostics.allocator;
        // ZON-era keys used underscores and dots; point at the new spelling.
        const respelled = try alloc.dupe(u8, key);
        for (respelled) |*c| {
            if (c.* == '_' or c.* == '.') c.* = '-';
        }
        const suggestion: ?[]const u8 = inline for (options) |option| {
            if (std.mem.eql(u8, respelled, option.key) or std.mem.eql(u8, respelled, comptime pluralOf(option))) break option.key;
        } else null;

        const note = if (suggestion) |name|
            try std.fmt.allocPrint(alloc, "no option named `{s}`; did you mean `{s}`?", .{ key, name })
        else
            try std.fmt.allocPrint(alloc, "no option named `{s}`; run `bobrwm show-config --default --docs` to see every option", .{key});
        try self.diagnostics.add(.warning, span, "unknown option ignored", note);
    }

    fn apply(self: *Parser, comptime option: Option, comptime index: usize, cfg: *Config, span: Span) Allocator.Error!void {
        const target = fieldPtr(Config, option.path, cfg);
        const raw = self.source[span.start..span.end];

        if (option.repeatable) {
            const Element = @typeInfo(@TypeOf(target.*)).pointer.child;
            // An empty value clears the list, ghostty-style.
            if (raw.len == 0) {
                target.* = &.{};
                self.explicit[index] = true;
                return;
            }
            const element = self.parseValue(Element, raw) catch |err| switch (err) {
                error.Invalid => return self.invalid(option.key, span),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!self.explicit[index]) target.* = &.{};
            self.explicit[index] = true;
            try self.spans.append(self.diagnostics.allocator, .{ .key = option.key, .index = target.len, .span = span });
            target.* = try appendOne(Element, self.allocator, target.*, element);
            return;
        }

        if (raw.len == 0) {
            // An empty value restores the default, ghostty-style.
            const defaults: option.Container = .{};
            target.* = @field(defaults, option.field);
            return;
        }
        target.* = self.parseValue(@TypeOf(target.*), raw) catch |err| switch (err) {
            error.Invalid => return self.invalid(option.key, span),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try self.spans.append(self.diagnostics.allocator, .{ .key = option.key, .index = null, .span = span });
    }

    fn invalid(self: *Parser, key: []const u8, span: Span) Allocator.Error!void {
        const title = try std.fmt.allocPrint(self.diagnostics.allocator, "invalid value for `{s}`", .{key});
        try self.diagnostics.add(.@"error", span, title, self.note);
    }

    fn fail(self: *Parser, comptime format: []const u8, args: anytype) Error {
        self.note = std.fmt.allocPrint(self.diagnostics.allocator, format, args) catch return error.OutOfMemory;
        return error.Invalid;
    }

    fn parseValue(self: *Parser, comptime T: type, raw: []const u8) Error!T {
        if (T == config.Keybind) return self.parseKeybind(raw);
        switch (@typeInfo(T)) {
            .bool => {
                if (std.mem.eql(u8, raw, "true")) return true;
                if (std.mem.eql(u8, raw, "false")) return false;
                return self.fail("expected true or false, found `{s}`", .{raw});
            },
            .int => return std.fmt.parseInt(T, raw, 10) catch
                return self.fail("expected a whole number from {d} through {d}, found `{s}`", .{
                    std.math.minInt(T),
                    std.math.maxInt(T),
                    raw,
                }),
            .float => return std.fmt.parseFloat(T, raw) catch
                return self.fail("expected a number, found `{s}`", .{raw}),
            .@"enum" => return std.meta.stringToEnum(T, raw) orelse
                return self.fail("expected one of {s}; found `{s}`", .{ comptime tagList(T), raw }),
            .optional => |optional| return try self.parseValue(optional.child, raw),
            .pointer => |pointer| {
                if (pointer.size != .slice or pointer.child != u8) {
                    @compileError("unsupported config value type " ++ @typeName(T));
                }
                return self.parseString(raw);
            },
            .@"struct" => return self.parseFields(T, raw),
            else => @compileError("unsupported config value type " ++ @typeName(T)),
        }
    }

    /// Quotes are optional and only needed to keep leading or trailing
    /// spaces; quoted strings take Zig escapes.
    fn parseString(self: *Parser, raw: []const u8) Error![]const u8 {
        if (raw[0] != '"') return raw;
        return std.zig.string_literal.parseAlloc(self.allocator, raw) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidLiteral => return self.fail("invalid quoted string {s}", .{raw}),
        };
    }

    /// `trigger=action` or `trigger=action:argument`, as in ghostty. The
    /// split is at the last `=` so `=` itself can be the key: `alt+==resize_grow`.
    fn parseKeybind(self: *Parser, raw: []const u8) Error!config.Keybind {
        const equals = std.mem.lastIndexOfScalar(u8, raw, '=') orelse
            return self.fail("expected `trigger=action`, such as `alt+h=focus_left`", .{});
        const trigger = std.mem.trim(u8, raw[0..equals], " \t");
        const binding = std.mem.trim(u8, raw[equals + 1 ..], " \t");
        if (trigger.len == 0) return self.fail("expected `trigger=action`, such as `alt+h=focus_left`", .{});

        var keybind: config.Keybind = .{ .key = "", .action = undefined };
        var parts = std.mem.splitScalar(u8, trigger, '+');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " \t");
            if (parts.peek() == null) {
                if (name.len == 0) return self.fail("missing key after the last `+` in `{s}`", .{trigger});
                keybind.key = name;
            } else {
                try self.setModifier(&keybind.mods, name);
            }
        }

        const colon = std.mem.indexOfScalar(u8, binding, ':');
        const action_name = if (colon) |i| binding[0..i] else binding;
        keybind.action = std.meta.stringToEnum(config.Action, action_name) orelse
            return self.fail("unknown action `{s}`; run `bobrwm list-actions` to see them", .{action_name});
        if (colon) |i| keybind.arg = try self.parseKeybindArg(keybind.action, binding[i + 1 ..]);
        return keybind;
    }

    fn setModifier(self: *Parser, mods: *config.Mods, name: []const u8) Error!void {
        const aliases = [_]struct { []const u8, []const u8 }{
            .{ "ctrl", "ctrl" }, .{ "control", "ctrl" }, .{ "alt", "alt" },
            .{ "opt", "alt" },   .{ "option", "alt" },   .{ "shift", "shift" },
            .{ "cmd", "cmd" },   .{ "command", "cmd" },  .{ "super", "cmd" },
        };
        for (aliases) |alias| {
            if (!std.mem.eql(u8, name, alias[0])) continue;
            inline for (@typeInfo(config.Mods).@"struct".fields) |field| {
                if (std.mem.eql(u8, alias[1], field.name)) @field(mods, field.name) = true;
            }
            return;
        }
        return self.fail("unknown modifier `{s}`; expected ctrl, alt, shift, or cmd", .{name});
    }

    fn parseKeybindArg(self: *Parser, action: config.Action, raw: []const u8) Error!u8 {
        if (action == .move_workspace_to_display) {
            if (std.mem.eql(u8, raw, "next")) return config.next_display_arg;
            if (std.mem.eql(u8, raw, "prev") or std.mem.eql(u8, raw, "previous")) return config.previous_display_arg;
        }
        return std.fmt.parseInt(u8, raw, 10) catch
            return self.fail("expected a number after `{t}:`, found `{s}`", .{ action, raw });
    }

    /// Comma-separated `field:value` pairs, ghostty's syntax for structured
    /// list entries: `app-id:com.apple.Safari,workspace:2`.
    fn parseFields(self: *Parser, comptime T: type, raw: []const u8) Error!T {
        const fields = @typeInfo(T).@"struct".fields;
        var result: T = undefined;
        var seen: [fields.len]bool = @splat(false);
        inline for (fields) |field| {
            if (field.defaultValue()) |default| @field(result, field.name) = default;
        }

        var pairs = std.mem.splitScalar(u8, raw, ',');
        while (pairs.next()) |pair_raw| {
            const pair = std.mem.trim(u8, pair_raw, " \t");
            if (pair.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, pair, ':') orelse
                return self.fail("expected `field:value`, found `{s}`", .{pair});
            const name = std.mem.trim(u8, pair[0..colon], " \t");
            const value = std.mem.trim(u8, pair[colon + 1 ..], " \t");
            const matched = inline for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, name, comptime kebab(field.name))) {
                    @field(result, field.name) = try self.parseValue(field.type, value);
                    seen[i] = true;
                    break true;
                }
            } else false;
            if (!matched) return self.fail("unknown field `{s}`; expected {s}", .{ name, comptime fieldList(T) });
        }
        inline for (fields, 0..) |field, i| {
            if (field.defaultValue() == null and !seen[i]) {
                return self.fail("missing `" ++ comptime kebab(field.name) ++ ":`", .{});
            }
        }
        return result;
    }

    // Validation

    const ValidationContext = struct {
        parser: *Parser,
        cfg: *const Config,
        failure: ?Allocator.Error = null,

        fn emit(context: *anyopaque, diagnostic: config.Validation.Diagnostic) bool {
            const self: *ValidationContext = @ptrCast(@alignCast(context));
            self.parser.reportValidation(self.cfg, diagnostic) catch |err| {
                self.failure = err;
                return false;
            };
            return true;
        }
    };

    fn validate(self: *Parser, cfg: *const Config) Allocator.Error!void {
        var context: ValidationContext = .{ .parser = self, .cfg = cfg };
        const sink: config.Validation.Sink = .{ .context = &context, .emitFn = ValidationContext.emit };
        config.Validation.visit(cfg, &sink);
        if (context.failure) |err| return err;
    }

    fn reportValidation(self: *Parser, cfg: *const Config, diagnostic: config.Validation.Diagnostic) Allocator.Error!void {
        const alloc = self.diagnostics.allocator;
        const option = diagnostic.kind.option();
        var note: Writer.Allocating = .init(alloc);
        config.Validation.writeMessage(&note.writer, cfg, diagnostic) catch return error.OutOfMemory;
        const title = try std.fmt.allocPrint(alloc, "invalid value for `{s}`", .{option});
        try self.diagnostics.add(.@"error", self.find(option, diagnostic.index), title, note.written());
    }

    /// The last place `key` was set, so a later line that overrides an
    /// earlier one is the one reported.
    fn find(self: *const Parser, key: []const u8, index: ?usize) ?Span {
        var i = self.spans.items.len;
        while (i > 0) {
            i -= 1;
            const located = self.spans.items[i];
            if (std.mem.eql(u8, located.key, key) and std.meta.eql(located.index, index)) return located.span;
        }
        return null;
    }
};

fn trimmed(source: []const u8, start: usize, end: usize) Span {
    var span: Span = .{ .start = start, .end = end };
    while (span.start < span.end and std.ascii.isWhitespace(source[span.start])) span.start += 1;
    while (span.end > span.start and std.ascii.isWhitespace(source[span.end - 1])) span.end -= 1;
    return span;
}

fn appendOne(comptime T: type, allocator: Allocator, items: []const T, item: T) Allocator.Error![]const T {
    const grown = try allocator.alloc(T, items.len + 1);
    @memcpy(grown[0..items.len], items);
    grown[items.len] = item;
    return grown;
}

// Writing

/// Write one value in the form the parser reads back.
pub fn writeValue(writer: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == config.Keybind) return writeKeybind(writer, value);
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int => try writer.print("{d}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .@"enum" => try writer.writeAll(@tagName(value)),
        .optional => if (value) |child| try writeValue(writer, child),
        .pointer => try writeString(writer, value),
        .@"struct" => |info| {
            var first = true;
            inline for (info.fields) |field| {
                const field_value = @field(value, field.name);
                const is_default = if (field.defaultValue()) |default| std.meta.eql(field_value, default) else false;
                if (!is_default) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeAll(comptime kebab(field.name) ++ ":");
                    try writeValue(writer, field_value);
                }
            }
        },
        else => @compileError("unsupported config value type " ++ @typeName(T)),
    }
}

fn writeString(writer: *Writer, value: []const u8) Writer.Error!void {
    const needs_quotes = value.len == 0 or value[0] == '"' or
        std.ascii.isWhitespace(value[0]) or std.ascii.isWhitespace(value[value.len - 1]) or
        std.mem.indexOfAny(u8, value, "\n\r") != null;
    if (needs_quotes) {
        try writer.print("\"{f}\"", .{std.zig.fmtString(value)});
    } else {
        try writer.writeAll(value);
    }
}

fn writeKeybind(writer: *Writer, keybind: config.Keybind) Writer.Error!void {
    // Same modifier order as the macOS menu glyphs: ⌃⌥⇧⌘.
    const modifiers = [_]struct { bool, []const u8 }{
        .{ keybind.mods.ctrl, "ctrl+" },
        .{ keybind.mods.alt, "alt+" },
        .{ keybind.mods.shift, "shift+" },
        .{ keybind.mods.cmd, "cmd+" },
    };
    for (modifiers) |modifier| {
        if (modifier[0]) try writer.writeAll(modifier[1]);
    }
    try writer.print("{s}={t}", .{ keybind.key, keybind.action });
    if (!config.Keybind.takesArg(keybind.action) and keybind.arg == 0) return;
    if (keybind.action == .move_workspace_to_display and keybind.arg == config.next_display_arg) {
        try writer.writeAll(":next");
    } else if (keybind.action == .move_workspace_to_display and keybind.arg == config.previous_display_arg) {
        try writer.writeAll(":prev");
    } else {
        try writer.print(":{d}", .{keybind.arg});
    }
}

// Option table

fn collectOptions(comptime T: type, comptime prefix: []const u8, comptime path: []const []const u8) []const Option {
    comptime {
        @setEvalBranchQuota(50_000);
        var out: []const Option = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            if (field.name[0] == '_') continue;
            const key = prefix ++ kebab(field.name);
            const field_path = path ++ &[_][]const u8{field.name};
            if (@typeInfo(field.type) == .@"struct") {
                out = out ++ collectOptions(field.type, key ++ "-", field_path);
                continue;
            }
            const repeatable = isList(field.type);
            out = out ++ &[_]Option{.{
                .key = if (repeatable) singular(key) else key,
                .path = field_path,
                .Container = T,
                .field = field.name,
                .repeatable = repeatable,
            }};
        }
        return out;
    }
}

fn isList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child != u8,
        else => false,
    };
}

/// List options are named for one entry, since each line adds one.
fn singular(comptime key: []const u8) []const u8 {
    if (key[key.len - 1] != 's') @compileError("list option `" ++ key ++ "` must be a plural field name");
    return key[0 .. key.len - 1];
}

/// The plural a user coming from ZON might write, for suggestions.
fn pluralOf(comptime option: Option) []const u8 {
    return if (option.repeatable) option.key ++ "s" else option.key;
}

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = name[0..name.len].*;
        for (&out) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = out;
        return &final;
    }
}

fn tagList(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ field.name;
        }
        return out;
    }
}

fn fieldList(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ kebab(field.name);
        }
        return out;
    }
}

fn Leaf(comptime T: type, comptime path: []const []const u8) type {
    return if (path.len == 0) T else Leaf(@FieldType(T, path[0]), path[1..]);
}

pub fn fieldPtr(comptime T: type, comptime path: []const []const u8, ptr: *T) *Leaf(T, path) {
    if (path.len == 0) return ptr;
    return fieldPtr(@FieldType(T, path[0]), path[1..], &@field(ptr.*, path[0]));
}

// Tests

const t = std.testing;

const TestResult = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    config: Config = .{},
    diagnostics: Diagnostics = undefined,

    /// Heap-allocated so `diagnostics` can keep a pointer into `arena`.
    fn parse(source: []const u8) !*TestResult {
        const result = try t.allocator.create(TestResult);
        errdefer t.allocator.destroy(result);
        result.* = .{ .arena = .init(t.allocator), .source = source };
        errdefer result.arena.deinit();
        result.diagnostics = .{ .allocator = result.arena.allocator() };
        result.config = try parseAndValidate(result.arena.allocator(), source, &result.diagnostics);
        return result;
    }

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
        t.allocator.destroy(self);
    }

    fn render(self: *TestResult) ![]const u8 {
        var out: Writer.Allocating = .init(self.arena.allocator());
        try self.diagnostics.write(&out.writer, "/tmp/config", self.source);
        return out.written();
    }
};

test "option keys flatten nested structs and singularize lists" {
    const keys = comptime blk: {
        var out: []const []const u8 = &.{};
        for (options) |option| out = out ++ &[_][]const u8{option.key};
        break :blk out;
    };
    const expected = [_][]const u8{
        "disable-default-keybinds", "keybind",          "app-rule",
        "workspace-name",           "swipe-enabled",    "swipe-fingers",
        "swipe-distance-pct",       "swipe-reverse",    "dimmed-inactive-enabled",
        "dimmed-inactive-level",    "gaps-inner",       "gaps-outer-left",
        "gaps-outer-right",         "gaps-outer-top",   "gaps-outer-bottom",
        "layout",                   "bsp-split",        "bsp-insert-point",
        "bsp-split-ratio",          "new-window-split", "animation-enabled",
        "animation-duration-ms",    "animation-easing", "start-at-login",
    };
    try t.expectEqual(expected.len, keys.len);
    for (expected, keys) |want, got| try t.expectEqualStrings(want, got);
}

test "parses every value kind, comments, and blank lines" {
    const result = try TestResult.parse(
        \\# a comment
        \\
        \\   # an indented comment
        \\layout = monocle
        \\bsp-split-ratio=0.7
        \\  gaps-inner   =   12
        \\swipe-reverse = true
        \\workspace-name = term
        \\workspace-name = "  padded  "
        \\keybind = ctrl+opt+shift+command+return=toggle_split
        \\keybind = alt+==resize_grow
        \\keybind = alt+n=move_workspace_to_display:next
        \\keybind = alt+p=move_workspace_to_display:prev
        \\app-rule = app-id:com.apple.Safari, workspace:2
        \\app-rule = app-id:com.example.Float,float:true
    );
    defer result.deinit();
    try t.expect(!result.diagnostics.has_errors);
    try t.expectEqual(@as(usize, 0), result.diagnostics.items.items.len);

    const cfg = result.config;
    try t.expectEqual(.monocle, cfg.layout);
    try t.expectEqual(@as(f64, 0.7), cfg.bsp_split_ratio);
    try t.expectEqual(@as(u16, 12), cfg.gaps.inner);
    try t.expect(cfg.swipe.reverse);
    try t.expectEqual(@as(usize, 2), cfg.workspace_names.len);
    try t.expectEqualStrings("  padded  ", cfg.workspace_names[1]);

    try t.expectEqual(@as(usize, 4), cfg.keybinds.len);
    try t.expectEqual(config.Mods{ .ctrl = true, .alt = true, .shift = true, .cmd = true }, cfg.keybinds[0].mods);
    try t.expectEqualStrings("return", cfg.keybinds[0].key);
    try t.expectEqualStrings("=", cfg.keybinds[1].key);
    try t.expectEqual(.resize_grow, cfg.keybinds[1].action);
    try t.expectEqual(config.next_display_arg, cfg.keybinds[2].arg);
    try t.expectEqual(config.previous_display_arg, cfg.keybinds[3].arg);

    try t.expectEqual(@as(usize, 2), cfg.app_rules.len);
    try t.expectEqual(@as(?u8, 2), cfg.app_rules[0].workspace);
    try t.expect(!cfg.app_rules[0].float);
    try t.expect(cfg.app_rules[1].float);
}

test "later single values win and empty values reset or clear" {
    const result = try TestResult.parse(
        \\gaps-inner = 4
        \\gaps-inner = 8
        \\layout = monocle
        \\layout =
        \\keybind = alt+h=focus_left
        \\keybind =
        \\keybind = alt+l=focus_right
    );
    defer result.deinit();
    try t.expect(!result.diagnostics.has_errors);
    try t.expectEqual(@as(u16, 8), result.config.gaps.inner);
    try t.expectEqual(.bsp, result.config.layout);
    try t.expectEqual(@as(usize, 1), result.config.keybinds.len);
    try t.expectEqual(.focus_right, result.config.keybinds[0].action);
}

test "omitted keybinds keep the default list" {
    const result = try TestResult.parse("gaps-inner = 4\n");
    defer result.deinit();
    try t.expect(config.isDefaultKeybindSlice(result.config.keybinds));
}

test "every problem is reported with its line, not just the first" {
    const result = try TestResult.parse(
        \\layout = spiral
        \\no equals sign here
        \\bsp_split_ratio = 0.5
        \\keybind = hyper+h=focus_left
        \\keybind = alt+h=fly
        \\app-rule = workspace:2
        \\swipe-fingers = 300
    );
    defer result.deinit();
    try t.expect(result.diagnostics.has_errors);
    const rendered = try result.render();

    try t.expectEqual(@as(usize, 6), std.mem.count(u8, rendered, "error: "));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "warning: unknown option ignored"));
    try t.expect(std.mem.indexOf(u8, rendered,
        \\error: invalid value for `layout`
        \\  --> /tmp/config:1:10
        \\   |
        \\  1 | layout = spiral
        \\   |          ^^^^^^
        \\   = expected one of bsp, monocle; found `spiral`
    ) != null);
    try t.expect(std.mem.indexOf(u8, rendered, "error: invalid syntax\n  --> /tmp/config:2:1") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "did you mean `bsp-split-ratio`?") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unknown modifier `hyper`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "unknown action `fly`; run `bobrwm list-actions`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "missing `app-id:`") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "expected a whole number from 0 through 255, found `300`") != null);
}

test "validation errors point at the entry that caused them" {
    const result = try TestResult.parse(
        \\workspace-name = one
        \\workspace-name = two
        \\keybind = alt+h=focus_left
        \\keybind = alt+3=focus_workspace:3
        \\dimmed-inactive-level = 1.5
    );
    defer result.deinit();
    try t.expect(result.diagnostics.has_errors);
    const rendered = try result.render();

    try t.expect(std.mem.indexOf(u8, rendered,
        \\error: invalid value for `keybind`
        \\  --> /tmp/config:4:11
        \\   |
        \\  4 | keybind = alt+3=focus_workspace:3
        \\   |           ^^^^^^^^^^^^^^^^^^^^^^^
        \\   = workspace must be from 1 through 2, found 3
    ) != null);
    try t.expect(std.mem.indexOf(u8, rendered, "--> /tmp/config:5:25") != null);
    try t.expect(std.mem.indexOf(u8, rendered, "expected a finite value from 0 through 1, found 1.5") != null);
    // Reported in source order even though validation found them after parsing.
    try t.expect(std.mem.indexOf(u8, rendered, ":4:11").? < std.mem.indexOf(u8, rendered, ":5:25").?);
}

test "an unparseable keybind does not shift the entries validation points at" {
    const result = try TestResult.parse(
        \\workspace-name = one
        \\keybind = alt+h=nope
        \\keybind = alt+2=focus_workspace:2
    );
    defer result.deinit();
    const rendered = try result.render();
    try t.expect(std.mem.indexOf(u8, rendered, "  3 | keybind = alt+2=focus_workspace:2") != null);
}

test "unknown options only warn" {
    const result = try TestResult.parse("future-option = 1\ngaps-inner = 2\n");
    defer result.deinit();
    try t.expect(!result.diagnostics.has_errors);
    try t.expectEqual(@as(u16, 2), result.config.gaps.inner);
    try t.expectEqual(@as(usize, 1), result.diagnostics.items.items.len);
}

test "written values parse back to the same config" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original: Config = .{
        .workspace_names = &.{ "term", " padded" },
        .keybinds = &.{
            .{ .key = "=", .mods = .{ .alt = true, .ctrl = true }, .action = .resize_grow },
            .{ .key = "1", .mods = .{ .cmd = true }, .action = .focus_workspace, .arg = 1 },
            .{ .key = "n", .action = .move_workspace_to_display, .arg = config.previous_display_arg },
        },
        .app_rules = &.{.{ .app_id = "com.apple.Safari", .workspace = 2, .float = true }},
        .dimmed_inactive = .{ .level = 0.35 },
    };

    var out: Writer.Allocating = .init(alloc);
    inline for (options) |option| {
        const value = fieldPtr(Config, option.path, @constCast(&original)).*;
        if (option.repeatable) {
            for (value) |item| {
                try out.writer.writeAll(option.key ++ " = ");
                try writeValue(&out.writer, item);
                try out.writer.writeByte('\n');
            }
        } else {
            try out.writer.writeAll(option.key ++ " = ");
            try writeValue(&out.writer, value);
            try out.writer.writeByte('\n');
        }
    }

    var diagnostics: Diagnostics = .{ .allocator = alloc };
    const parsed = try parseAndValidate(alloc, out.written(), &diagnostics);
    try t.expect(!diagnostics.has_errors);
    try t.expectEqualStrings(" padded", parsed.workspace_names[1]);
    try t.expectEqual(@as(usize, 3), parsed.keybinds.len);
    for (original.keybinds, parsed.keybinds) |want, got| {
        try t.expectEqualStrings(want.key, got.key);
        try t.expectEqual(want.mods, got.mods);
        try t.expectEqual(want.action, got.action);
        try t.expectEqual(want.arg, got.arg);
    }
    try t.expectEqual(original.app_rules[0].workspace, parsed.app_rules[0].workspace);
    try t.expect(parsed.app_rules[0].float);
    try t.expectEqual(original.dimmed_inactive.level, parsed.dimmed_inactive.level);
}

test "legacy ZON converts, folding workspace assignments into app rules" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const cfg = try fromLegacyZon(arena.allocator(),
        \\.{
        \\    .gaps = .{ .inner = 6 },
        \\    .app_rules = .{ .{ .app_id = "com.a", .float = true } },
        \\    .workspace_assignments = .{
        \\        .{ .app_id = "com.a", .workspace = 3 },
        \\        .{ .app_id = "com.b", .workspace = 2 },
        \\    },
        \\}
    , &zon_diagnostics);
    try t.expectEqual(@as(u16, 6), cfg.gaps.inner);
    try t.expectEqual(@as(usize, 2), cfg.app_rules.len);
    try t.expectEqual(@as(?u8, null), cfg.app_rules[0].workspace);
    try t.expectEqualStrings("com.b", cfg.app_rules[1].app_id);
    try t.expectEqual(@as(?u8, 2), cfg.app_rules[1].workspace);
}
