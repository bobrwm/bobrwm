//! Renders the UI to PNGs without the core, so it can be iterated on without
//! restarting the running window manager.
const BobrwmUiPreview = @This();

const std = @import("std");
const BobrwmApp = @import("BobrwmApp.zig");
const Config = @import("Config.zig");

run: *std.Build.Step.Run,

pub fn init(b: *std.Build, config: *const Config) BobrwmUiPreview {
    const swiftc = BobrwmApp.addSwiftc(b, config);
    const exe = swiftc.addPrefixedOutputFileArg("-o", "bobrwm-ui-preview");
    swiftc.addPrefixedDirectoryArg("-I", b.path("macos/include"));
    swiftc.addFileInput(b.path("macos/include/bobrwm_ui.h"));
    swiftc.addFileInput(b.path("macos/include/module.modulemap"));
    swiftc.addFileArg(b.path("macos/src/StatusMenu.swift"));
    swiftc.addFileArg(b.path("macos/src/Settings.swift"));
    swiftc.addFileArg(b.path("macos/preview/main.swift"));

    const run = std.Build.Step.Run.create(b, "render ui preview");
    run.has_side_effects = true;
    run.addFileArg(exe);
    run.addDirectoryArg(b.path("zig-out/ui-preview"));
    return .{ .run = run };
}
