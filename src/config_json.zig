//! Loads the settings UI's JSON layer. The app writes this file; people write
//! `init.lua`. Each entry mirrors a Lua call and is validated the same way:
//!
//!     {
//!       "settings": { "gaps": { "inner": 12 } },
//!       "keybinds": [
//!         { "key": "alt+1", "action": "focus_workspace", "args": { "workspace": 1 } },
//!         { "unbind": "alt+h" },
//!         { "unbind_all": true }
//!       ],
//!       "rules": [ { "app": "com.apple.Safari", "workspace": 2 } ]
//!     }

const std = @import("std");
const ConfigApply = @import("config_apply.zig");
const config_layer = @import("config_layer.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const LoadError = error{ OutOfMemory, InvalidJson };

/// Parses `source` and fills `layer`. Everything added to `layer` and
/// `diagnostics` is allocated from `arena`. Invalid JSON fails the whole
/// load; a bad entry is reported and skipped.
pub fn load(
    arena: Allocator,
    file_name: []const u8,
    source: []const u8,
    layer: *config_layer.Layer,
    diagnostics: *std.ArrayList(config_layer.Diagnostic),
) LoadError!void {
    std.debug.assert(layer.kind == .settings_ui);
    var applier: ConfigApply = .{ .arena = arena, .layer = layer, .diagnostics = diagnostics };
    const location: config_layer.Location = .{ .file = file_name };

    const root = std.json.parseFromSliceLeaky(Value, arena, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report(&applier, .@"error", location, "invalid JSON: {t}", .{err});
            return error.InvalidJson;
        },
    };
    if (root != .object) {
        try report(&applier, .@"error", location, "expected an object at the top level", .{});
        return error.InvalidJson;
    }

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "settings")) {
            if (value != .object) {
                try report(&applier, .@"error", location, "settings: expected an object", .{});
                continue;
            }
            try applier.setAll(value.object, location);
        } else if (std.mem.eql(u8, name, "keybinds")) {
            for (try list(&applier, name, value, location)) |op| try keybind(&applier, op, location);
        } else if (std.mem.eql(u8, name, "rules")) {
            for (try list(&applier, name, value, location)) |rule| try applier.rule(rule, location);
        } else {
            try report(&applier, .warning, location, "unknown section \"{s}\"", .{name});
        }
    }
}

fn keybind(applier: *ConfigApply, op: Value, location: config_layer.Location) Allocator.Error!void {
    if (op == .object) {
        const fields = op.object;
        if (fields.get("unbind_all")) |all| {
            if (all == .bool and all.bool) return applier.unbindAll(location);
        } else if (fields.get("unbind")) |key| {
            if (key == .string) return applier.unbind(key.string, location);
        } else if (fields.get("key")) |key| {
            const action = fields.get("action") orelse .null;
            if (key == .string and action == .string) return applier.bind(key.string, action.string, fields.get("args"), location);
        }
    }
    try report(applier, .@"error", location, "keybinds: expected {{\"key\", \"action\"}}, {{\"unbind\"}}, or {{\"unbind_all\": true}}", .{});
}

fn list(applier: *ConfigApply, name: []const u8, value: Value, location: config_layer.Location) Allocator.Error![]const Value {
    if (value == .array) return value.array.items;
    try report(applier, .@"error", location, "{s}: expected a list", .{name});
    return &.{};
}

fn report(
    applier: *ConfigApply,
    severity: anytype,
    location: config_layer.Location,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    try applier.diagnostics.append(applier.arena, .{
        .severity = severity,
        .location = location,
        .message = try std.fmt.allocPrint(applier.arena, fmt, args),
    });
}

test "settings UI layer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var layer: config_layer.Layer = .{ .kind = .settings_ui };
    var diagnostics: std.ArrayList(config_layer.Diagnostic) = .empty;
    try load(arena.allocator(), "settings.json",
        \\{
        \\  "settings": { "gaps": { "inner": 12 }, "layout": "monocle" },
        \\  "keybinds": [
        \\    { "key": "alt+1", "action": "focus_workspace", "args": { "workspace": 1 } },
        \\    { "unbind": "alt+h" },
        \\    { "unbind_all": true },
        \\    { "bind": "alt+x" }
        \\  ],
        \\  "rules": [ { "app": "com.apple.Safari", "workspace": 2 } ],
        \\  "theme": {}
        \\}
    , &layer, &diagnostics);

    try std.testing.expectEqual(12, layer.settings.gaps.inner.?.value);
    try std.testing.expectEqualStrings("settings.json", layer.settings.gaps.inner.?.location.file);
    try std.testing.expectEqual(3, layer.keybinds.items.len);
    try std.testing.expectEqual(1, layer.rules.items.len);
    try std.testing.expectEqual(2, diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "keybinds: expected") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items[1].message, "unknown section \"theme\"") != null);
}

test "invalid JSON fails the load" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var layer: config_layer.Layer = .{ .kind = .settings_ui };
    var diagnostics: std.ArrayList(config_layer.Diagnostic) = .empty;
    try std.testing.expectError(error.InvalidJson, load(arena.allocator(), "settings.json", "{ \"settings\": ", &layer, &diagnostics));
    try std.testing.expectError(error.InvalidJson, load(arena.allocator(), "settings.json", "[]", &layer, &diagnostics));
    try std.testing.expectEqual(2, diagnostics.items.len);
}
