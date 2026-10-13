//! Converts a doc comment into the markdown the website renders. Doc
//! comments use indented code blocks and "Note:"/"Warning:" paragraphs
//! because they also print in a terminal; the website wants fenced code
//! blocks and `<Note>`/`<Warning>` callouts instead.
//!
//! Adapted from ghostty-org/ghostty `src/build/webgen/main_config.zig` @ b1c264163.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! MIT License, see LICENSES/ghostty.txt.

const std = @import("std");

const Block = enum {
    /// Plaintext, do nothing.
    text,

    /// Code block, wrapped in triple backticks.
    code,

    /// Callouts, detected by paragraphs starting with "Note:" or
    /// "Warning:" (case-insensitive).
    callout_note,
    callout_warning,
};

/// Write one `## key` section per entry of a `help_strings` namespace, in
/// declaration order.
pub fn writeEntries(writer: *std.Io.Writer, comptime Namespace: type) !void {
    inline for (Namespace.keys) |key| {
        try writer.writeAll("## `" ++ key ++ "`\n\n");
        try writeDoc(writer, @field(Namespace, key));
        try writer.writeAll("\n");
    }
}

pub fn writeDoc(writer: *std.Io.Writer, doc: []const u8) !void {
    var block: ?Block = null;
    var iter = std.mem.splitScalar(u8, doc, '\n');
    while (iter.next()) |line| {
        // Empty line resets our block
        if (line.len == 0) {
            try endBlock(writer, block);
            block = null;
            try writer.writeAll("\n");
            continue;
        }

        // If we don't have a block figure out our type.
        const first = block == null;
        if (block == null) {
            if (std.mem.startsWith(u8, line, "    ")) {
                block = .code;
                try writer.writeAll("```\n");
            } else if (std.ascii.startsWithIgnoreCase(line, "note:")) {
                block = .callout_note;
                // The blank line lets markdown inside the callout render.
                try writer.writeAll("<Note>\n\n");
            } else if (std.ascii.startsWithIgnoreCase(line, "warning:")) {
                block = .callout_warning;
                try writer.writeAll("<Warning>\n\n");
            } else {
                block = .text;
            }
        }

        try writer.writeAll(switch (block.?) {
            .text => line,
            .callout_note => if (first) std.mem.trimStart(u8, line["note:".len..], " ") else line,
            .callout_warning => if (first) std.mem.trimStart(u8, line["warning:".len..], " ") else line,
            .code => if (std.mem.startsWith(u8, line, "    ")) line[4..] else line,
        });
        try writer.writeAll("\n");
    }
    try endBlock(writer, block);
}

fn endBlock(writer: *std.Io.Writer, block: ?Block) !void {
    if (block) |v| switch (v) {
        .text => {},
        .code => try writer.writeAll("```\n"),
        .callout_note => try writer.writeAll("\n</Note>\n"),
        .callout_warning => try writer.writeAll("\n</Warning>\n"),
    };
}
