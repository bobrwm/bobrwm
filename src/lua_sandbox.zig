//! Sandboxed Lua runtime for user config, run on the main thread.
//!
//! - Libraries: base, table, string, math, utf8, coroutine. No io/os/package/debug.
//! - Removed: dofile, loadfile, load, collectgarbage, string.dump.
//! - setmetatable refuses __gc: finalizers run with hooks disabled.
//! - Text chunks only; Lua does not verify bytecode.
//! - Memory and per-exec instruction budgets.
//!
//! The instruction hook cannot interrupt pattern matching, which runs in C.

const Self = @This();

const std = @import("std");
const zlua = @import("zlua");

const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;

const log = std.log.scoped(.lua);

pub const Limits = struct {
    /// Max live bytes for the whole state.
    memory_bytes: usize = 16 * 1024 * 1024,
    /// Max VM instructions per `exec`. 10M is tens of milliseconds.
    // NOTE: Arbritrary limit that was decided from testing locally. Just the first value that wasn't in the way.
    instructions: u31 = 10_000_000,
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
lua: *Lua,

pub fn init(gpa: Allocator, limits: Limits) InitError!*Self {
    std.debug.assert(limits.instructions > 0);

    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        // Unlimited until the state exists: ziglua's Lua.init leaks when
        // lua_newstate fails (ce59a32).
        .budget = .{ .child = gpa, .limit = std.math.maxInt(usize) },
        .instructions = limits.instructions,
        .lua = undefined,
    };
    self.lua = try Lua.init(self.budget.allocator());
    errdefer self.lua.deinit();
    if (self.budget.used > limits.memory_bytes) return error.OutOfMemory;
    self.budget.limit = limits.memory_bytes;

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

    self.armInstructionBudget();
    defer self.lua.setHook(zlua.wrap(instructionHook), .{}, 0);

    self.lua.protectedCall(.{}) catch |err| return self.fail(diag, switch (err) {
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
        \\  "io", "os", "package", "debug", "require",
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
