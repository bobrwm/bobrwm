//! Exports the generated `help_strings` as JSON for the website and other
//! tooling that cannot import Zig. Every key is listed in declaration order,
//! with `doc: null` for undocumented keys, so consumers can render the full
//! option set before all docs are written.
//!
//! Adapted from ghostty-org/ghostty `src/build/webgen/` @ b1c264163.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! MIT License, see LICENSES/ghostty.txt.

const std = @import("std");
const help_strings = @import("help_strings");

const Entry = struct {
    key: []const u8,
    doc: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const writer = &stdout.interface;

    const config = comptime entries(help_strings.Config);
    const keybind_actions = comptime entries(help_strings.KeybindAction);
    try std.json.Stringify.value(.{
        .config = &config,
        .keybind_actions = &keybind_actions,
    }, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
    try stdout.end();
}

fn entries(comptime Namespace: type) [Namespace.keys.len]Entry {
    var out: [Namespace.keys.len]Entry = undefined;
    for (Namespace.keys, &out) |key, *entry| {
        entry.* = .{
            .key = key,
            .doc = if (@hasDecl(Namespace, key)) @field(Namespace, key) else null,
        };
    }
    return out;
}
