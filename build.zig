const std = @import("std");

fn parseLogLevelEnv(raw: []const u8) ?std.log.Level {
    const trimmed = std.mem.trim(u8, raw, &.{ ' ', '\t', '\r', '\n' });
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "trace")) return .debug;

    inline for (comptime std.meta.fields(std.log.Level)) |field| {
        if (std.ascii.eqlIgnoreCase(trimmed, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

const version = "0.1.0";

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const optimize = b.standardOptimizeOption(.{});
    // Process environment is already captured by the build graph; query
    // it directly rather than re-fetching.
    const env = &b.graph.environ_map;

    // Prefer an explicit SDKROOT so Nix sandbox builds can use the SDK path
    // provided by the derivation instead of probing host Xcode via xcrun.
    const sdk_root = if (env.get("SDKROOT")) |raw| blk: {
        const trimmed = std.mem.trim(u8, raw, &.{ ' ', '\t', '\r', '\n' });
        if (trimmed.len == 0) @panic("SDKROOT is empty");
        break :blk trimmed;
    } else blk: {
        // Resolve macOS SDK paths via xcrun (wrapped by Zig stdlib). Hard-fail
        // if the SDK isn't installed; bobrwm is macOS-only so we can't proceed.
        const libc = try std.zig.LibCInstallation.findNative(b.allocator, b.graph.io, .{
            .target = &target.result,
            .environ_map = env,
            .verbose = false,
        });
        const sdk_include_native = libc.sys_include_dir orelse
            @panic("macOS SDK sys_include_dir missing from LibCInstallation");
        // sys_include_dir is `<SDK>/usr/include`.
        break :blk std.fs.path.dirname(std.fs.path.dirname(sdk_include_native) orelse
            @panic("unexpected SDK layout")) orelse
            @panic("unexpected SDK layout");
    };
    const sdk_include = b.fmt("{s}/usr/include", .{sdk_root});
    const sdk_lib = b.fmt("{s}/usr/lib", .{sdk_root});
    const sdk_frameworks = b.fmt("{s}/System/Library/Frameworks", .{sdk_root});
    const sdk_private_frameworks = b.fmt("{s}/System/Library/PrivateFrameworks", .{sdk_root});

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
    ) orelse if (env.get("LOG_LEVEL")) |raw|
        parseLogLevelEnv(raw)
    else
        null;

    const build_options = b.addOptions();
    // std.log.Level can't be serialized directly; pass as backing int.
    const log_level_int: ?u3 = if (log_level) |l| @intFromEnum(l) else null;
    build_options.addOption(?u3, "log_level_int", log_level_int);
    build_options.addOption([]const u8, "version", version);
    exe_mod.addImport("build_options", build_options.createModule());

    const objc_dep = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("objc", objc_dep.module("objc"));

    // Translate the aggregated C header surface (ApplicationServices,
    // dispatch, pthread, os/lock) once via the build system, replacing
    // the per-file `@cImport` blocks deprecated in Zig 0.16.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    translate_c.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    // macOS umbrella frameworks (ApplicationServices, CoreServices, Carbon)
    // expose their sub-frameworks via nested `Frameworks/` directories.
    // Aro's translate-c does not traverse umbrellas implicitly, so add
    // the relevant nested paths so e.g. `<HIServices/AXUIElement.h>`
    // resolves.
    for ([_][]const u8{
        "ApplicationServices.framework/Frameworks",
        "CoreServices.framework/Frameworks",
        "Carbon.framework/Frameworks",
    }) |sub| {
        translate_c.addSystemFrameworkPath(.{
            .cwd_relative = b.fmt("{s}/{s}", .{ sdk_frameworks, sub }),
        });
    }
    // Aro rejects Apple's nullability annotations on array parameters
    // (e.g. `CGFloat whitePoint[_Nonnull 3]`). These attributes are
    // optimization hints with no semantic effect on translation, so
    // defining them away is safe.
    for ([_][]const u8{
        "-D_Nullable=",
        "-D_Nonnull=",
        "-D_Null_unspecified=",
        "-D__nullable=",
        "-D__nonnull=",
        "-D__null_unspecified=",
    }) |flag| {
        translate_c.defineCMacroRaw(flag[2..]);
    }
    const c_mod = translate_c.createModule();
    exe_mod.addImport("c", c_mod);

    // Hand-written extern decls for CGEvent/CGWindow symbols Aro can't
    // translate. Needs `c` itself in scope to reference shared types.
    const cg_extra_mod = b.createModule(.{
        .root_source_file = b.path("src/c/cg_extra.zig"),
        .target = target,
        .optimize = optimize,
    });
    cg_extra_mod.addImport("c", c_mod);
    exe_mod.addImport("cg_extra", cg_extra_mod);

    // BW* Objective-C classes (BWStatusBarDelegate, BWObserver, BWLaunchGate)
    // are registered at runtime by src/objc_classes.zig via zig-objc's
    // allocateClassPair. No clang-compiled translation unit is required.

    exe_mod.addAnonymousImport("launchd_plist", .{
        .root_source_file = b.path("res/com.bobrwm.bobrwm.plist"),
    });
    exe_mod.addAssemblyFile(b.path("src/info_plist.s"));

    exe_mod.linkFramework("ApplicationServices", .{});
    exe_mod.linkFramework("CoreGraphics", .{});
    exe_mod.linkFramework("Carbon", .{});
    exe_mod.linkFramework("AppKit", .{});
    exe_mod.linkFramework("CoreFoundation", .{});

    exe_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    exe_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_private_frameworks });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    exe_mod.addLibraryPath(.{ .cwd_relative = sdk_lib });

    const exe = b.addExecutable(.{
        .name = "bobrwm",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const swipe_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const swipe_mod = b.createModule(.{
        .root_source_file = b.path("packages/bobrwm-swipe/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    swipe_mod.addImport("objc", objc_dep.module("objc"));
    swipe_mod.addImport("c", c_mod);
    swipe_mod.addImport("cg_extra", cg_extra_mod);
    swipe_mod.addImport("bobrwm_config", swipe_config_mod);
    swipe_mod.addAssemblyFile(b.path("packages/bobrwm-swipe/src/info_plist.s"));
    swipe_mod.linkFramework("ApplicationServices", .{});
    swipe_mod.linkFramework("CoreGraphics", .{});
    swipe_mod.linkFramework("AppKit", .{});
    swipe_mod.linkFramework("CoreFoundation", .{});
    swipe_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    swipe_mod.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    swipe_mod.addLibraryPath(.{ .cwd_relative = sdk_lib });

    const swipe_exe = b.addExecutable(.{
        .name = "bobrwm-swipe",
        .root_module = swipe_mod,
    });

    b.installArtifact(swipe_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run bobrwm");
    run_step.dependOn(&run_cmd.step);

    const run_swipe_cmd = b.addRunArtifact(swipe_exe);
    run_swipe_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_swipe_cmd.addArgs(args);
    }

    const run_swipe_step = b.step("run-swipe", "Run bobrwm-swipe");
    run_swipe_step.dependOn(&run_swipe_cmd.step);

    // config.zig imports only Zig declarations, so the test module needs
    // no SDK or include wiring.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{
        .name = "config-tests",
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ipc_tests = b.addTest(.{
        .name = "ipc-tests",
        .root_module = ipc_test_mod,
    });

    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    // tabgroup.zig and tiling.zig are pure Zig (window.zig types only),
    // so their test modules need no SDK or include wiring either.
    const tabgroup_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tabgroup.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tabgroup_tests = b.addTest(.{
        .name = "tabgroup-tests",
        .root_module = tabgroup_test_mod,
    });

    const run_tabgroup_tests = b.addRunArtifact(tabgroup_tests);

    const tiling_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tiling.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tiling_tests = b.addTest(.{
        .name = "tiling-tests",
        .root_module = tiling_test_mod,
    });

    const run_tiling_tests = b.addRunArtifact(tiling_tests);

    const swipe_test_mod = b.createModule(.{
        .root_source_file = b.path("packages/bobrwm-swipe/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    swipe_test_mod.addImport("objc", objc_dep.module("objc"));
    swipe_test_mod.addImport("c", c_mod);
    swipe_test_mod.addImport("cg_extra", cg_extra_mod);
    swipe_test_mod.addImport("bobrwm_config", swipe_config_mod);
    swipe_test_mod.linkFramework("ApplicationServices", .{});
    swipe_test_mod.linkFramework("CoreGraphics", .{});
    swipe_test_mod.linkFramework("AppKit", .{});
    swipe_test_mod.linkFramework("CoreFoundation", .{});
    swipe_test_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    swipe_test_mod.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    swipe_test_mod.addLibraryPath(.{ .cwd_relative = sdk_lib });

    const swipe_tests = b.addTest(.{
        .name = "bobrwm-swipe-tests",
        .root_module = swipe_test_mod,
    });

    const run_swipe_tests = b.addRunArtifact(swipe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_tabgroup_tests.step);
    test_step.dependOn(&run_tiling_tests.step);
    test_step.dependOn(&run_swipe_tests.step);
}
