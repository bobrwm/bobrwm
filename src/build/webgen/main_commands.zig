const std = @import("std");
const help_strings = @import("help_strings");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\---
        \\title: CLI reference
        \\description: Reference of all bobrwm client commands.
        \\editOnGithubLink: https://github.com/bobrwm/bobrwm/edit/main/src/command.zig
        \\---
        \\
        \\The `bobrwm` client includes these commands. Run
        \\`bobrwm <command> --help` for the same text in your terminal.
        \\
        \\
    );

    // Command docs are the literal `--help` text, laid out for a terminal
    // with two-space indented flag lists that markdown would reflow, so
    // they render verbatim in a code block.
    inline for (help_strings.Command.keys) |key| {
        try writer.writeAll("## `" ++ key ++ "`\n\n```\n");
        try writer.writeAll(@field(help_strings.Command, key));
        try writer.writeAll("\n```\n\n");
    }
    try stdout.end();
}
