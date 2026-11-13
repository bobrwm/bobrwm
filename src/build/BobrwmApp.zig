//! The app executable: the Swift shell linked against the core archive. No
//! Xcode project is involved; swiftc drives Apple's linker directly.
const BobrwmApp = @This();

const std = @import("std");
const BobrwmBundle = @import("BobrwmBundle.zig");
const BobrwmCore = @import("BobrwmCore.zig");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

exe: std.Build.LazyPath,

pub fn init(b: *std.Build, deps: *const SharedDeps, core: BobrwmCore) BobrwmApp {
    const config = deps.config;

    // Clang must compile the os_log macro so its __oslogstring metadata reaches
    // Apple's linker unchanged. The object is linked directly into the app.
    const oslog_compile = b.addSystemCommand(&.{
        "clang",
        "-c",
        "-target",
        "arm64-apple-macos15.0",
        "-isysroot",
        config.sdk.root,
    });
    const oslog_object = oslog_compile.addPrefixedOutputFileArg("-o", "oslog.o");
    oslog_compile.addFileArg(b.path("src/c/oslog.c"));

    const swiftc = addSwiftc(b, config);
    swiftc.addArgs(&.{ "-module-name", "Bobrwm" });
    if (config.optimize != .debug) swiftc.addArg("-O");
    // Include paths alone do not invalidate Swift's build cache on ABI edits.
    swiftc.addPrefixedDirectoryArg("-I", b.path("macos/include"));
    swiftc.addFileInput(b.path("macos/include/bobrwm_ui.h"));
    swiftc.addFileInput(b.path("macos/include/module.modulemap"));
    const exe = swiftc.addPrefixedOutputFileArg("-o", BobrwmBundle.server_exe_name);
    for ([_][]const u8{ "main", "Settings", "MenuBar", "StatusMenu" }) |name| {
        swiftc.addFileArg(b.path(b.fmt("macos/src/{s}.swift", .{name})));
    }
    swiftc.addFileArg(core.archive);
    // Not folded into the core archive.
    if (deps.lua_lib) |lib| swiftc.addFileArg(lib.getEmittedBin());
    swiftc.addFileArg(oslog_object);
    for ([_][]const u8{
        "ApplicationServices",
        "CoreGraphics",
        "Carbon",
        "AppKit",
        "CoreFoundation",
        "ServiceManagement",
    }) |framework| {
        swiftc.addArgs(&.{ "-framework", framework });
    }
    return .{ .exe = exe };
}

/// swiftc against the toolchain's own SDK; see `Config.swift_sdk_root`.
pub fn addSwiftc(b: *std.Build, config: *const Config) *std.Build.Step.Run {
    const swiftc = b.addSystemCommand(&.{
        "swiftc",
        "-swift-version",
        "5",
        "-target",
        "arm64-apple-macos15.0",
        "-sdk",
        config.swift_sdk_root,
    });
    if (config.swift_developer_dir) |developer_dir| {
        swiftc.setEnvironmentVariable("DEVELOPER_DIR", developer_dir);
    }
    return swiftc;
}
