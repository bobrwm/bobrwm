//! Renders the generated help strings as MDX pages for the website, one
//! generator per page, the way Ghostty emits its webdata.
const BobrwmWebdata = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

install_steps: []const *std.Build.Step,

pub fn init(b: *std.Build, deps: *const SharedDeps) !BobrwmWebdata {
    const pages = [_][]const u8{ "config", "actions", "commands" };
    const steps = try b.allocator.alloc(*std.Build.Step, pages.len);
    for (pages, steps) |page, *step| {
        const webgen = b.addExecutable(.{
            .name = b.fmt("webgen_{s}", .{page}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/build/webgen/main_{s}.zig", .{page})),
                .target = b.graph.host,
            }),
        });
        webgen.root_module.addImport("help_strings", deps.help_strings.module);
        const output = b.addRunArtifact(webgen).captureStdOut(.{});
        step.* = &b.addInstallFile(output, b.fmt("share/bobrwm/webdata/{s}.mdx", .{page})).step;
    }
    return .{ .install_steps = steps };
}
