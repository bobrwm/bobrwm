const std = @import("std");
const AppVersion = @import("src/build/AppVersion.zig");
const app_zon_version = @import("build.zig.zon").version;

// An .app is only a directory tree with an Info.plist, so the build system
// assembles it directly and no Xcode project is involved.
const bundle_name = "Bobrwm.app";
const bundle_contents = bundle_name ++ "/Contents";
const bundle_macos = bundle_contents ++ "/MacOS";

// The window manager and the client ship side by side in Contents/MacOS, so
// their names have to differ by more than case: APFS is case-insensitive by
// default and `Bobrwm` would collide with `bobrwm`. The Homebrew cask
// symlinks the client into PATH as plain `bobrwm`.
const server_exe_name = "Bobrwm";
const cli_exe_name = "bobrwm-cli";

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

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const optimize = b.standardOptimizeOption(.{});
    const app_version = try AppVersion.resolve(b, app_zon_version);
    const version_string = b.fmt("{f}", .{app_version});
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

    // macOS keys Accessibility grants to a binary's designated requirement.
    // Unsigned builds derive one from the code hash, so each rebuild reads as
    // a new application and drops the grant. Signing against a fixed identity
    // holds the requirement steady. See script/dev-identity.sh.
    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "Code-signing identity to sign installed binaries with",
    );

    const build_options = b.addOptions();
    // std.log.Level can't be serialized directly; pass as backing int.
    const log_level_int: ?u3 = if (log_level) |l| @intFromEnum(l) else null;
    build_options.addOption(?u3, "log_level_int", log_level_int);
    build_options.addOption([]const u8, "version", version_string);
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

    exe_mod.linkFramework("ApplicationServices", .{});
    exe_mod.linkFramework("CoreGraphics", .{});
    exe_mod.linkFramework("Carbon", .{});
    exe_mod.linkFramework("AppKit", .{});
    exe_mod.linkFramework("CoreFoundation", .{});
    exe_mod.linkFramework("ServiceManagement", .{});

    exe_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    exe_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_private_frameworks });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    exe_mod.addLibraryPath(.{ .cwd_relative = sdk_lib });

    const exe = b.addExecutable(.{
        .name = server_exe_name,
        .root_module = exe_mod,
    });

    installBundleArtifact(b, exe);

    // The client links no frameworks at all: it only parses arguments and
    // talks to the daemon over a unix socket. Loading AppKit and friends here
    // would cost every `bobrwm query ...` invocation for nothing.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addImport("build_options", build_options.createModule());

    const cli_exe = b.addExecutable(.{
        .name = cli_exe_name,
        .root_module = cli_mod,
    });

    installBundleArtifact(b, cli_exe);

    const swipe_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // config.zig reaches osutil.appBundleId, which uses the objc module.
    swipe_config_mod.addImport("objc", objc_dep.module("objc"));

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

    installBundleArtifact(b, swipe_exe);

    installBundleFile(b, bundleInfoPlist(b, app_version), "Contents", "Info.plist");
    // Classic-era type/creator record. LaunchServices no longer needs it, but
    // some tooling still probes for it and it costs eight bytes.
    installBundleFile(b, b.addWriteFiles().add("PkgInfo", "APPL????"), "Contents", "PkgInfo");

    const sign_step: ?*std.Build.Step = if (codesign_identity) |identity| blk: {
        const step = b.step("codesign", "Code-sign the app bundle");

        // The app takes its identifier from CFBundleIdentifier.
        const sign_app = devCodesign(b, identity);
        sign_app.addArg(b.getInstallPath(.prefix, bundle_name));

        // Nested code must be sealed before the enclosing bundle, otherwise
        // the outer signature covers a helper that is about to change.
        for ([_][2][]const u8{
            .{ cli_exe_name, "com.bobrwm.cli" },
            .{ "bobrwm-swipe", "com.bobrwm.swipe" },
        }) |entry| {
            const sign_helper = devCodesign(b, identity);
            sign_helper.addArgs(&.{ "--identifier", entry[1] });
            sign_helper.addArg(b.getInstallPath(.prefix, b.fmt("{s}/{s}", .{ bundle_macos, entry[0] })));
            sign_helper.step.dependOn(b.getInstallStep());
            sign_app.step.dependOn(&sign_helper.step);
        }

        step.dependOn(&sign_app.step);
        b.default_step = step;
        break :blk step;
    } else null;

    // Run the installed bundle rather than the cache artifacts: only the
    // installed copy carries both the signature TCC matches against and the
    // surrounding bundle that gives the process its identity. Exec'ing the
    // binary directly instead of `open`ing the app keeps stdio on the
    // terminal, which the log-driven debugging workflow depends on.
    const run_cmd = b.addSystemCommand(&.{
        b.getInstallPath(.prefix, bundle_macos ++ "/" ++ server_exe_name),
    });
    run_cmd.has_side_effects = true;
    run_cmd.step.dependOn(sign_step orelse b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run bobrwm");
    run_step.dependOn(&run_cmd.step);

    const run_swipe_cmd = b.addSystemCommand(&.{
        b.getInstallPath(.prefix, bundle_macos ++ "/bobrwm-swipe"),
    });
    run_swipe_cmd.has_side_effects = true;
    run_swipe_cmd.step.dependOn(sign_step orelse b.getInstallStep());
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

    // workspace.zig is pure Zig (window.zig types only) as well.
    const workspace_test_mod = b.createModule(.{
        .root_source_file = b.path("src/workspace.zig"),
        .target = target,
        .optimize = optimize,
    });

    const workspace_tests = b.addTest(.{
        .name = "workspace-tests",
        .root_module = workspace_test_mod,
    });

    const run_workspace_tests = b.addRunArtifact(workspace_tests);

    // dim.zig draws overlay panels via zig-objc and imports config.zig (needs
    // libc via osutil), so its test module needs the objc import plus AppKit /
    // CoreGraphics linkage and SDK paths, like the swipe test module.
    const dim_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dim.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dim_test_mod.addImport("objc", objc_dep.module("objc"));
    dim_test_mod.linkFramework("AppKit", .{});
    dim_test_mod.linkFramework("CoreGraphics", .{});
    dim_test_mod.linkFramework("CoreFoundation", .{});
    dim_test_mod.addSystemFrameworkPath(.{ .cwd_relative = sdk_frameworks });
    dim_test_mod.addSystemIncludePath(.{ .cwd_relative = sdk_include });
    dim_test_mod.addLibraryPath(.{ .cwd_relative = sdk_lib });

    const dim_tests = b.addTest(.{
        .name = "dim-tests",
        .root_module = dim_test_mod,
    });

    const run_dim_tests = b.addRunArtifact(dim_tests);

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
    test_step.dependOn(&run_workspace_tests.step);
    test_step.dependOn(&run_dim_tests.step);
    test_step.dependOn(&run_swipe_tests.step);
}

fn installBundleArtifact(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    b.getInstallStep().dependOn(&b.addInstallArtifact(artifact, .{
        .dest_dir = .{ .override = .{ .custom = bundle_macos } },
    }).step);
}

fn installBundleFile(
    b: *std.Build,
    source: std.Build.LazyPath,
    sub_dir: []const u8,
    dest_name: []const u8,
) void {
    const dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/{s}", .{ bundle_name, sub_dir }) };
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(source, dir, dest_name).step);
}

fn bundleInfoPlist(b: *std.Build, version: std.SemanticVersion) std.Build.LazyPath {
    // Both version keys must be dotted integers. The pre-release and build
    // metadata that AppVersion carries for `--version` would make
    // LaunchServices reject them, so they get the numeric triple only.
    const short_version = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    return b.addWriteFiles().add("Info.plist", b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{[server]s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.bobrwm.bobrwm</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>bobrwm</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{[version]s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{[version]s}</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>13.0</string>
        \\    <key>LSUIElement</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ .server = server_exe_name, .version = short_version }));
}

fn devCodesign(b: *std.Build, identity: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "codesign",
        "--force",
        "--sign",
        identity,
        // A self-signed identity has no timestamp authority, and the hardened
        // runtime blocks lldb without get-task-allow. Both are release-only
        // concerns.
        "--timestamp=none",
    });
    // The argument list never changes, but its input does.
    run.has_side_effects = true;
    return run;
}
