//! Runs helpgen and exposes its output as the `help_strings` module. The
//! client prints these strings and webgen exports them.
//!
//! Adapted from ghostty-org/ghostty `src/build/HelpStrings.zig` @ b1c264163.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! MIT License, see LICENSES/ghostty.txt.
const HelpStrings = @This();

const std = @import("std");

module: *std.Build.Module,
/// Running the generator itself catches doc lookups broken by renamed
/// containers or fields, which the unit tests cannot see.
run: *std.Build.Step.Run,

pub fn init(b: *std.Build) HelpStrings {
    const exe = b.addExecutable(.{
        .name = "helpgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpgen.zig"),
            .target = b.graph.host,
            // config.zig links against libc through its osutil import.
            .link_libc = true,
        }),
    });
    const help_run = b.addRunArtifact(exe);

    // Generated Zig files have to end with .zig
    const wf = b.addWriteFiles();
    const output = wf.addCopyFile(help_run.captureStdOut(.{}), "help_strings.zig");
    return .{
        .module = b.createModule(.{ .root_source_file = output }),
        .run = help_run,
    };
}
