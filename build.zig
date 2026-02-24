const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Log level: -Dlog_level=debug, or LOG_LEVEL=debug zig build
    const log_level: ?std.log.Level = b.option(
        std.log.Level,
        "log_level",
        "Log level (debug, info, warn, err)",
    ) orelse if (std.posix.getenv("LOG_LEVEL")) |env|
        std.meta.stringToEnum(std.log.Level, env)
    else
        null;

    const build_options = b.addOptions();
    // std.log.Level can't be serialized directly — pass as backing int
    const log_level_int: ?u3 = if (log_level) |l| @intFromEnum(l) else null;
    build_options.addOption(?u3, "log_level_int", log_level_int);
    exe_mod.addImport("build_options", build_options.createModule());

    const xev_dep = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("xev", xev_dep.module("xev"));

    exe_mod.addCSourceFile(.{
        .file = b.path("src/shim/shim.m"),
        .flags = &.{"-fobjc-arc"},
    });

    exe_mod.addIncludePath(b.path("src/shim"));

    exe_mod.linkFramework("ApplicationServices", .{});
    exe_mod.linkFramework("CoreGraphics", .{});
    exe_mod.linkFramework("Carbon", .{});
    exe_mod.linkFramework("AppKit", .{});
    exe_mod.linkFramework("CoreFoundation", .{});

    const sdk_path = sdk: {
        var code: u8 = undefined;
        const stdout = b.runAllowFail(
            &.{ "xcrun", "--show-sdk-path" },
            &code,
            .Inherit,
        ) catch break :sdk null;
        const trimmed = std.mem.trimEnd(u8, stdout, &.{ '\n', '\r', ' ' });
        if (trimmed.len == 0) break :sdk null;
        break :sdk trimmed;
    };

    if (sdk_path) |sdk| {
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/PrivateFrameworks", .{sdk}) });
        exe_mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
        exe_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    } else {
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/PrivateFrameworks" });
    }

    const exe = b.addExecutable(.{
        .name = "bobrwm",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run bobrwm");
    run_step.dependOn(&run_cmd.step);
}
