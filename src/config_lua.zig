//! Loads `init.lua` into a config layer. The file runs once, top to bottom, in
//! the sandbox. Each `bobrwm.*` call is validated on its own: a bad call is
//! reported with its `file:line` and skipped, and the rest of the file still
//! loads. A Lua error, such as a syntax error, fails the whole load.

const std = @import("std");
const zlua = @import("zlua");
const LuaSandbox = @import("lua_sandbox.zig");
const ConfigApply = @import("config_apply.zig");
const config_layer = @import("config_layer.zig");

const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const Value = std.json.Value;
const Location = config_layer.Location;

pub const LoadError = LuaSandbox.ExecError || LuaSandbox.InitError;

/// Runs `source` as `file_name` and fills `layer`. Everything added to
/// `layer` and `diagnostics` is allocated from `arena`.
pub fn load(
    gpa: Allocator,
    arena: Allocator,
    file_name: []const u8,
    source: []const u8,
    modules: ?LuaSandbox.ModuleSource,
    layer: *config_layer.Layer,
    diagnostics: *std.ArrayList(config_layer.Diagnostic),
) LoadError!void {
    std.debug.assert(layer.kind == .lua);
    var applier: ConfigApply = .{ .arena = arena, .layer = layer, .diagnostics = diagnostics };
    const sandbox = try LuaSandbox.init(gpa, .{ .modules = modules });
    defer sandbox.deinit();
    sandbox.context = &applier;

    var diag: LuaSandbox.Diagnostic = .{ .allocator = arena };
    errdefer diagnostics.append(arena, .{
        .severity = .@"error",
        .location = .{ .file = file_name },
        .message = diag.message,
    }) catch {};
    try sandbox.callZig(registerApi, &diag);
    const chunk_name = try std.fmt.allocPrintSentinel(arena, "@{s}", .{file_name}, 0);
    try sandbox.exec(chunk_name, source, &diag);
}

/// `bobrwm.settings`, `bobrwm.keymap`, and `bobrwm.app_rules`, each a table
/// of functions named for what they do to that part of the config.
fn registerApi(lua: *Lua) i32 {
    lua.newTable();
    inline for (.{
        .{ "settings", .{.{ "set", settingsSet }} },
        .{ "keymap", .{ .{ "set", keymapSet }, .{ "del", keymapDel }, .{ "clear", keymapClear } } },
        .{ "app_rules", .{.{ "add", appRulesAdd }} },
    }) |namespace| {
        lua.newTable();
        inline for (namespace[1]) |entry| {
            lua.pushFunction(zlua.wrap(entry[1]));
            lua.setField(-2, entry[0]);
        }
        lua.setField(-2, namespace[0]);
    }
    lua.setGlobal("bobrwm");
    return 0;
}

/// `bobrwm.settings.set("gaps.inner", 8)` or `bobrwm.settings.set{ gaps = { inner = 8 } }`.
fn settingsSet(lua: *Lua) i32 {
    var call = Call.init(lua, "bobrwm.settings.set");
    if (lua.typeOf(1) == .table) {
        const settings = call.value(1) orelse return 0;
        if (settings != .object) {
            call.report("expected named settings, got a list", .{});
            return 0;
        }
        call.check(call.applier.setAll(settings.object, call.location));
    } else {
        const path = call.string(1) orelse return 0;
        const value = call.value(2) orelse return 0;
        call.check(call.applier.set(path, value, call.location));
    }
    return 0;
}

/// `bobrwm.keymap.set("alt+1", "focus_workspace", { workspace = 1 })`.
fn keymapSet(lua: *Lua) i32 {
    var call = Call.init(lua, "bobrwm.keymap.set");
    const key = call.string(1) orelse return 0;
    const action = call.string(2) orelse return 0;
    const args = if (lua.isNoneOrNil(3)) null else call.value(3) orelse return 0;
    call.check(call.applier.bind(key, action, args, call.location));
    return 0;
}

/// `bobrwm.keymap.del("alt+h")`.
fn keymapDel(lua: *Lua) i32 {
    var call = Call.init(lua, "bobrwm.keymap.del");
    const key = call.string(1) orelse return 0;
    call.check(call.applier.unbind(key, call.location));
    return 0;
}

/// `bobrwm.keymap.clear()` drops the defaults and every earlier binding.
fn keymapClear(lua: *Lua) i32 {
    var call = Call.init(lua, "bobrwm.keymap.clear");
    call.check(call.applier.unbindAll(call.location));
    return 0;
}

/// `bobrwm.app_rules.add{ app = "com.apple.finder", float = true }`.
fn appRulesAdd(lua: *Lua) i32 {
    var call = Call.init(lua, "bobrwm.app_rules.add");
    if (lua.typeOf(1) != .table) {
        call.report("expected a table, got {s}", .{lua.typeNameIndex(1)});
        return 0;
    }
    const value = call.value(1) orelse return 0;
    call.check(call.applier.rule(value, call.location));
    return 0;
}

/// One `bobrwm.*` call: its applier, where it was made, and argument
/// conversion that reports mistakes instead of raising.
const Call = struct {
    lua: *Lua,
    name: []const u8,
    applier: *ConfigApply,
    location: Location,

    fn init(lua: *Lua, name: []const u8) Call {
        const applier: *ConfigApply = @ptrCast(@alignCast(LuaSandbox.fromLua(lua).context.?));
        return .{ .lua = lua, .name = name, .applier = applier, .location = callerLocation(lua, applier.arena) };
    }

    fn string(self: *Call, index: i32) ?[]const u8 {
        if (self.lua.typeOf(index) != .string) {
            self.report("expected a string, got {s}", .{self.lua.typeNameIndex(index)});
            return null;
        }
        return self.applier.arena.dupe(u8, self.lua.toString(index) catch unreachable) catch self.outOfMemory();
    }

    fn value(self: *Call, index: i32) ?Value {
        return toValue(self.lua, self.applier.arena, self.lua.absIndex(index), 0) catch |err| switch (err) {
            error.OutOfMemory => self.outOfMemory(),
            error.Unsupported => {
                self.report("values must be booleans, numbers, strings, or tables of them", .{});
                return null;
            },
            error.TooDeep => {
                self.report("tables nest more than {d} deep", .{max_depth});
                return null;
            },
            error.MixedTable => {
                self.report("a table cannot mix list items and named fields", .{});
                return null;
            },
        };
    }

    fn report(self: *Call, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.applier.arena, "{s}: " ++ fmt, .{self.name} ++ args) catch self.outOfMemory();
        self.applier.diagnostics.append(self.applier.arena, .{
            .severity = .@"error",
            .location = self.location,
            .message = message,
        }) catch self.outOfMemory();
    }

    fn check(self: *Call, result: Allocator.Error!void) void {
        result catch self.outOfMemory();
    }

    fn outOfMemory(self: *Call) noreturn {
        self.lua.raiseErrorStr("not enough memory", .{});
    }
};

/// The Lua function that called the current `bobrwm.*` function.
fn callerLocation(lua: *Lua, arena: Allocator) Location {
    var info = lua.getStack(1) catch return .{};
    lua.getInfo(.{ .S = true, .l = true }, &info);
    return .{
        .file = arena.dupe(u8, std.mem.sliceTo(&info.short_src, 0)) catch "",
        .line = if (info.current_line) |line| @intCast(line) else 0,
    };
}

// Bounds recursion; a table that contains itself would otherwise never end.
const max_depth = 16;

/// Converts the Lua value at absolute `index`. A table whose keys are exactly
/// 1..n is a list; one with string keys is an object. Strings are copied into
/// `arena` because Lua may collect the originals once the call returns.
fn toValue(lua: *Lua, arena: Allocator, index: i32, depth: u8) error{ OutOfMemory, Unsupported, TooDeep, MixedTable }!Value {
    return switch (lua.typeOf(index)) {
        .nil, .none => .null,
        .boolean => .{ .bool = lua.toBoolean(index) },
        .number => if (lua.isInteger(index))
            .{ .integer = lua.toInteger(index) catch unreachable }
        else
            .{ .float = lua.toNumber(index) catch unreachable },
        .string => .{ .string = try arena.dupe(u8, lua.toString(index) catch unreachable) },
        .table => {
            if (depth == max_depth) return error.TooDeep;
            // Each level holds a key and a value; a C function is only
            // guaranteed LUA_MINSTACK (20) slots.
            lua.checkStack(2) catch return error.OutOfMemory;
            // Bound list allocation by actual entries, not an arbitrary Lua
            // index that could request terabytes outside the sandbox budget.
            var entries: usize = 0;
            lua.pushNil();
            while (lua.next(index)) {
                entries += 1;
                lua.pop(1);
            }
            var object: std.json.ObjectMap = .empty;
            var list: std.json.Array = .init(arena);
            lua.pushNil();
            while (lua.next(index)) {
                // Never call toString on a non-string key: converting it in
                // place would break the traversal.
                const item = try toValue(lua, arena, lua.getTop(), depth + 1);
                switch (lua.typeOf(-2)) {
                    .string => try object.put(arena, try arena.dupe(u8, lua.toString(-2) catch unreachable), item),
                    .number => {
                        if (!lua.isInteger(-2)) return error.Unsupported;
                        const position = lua.toInteger(-2) catch unreachable;
                        if (position < 1 or position > entries) return error.MixedTable;
                        const slot: usize = @intCast(position - 1);
                        if (slot >= list.items.len) try list.appendNTimes(.null, slot + 1 - list.items.len);
                        list.items[slot] = item;
                    },
                    else => return error.Unsupported,
                }
                lua.pop(1);
            }
            if (list.items.len > 0 and object.count() > 0) return error.MixedTable;
            for (list.items) |item| if (item == .null) return error.MixedTable;
            return if (list.items.len > 0) .{ .array = list } else .{ .object = object };
        },
        else => error.Unsupported,
    };
}

const TestLoad = struct {
    arena: std.heap.ArenaAllocator,
    layer: config_layer.Layer = .{ .kind = .lua },
    diagnostics: std.ArrayList(config_layer.Diagnostic) = .empty,

    fn run(self: *TestLoad, source: []const u8) LoadError!void {
        return load(std.testing.allocator, self.arena.allocator(), "init.lua", source, null, &self.layer, &self.diagnostics);
    }

    fn expectMessage(self: *const TestLoad, line: u32, message: []const u8) !void {
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.location.line == line and std.mem.indexOf(u8, diagnostic.message, message) != null) return;
        }
        for (self.diagnostics.items) |d| std.debug.print("{s}:{d}: {s}\n", .{ d.location.file, d.location.line, d.message });
        return error.TestUnexpectedResult;
    }
};

test "init.lua fills a layer with locations" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try t.run(
        \\bobrwm.settings.set("gaps.inner", 8)
        \\bobrwm.settings.set{ layout = "monocle", workspace_names = { "term", "web" } }
        \\for i = 1, 2 do
        \\  bobrwm.keymap.set("alt+" .. i, "focus_workspace", { workspace = i })
        \\end
        \\bobrwm.keymap.del("alt+h")
        \\bobrwm.app_rules.add{ app = "com.apple.finder", float = true }
    );
    try std.testing.expectEqual(0, t.diagnostics.items.len);
    const s = t.layer.settings;
    try std.testing.expectEqual(8, s.gaps.inner.?.value);
    try std.testing.expectEqualStrings("init.lua", s.gaps.inner.?.location.file);
    try std.testing.expectEqual(1, s.gaps.inner.?.location.line);
    try std.testing.expectEqual(.monocle, s.layout.?.value);
    try std.testing.expectEqualStrings("web", s.workspace_names.?.value[1]);
    try std.testing.expectEqual(3, t.layer.keybinds.items.len);
    try std.testing.expectEqual(2, t.layer.keybinds.items[1].value.bind.arg);
    try std.testing.expectEqual(4, t.layer.keybinds.items[1].location.line);
    try std.testing.expectEqualStrings("com.apple.finder", t.layer.rules.items[0].value.app_id);
}

test "a bad call is skipped and the file keeps loading" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try t.run(
        \\bobrwm.keymap.set({ "alt+h" }, "focus_left")
        \\bobrwm.settings.set("gaps.inner", function() end)
        \\bobrwm.settings.set("gaps.innr", 1)
        \\bobrwm.settings.set("gaps", { 1, x = 2 })
        \\bobrwm.app_rules.add("finder")
        \\bobrwm.keymap.set("alt+l", "focus_right")
        \\bobrwm.settings.set{ 1, 2 }
        \\bobrwm.settings.set("workspace_names", { [1099511627776] = "term" })
    );
    try t.expectMessage(1, "bobrwm.keymap.set: expected a string, got table");
    try t.expectMessage(2, "values must be booleans, numbers, strings, or tables");
    try t.expectMessage(3, "unknown setting \"gaps.innr\"");
    try t.expectMessage(4, "cannot mix list items and named fields");
    try t.expectMessage(5, "bobrwm.app_rules.add: expected a table, got string");
    try t.expectMessage(7, "expected named settings, got a list");
    try t.expectMessage(8, "cannot mix list items and named fields");
    try std.testing.expectEqual(1, t.layer.keybinds.items.len);
}

test "a Lua error fails the load with a diagnostic" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try std.testing.expectError(error.Syntax, t.run("bobrwm.settings.set(\"gaps.inner\", 8"));
    try std.testing.expect(std.mem.indexOf(u8, t.diagnostics.items[0].message, "init.lua:1:") != null);

    var u: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer u.arena.deinit();
    try std.testing.expectError(error.Runtime, u.run("\nerror('nope')"));
    try std.testing.expect(std.mem.indexOf(u8, u.diagnostics.items[0].message, "init.lua:2: nope") != null);
}

test "self-referencing tables are rejected" {
    var t: TestLoad = .{ .arena = .init(std.testing.allocator) };
    defer t.arena.deinit();
    try t.run("local t = {} t.t = t bobrwm.settings.set('gaps', t)");
    try t.expectMessage(1, "nest more than");
}
