//! Config layers. `init.lua` and the settings UI's JSON each fill a `Layer`;
//! `merge` stacks them over the built-in defaults, later layers winning, into
//! the `Config` the rest of bobrwm reads plus where each value came from, so
//! the settings UI can show what overrides what.

const std = @import("std");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Config = config.Config;
const Keybind = config.Keybind;
const AppRule = config.AppRule;

/// Lowest to highest priority. `default` is the built-in base, not a layer.
pub const Kind = enum { default, lua, settings_ui };

/// Where in a layer's source a value was written. `line` is 0 when the source
/// has no meaningful lines, as with machine-written JSON.
pub const Location = struct {
    file: []const u8 = "",
    line: u32 = 0,
};

/// A problem in one layer's source. Errors skip the entry they describe;
/// warnings keep it.
pub const Diagnostic = struct {
    severity: enum { warning, @"error" },
    location: Location,
    message: []const u8,
};

pub const Origin = struct {
    kind: Kind = .default,
    location: Location = .{},
};

/// A value a layer wrote, and where it wrote it.
pub fn Set(comptime T: type) type {
    return struct {
        value: T,
        location: Location = .{},
    };
}

/// `T`'s settings with every leaf optional, so a layer only carries what it
/// sets. Nested structs recurse: `gaps.inner` can be set without `gaps.outer`.
pub fn Partial(comptime T: type) type {
    return Mirror(T, .partial);
}

/// `T`'s settings with an `Origin` per leaf.
pub fn Origins(comptime T: type) type {
    return Mirror(T, .origin);
}

// Merged as ordered operations rather than per value. `workspace_assignments`
// is the deprecated alias of `app_rules`, and `disable_default_keybinds` is
// `unbind_all` in a layer.
const list_fields = [_][]const u8{ "keybinds", "app_rules", "workspace_assignments", "disable_default_keybinds" };

pub fn isSetting(comptime T: type, comptime name: []const u8) bool {
    if (T != Config) return true;
    for (list_fields) |list_field| {
        if (std.mem.eql(u8, name, list_field)) return false;
    }
    return true;
}

fn Mirror(comptime T: type, comptime mode: enum { partial, origin }) type {
    const info = @typeInfo(T).@"struct";
    var names: [info.field_names.len][]const u8 = undefined;
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    var len: usize = 0;
    for (info.field_names, info.field_types) |name, Field| {
        if (!isSetting(T, name)) continue;
        names[len] = name;
        if (@typeInfo(Field) == .@"struct") {
            const Nested = Mirror(Field, mode);
            types[len] = Nested;
            attrs[len] = .{ .default_value_ptr = &@as(Nested, .{}) };
        } else switch (mode) {
            .partial => {
                types[len] = ?Set(Field);
                attrs[len] = .{ .default_value_ptr = &@as(?Set(Field), null) };
            },
            .origin => {
                types[len] = Origin;
                attrs[len] = .{ .default_value_ptr = &@as(Origin, .{}) };
            },
        }
        len += 1;
    }
    return @Struct(.auto, null, names[0..len], types[0..len], attrs[0..len]);
}

/// A key and modifiers. Two binds with the same trigger are the same binding.
pub const Trigger = struct {
    key: []const u8,
    mods: config.Mods = .{},

    fn matches(self: Trigger, keybind: Keybind) bool {
        return std.mem.eql(u8, self.key, keybind.key) and std.meta.eql(self.mods, keybind.mods);
    }
};

pub const KeybindOp = union(enum) {
    bind: Keybind,
    unbind: Trigger,
    /// Drops every binding from the defaults and lower layers.
    unbind_all,
};

/// One source's contribution. Keybind and rule operations keep their order,
/// so a file that binds and then unbinds a key ends with it unbound.
pub const Layer = struct {
    kind: Kind,
    settings: Partial(Config) = .{},
    keybinds: std.ArrayList(Set(KeybindOp)) = .empty,
    /// A rule replaces any earlier rule for the same app.
    rules: std.ArrayList(Set(AppRule)) = .empty,

    pub fn deinit(self: *Layer, gpa: Allocator) void {
        self.keybinds.deinit(gpa);
        self.rules.deinit(gpa);
    }
};

pub const Merged = struct {
    config: Config,
    origins: Origins(Config),
    /// Parallel to `config.keybinds`.
    keybind_origins: []const Origin,
    /// Parallel to `config.app_rules`.
    rule_origins: []const Origin,
};

/// Stacks `layers` in order over the defaults. The result borrows strings
/// from the layers and allocates its lists from `arena`.
pub fn merge(arena: Allocator, layers: []const *const Layer) Allocator.Error!Merged {
    var merged: Merged = .{
        .config = .{},
        .origins = .{},
        .keybind_origins = &.{},
        .rule_origins = &.{},
    };

    var keybinds: Entries(Keybind) = .empty;
    for (config.default_keybinds) |keybind| {
        try keybinds.append(arena, .{ .value = keybind, .origin = .{} });
    }
    var rules: Entries(AppRule) = .empty;

    for (layers, 0..) |layer, layer_index| {
        std.debug.assert(layer.kind != .default);
        mergeSettings(Config, &merged.config, &merged.origins, layer.settings, layer.kind);
        for (layer.keybinds.items) |op| {
            const origin: Origin = .{ .kind = layer.kind, .location = op.location };
            try applyKeybindOp(arena, &keybinds, op.value, origin, layer_index + 1);
        }
        for (layer.rules.items) |rule| {
            const origin: Origin = .{ .kind = layer.kind, .location = rule.location };
            try upsert(AppRule, arena, &rules, rule.value, origin, 0, sameApp);
        }
    }

    // Triggers are already unique. Put higher layers first so Config's
    // action-based menu lookup prefers them without changing live shortcuts.
    // Stable sorting preserves each layer's choice among equivalent actions.
    std.mem.sort(Entry(Keybind), keybinds.list.items, {}, struct {
        fn lessThan(_: void, a: Entry(Keybind), b: Entry(Keybind)) bool {
            return a.priority > b.priority;
        }
    }.lessThan);

    // The list already holds the surviving defaults; don't let
    // `buildKeybinds` add them a second time.
    merged.config.disable_default_keybinds = true;
    merged.config.keybinds, merged.keybind_origins = try keybinds.split(arena);
    merged.config.app_rules, merged.rule_origins = try rules.split(arena);
    merged.config.workspace_assignments = &.{};
    return merged;
}

fn mergeSettings(comptime T: type, target: *T, origins: *Origins(T), partial: Partial(T), kind: Kind) void {
    inline for (@typeInfo(Partial(T)).@"struct".field_names) |name| {
        const value = @field(partial, name);
        if (@typeInfo(@TypeOf(value)) == .@"struct") {
            mergeSettings(@FieldType(T, name), &@field(target, name), &@field(origins, name), value, kind);
        } else if (value) |set| {
            @field(target, name) = set.value;
            @field(origins, name) = .{ .kind = kind, .location = set.location };
        }
    }
}

fn applyKeybindOp(arena: Allocator, keybinds: *Entries(Keybind), op: KeybindOp, origin: Origin, priority: usize) Allocator.Error!void {
    switch (op) {
        .bind => |keybind| try upsert(Keybind, arena, keybinds, keybind, origin, priority, sameTrigger),
        .unbind => |trigger| {
            var i: usize = 0;
            while (i < keybinds.list.items.len) {
                if (trigger.matches(keybinds.list.items[i].value)) {
                    _ = keybinds.list.orderedRemove(i);
                } else i += 1;
            }
        },
        .unbind_all => keybinds.list.clearRetainingCapacity(),
    }
}

fn sameTrigger(a: Keybind, b: Keybind) bool {
    const trigger: Trigger = .{ .key = a.key, .mods = a.mods };
    return trigger.matches(b);
}

fn sameApp(a: AppRule, b: AppRule) bool {
    return std.mem.eql(u8, a.app_id, b.app_id);
}

fn Entry(comptime T: type) type {
    return struct { value: T, origin: Origin, priority: usize = 0 };
}

fn Entries(comptime T: type) type {
    return struct {
        list: std.ArrayList(Entry(T)),

        const Self = @This();
        const empty: Self = .{ .list = .empty };

        fn append(self: *Self, arena: Allocator, entry: Entry(T)) Allocator.Error!void {
            try self.list.append(arena, entry);
        }

        /// Separates values and origins into the parallel slices `Merged` exposes.
        fn split(self: *const Self, arena: Allocator) Allocator.Error!struct { []const T, []const Origin } {
            const values = try arena.alloc(T, self.list.items.len);
            const origins = try arena.alloc(Origin, self.list.items.len);
            for (self.list.items, values, origins) |entry, *value, *origin| {
                value.* = entry.value;
                origin.* = entry.origin;
            }
            return .{ values, origins };
        }
    };
}

/// Replaces the entry `same` matches in place, keeping its position, or
/// appends a new one.
fn upsert(
    comptime T: type,
    arena: Allocator,
    entries: *Entries(T),
    value: T,
    origin: Origin,
    priority: usize,
    comptime same: fn (T, T) bool,
) Allocator.Error!void {
    for (entries.list.items) |*entry| {
        if (same(entry.value, value)) {
            entry.* = .{ .value = value, .origin = origin, .priority = priority };
            return;
        }
    }
    try entries.append(arena, .{ .value = value, .origin = origin, .priority = priority });
}

test "partial config mirrors settings and omits list fields" {
    const P = Partial(Config);
    try std.testing.expect(!@hasField(P, "keybinds"));
    try std.testing.expect(!@hasField(P, "app_rules"));
    try std.testing.expect(!@hasField(P, "disable_default_keybinds"));
    try std.testing.expectEqual(?Set(u16), @FieldType(@FieldType(P, "gaps"), "inner"));
    try std.testing.expectEqual(?Set(u16), @FieldType(@FieldType(@FieldType(P, "gaps"), "outer"), "left"));
    try std.testing.expectEqual(?Set([]const []const u8), @FieldType(P, "workspace_names"));
}

test "no layers gives the defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const merged = try merge(arena.allocator(), &.{});
    const defaults: Config = .{};
    try std.testing.expectEqual(defaults.gaps, merged.config.gaps);
    try std.testing.expectEqual(defaults.layout, merged.config.layout);
    try std.testing.expectEqual(config.default_keybinds.len, merged.config.keybinds.len);
    for (merged.keybind_origins) |origin| try std.testing.expectEqual(Kind.default, origin.kind);
    try std.testing.expectEqual(Kind.default, merged.origins.gaps.inner.kind);
}

test "later layers win per setting and record where" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var lua: Layer = .{ .kind = .lua };
    lua.settings.gaps.inner = .{ .value = 8, .location = .{ .file = "init.lua", .line = 3 } };
    lua.settings.gaps.outer.left = .{ .value = 4, .location = .{ .file = "init.lua", .line = 4 } };
    lua.settings.layout = .{ .value = .monocle };
    var ui: Layer = .{ .kind = .settings_ui };
    ui.settings.gaps.inner = .{ .value = 12 };

    const merged = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqual(12, merged.config.gaps.inner);
    try std.testing.expectEqual(Kind.settings_ui, merged.origins.gaps.inner.kind);
    try std.testing.expectEqual(4, merged.config.gaps.outer.left);
    try std.testing.expectEqual(Kind.lua, merged.origins.gaps.outer.left.kind);
    try std.testing.expectEqual(4, merged.origins.gaps.outer.left.location.line);
    try std.testing.expectEqual(.monocle, merged.config.layout);
    try std.testing.expectEqual(Kind.default, merged.origins.gaps.outer.right.kind);
}

test "keybind operations apply in order across layers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    const alt: config.Mods = .{ .alt = true };
    const default = config.default_keybinds[0];

    var lua: Layer = .{ .kind = .lua };
    defer lua.deinit(gpa);
    // Rebind a default's trigger, add a bind, then add and remove another.
    try lua.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = default.key, .mods = default.mods, .action = .reload_config } } });
    try lua.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "x", .mods = alt, .action = .toggle_split } }, .location = .{ .file = "init.lua", .line = 7 } });
    try lua.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "y", .mods = alt, .action = .toggle_split } } });
    try lua.keybinds.append(gpa, .{ .value = .{ .unbind = .{ .key = "y", .mods = alt } } });
    var ui: Layer = .{ .kind = .settings_ui };
    defer ui.deinit(gpa);
    try ui.keybinds.append(gpa, .{ .value = .{ .unbind = .{ .key = "x", .mods = alt } } });

    const lua_only = try merge(arena.allocator(), &.{&lua});
    try std.testing.expectEqual(config.default_keybinds.len + 1, lua_only.config.keybinds.len);
    try std.testing.expectEqual(.reload_config, lua_only.config.keybinds[0].action);
    try std.testing.expectEqual(Kind.lua, lua_only.keybind_origins[0].kind);
    try std.testing.expectEqualStrings("x", lua_only.config.findKeybind(.toggle_split, 0).?.key);
    for (lua_only.config.keybinds, lua_only.keybind_origins) |keybind, origin| {
        if (std.mem.eql(u8, keybind.key, "x")) try std.testing.expectEqual(7, origin.location.line);
    }
    try std.testing.expect(lua_only.config.disable_default_keybinds);

    // The settings UI can remove a binding init.lua created.
    const both = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqual(config.default_keybinds.len, both.config.keybinds.len);
}

test "menu shortcuts prefer the highest layer without removing other triggers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    var lua: Layer = .{ .kind = .lua };
    defer lua.deinit(gpa);
    var ui: Layer = .{ .kind = .settings_ui };
    defer ui.deinit(gpa);
    try lua.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "f", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 } } });
    try ui.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "w", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 } } });
    const both = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqualStrings("w", both.config.findKeybind(.focus_workspace, 1).?.key);
    try std.testing.expectEqual(config.default_keybinds.len + 2, both.config.keybinds.len);
    for (both.config.keybinds, both.keybind_origins) |keybind, origin| {
        if (std.mem.eql(u8, keybind.key, "w")) try std.testing.expectEqual(Kind.settings_ui, origin.kind);
        if (std.mem.eql(u8, keybind.key, "f")) try std.testing.expectEqual(Kind.lua, origin.kind);
    }

    try ui.keybinds.append(gpa, .{ .value = .{ .unbind = .{ .key = "w", .mods = .{ .alt = true } } } });
    const removed = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqualStrings("f", removed.config.findKeybind(.focus_workspace, 1).?.key);
    try std.testing.expectEqual(config.default_keybinds.len + 1, removed.config.keybinds.len);

    // A higher layer taking the preferred trigger for a different action
    // must not advertise that trigger for its former action.
    try ui.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "f", .mods = .{ .alt = true }, .action = .toggle_float } } });
    const reassigned = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqualStrings("1", reassigned.config.findKeybind(.focus_workspace, 1).?.key);
    try std.testing.expectEqualStrings("f", reassigned.config.findKeybind(.toggle_float, 0).?.key);
}

test "unbind_all clears defaults before later binds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    var lua: Layer = .{ .kind = .lua };
    defer lua.deinit(gpa);
    try lua.keybinds.append(gpa, .{ .value = .unbind_all });
    try lua.keybinds.append(gpa, .{ .value = .{ .bind = .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left } } });

    const merged = try merge(arena.allocator(), &.{&lua});
    try std.testing.expectEqual(1, merged.config.keybinds.len);
    try std.testing.expectEqual(.focus_left, merged.config.keybinds[0].action);
}

test "rules replace by app id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    var lua: Layer = .{ .kind = .lua };
    defer lua.deinit(gpa);
    try lua.rules.append(gpa, .{ .value = .{ .app_id = "com.apple.Safari", .workspace = 2 } });
    try lua.rules.append(gpa, .{ .value = .{ .app_id = "com.apple.finder", .float = true } });
    var ui: Layer = .{ .kind = .settings_ui };
    defer ui.deinit(gpa);
    try ui.rules.append(gpa, .{ .value = .{ .app_id = "com.apple.Safari", .workspace = 3 } });

    const merged = try merge(arena.allocator(), &.{ &lua, &ui });
    try std.testing.expectEqual(2, merged.config.app_rules.len);
    try std.testing.expectEqual(3, merged.config.app_rules[0].workspace.?);
    try std.testing.expectEqual(Kind.settings_ui, merged.rule_origins[0].kind);
    try std.testing.expect(merged.config.app_rules[1].float);
}
