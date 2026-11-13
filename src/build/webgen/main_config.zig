const std = @import("std");
const help_strings = @import("help_strings");
const markdown = @import("markdown.zig");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\---
        \\title: Config reference
        \\description: Reference of all bobrwm configuration options.
        \\editOnGithubLink: https://github.com/bobrwm/bobrwm/edit/main/src/config.zig
        \\---
        \\
        \\This is a reference of all bobrwm configuration options, set in
        \\`~/.config/bobrwm/init.lua` or the settings window. Nested keys are
        \\dotted, as in `bobrwm.settings.set("gaps.inner", 8)`. Keybinds and app rules
        \\are set with `bobrwm.keymap.set` and `bobrwm.app_rules.add`.
        \\
        \\
    );
    try markdown.writeEntries(writer, help_strings.Config);
    try stdout.end();
}
