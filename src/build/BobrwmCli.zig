//! The `bobrwm` client. It links no frameworks at all: it only parses
//! arguments, loads the config for `check-config` and friends, and talks to
//! the daemon over a unix socket. Loading AppKit and friends here would cost
//! every `bobrwm query ...` invocation for nothing.
const BobrwmCli = @This();

const std = @import("std");
const BobrwmBundle = @import("BobrwmBundle.zig");
const SharedDeps = @import("SharedDeps.zig");

exe: *std.Build.Step.Compile,

pub fn init(b: *std.Build, deps: *const SharedDeps) BobrwmCli {
    const module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = deps.config.target,
        .optimize = deps.config.optimize,
        .link_libc = true,
    });
    module.addImport("build_options", deps.build_options);
    module.addImport("help_strings", deps.help_strings.module);
    module.addImport("zlua", deps.zlua);

    return .{ .exe = b.addExecutable(.{
        .name = BobrwmBundle.cli_exe_name,
        .root_module = module,
    }) };
}
