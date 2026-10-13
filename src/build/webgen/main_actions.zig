const std = @import("std");
const help_strings = @import("help_strings");
const markdown = @import("markdown.zig");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\---
        \\title: Keybind action reference
        \\description: Reference of all actions a bobrwm keybind can run.
        \\editOnGithubLink: https://github.com/bobrwm/bobrwm/edit/main/src/config.zig
        \\---
        \\
        \\These are the values of `.action` in a `.keybinds` entry. Actions
        \\that take a value read it from the entry's `.arg`.
        \\
        \\
    );
    try markdown.writeEntries(writer, help_strings.KeybindAction);
    try stdout.end();
}
