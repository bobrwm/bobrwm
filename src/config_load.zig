//! Finds, loads, and validates the config: `init.lua`, written by hand, and
//! `settings.json`, written by the settings UI, merged over the defaults.
//! Problems are reported against the line that caused them.

const std = @import("std");
const config = @import("config.zig");
const config_layer = @import("config_layer.zig");
const config_lua = @import("config_lua.zig");
const config_json = @import("config_json.zig");
const config_format = @import("config_format.zig");
const LuaSandbox = @import("lua_sandbox.zig");
const osutil = @import("osutil.zig");

const Allocator = std.mem.Allocator;
pub const Diagnostic = config_layer.Diagnostic;
const Validation = config.Validation;

const log = std.log.scoped(.config);

// Config files are small; anything larger is a mistake, not a config.
const max_file_bytes = 1024 * 1024;

pub const Paths = struct {
    /// Holds the files below; `require` resolves modules here.
    dir: [:0]const u8,
    lua: [:0]const u8,
    json: [:0]const u8,
    /// The pre-Lua config, read only to migrate it.
    zon: [:0]const u8,

    /// `explicit` names `init.lua` (from `--config`). Otherwise the files live
    /// in `$XDG_CONFIG_HOME/bobrwm`, or `~/.config/bobrwm`. The files need not
    /// exist yet, so the daemon can notice them being created.
    pub fn resolve(allocator: Allocator, explicit: ?[]const u8) !Paths {
        const dir = if (explicit) |path|
            try allocator.dupeSentinel(u8, std.fs.path.dirname(path) orelse ".", 0)
        else if (osutil.getenv("XDG_CONFIG_HOME")) |config_home|
            try std.fmt.allocPrintSentinel(allocator, "{s}/bobrwm", .{config_home}, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}/.config/bobrwm", .{osutil.getenv("HOME") orelse return error.MissingHome}, 0);
        errdefer allocator.free(dir);
        const lua = if (explicit) |path| try allocator.dupeSentinel(u8, path, 0) else try join(allocator, dir, "init.lua");
        errdefer allocator.free(lua);
        const json = try join(allocator, dir, "settings.json");
        errdefer allocator.free(json);
        return .{ .dir = dir, .lua = lua, .json = json, .zon = try join(allocator, dir, "config.zon") };
    }

    pub fn deinit(self: Paths, allocator: Allocator) void {
        inline for (.{ self.dir, self.lua, self.json, self.zon }) |path| allocator.free(path);
    }

    fn join(allocator: Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    }
};

pub const LoadError = error{ InvalidConfig, OutOfMemory };

/// Reads both files and merges them. Missing files are empty layers.
/// `module_paths`, when supplied, receives attempted require paths, including
/// missing or invalid modules, so fixing a failed load can trigger a retry.
/// The paths borrow `arena`. See `loadSources` for what fails the load.
pub fn load(gpa: Allocator, arena: Allocator, paths: Paths, diagnostics: *std.ArrayList(Diagnostic), module_paths: ?*std.ArrayList([:0]const u8)) LoadError!config_layer.Merged {
    return loadWithSettings(gpa, arena, paths, try readOptional(arena, paths.json, diagnostics), diagnostics, module_paths);
}

/// `load` with `settings_json` in place of `settings.json`, so the settings
/// window can check a change before writing it.
pub fn loadWithSettings(
    gpa: Allocator,
    arena: Allocator,
    paths: Paths,
    settings_json: ?[]const u8,
    diagnostics: *std.ArrayList(Diagnostic),
    module_paths: ?*std.ArrayList([:0]const u8),
) LoadError!config_layer.Merged {
    var modules: ModuleDir = .{ .dir = paths.dir, .arena = arena, .paths = module_paths };
    return loadSources(gpa, arena, .{
        .lua = try readOptional(arena, paths.lua, diagnostics),
        .json = settings_json,
        .lua_name = std.fs.path.basename(paths.lua),
        .modules = modules.source(),
    }, diagnostics);
}

pub const EditError = error{ OutOfMemory, InvalidJson };

/// The settings window's layer after a save: `existing`, the current
/// `settings.json` if there is one, with every setting that differs between
/// `current` and `next` set to its new value. Settings the window did not
/// change keep whichever layer set them. Removed rules become neutral
/// overrides, masking Lua without editing it or freezing unrelated rules.
pub fn editSettings(arena: Allocator, existing: ?[]const u8, current: *const config.Config, next: *const config.Config) EditError![]const u8 {
    var root = try parseSettings(arena, existing);
    const settings = try root.object.getOrPut(arena, "settings");
    if (!settings.found_existing or settings.value_ptr.* != .object) settings.value_ptr.* = .{ .object = .empty };
    try putChanged(config.Config, arena, settings.value_ptr, current.*, next.*, "");
    for (next.app_rules) |rule| {
        if (findRule(current.app_rules, rule.app_id)) |before| {
            if (before.workspace == rule.workspace and before.float == rule.float) continue;
        }
        try putRule(arena, &root.object, rule);
    }
    for (current.app_rules) |rule| {
        if (findRule(next.app_rules, rule.app_id) == null)
            try putRule(arena, &root.object, .{ .app_id = rule.app_id });
    }
    return std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
}

/// Removes only the UI override, so a fresh load uses Lua or built-in defaults.
/// Rule names are bundle IDs; setting names are dotted paths.
pub fn resetOverride(arena: Allocator, existing: ?[]const u8, name: []const u8, is_rule: bool) EditError![]const u8 {
    var root = try parseSettings(arena, existing);
    if (is_rule) {
        if (root.object.getPtr("rules")) |rules| {
            if (rules.* != .array) return error.InvalidJson;
            var i: usize = 0;
            while (i < rules.array.items.len) {
                if (ruleMatches(rules.array.items[i], name)) {
                    _ = rules.array.orderedRemove(i);
                } else i += 1;
            }
        }
    } else if (root.object.getPtr("settings")) |settings| {
        removeSetting(settings, name);
    }
    return std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
}

fn removeSetting(value: *std.json.Value, path: []const u8) void {
    if (value.* != .object) return;
    // Preserve order: dotted and nested keys can address the same setting.
    _ = value.object.orderedRemove(path);
    // Every dotted prefix is valid: gaps.outer.left can also be represented
    // by {"gaps.outer":{"left":...}} or {"gaps":{"outer.left":...}}.
    for (path, 0..) |char, dot| {
        if (char != '.') continue;
        if (value.object.getPtr(path[0..dot])) |child| removeSetting(child, path[dot + 1 ..]);
    }
}

fn parseSettings(arena: Allocator, existing: ?[]const u8) EditError!std.json.Value {
    const root: std.json.Value = if (existing) |source|
        std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        }
    else
        .{ .object = .empty };
    if (root != .object) return error.InvalidJson;
    return root;
}

fn putRule(arena: Allocator, root: *std.json.ObjectMap, rule: config.AppRule) EditError!void {
    const entry = try root.getOrPut(arena, "rules");
    if (!entry.found_existing) entry.value_ptr.* = .{ .array = .init(arena) };
    if (entry.value_ptr.* != .array) return error.InvalidJson;
    var rules = &entry.value_ptr.array;
    var i: usize = 0;
    while (i < rules.items.len) {
        if (ruleMatches(rules.items[i], rule.app_id)) {
            _ = rules.orderedRemove(i);
        } else i += 1;
    }
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "app", .{ .string = rule.app_id });
    if (rule.workspace) |workspace| try object.put(arena, "workspace", .{ .integer = workspace });
    try object.put(arena, "float", .{ .bool = rule.float });
    try rules.append(.{ .object = object });
}

fn ruleMatches(value: std.json.Value, app_id: []const u8) bool {
    if (value != .object) return false;
    const app = value.object.get("app") orelse return false;
    return app == .string and std.mem.eql(u8, app.string, app_id);
}

fn findRule(rules: []const config.AppRule, app_id: []const u8) ?config.AppRule {
    for (rules) |rule| if (std.mem.eql(u8, rule.app_id, app_id)) return rule;
    return null;
}

fn objectField(arena: Allocator, object: *std.json.ObjectMap, name: []const u8) Allocator.Error!*std.json.ObjectMap {
    const entry = try object.getOrPut(arena, name);
    if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
    return &entry.value_ptr.object;
}

fn putChanged(comptime T: type, arena: Allocator, settings: *std.json.Value, current: T, next: T, comptime prefix: []const u8) Allocator.Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime !config_layer.isSetting(T, name)) continue;
        const Field = @FieldType(T, name);
        const before = @field(current, name);
        const after = @field(next, name);
        const path = prefix ++ name;
        if (!config_format.sameSettings(Field, before, after)) {
            if (@typeInfo(Field) == .@"struct") {
                try putChanged(Field, arena, settings, before, after, path ++ ".");
            } else {
                // Remove all equivalent spellings before writing the canonical
                // nested leaf, otherwise a later dotted key can still win.
                removeSetting(settings, path);
                var object = &settings.object;
                var parts = std.mem.splitScalar(u8, path, '.');
                while (parts.next()) |part| {
                    if (parts.peek() != null) {
                        object = try objectField(arena, object, part);
                    } else try object.put(arena, part, try jsonValue(arena, after));
                }
            }
        }
    }
}

fn jsonValue(arena: Allocator, value: anytype) Allocator.Error!std.json.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        .int => .{ .integer = std.math.lossyCast(i64, value) },
        // Through decimal text, so an f32 0.35 is written as 0.35 rather
        // than its nearest f64.
        .float => .{ .float = std.fmt.parseFloat(f64, try std.fmt.allocPrint(arena, "{d}", .{value})) catch unreachable },
        .@"enum" => .{ .string = @tagName(value) },
        .pointer => blk: {
            comptime std.debug.assert(T == []const []const u8);
            var array: std.json.Array = .init(arena);
            for (value) |string| try array.append(.{ .string = string });
            break :blk .{ .array = array };
        },
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    };
}

pub const Sources = struct {
    lua: ?[]const u8 = null,
    json: ?[]const u8 = null,
    lua_name: []const u8 = "init.lua",
    json_name: []const u8 = "settings.json",
    modules: ?LuaSandbox.ModuleSource = null,
};

/// Fails with `InvalidConfig` when `init.lua` raises, `settings.json` is not
/// valid JSON, or the merged config breaks an invariant, such as a keybind
/// for workspace 7 with five workspaces. Skipped entries are only
/// diagnostics. On failure, the caller keeps its last good config.
pub fn loadSources(gpa: Allocator, arena: Allocator, sources: Sources, diagnostics: *std.ArrayList(Diagnostic)) LoadError!config_layer.Merged {
    var lua: config_layer.Layer = .{ .kind = .lua };
    var json: config_layer.Layer = .{ .kind = .settings_ui };
    var failed = false;

    if (sources.lua) |source| {
        config_lua.load(gpa, arena, sources.lua_name, source, sources.modules, &lua, diagnostics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => failed = true,
        };
    }
    if (sources.json) |source| {
        config_json.load(arena, sources.json_name, source, &json, diagnostics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => failed = true,
        };
    }
    if (failed) return error.InvalidConfig;

    const merged = try config_layer.merge(arena, &.{ &lua, &json });
    var sink_context: ValidationContext = .{ .arena = arena, .merged = &merged, .diagnostics = diagnostics };
    const sink: Validation.ValidationSink = .{ .context = &sink_context, .emitFn = ValidationContext.emit };
    Validation.visitValidationDiagnostics(&merged.config, &sink);
    if (sink_context.err) |err| return err;
    if (sink_context.found) return error.InvalidConfig;
    return merged;
}

/// Logs each diagnostic as `file:line: message`.
pub fn logDiagnostics(diagnostics: []const Diagnostic) void {
    for (diagnostics) |diagnostic| {
        const where = diagnostic.location;
        switch (diagnostic.severity) {
            .@"error" => log.err("{f}{s}", .{ fmtLocation(where), diagnostic.message }),
            .warning => log.warn("{f}{s}", .{ fmtLocation(where), diagnostic.message }),
        }
    }
}

pub fn fmtLocation(location: config_layer.Location) std.fmt.Alt(config_layer.Location, writeLocation) {
    return .{ .data = location };
}

fn writeLocation(location: config_layer.Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (location.file.len == 0) return;
    try writer.writeAll(location.file);
    if (location.line > 0) try writer.print(":{d}", .{location.line});
    try writer.writeAll(": ");
}

/// Writes `init.lua` from a pre-Lua `config.zon` when `init.lua` does not
/// exist yet, so upgrading needs no manual step. `config.zon` is left alone.
pub fn migrateIfNeeded(arena: Allocator, paths: Paths) void {
    if (osutil.pathExists(paths.lua) or !osutil.pathExists(paths.zon)) return;
    const source = osutil.readFileAllocSentinel(arena, paths.zon, max_file_bytes) orelse {
        log.err("could not read {s} to migrate it", .{paths.zon});
        return;
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const lua = migrate(arena, source, &diagnostics) catch |err| {
        if (err == error.InvalidZon) {
            const formatter: std.zon.parse.Diagnostics.Formatter = .{ .path = paths.zon, .errors = diagnostics.errors };
            log.err("could not migrate {s}:\n{f}", .{ paths.zon, formatter });
        } else log.err("could not migrate {s}: {t}", .{ paths.zon, err });
        return;
    };
    if (!osutil.writeFile(paths.lua, lua)) {
        log.err("could not write {s}", .{paths.lua});
        return;
    }
    log.info("migrated {s} to {s}", .{ paths.zon, paths.lua });
}

/// Written when the menu bar opens a config that does not exist yet.
pub const starter_file =
    \\-- bobrwm config. `bobrwm show-config --default --docs` lists every setting.
    \\
    \\-- bobrwm.settings.set{ gaps = { inner = 8 } }
    \\-- bobrwm.keymap.set("alt+1", "focus_workspace", { workspace = 1 })
    \\-- bobrwm.app_rules.add{ app = "com.apple.finder", float = true }
    \\
;

pub const MigrateError = error{ OutOfMemory, InvalidZon };

/// Converts `config.zon` source to `init.lua` source holding only what
/// differs from the defaults. Fields that no longer exist are dropped. On
/// `InvalidZon`, `diagnostics` says why.
pub fn migrate(arena: Allocator, source: [:0]const u8, diagnostics: *std.zon.parse.Diagnostics) MigrateError![]const u8 {
    const parsed = std.zon.parse.fromSlice(config.Config, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.InvalidZon,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll(migration_header) catch return error.OutOfMemory;
    config_format.write(&out.writer, &parsed, null, .{ .all_settings = false }) catch return error.OutOfMemory;
    return out.written();
}

const migration_header =
    \\-- Migrated from config.zon, which bobrwm no longer reads.
    \\-- `bobrwm show-config --default --docs` lists every setting.
    \\
    \\
;

/// Turns validation problems in the merged config into diagnostics placed at
/// the line in whichever layer set the offending value.
const ValidationContext = struct {
    arena: Allocator,
    merged: *const config_layer.Merged,
    diagnostics: *std.ArrayList(Diagnostic),
    found: bool = false,
    err: ?Allocator.Error = null,

    fn emit(context: *anyopaque, issue: Validation.ValidationDiagnostic) bool {
        const self: *ValidationContext = @ptrCast(@alignCast(context));
        // Built-in binds cover all ten workspaces; with fewer, the extra
        // ones are inert rather than mistakes.
        if (self.origin(issue).kind == .default) return true;
        self.found = true;
        self.append(issue) catch |err| {
            self.err = err;
            return false;
        };
        return true;
    }

    fn append(self: *ValidationContext, issue: Validation.ValidationDiagnostic) Allocator.Error!void {
        var message: std.Io.Writer.Allocating = .init(self.arena);
        Validation.writeValidationMessage(&message.writer, &self.merged.config, issue) catch return error.OutOfMemory;
        try self.diagnostics.append(self.arena, .{
            .severity = .@"error",
            .location = self.origin(issue).location,
            .message = message.written(),
        });
    }

    fn origin(self: *const ValidationContext, issue: Validation.ValidationDiagnostic) config_layer.Origin {
        const origins = &self.merged.origins;
        return switch (issue.kind) {
            .too_many_workspaces, .invalid_workspace_name => origins.workspace_names,
            .invalid_bsp_split_ratio => origins.bsp_split_ratio,
            .invalid_dim_level => origins.dimmed_inactive.level,
            .unknown_key_name, .invalid_keybind_workspace, .invalid_keybind_display => self.merged.keybind_origins[issue.index.?],
            .empty_app_rule_id, .invalid_app_rule_workspace, .duplicate_app_rule => self.merged.rule_origins[issue.index.?],
            // `merge` folds the deprecated alias into app rules.
            .empty_workspace_assignment_id, .invalid_workspace_assignment, .duplicate_workspace_assignment => unreachable,
        };
    }
};

/// Reads `path`, or returns null when it does not exist. A file that exists
/// but cannot be read must fail the load to preserve the running config.
fn readOptional(arena: Allocator, path: [:0]const u8, diagnostics: *std.ArrayList(Diagnostic)) LoadError!?[]const u8 {
    if (!osutil.pathExists(path)) return null;
    if (osutil.readFileAlloc(arena, path, max_file_bytes)) |source| return source;
    try diagnostics.append(arena, .{
        .severity = .@"error",
        .location = .{ .file = path },
        .message = "could not be read, or is larger than 1 MiB",
    });
    return error.InvalidConfig;
}

/// Resolves `require` against the config directory.
const ModuleDir = struct {
    dir: []const u8,
    arena: Allocator,
    paths: ?*std.ArrayList([:0]const u8),

    fn source(self: *ModuleDir) LuaSandbox.ModuleSource {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
        const self: *ModuleDir = @ptrCast(@alignCast(context));
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ self.dir, path }, 0) catch return null;
        if (self.paths) |paths| {
            const known = for (paths.items) |previous| {
                if (std.mem.eql(u8, previous, full)) break true;
            } else false;
            if (!known) {
                const owned = self.arena.dupeSentinel(u8, full, 0) catch return null;
                paths.append(self.arena, owned) catch return null;
            }
        }
        return osutil.readFileAlloc(gpa, full, max_file_bytes);
    }
};

const TestLoad = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    fn run(self: *TestLoad, sources: Sources) LoadError!config_layer.Merged {
        return loadSources(std.testing.allocator, self.arena.allocator(), sources, &self.diagnostics);
    }

    fn expectMessage(self: *const TestLoad, file: []const u8, line: u32, message: []const u8) !void {
        for (self.diagnostics.items) |d| {
            if (std.mem.eql(u8, d.location.file, file) and d.location.line == line and
                std.mem.indexOf(u8, d.message, message) != null) return;
        }
        for (self.diagnostics.items) |d| std.debug.print("{f}{s}\n", .{ fmtLocation(d.location), d.message });
        return error.TestUnexpectedResult;
    }
};

test "the settings UI overrides init.lua" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const merged = try t.run(.{
        .lua = "bobrwm.settings.set('gaps.inner', 8) bobrwm.settings.set('gaps.outer.top', 2)",
        .json = "{ \"settings\": { \"gaps\": { \"inner\": 12 } } }",
    });
    try std.testing.expectEqual(12, merged.config.gaps.inner);
    try std.testing.expectEqual(2, merged.config.gaps.outer.top);
    try std.testing.expectEqual(.settings_ui, merged.origins.gaps.inner.kind);
}

test "no files gives the defaults" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const merged = try t.run(.{});
    try std.testing.expectEqual(config.default_keybinds.len, merged.config.keybinds.len);
    try std.testing.expectEqual(0, t.diagnostics.items.len);
}

test "validation errors point at the line that set the value" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try std.testing.expectError(error.InvalidConfig, t.run(.{ .lua =
        \\bobrwm.settings.set("workspace_names", { "a", "b", "c" })
        \\bobrwm.keymap.set("alt+7", "focus_workspace", { workspace = 7 })
        \\bobrwm.settings.set("bsp_split_ratio", 0.95)
    }));
    try t.expectMessage("init.lua", 2, "workspace must be from 1 through 3, found 7");
    try t.expectMessage("init.lua", 3, "expected a finite value from 0.1 through 0.9");
}

test "a failing layer fails the load" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try std.testing.expectError(error.InvalidConfig, t.run(.{ .lua = "error('x')" }));
    try std.testing.expectError(error.InvalidConfig, t.run(.{ .json = "{" }));
    // Skipped calls are reported but do not fail the load.
    _ = try t.run(.{ .lua = "bobrwm.settings.set('nope', 1)" });
    try t.expectMessage("init.lua", 1, "unknown setting \"nope\"");
}

test "built-in binds past the workspace count are not errors" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    _ = try t.run(.{ .lua = "bobrwm.settings.set('workspace_names', { 'a', 'b' })" });
    try std.testing.expectEqual(0, t.diagnostics.items.len);
}

test "config.zon migrates to an equivalent init.lua" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    var zon_diagnostics: std.zon.parse.Diagnostics = undefined;
    const lua = try migrate(t.arena.allocator(),
        \\.{
        \\    .gaps = .{ .inner = 6 },
        \\    .swipe = .{ .enabled = true, .fingers = 3 },
        \\    .keybinds = .{
        \\        .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 },
        \\    },
        \\    .workspace_assignments = .{ .{ .app_id = "com.apple.Safari", .workspace = 2 } },
        \\}
    , &zon_diagnostics);
    try std.testing.expectEqualStrings(migration_header ++
        \\bobrwm.settings.set{
        \\  swipe = {
        \\    enabled = true,
        \\  },
        \\  gaps = {
        \\    inner = 6,
        \\  },
        \\}
        \\
        \\bobrwm.keymap.set("alt+1", "focus_workspace", { workspace = 1 })
        \\
        \\bobrwm.app_rules.add{ app = "com.apple.Safari", workspace = 2 }
        \\
    , lua);

    const merged = try t.run(.{ .lua = lua });
    try std.testing.expectEqual(6, merged.config.gaps.inner);
    try std.testing.expectEqual(2, merged.config.workspaceForApp("com.apple.Safari").?);
    try std.testing.expectEqual(0, t.diagnostics.items.len);
}

test "unparseable config.zon is not migrated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    try std.testing.expectError(error.InvalidZon, migrate(arena.allocator(), ".{ .gaps = ", &diagnostics));
    try std.testing.expectEqual(1, diagnostics.errors.len);
}

test "paths resolve beside an explicit init.lua" {
    const paths = try Paths.resolve(std.testing.allocator, "/tmp/bobrwm/custom.lua");
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/bobrwm", paths.dir);
    try std.testing.expectEqualStrings("/tmp/bobrwm/custom.lua", paths.lua);
    try std.testing.expectEqualStrings("/tmp/bobrwm/settings.json", paths.json);
}

test "load reads both files and requires modules beside init.lua" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/bobrwm-config-load-{d}", .{std.c.getpid()});
    try std.testing.expect(osutil.makePath(std.testing.allocator, dir));
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const arena = t.arena.allocator();
    const paths = try Paths.resolve(std.testing.allocator, try std.fmt.allocPrint(arena, "{s}/init.lua", .{dir}));
    defer paths.deinit(std.testing.allocator);
    const keys = try std.fmt.allocPrintSentinel(arena, "{s}/keys.lua", .{dir}, 0);
    defer for ([_][*:0]const u8{ paths.lua, paths.json, keys }) |path| osutil.deleteFile(path);

    try std.testing.expect(osutil.writeFile(paths.lua, "require('keys') bobrwm.settings.set('gaps.inner', 4)"));
    try std.testing.expect(osutil.writeFile(keys, "\nbobrwm.settings.set('gaps.outer.left', 'x')"));
    try std.testing.expect(osutil.writeFile(paths.json, "{ \"settings\": { \"gaps\": { \"inner\": 9 } } }"));

    var module_paths: std.ArrayList([:0]const u8) = .empty;
    const merged = try load(std.testing.allocator, arena, paths, &t.diagnostics, &module_paths);
    try std.testing.expectEqual(9, merged.config.gaps.inner);
    try t.expectMessage("keys.lua", 2, "gaps.outer.left: expected an integer, got string");
    try std.testing.expectEqual(1, module_paths.items.len);
    try std.testing.expectEqualStrings(keys, module_paths.items[0]);

    // Failed transitive requires must be observable too, so creating or
    // fixing the module can recover without touching init.lua again.
    module_paths.clearRetainingCapacity();
    try std.testing.expect(osutil.writeFile(keys, "require('ui.missing')"));
    try std.testing.expectError(error.InvalidConfig, load(std.testing.allocator, arena, paths, &t.diagnostics, &module_paths));
    try std.testing.expectEqual(2, module_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, module_paths.items[1], "/ui/missing.lua"));

    // An unreadable existing layer must not silently reset its values.
    const oversized = try arena.alloc(u8, max_file_bytes + 1);
    @memset(oversized, ' ');
    try std.testing.expect(osutil.writeFile(paths.json, oversized));
    try std.testing.expectError(error.InvalidConfig, load(std.testing.allocator, arena, paths, &t.diagnostics, null));
    try t.expectMessage(paths.json, 0, "could not be read, or is larger than 1 MiB");
}

test "the settings window writes only what it changed" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const arena = t.arena.allocator();
    const lua = "bobrwm.settings.set('gaps.inner', 8) bobrwm.app_rules.add{ app = 'com.apple.finder', float = true }";
    const current = (try t.run(.{ .lua = lua, .json = "{ \"settings\": { \"layout\": \"monocle\" } }" })).config;

    var next = current;
    next.gaps.outer.top = 30;
    next.dimmed_inactive.level = 0.4;
    next.app_rules = &.{ current.app_rules[0], .{ .app_id = "com.apple.Safari", .workspace = 2 } };
    const json = try editSettings(arena, "{ \"settings\": { \"layout\": \"monocle\" } }", &current, &next);

    // Unchanged values stay with the layer that set them.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inner\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"layout\": \"monocle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"level\": 0.4") != null);

    const merged = try t.run(.{ .lua = lua, .json = json });
    try std.testing.expectEqual(8, merged.config.gaps.inner);
    try std.testing.expectEqual(30, merged.config.gaps.outer.top);
    try std.testing.expectEqual(.monocle, merged.config.layout);
    try std.testing.expectEqual(2, merged.config.workspaceForApp("com.apple.Safari").?);
    try std.testing.expect(merged.config.shouldFloatApp("com.apple.finder"));
    try std.testing.expectEqual(.settings_ui, merged.origins.gaps.outer.top.kind);
    try std.testing.expectEqual(.lua, merged.origins.gaps.inner.kind);
    try std.testing.expectEqual(.lua, merged.rule_origins[0].kind);
}

test "removing and resetting app overrides keeps unrelated rules inherited" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const arena = t.arena.allocator();
    const lua =
        \\bobrwm.app_rules.add{ app = 'finder', workspace = 2, float = true }
        \\bobrwm.app_rules.add{ app = 'safari', workspace = 3 }
    ;
    const existing = "{\"rules\":[{\"app\":\"music\",\"float\":true}]}";
    const current = (try t.run(.{ .lua = lua, .json = existing })).config;
    var next = current;
    // Unpin but keep floating, as the two Apps tables edit independently.
    next.app_rules = &.{ .{ .app_id = "finder", .float = true }, current.app_rules[1], current.app_rules[2] };
    const unpinned_json = try editSettings(arena, existing, &current, &next);
    const unpinned = (try t.run(.{ .lua = lua, .json = unpinned_json })).config;
    try std.testing.expectEqual(null, unpinned.workspaceForApp("finder"));
    try std.testing.expect(unpinned.shouldFloatApp("finder"));

    next.app_rules = &.{ current.app_rules[1], current.app_rules[2] };
    const removed_json = try editSettings(arena, unpinned_json, &unpinned, &next);
    const updated_lua = lua ++ "\nbobrwm.app_rules.add{app='safari',workspace=4}";
    const removed = try t.run(.{ .lua = updated_lua, .json = removed_json });
    try std.testing.expectEqual(null, removed.config.workspaceForApp("finder"));
    try std.testing.expect(!removed.config.shouldFloatApp("finder"));
    try std.testing.expectEqual(4, removed.config.workspaceForApp("safari").?);
    try std.testing.expect(removed.config.shouldFloatApp("music"));
    try std.testing.expectEqual(.settings_ui, removed.rule_origins[0].kind);
    try std.testing.expectEqual(.lua, removed.rule_origins[1].kind);

    const reset_json = try resetOverride(arena, removed_json, "finder", true);
    const reset = try t.run(.{ .lua = updated_lua, .json = reset_json });
    try std.testing.expectEqual(2, reset.config.workspaceForApp("finder").?);
    try std.testing.expect(reset.config.shouldFloatApp("finder"));
    try std.testing.expect(reset.config.shouldFloatApp("music"));
    try std.testing.expectEqual(.lua, reset.rule_origins[0].kind);
    const reset_ui_only = try resetOverride(arena, reset_json, "music", true);
    const restored = try t.run(.{ .lua = updated_lua, .json = reset_ui_only });
    try std.testing.expectEqual(2, restored.config.app_rules.len);
}

test "editing and resetting mixed dotted settings preserves unrelated precedence" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const arena = t.arena.allocator();
    const lua = "bobrwm.settings.set{ gaps = { inner = 7, outer = { left = 11 } } }";
    const existing =
        \\{"settings":{"layout":"monocle",
        \\ "gaps":{"inner":19,"outer":{"left":23,"right":29},"outer.left":31},
        \\ "gaps.inner":37,"gaps.outer":{"left":41,"bottom":43},"gaps.outer.left":47}}
    ;
    const current = (try t.run(.{ .lua = lua, .json = existing })).config;
    try std.testing.expectEqual(47, current.gaps.outer.left);
    var next = current;
    next.gaps.inner = 17;
    next.gaps.outer.left = 13;
    const saved = try editSettings(arena, existing, &current, &next);
    const edited = try t.run(.{ .lua = lua, .json = saved });
    try std.testing.expectEqual(17, edited.config.gaps.inner);
    try std.testing.expectEqual(13, edited.config.gaps.outer.left);
    for ([_][]const u8{ existing, saved }) |json| {
        const reset = try resetOverride(arena, json, "gaps.outer.left", false);
        const merged = try t.run(.{ .lua = lua, .json = reset });
        try std.testing.expectEqual(11, merged.config.gaps.outer.left);
        try std.testing.expectEqual(.lua, merged.origins.gaps.outer.left.kind);
        try std.testing.expectEqual(29, merged.config.gaps.outer.right);
        try std.testing.expectEqual(43, merged.config.gaps.outer.bottom);
        try std.testing.expectEqual(.monocle, merged.config.layout);
    }
}

test "resetting a setting restores its source without touching siblings or keybinds" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    const arena = t.arena.allocator();
    const lua = "bobrwm.settings.set('gaps.inner', 7)";
    const existing =
        \\{"settings":{"layout":"monocle","gaps":{"inner":19,"outer":{"left":23}},"gaps.inner":31},
        \\ "keybinds":[{"unbind_all":true}],"rules":[{"app":"music","float":true}]}
    ;
    const json = try resetOverride(arena, existing, "gaps.inner", false);
    const merged = try t.run(.{ .lua = lua, .json = json });
    try std.testing.expectEqual(7, merged.config.gaps.inner);
    try std.testing.expectEqual(23, merged.config.gaps.outer.left);
    try std.testing.expectEqual(0, merged.config.keybinds.len);
    try std.testing.expect(merged.config.shouldFloatApp("music"));
    try std.testing.expectEqual(.lua, merged.origins.gaps.inner.kind);
    try std.testing.expectEqual(1, merged.origins.gaps.inner.location.line);
    try std.testing.expectEqual(.settings_ui, merged.origins.gaps.outer.left.kind);

    const defaults_json = try resetOverride(arena, json, "layout", false);
    const defaults = try t.run(.{ .lua = lua, .json = defaults_json });
    try std.testing.expectEqual(.bsp, defaults.config.layout);
    try std.testing.expectEqual(.default, defaults.origins.layout.kind);
    try std.testing.expectEqual(23, defaults.config.gaps.outer.left);
    const layout_only = try resetOverride(arena, existing, "layout", false);
    const preserved = try t.run(.{ .lua = lua, .json = layout_only });
    try std.testing.expectEqual(31, preserved.config.gaps.inner);
    try std.testing.expectError(error.InvalidJson, resetOverride(arena, "{", "layout", false));
}
