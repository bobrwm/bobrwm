//! Modules shared by everything that compiles the Zig core: build options,
//! zig-objc, ziglua, and the translated macOS headers.
const SharedDeps = @This();

const std = @import("std");
const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");

config: *const Config,
build_options: *std.Build.Module,
objc: *std.Build.Module,
zlua: *std.Build.Module,
/// Null before ziglua's lazy fetch of the Lua sources completes; the build
/// runner reconfigures once it has.
lua_lib: ?*std.Build.Step.Compile,
c: *std.Build.Module,
cg_extra: *std.Build.Module,
help_strings: HelpStrings,

pub fn init(b: *std.Build, config: *const Config) SharedDeps {
    const options = b.addOptions();
    config.addOptions(b, options);

    const objc_dep = b.dependency("zig_objc", .{ .target = config.target, .optimize = config.optimize });

    // Pin the Lua version so script semantics don't follow ziglua's default.
    const zlua_dep = b.dependency("zlua", .{
        .target = config.target,
        .optimize = config.optimize,
        .lang = .lua55,
    });
    const zlua = zlua_dep.module("zlua");

    const c = translateHeaders(b, config);
    // Hand-written extern decls for CGEvent/CGWindow symbols Aro can't
    // translate. Needs `c` itself in scope to reference shared types.
    const cg_extra = b.createModule(.{
        .root_source_file = b.path("src/c/cg_extra.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    cg_extra.addImport("c", c);

    return .{
        .config = config,
        .build_options = options.createModule(),
        .objc = objc_dep.module("objc"),
        .zlua = zlua,
        .lua_lib = linkedLibrary(zlua),
        .c = c,
        .cg_extra = cg_extra,
        // Doc comments on config fields, keybind actions, and client commands
        // are the source of truth for user-facing docs.
        .help_strings = .init(b),
    };
}

/// Wire a module that compiles the Zig core to the platform imports and
/// frameworks. Swift remains in the final app link, so Zig tests do not need
/// to compile the native application shell.
pub fn addApp(self: *const SharedDeps, module: *std.Build.Module) void {
    module.addImport("build_options", self.build_options);
    module.addImport("objc", self.objc);
    module.addImport("zlua", self.zlua);
    module.addImport("c", self.c);
    module.addImport("cg_extra", self.cg_extra);

    for ([_][]const u8{
        "ApplicationServices",
        "CoreGraphics",
        "Carbon",
        "AppKit",
        "CoreFoundation",
        "ServiceManagement",
    }) |framework| module.linkFramework(framework, .{});

    const sdk = self.config.sdk;
    module.addSystemFrameworkPath(.{ .cwd_relative = sdk.frameworks });
    module.addSystemFrameworkPath(.{ .cwd_relative = sdk.private_frameworks });
    module.addSystemIncludePath(.{ .cwd_relative = sdk.include });
    module.addLibraryPath(.{ .cwd_relative = sdk.lib });
}

/// Translate the aggregated C header surface (ApplicationServices, dispatch,
/// pthread, os/lock) once via the build system, replacing the per-file
/// `@cImport` blocks deprecated in Zig 0.16.
fn translateHeaders(b: *std.Build, config: *const Config) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c.h"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    translate_c.addSystemIncludePath(.{ .cwd_relative = config.sdk.include });
    translate_c.addSystemFrameworkPath(.{ .cwd_relative = config.sdk.frameworks });
    // macOS umbrella frameworks (ApplicationServices, CoreServices, Carbon)
    // expose their sub-frameworks via nested `Frameworks/` directories. Aro's
    // translate-c does not traverse umbrellas implicitly, so add the relevant
    // nested paths so e.g. `<HIServices/AXUIElement.h>` resolves.
    for ([_][]const u8{
        "ApplicationServices.framework/Frameworks",
        "CoreServices.framework/Frameworks",
        "Carbon.framework/Frameworks",
    }) |sub| {
        translate_c.addSystemFrameworkPath(.{
            .cwd_relative = b.fmt("{s}/{s}", .{ config.sdk.frameworks, sub }),
        });
    }
    // Aro rejects Apple's nullability annotations on array parameters (e.g.
    // `CGFloat whitePoint[_Nonnull 3]`). These attributes are optimization
    // hints with no semantic effect on translation, so defining them away is
    // safe.
    for ([_][]const u8{
        "_Nullable=",
        "_Nonnull=",
        "_Null_unspecified=",
        "__nullable=",
        "__nonnull=",
        "__null_unspecified=",
    }) |macro| {
        translate_c.defineCMacroRaw(macro);
    }
    return translate_c.createModule();
}

/// The library `module` links, or null before ziglua's lazy fetch completes
/// (where `Dependency.artifact` would panic).
fn linkedLibrary(module: *std.Build.Module) ?*std.Build.Step.Compile {
    for (module.link_objects.items) |link_object| switch (link_object) {
        .other_step => |compile| return compile,
        else => {},
    };
    return null;
}
