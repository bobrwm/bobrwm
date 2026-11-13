//! Validates settings, keybinds, and rules into a `Layer`. The Lua and JSON
//! loaders both convert their input to `std.json.Value` and come here, so a
//! value means the same thing in either layer. A bad entry is skipped with a
//! diagnostic and the rest still applies.

const Self = @This();

const std = @import("std");
const config = @import("config.zig");
const config_layer = @import("config_layer.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Layer = config_layer.Layer;
const Location = config_layer.Location;
const Diagnostic = config_layer.Diagnostic;
const Partial = config_layer.Partial;

/// Owns everything added to `layer` and `diagnostics`.
arena: Allocator,
layer: *Layer,
diagnostics: *std.ArrayList(Diagnostic),

/// Sets the setting at a dotted `path`. An object value sets the keys
/// inside a nested group, so `set("gaps", .{ inner = 8 })` sets `gaps.inner`.
pub fn set(self: *Self, path: []const u8, value: Value, location: Location) Allocator.Error!void {
    try self.setIn(config.Config, &self.layer.settings, path, path, value, location);
}

/// Sets each key of `object` as a top-level setting.
pub fn setAll(self: *Self, object: std.json.ObjectMap, location: Location) Allocator.Error!void {
    var it = object.iterator();
    while (it.next()) |entry| try self.set(entry.key_ptr.*, entry.value_ptr.*, location);
}

pub fn bind(self: *Self, key: []const u8, action_name: []const u8, args: ?Value, location: Location) Allocator.Error!void {
    const trigger = try self.parseTrigger(key, location) orelse return;
    const action = std.meta.stringToEnum(config.Action, action_name) orelse
        return self.report(.@"error", location, "unknown action \"{s}\"", .{action_name});
    const arg = try self.parseActionArg(action, args, location) orelse return;
    try self.layer.keybinds.append(self.arena, .{
        .value = .{ .bind = .{ .key = trigger.key, .mods = trigger.mods, .action = action, .arg = arg } },
        .location = location,
    });
}

pub fn unbind(self: *Self, key: []const u8, location: Location) Allocator.Error!void {
    const trigger = try self.parseTrigger(key, location) orelse return;
    try self.layer.keybinds.append(self.arena, .{ .value = .{ .unbind = trigger }, .location = location });
}

pub fn unbindAll(self: *Self, location: Location) Allocator.Error!void {
    try self.layer.keybinds.append(self.arena, .{ .value = .unbind_all, .location = location });
}

/// `{ app = "...", workspace = 2, float = true }`. `app` is required.
pub fn rule(self: *Self, value: Value, location: Location) Allocator.Error!void {
    if (value != .object) return self.report(.@"error", location, "rule: expected a table, got {s}", .{typeName(value)});
    var app_rule: config.AppRule = .{ .app_id = "" };
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "app")) {
            if (field != .string) return self.report(.@"error", location, "rule: app: expected a string, got {s}", .{typeName(field)});
            app_rule.app_id = field.string;
        } else if (std.mem.eql(u8, name, "workspace")) {
            app_rule.workspace = try self.parseWorkspace("rule", field, location) orelse return;
        } else if (std.mem.eql(u8, name, "float")) {
            if (field != .bool) return self.report(.@"error", location, "rule: float: expected a boolean, got {s}", .{typeName(field)});
            app_rule.float = field.bool;
        } else {
            try self.report(.warning, location, "rule: unknown field \"{s}\"", .{name});
        }
    }
    if (app_rule.app_id.len == 0) return self.report(.@"error", location, "rule: app is required", .{});
    try self.layer.rules.append(self.arena, .{ .value = app_rule, .location = location });
}

fn setIn(
    self: *Self,
    comptime T: type,
    partial: *Partial(T),
    path: []const u8,
    rest: []const u8,
    value: Value,
    location: Location,
) Allocator.Error!void {
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const name = if (dot) |i| rest[0..i] else rest;
    inline for (@typeInfo(Partial(T)).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) {
            const Field = @FieldType(T, field_name);
            const target = &@field(partial, field_name);
            if (@typeInfo(Field) == .@"struct") {
                if (dot) |i| return self.setIn(Field, target, path, rest[i + 1 ..], value, location);
                if (value != .object) return self.report(.@"error", location, "{s}: expected a table, got {s}", .{ path, typeName(value) });
                var it = value.object.iterator();
                while (it.next()) |entry| {
                    const child = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
                    try self.setIn(Field, target, child, entry.key_ptr.*, entry.value_ptr.*, location);
                }
                return;
            }
            if (dot != null) return self.report(.@"error", location, "unknown setting \"{s}\"", .{path});
            const converted = try self.convert(Field, path, value, location) orelse return;
            target.* = .{ .value = converted, .location = location };
            return;
        }
    }
    return self.report(.@"error", location, "unknown setting \"{s}\"", .{path});
}

fn convert(self: *Self, comptime T: type, path: []const u8, value: Value, location: Location) Allocator.Error!?T {
    switch (@typeInfo(T)) {
        .bool => if (value == .bool) return value.bool,
        .@"enum" => if (value == .string) {
            if (std.meta.stringToEnum(T, value.string)) |tag| return tag;
            try self.report(.@"error", location, "{s}: \"{s}\" is not one of {s}", .{ path, value.string, comptime enumNames(T) });
            return null;
        },
        .int => if (value == .integer) {
            if (std.math.cast(T, value.integer)) |int| return int;
            try self.report(.@"error", location, "{s}: {d} is out of range", .{ path, value.integer });
            return null;
        },
        .float => switch (value) {
            .integer => |int| return @floatFromInt(int),
            .float => |float| return @floatCast(float),
            else => {},
        },
        .pointer => {
            comptime std.debug.assert(T == []const []const u8);
            // Lua cannot tell an empty list from an empty table.
            if (value == .object and value.object.count() == 0) return &.{};
            if (value == .array) {
                const strings = try self.arena.alloc([]const u8, value.array.items.len);
                for (value.array.items, strings) |item, *string| {
                    if (item != .string) {
                        try self.report(.@"error", location, "{s}: expected a list of strings, found {s}", .{ path, typeName(item) });
                        return null;
                    }
                    string.* = item.string;
                }
                return strings;
            }
        },
        else => @compileError("unsupported setting type " ++ @typeName(T)),
    }
    try self.report(.@"error", location, "{s}: expected {s}, got {s}", .{ path, comptime expectedName(T), typeName(value) });
    return null;
}

/// `"alt+shift+h"`: modifiers, then the key, joined by `+`.
fn parseTrigger(self: *Self, spec: []const u8, location: Location) Allocator.Error!?config_layer.Trigger {
    var trigger: config_layer.Trigger = .{ .key = "" };
    var parts = std.mem.splitScalar(u8, spec, '+');
    while (parts.next()) |part| {
        if (parts.peek() == null) {
            trigger.key = part;
        } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "opt")) {
            trigger.mods.alt = true;
        } else if (std.mem.eql(u8, part, "shift")) {
            trigger.mods.shift = true;
        } else if (std.mem.eql(u8, part, "cmd")) {
            trigger.mods.cmd = true;
        } else if (std.mem.eql(u8, part, "ctrl")) {
            trigger.mods.ctrl = true;
        } else {
            try self.report(.@"error", location, "\"{s}\": unknown modifier \"{s}\"", .{ spec, part });
            return null;
        }
    }
    if (config.keyNameToCode(trigger.key) == null) {
        try self.report(.@"error", location, "\"{s}\": unknown key \"{s}\"", .{ spec, trigger.key });
        return null;
    }
    return trigger;
}

/// Keybinds store one `u8` argument; actions name it in `args`.
fn parseActionArg(self: *Self, action: config.Action, args: ?Value, location: Location) Allocator.Error!?u8 {
    const name: ?[]const u8 = switch (action) {
        .focus_workspace, .move_to_workspace => "workspace",
        .move_workspace_to_display => "display",
        else => null,
    };
    const object: ?std.json.ObjectMap = if (args) |value| switch (value) {
        .object => |object| object,
        .null => null,
        else => {
            try self.report(.@"error", location, "{t}: expected a table of arguments, got {s}", .{ action, typeName(value) });
            return null;
        },
    } else null;

    if (object) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            if (name == null or !std.mem.eql(u8, entry.key_ptr.*, name.?)) {
                try self.report(.warning, location, "{t}: no argument named \"{s}\"", .{ action, entry.key_ptr.* });
            }
        }
    }
    const arg_name = name orelse return 0;
    const arg = (if (object) |map| map.get(arg_name) else null) orelse {
        try self.report(.@"error", location, "{t}: missing argument \"{s}\"", .{ action, arg_name });
        return null;
    };
    return switch (action) {
        .move_workspace_to_display => self.parseDisplay(arg, location),
        else => self.parseWorkspace(@tagName(action), arg, location),
    };
}

fn parseWorkspace(self: *Self, context: []const u8, value: Value, location: Location) Allocator.Error!?u8 {
    if (value == .integer and value.integer >= 1 and value.integer <= workspace.max_workspaces) {
        return @intCast(value.integer);
    }
    try self.report(.@"error", location, "{s}: workspace must be an integer from 1 to {d}", .{ context, workspace.max_workspaces });
    return null;
}

fn parseDisplay(self: *Self, value: Value, location: Location) Allocator.Error!?u8 {
    switch (value) {
        .integer => |int| if (int >= 1 and int <= workspace.max_displays) return @intCast(int),
        .string => |string| {
            if (std.mem.eql(u8, string, "next")) return config.next_display_arg;
            if (std.mem.eql(u8, string, "previous")) return config.previous_display_arg;
        },
        else => {},
    }
    try self.report(.@"error", location, "move_workspace_to_display: display must be 1 to {d}, \"next\", or \"previous\"", .{workspace.max_displays});
    return null;
}

fn report(self: *Self, severity: anytype, location: Location, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    try self.diagnostics.append(self.arena, .{
        .severity = severity,
        .location = location,
        .message = try std.fmt.allocPrint(self.arena, fmt, args),
    });
}

fn typeName(value: Value) []const u8 {
    return switch (value) {
        .null => "nil",
        .bool => "boolean",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "list",
        .object => "table",
    };
}

fn expectedName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "a boolean",
        .int => "an integer",
        .float => "a number",
        .pointer => "a list of strings",
        .@"enum" => "one of " ++ enumNames(T),
        else => unreachable,
    };
}

fn enumNames(comptime T: type) []const u8 {
    var names: []const u8 = "";
    for (@typeInfo(T).@"enum".field_names, 0..) |name, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ "\"" ++ name ++ "\"";
    }
    return names;
}

const TestApplier = struct {
    arena: std.heap.ArenaAllocator,
    layer: Layer = .{ .kind = .lua },
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    fn init() TestApplier {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *TestApplier) void {
        self.arena.deinit();
    }

    fn applier(self: *TestApplier) Self {
        return .{ .arena = self.arena.allocator(), .layer = &self.layer, .diagnostics = &self.diagnostics };
    }

    fn parse(self: *TestApplier, json: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.arena.allocator(), json, .{});
    }

    fn expectMessage(self: *const TestApplier, message: []const u8) !void {
        for (self.diagnostics.items) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, message) != null) return;
        }
        std.debug.print("no diagnostic containing \"{s}\"\n", .{message});
        return error.TestUnexpectedResult;
    }
};

test "settings by path and by table" {
    var t: TestApplier = .init();
    defer t.deinit();
    var a = t.applier();
    const at: Location = .{ .file = "init.lua", .line = 2 };
    try a.set("gaps.inner", .{ .integer = 8 }, at);
    try a.set("layout", .{ .string = "monocle" }, at);
    try a.setAll((try t.parse(
        \\{ "dimmed_inactive": { "enabled": true, "level": 0.3 }, "workspace_names": ["a", "b"], "bsp_split_ratio": 1 }
    )).object, at);

    const s = t.layer.settings;
    try std.testing.expectEqual(8, s.gaps.inner.?.value);
    try std.testing.expectEqual(2, s.gaps.inner.?.location.line);
    try std.testing.expectEqual(.monocle, s.layout.?.value);
    try std.testing.expect(s.dimmed_inactive.enabled.?.value);
    try std.testing.expectApproxEqAbs(0.3, s.dimmed_inactive.level.?.value, 1e-6);
    try std.testing.expectEqualStrings("b", s.workspace_names.?.value[1]);
    try std.testing.expectEqual(1.0, s.bsp_split_ratio.?.value);
    try std.testing.expectEqual(0, t.diagnostics.items.len);
}

test "bad settings are skipped with a diagnostic" {
    var t: TestApplier = .init();
    defer t.deinit();
    var a = t.applier();
    try a.set("gaps.innr", .{ .integer = 8 }, .{});
    try a.set("gaps.inner.x", .{ .integer = 8 }, .{});
    try a.set("gaps.inner", .{ .integer = 70000 }, .{});
    try a.set("layout", .{ .string = "grid" }, .{});
    try a.set("focus_follows_mouse", .{ .string = "yes" }, .{});
    try a.set("keybinds", .{ .array = .init(std.testing.allocator) }, .{});
    try std.testing.expectEqual(null, t.layer.settings.gaps.inner);
    try t.expectMessage("unknown setting \"gaps.innr\"");
    try t.expectMessage("unknown setting \"gaps.inner.x\"");
    try t.expectMessage("gaps.inner: 70000 is out of range");
    try t.expectMessage("layout: \"grid\" is not one of \"bsp\", \"monocle\"");
    try t.expectMessage("focus_follows_mouse: expected a boolean, got string");
    // List-valued fields are bobrwm.keymap.set/rule territory, not settings.
    try t.expectMessage("unknown setting \"keybinds\"");
}

test "binds parse triggers and named arguments" {
    var t: TestApplier = .init();
    defer t.deinit();
    var a = t.applier();
    try a.bind("alt+shift+h", "swap_left", null, .{});
    try a.bind("alt+1", "focus_workspace", try t.parse("{\"workspace\": 1}"), .{});
    try a.bind("ctrl+alt+right", "move_workspace_to_display", try t.parse("{\"display\": \"next\"}"), .{});
    try a.unbind("cmd+q", .{});
    try a.unbindAll(.{});
    try std.testing.expectEqual(0, t.diagnostics.items.len);

    const ops = t.layer.keybinds.items;
    try std.testing.expectEqual(5, ops.len);
    try std.testing.expectEqualStrings("h", ops[0].value.bind.key);
    try std.testing.expect(ops[0].value.bind.mods.alt and ops[0].value.bind.mods.shift);
    try std.testing.expectEqual(1, ops[1].value.bind.arg);
    try std.testing.expectEqual(config.next_display_arg, ops[2].value.bind.arg);
    try std.testing.expect(ops[3].value.unbind.mods.cmd);
    try std.testing.expectEqual(.unbind_all, std.meta.activeTag(ops[4].value));
}

test "bad binds are reported" {
    var t: TestApplier = .init();
    defer t.deinit();
    var a = t.applier();
    try a.bind("hyper+h", "focus_left", null, .{});
    try a.bind("alt+f13", "focus_left", null, .{});
    try a.bind("alt+h", "focus_lfet", null, .{});
    try a.bind("alt+1", "focus_workspace", null, .{});
    try a.bind("alt+1", "focus_workspace", try t.parse("{\"workspace\": 11}"), .{});
    try a.bind("alt+d", "move_workspace_to_display", try t.parse("{\"display\": \"up\"}"), .{});
    try std.testing.expectEqual(0, t.layer.keybinds.items.len);
    try t.expectMessage("unknown modifier \"hyper\"");
    try t.expectMessage("unknown key \"f13\"");
    try t.expectMessage("unknown action \"focus_lfet\"");
    try t.expectMessage("focus_workspace: missing argument \"workspace\"");
    try t.expectMessage("workspace must be an integer from 1 to 10");
    try t.expectMessage("display must be 1 to");

    // A stray argument is a warning; the bind still applies.
    try a.bind("alt+h", "focus_left", try t.parse("{\"workspace\": 1}"), .{});
    try std.testing.expectEqual(1, t.layer.keybinds.items.len);
    try t.expectMessage("focus_left: no argument named \"workspace\"");
}

test "rules" {
    var t: TestApplier = .init();
    defer t.deinit();
    var a = t.applier();
    try a.rule(try t.parse("{\"app\": \"com.apple.Safari\", \"workspace\": 2, \"float\": true}"), .{});
    try a.rule(try t.parse("{\"workspace\": 2}"), .{});
    try a.rule(try t.parse("{\"app\": \"x\", \"floating\": true}"), .{});
    try std.testing.expectEqual(2, t.layer.rules.items.len);
    try std.testing.expectEqual(2, t.layer.rules.items[0].value.workspace.?);
    try std.testing.expect(t.layer.rules.items[0].value.float);
    try t.expectMessage("rule: app is required");
    try t.expectMessage("rule: unknown field \"floating\"");
}
