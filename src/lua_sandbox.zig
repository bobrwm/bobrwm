//! Sandboxed Lua runtime for user config, run on the main thread.
//!
//! - Libraries: base, table, string, math, utf8, coroutine. No io/os/package/debug.
//! - Removed: dofile, loadfile, load, collectgarbage, string.dump.
//! - setmetatable refuses __gc: finalizers run with hooks disabled.
//! - Text chunks only; Lua does not verify bytecode.
//! - Memory and per-exec instruction budgets.
//! - `require` only reads from the embedder's `ModuleSource`.
//!
//! The instruction hook cannot interrupt pattern matching, which runs in C.

const Self = @This();

const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;

const log = std.log.scoped(.lua);

pub const Options = struct {
    /// Max live bytes for the whole state.
    memory_bytes: usize = 16 * 1024 * 1024,
    /// Max VM instructions per `exec`. 10M is tens of milliseconds.
    // NOTE: Arbritrary limit that was decided from testing locally. Just the first value that wasn't in the way.
    instructions: u31 = 10_000_000,
    /// Where `require` finds modules. Without one, `require` raises.
    modules: ?ModuleSource = null,
};

/// Reads modules for `require`. `readFn` gets a relative path such as
/// `keys.lua` or `ui/bar.lua` and returns its contents allocated with `gpa`,
/// or null if there is none. Module source is not counted against the memory
/// budget, so `readFn` should cap what it reads.
pub const ModuleSource = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8,
};

pub const InitError = error{ OutOfMemory, SandboxSetup };
pub const ExecError = error{ Syntax, Runtime, OutOfMemory };

/// Why `exec` failed. `message` is allocated from `allocator`, typically the
/// caller's config arena
pub const Diagnostic = struct {
    allocator: Allocator,
    message: []const u8 = "",
};

// Heap-allocated: Lua holds a pointer to `budget`.
gpa: Allocator,
budget: Budget,
instructions: u31,
modules: ?ModuleSource,
lua: *Lua,
/// Embedder state for Zig functions called from Lua; see `fromLua`.
context: ?*anyopaque = null,

pub fn init(gpa: Allocator, options: Options) InitError!*Self {
    std.debug.assert(options.instructions > 0);

    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        // Unlimited until the state exists: ziglua's Lua.init leaks when
        // lua_newstate fails (ce59a32).
        .budget = .{ .child = gpa, .limit = std.math.maxInt(usize) },
        .instructions = options.instructions,
        .modules = options.modules,
        .lua = undefined,
    };
    self.lua = try Lua.init(self.budget.allocator());
    errdefer self.lua.deinit();
    if (self.budget.used > options.memory_bytes) return error.OutOfMemory;
    self.budget.limit = options.memory_bytes;
    // Coroutines copy the main thread's extra space, so this reaches all.
    @memcpy(self.lua.getExtraSpace()[0..@sizeOf(*Self)], std.mem.asBytes(&self));

    // Library setup can raise; unprotected, that aborts the process.
    self.lua.pushFunction(zlua.wrap(openSandbox));
    self.lua.protectedCall(.{}) catch return error.SandboxSetup;
    return self;
}

pub fn deinit(self: *Self) void {
    self.lua.deinit();
    std.debug.assert(self.budget.used == 0);
    self.gpa.destroy(self);
}

/// Run `source` as a text chunk. On failure, `diag` gets the error message.
pub fn exec(self: *Self, chunk_name: [:0]const u8, source: []const u8, diag: ?*Diagnostic) ExecError!void {
    // Catches stack leaks that would accumulate across reloads.
    std.debug.assert(self.lua.getTop() == 0);

    self.lua.loadBuffer(source, chunk_name, .text) catch |err| return self.fail(diag, switch (err) {
        error.LuaSyntax => error.Syntax,
        error.OutOfMemory => error.OutOfMemory,
    });
    return self.protectedRun(0, 0, diag);
}

/// Runs `function` in protected mode, for embedder setup such as registering
/// bindings, which can raise on allocation failure.
pub fn callZig(self: *Self, comptime function: fn (*Lua) i32, diag: ?*Diagnostic) ExecError!void {
    std.debug.assert(self.lua.getTop() == 0);
    self.lua.pushFunction(zlua.wrap(function));
    return self.protectedRun(0, 0, diag);
}

/// The sandbox that owns `lua`, for Zig functions called from Lua.
pub fn fromLua(lua: *Lua) *Self {
    return std.mem.bytesToValue(*Self, lua.getExtraSpace()[0..@sizeOf(*Self)]);
}

/// Calls the function below its `nargs` arguments under a fresh instruction
/// budget, leaving `nresults` results. Every entry into Lua goes through here.
fn protectedRun(self: *Self, nargs: i32, nresults: i32, diag: ?*Diagnostic) ExecError!void {
    self.armInstructionBudget();
    defer self.lua.setHook(zlua.wrap(instructionHook), .{}, 0);

    self.lua.protectedCall(.{ .args = nargs, .results = nresults }) catch |err| return self.fail(diag, switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LuaRuntime, error.LuaMsgHandler => error.Runtime,
    });
}

fn armInstructionBudget(self: *Self) void {
    // lua_sethook resets the countdown.
    self.lua.setHook(zlua.wrap(instructionHook), .{ .count = true }, self.instructions);
}

/// Pops the error object, copying its message into `diag`.
fn fail(self: *Self, diag: ?*Diagnostic, err: ExecError) ExecError {
    defer self.lua.pop(1);
    const d = diag orelse return err;
    // toString converts numbers in place, which allocates and can raise
    // outside any pcall.
    d.message = if (self.lua.typeOf(-1) == .string)
        d.allocator.dupe(u8, self.lua.toString(-1) catch unreachable) catch ""
    else
        std.fmt.allocPrint(d.allocator, "(error object is a {s} value)", .{self.lua.typeNameIndex(-1)}) catch "";
    return err;
}

fn instructionHook(lua: *Lua, event: zlua.Event, _: *zlua.DebugInfo) void {
    std.debug.assert(event == .count);
    // Fire on every instruction from now on so pcall cannot swallow the error.
    lua.setHook(zlua.wrap(instructionHook), .{ .count = true }, 1);
    lua.raiseErrorStr("instruction limit exceeded", .{});
}

fn openSandbox(lua: *Lua) i32 {
    lua.openBase();
    lua.openTable();
    lua.openString();
    lua.openMath();
    lua.openUtf8();
    lua.openCoroutine();

    for ([_][:0]const u8{ "dofile", "loadfile", "load", "collectgarbage" }) |name| {
        lua.pushNil();
        lua.setGlobal(name);
    }
    // The app does not own stdout.
    lua.pushFunction(zlua.wrap(luaPrint));
    lua.setGlobal("print");

    _ = lua.getGlobal("setmetatable");
    lua.pushClosure(zlua.wrap(setMetatable), 1);
    lua.setGlobal("setmetatable");

    lua.pushFunction(zlua.wrap(luaRequire));
    lua.setGlobal("require");

    _ = lua.getGlobal("string");
    lua.pushNil();
    lua.setField(-2, "dump");
    lua.pop(1);
    return 0;
}

/// setmetatable that refuses `__gc`. Lua disables hooks inside finalizers
/// (lgc.c GCTM), so the instruction budget cannot stop one. Lua only checks
/// for `__gc`, raw, when the metatable is set, so adding it later is inert.
fn setMetatable(lua: *Lua) i32 {
    if (lua.typeOf(2) == .table) {
        _ = lua.pushStringZ("__gc");
        const gc_type = lua.getTableRaw(2);
        lua.pop(1);
        if (gc_type != .nil) lua.raiseErrorStr("__gc metamethods are not allowed", .{});
    }
    lua.setTop(2);
    lua.pushValue(Lua.upvalueIndex(1));
    lua.insert(1);
    lua.call(.{ .args = 2, .results = 1 });
    return 1;
}

const loaded_key = "bobrwm.sandbox.loaded";
const max_module_name = 128;

/// `require` limited to `modules`. Results are cached per sandbox; a private
/// sentinel marks in-progress loads without conflicting with module results.
fn luaRequire(lua: *Lua) i32 {
    const name = lua.checkString(1);
    const self = fromLua(lua);
    const modules = self.modules orelse lua.raiseErrorStr("require is not available", .{});

    _ = lua.getSubtable(zlua.registry_index, loaded_key);
    const loaded_table = lua.getTop();
    const cached = lua.getField(loaded_table, name);
    if (cached == .light_userdata and (lua.toUserdata(Self, -1) catch unreachable) == self)
        lua.raiseErrorStr("require cycle through '%s'", .{name.ptr});
    // As in Lua's require, false is a valid result but does not cache a load.
    if (lua.toBoolean(-1)) return 1;
    lua.pop(1);

    var buf: [max_module_name + ".lua".len + 2]u8 = undefined;
    const chunk_name = moduleChunkName(&buf, name) orelse lua.raiseErrorStr("invalid module name '%s'", .{name.ptr});
    lua.pushLightUserdata(self);
    lua.setField(loaded_table, name);

    // Free the source before anything that can raise: a raise skips Zig code.
    const source = modules.readFn(modules.context, self.gpa, chunk_name[1..]) orelse {
        forgetModule(lua, loaded_table, name);
        lua.raiseErrorStr("module '%s' not found", .{name.ptr});
    };
    const loaded = lua.loadBuffer(source, chunk_name, .text);
    self.gpa.free(source);
    loaded catch {
        forgetModule(lua, loaded_table, name);
        lua.raiseError();
    };
    lua.protectedCall(.{ .results = 1 }) catch {
        forgetModule(lua, loaded_table, name);
        lua.raiseError();
    };

    if (lua.isNil(-1)) {
        lua.pop(1);
        lua.pushBoolean(true);
    }
    lua.pushValue(-1);
    lua.setField(loaded_table, name);
    return 1;
}

/// Clears the loading marker so a failed module can be required again.
fn forgetModule(lua: *Lua, loaded_table: i32, name: [:0]const u8) void {
    lua.pushNil();
    lua.setField(loaded_table, name);
}

/// Maps `a.b` to `@a/b.lua`. Segments are [A-Za-z0-9_-]+, so a module name
/// cannot reach outside the module root.
fn moduleChunkName(buf: []u8, name: []const u8) ?[:0]const u8 {
    if (name.len == 0 or name.len > max_module_name) return null;
    var segment_len: usize = 0;
    for (name, 0..) |char, i| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => segment_len += 1,
            '.' => {
                if (segment_len == 0) return null;
                segment_len = 0;
            },
            else => return null,
        }
        buf[i + 1] = if (char == '.') '/' else char;
    }
    if (segment_len == 0) return null;
    buf[0] = '@';
    const ext = ".lua";
    @memcpy(buf[name.len + 1 ..][0..ext.len], ext);
    buf[name.len + 1 + ext.len] = 0;
    return buf[0 .. name.len + 1 + ext.len :0];
}

fn luaPrint(lua: *Lua) i32 {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const n = lua.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        // toStringEx pushes; pop so many args cannot overflow the stack.
        const text = lua.toStringEx(i);
        if (i > 1) writer.writeByte('\t') catch {};
        writer.writeAll(text) catch {};
        lua.pop(1);
    }
    log.info("{s}", .{writer.buffered()});
    return 0;
}

/// Caps live bytes. Lua turns a refused allocation into a catchable error.
const Budget = struct {
    child: Allocator,
    limit: usize,
    used: usize = 0,

    fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn reserve(self: *Budget, old_len: usize, new_len: usize) bool {
        if (new_len <= old_len) return true;
        return new_len - old_len <= self.limit - self.used;
    }

    fn commit(self: *Budget, old_len: usize, new_len: usize) void {
        self.used = self.used - old_len + new_len;
        std.debug.assert(self.used <= self.limit);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.reserve(0, len)) return null;
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.commit(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.reserve(memory.len, new_len)) return false;
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.commit(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.reserve(memory.len, new_len)) return null;
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.commit(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.commit(memory.len, 0);
    }
};

fn expectExec(sandbox: *Self, source: []const u8) !void {
    var diag: Diagnostic = .{ .allocator = std.testing.allocator };
    defer std.testing.allocator.free(diag.message);
    sandbox.exec("=test", source, &diag) catch |err| {
        std.debug.print("lua error: {s}\n", .{diag.message});
        return err;
    };
}

fn expectExecError(sandbox: *Self, expected: ExecError, source: []const u8, message: []const u8) !void {
    var diag: Diagnostic = .{ .allocator = std.testing.allocator };
    defer std.testing.allocator.free(diag.message);
    try std.testing.expectError(expected, sandbox.exec("=test", source, &diag));
    if (std.mem.indexOf(u8, diag.message, message) == null) {
        std.debug.print("expected \"{s}\" in: {s}\n", .{ message, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "only the intended libraries are reachable" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    try expectExec(sandbox,
        \\for _, name in ipairs({ "string", "table", "math", "utf8", "coroutine" }) do
        \\  assert(type(_G[name]) == "table", name)
        \\end
        \\for _, name in ipairs({
        \\  "io", "os", "package", "debug",
        \\  "dofile", "loadfile", "load", "collectgarbage",
        \\}) do
        \\  assert(_G[name] == nil, name)
        \\end
        \\assert(string.dump == nil)
    );
}

test "print pops each converted argument" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    // Well past LUA_MINSTACK (20).
    try expectExec(sandbox,
        \\local args = {}
        \\for i = 1, 200 do args[i] = i end
        \\print(table.unpack(args))
    );
}

test "binary chunks are rejected" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    // Rejected by mode, not by the parser.
    try expectExecError(sandbox, error.Syntax, "\x1bLua\x55\x00", "binary");
}

test "instruction budget stops runaway loops and rearms per exec" {
    const sandbox = try Self.init(std.testing.allocator, .{ .instructions = 100_000 });
    defer sandbox.deinit();
    try expectExecError(sandbox, error.Runtime, "while true do end", "instruction limit");
    // The latched every-instruction hook must not carry over.
    try expectExec(sandbox, "local x = 0 for i = 1, 1000 do x = x + i end");
}

test "pcall cannot swallow the instruction budget" {
    const sandbox = try Self.init(std.testing.allocator, .{ .instructions = 100_000 });
    defer sandbox.deinit();
    try expectExecError(sandbox, error.Runtime,
        \\while true do
        \\  pcall(function() while true do end end)
        \\end
    , "instruction limit");
}

test "memory budget refuses fresh and growing allocations" {
    const sandbox = try Self.init(std.testing.allocator, .{
        .memory_bytes = 1024 * 1024,
        .instructions = std.math.maxInt(u31),
    });
    defer sandbox.deinit();
    // Fresh allocation, then realloc growth.
    try std.testing.expectError(error.OutOfMemory, sandbox.exec("=test", "local s = string.rep('x', 1 << 30)", null));
    try std.testing.expectError(error.OutOfMemory, sandbox.exec("=test",
        \\local t = {}
        \\for i = 1, 1e9 do t[i] = i end
    , null));
    // Still usable after hitting the limit.
    try expectExec(sandbox, "local t = { 1, 2, 3 }");
}

test "init under a tight budget fails without leaking" {
    // Raise the budget until init succeeds; every failure must be clean.
    var limit: usize = 0;
    while (limit <= 128 * 1024) : (limit += 1024) {
        const sandbox = Self.init(std.testing.allocator, .{ .memory_bytes = limit }) catch |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.SandboxSetup);
            continue;
        };
        sandbox.deinit();
        return;
    }
    return error.TestUnexpectedResult;
}

test "__gc metamethods are refused" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    // A looping finalizer would hang lua_close: hooks do not run inside __gc.
    try expectExecError(sandbox, error.Runtime,
        \\setmetatable({}, { __gc = function() while true do end end })
    , "__gc");
    try expectExec(sandbox,
        \\local mt = {}
        \\local t = setmetatable({}, mt)
        \\assert(getmetatable(t) == mt)
        \\mt.__gc = function() while true do end end
    );
}

test "non-string error objects are not converted" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    try expectExecError(sandbox, error.Runtime, "error(42)", "(error object is a number value)");
}

const TestModules = struct {
    files: []const struct { path: []const u8, source: []const u8 },

    fn source(self: *TestModules) ModuleSource {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
        const self: *TestModules = @ptrCast(@alignCast(context));
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return gpa.dupe(u8, file.source) catch null;
        }
        return null;
    }
};

test "require loads each module once from the module source" {
    var modules: TestModules = .{ .files = &.{
        .{ .path = "keys.lua", .source = "loads = (loads or 0) + 1 return { key = 'alt+h' }" },
        .{ .path = "ui/bar.lua", .source = "return 'bar'" },
        .{ .path = "empty.lua", .source = "" },
        .{ .path = "disabled.lua", .source = "false_loads = (false_loads or 0) + 1 return false" },
    } };
    const sandbox = try Self.init(std.testing.allocator, .{ .modules = modules.source() });
    defer sandbox.deinit();
    try expectExec(sandbox,
        \\assert(require("keys").key == "alt+h")
        \\assert(require("keys") == require("keys"))
        \\assert(loads == 1)
        \\assert(require("ui.bar") == "bar")
        \\assert(require("empty") == true)
        \\assert(require("disabled") == false)
        \\assert(require("disabled") == false)
        \\assert(false_loads == 2)
    );
}

test "require errors name the module file" {
    var modules: TestModules = .{ .files = &.{
        .{ .path = "bad.lua", .source = "\nerror('boom')" },
        .{ .path = "a.lua", .source = "require('b')" },
        .{ .path = "b.lua", .source = "require('a')" },
    } };
    const sandbox = try Self.init(std.testing.allocator, .{ .modules = modules.source() });
    defer sandbox.deinit();
    try expectExecError(sandbox, error.Runtime, "require('bad')", "bad.lua:2: boom");
    try expectExecError(sandbox, error.Runtime, "require('missing')", "module 'missing' not found");
    try expectExecError(sandbox, error.Runtime, "require('../secrets')", "invalid module name");
    try expectExecError(sandbox, error.Runtime, "require('a')", "require cycle through 'a'");
    // A failed module is not cached as loading.
    try expectExecError(sandbox, error.Runtime, "pcall(require, 'bad') require('bad')", "bad.lua:2: boom");
}

test "require is unavailable without a module source" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    try expectExecError(sandbox, error.Runtime, "require('keys')", "require is not available");
}

test "module names map to paths inside the root" {
    var buf: [max_module_name + 8]u8 = undefined;
    try std.testing.expectEqualStrings("@keys.lua", moduleChunkName(&buf, "keys").?);
    try std.testing.expectEqualStrings("@ui/bar-2.lua", moduleChunkName(&buf, "ui.bar-2").?);
    for ([_][]const u8{ "", ".", "..", "a..b", ".a", "a.", "a/b", "../a", "a b" }) |name| {
        try std.testing.expect(moduleChunkName(&buf, name) == null);
    }
}

test "Zig functions reach the embedder through fromLua" {
    const sandbox = try Self.init(std.testing.allocator, .{});
    defer sandbox.deinit();
    var calls: u32 = 0;
    sandbox.context = &calls;
    const count = struct {
        fn count(lua: *Lua) i32 {
            const counter: *u32 = @ptrCast(@alignCast(fromLua(lua).context.?));
            counter.* += 1;
            return 0;
        }
    }.count;
    sandbox.lua.pushFunction(zlua.wrap(count));
    sandbox.lua.setGlobal("count");
    try expectExec(sandbox, "count() coroutine.wrap(count)()");
    try std.testing.expectEqual(2, calls);
}
