const std = @import("std");
const buildpkg = @import("src/build/main.zig");

const app_zon_version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) !void {
    // Every `-D` option is defined in src/build/Config.zig.
    const config = try buildpkg.Config.init(b, app_zon_version);
    const deps = buildpkg.SharedDeps.init(b, &config);

    const core = buildpkg.BobrwmCore.init(b, &deps);
    const app = buildpkg.BobrwmApp.init(b, &deps, core);
    const cli = buildpkg.BobrwmCli.init(b, &deps);
    const bundle = buildpkg.BobrwmBundle.init(b, &config, app, cli);

    // Run the installed bundle rather than the cache artifacts: only the
    // installed copy carries both the signature TCC matches against and the
    // surrounding bundle that gives the process its identity. Exec'ing the
    // binary directly instead of `open`ing the app keeps stdio on the
    // terminal, which the log-driven debugging workflow depends on.
    const run_cmd = std.Build.Step.Run.create(b, "run bobrwm");
    run_cmd.addFileArg(buildpkg.BobrwmBundle.installedPath(
        b,
        buildpkg.BobrwmBundle.bundle_macos ++ "/" ++ buildpkg.BobrwmBundle.server_exe_name,
    ));
    run_cmd.addPassthruArgs();
    run_cmd.has_side_effects = true;
    run_cmd.step.dependOn(bundle.sign_step orelse b.getInstallStep());
    b.step("run", "Run bobrwm").dependOn(&run_cmd.step);

    const preview = buildpkg.BobrwmUiPreview.init(b, &config);
    b.step("ui-preview", "Render the menu bar UI to PNGs").dependOn(&preview.run.step);

    const webdata = try buildpkg.BobrwmWebdata.init(b, &deps);
    const docs_step = b.step("docs", "Generate website docs into share/bobrwm/webdata");
    for (webdata.install_steps) |step| docs_step.dependOn(step);

    // One test binary for the whole tree, registered in src/tests.zig. Separate binaries per file each re-analysed the shared code, so
    // an edit to config.zig recompiled it once per binary.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose names contain this text",
    ) orelse &.{};
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    deps.addApp(test_mod);
    test_mod.addImport("help_strings", deps.help_strings.module);
    // The app gets os_log from the clang-built object swiftc links.
    test_mod.addCSourceFile(.{ .file = b.path("src/c/oslog.c"), .flags = &.{} });
    const tests = b.addTest(.{
        .name = "bobrwm-test",
        .root_module = test_mod,
        .filters = test_filters,
        .use_llvm = true,
    });

    // helpgen runs on the build host, so its tests cannot share the binary.
    const helpgen_tests = b.addTest(.{
        .name = "helpgen-tests",
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpgen.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(helpgen_tests).step);
    // Running the generator itself catches doc lookups broken by renamed
    // containers or fields, which the unit tests cannot see.
    test_step.dependOn(&deps.help_strings.run.step);
}
