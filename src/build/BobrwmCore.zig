//! The window manager core as a static archive for the Swift app to link.
//! Matches Ghostty's embedding model: Zig emits a static core and Swift owns
//! the final Apple-linker invocation and NSApplication lifecycle.
const BobrwmCore = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

archive: std.Build.LazyPath,

pub fn init(b: *std.Build, deps: *const SharedDeps) BobrwmCore {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.config.target,
        .optimize = deps.config.optimize,
        .link_libc = true,
    });
    deps.addApp(module);

    const lib = b.addLibrary(.{
        .name = "bobrwm-core",
        .linkage = .static,
        .root_module = module,
        .use_llvm = true,
    });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    // Normalize Zig's archive before libtool. Newer Apple tools otherwise drop
    // members whose archive offsets are not aligned to eight bytes.
    const normalize = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        "/bin/cp \"$1\" \"$2\" && /usr/bin/ranlib \"$2\"",
        "_",
    });
    normalize.addFileArg(lib.getEmittedBin());
    const normalized = normalize.addOutputFileArg("libbobrwm-core-normalized.a");

    // Repack with Apple's libtool, as Ghostty does for its embedded library.
    const repack = b.addSystemCommand(&.{ "xcrun", "libtool", "-static" });
    repack.addFileArg(normalized);
    repack.addArg("-o");
    const repacked = repack.addOutputFileArg("libbobrwm-core.a");

    // Keep the bundled compiler-rt intrinsics Zig needs, but make its libc and
    // libm fallbacks local so the app binds to Apple's optimized libSystem.
    const prefer_libsystem = b.addSystemCommand(&.{"/bin/sh"});
    prefer_libsystem.addFileArg(b.path("script/libsystem-override.sh"));
    prefer_libsystem.addFileArg(repacked);
    return .{ .archive = prefer_libsystem.addOutputFileArg("libbobrwm-core.a") };
}
