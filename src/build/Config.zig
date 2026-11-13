//! Build options (`-D`) and the macOS SDK every artifact builds against.
const Config = @This();

const std = @import("std");
const AppVersion = @import("AppVersion.zig");

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
version: std.SemanticVersion,
log_level: ?std.log.Level,
/// macOS keys Accessibility grants to a binary's designated requirement.
/// Unsigned builds derive one from the code hash, so each rebuild reads as a
/// new application and drops the grant. Signing against a fixed identity
/// holds the requirement steady. See script/dev-identity.sh.
codesign_identity: ?[]const u8,
sdk: Sdk,
/// Nix's SDK is sufficient for Zig and C, but Apple's swiftc needs the SDK
/// from its own selected developer toolchain to locate Swift overlays.
swift_sdk_root: []const u8,
swift_developer_dir: ?[]const u8,

pub const Sdk = struct {
    root: []const u8,
    include: []const u8,
    lib: []const u8,
    frameworks: []const u8,
    private_frameworks: []const u8,
};

pub fn init(b: *std.Build, zon_version: []const u8) !Config {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
    });
    // Process environment is already captured by the build graph; query
    // it directly rather than re-fetching.
    const env = &b.graph.environ_map;
    const sdk_root = try sdkRoot(b, target, env);

    return .{
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .version = try AppVersion.resolve(b, zon_version),
        // -Dlog_level=debug, or LOG_LEVEL=debug zig build
        .log_level = b.option(
            std.log.Level,
            "log_level",
            "Log level (debug, info, warn, err)",
        ) orelse if (env.get("LOG_LEVEL")) |raw| parseLogLevelEnv(raw) else null,
        .codesign_identity = b.option(
            []const u8,
            "codesign-identity",
            "Code-signing identity to sign installed binaries with",
        ),
        .sdk = .{
            .root = sdk_root,
            .include = b.fmt("{s}/usr/include", .{sdk_root}),
            .lib = b.fmt("{s}/usr/lib", .{sdk_root}),
            .frameworks = b.fmt("{s}/System/Library/Frameworks", .{sdk_root}),
            .private_frameworks = b.fmt("{s}/System/Library/PrivateFrameworks", .{sdk_root}),
        },
        .swift_sdk_root = env.get("SWIFT_SDKROOT") orelse sdk_root,
        .swift_developer_dir = env.get("SWIFT_DEVELOPER_DIR"),
    };
}

/// The `build_options` module the core and the client import.
pub fn addOptions(self: *const Config, b: *std.Build, options: *std.Build.Step.Options) void {
    // std.log.Level can't be serialized directly; pass as backing int.
    const log_level_int: ?u3 = if (self.log_level) |l| @backingInt(l) else null;
    options.addOption(?u3, "log_level_int", log_level_int);
    options.addOption([]const u8, "version", b.fmt("{f}", .{self.version}));
}

/// Prefer an explicit SDKROOT so Nix sandbox builds can use the SDK path
/// provided by the derivation instead of probing host Xcode via xcrun.
fn sdkRoot(b: *std.Build, target: std.Build.ResolvedTarget, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("SDKROOT")) |raw| {
        const trimmed = std.mem.trim(u8, raw, &.{ ' ', '\t', '\r', '\n' });
        if (trimmed.len == 0) @panic("SDKROOT is empty");
        return trimmed;
    }
    // Resolve macOS SDK paths via xcrun (wrapped by Zig stdlib). Hard-fail if
    // the SDK isn't installed; bobrwm is macOS-only so we can't proceed.
    const libc = try std.zig.LibCInstallation.findNative(b.allocator, b.graph.io, .{
        .target = &target.result,
        .environ_map = env,
        .verbose = false,
    });
    const sdk_include = libc.sys_include_dir orelse
        @panic("macOS SDK sys_include_dir missing from LibCInstallation");
    // sys_include_dir is `<SDK>/usr/include`.
    return std.fs.path.dirname(std.fs.path.dirname(sdk_include) orelse
        @panic("unexpected SDK layout")) orelse
        @panic("unexpected SDK layout");
}

fn parseLogLevelEnv(raw: []const u8) ?std.log.Level {
    const trimmed = std.mem.trim(u8, raw, &.{ ' ', '\t', '\r', '\n' });
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "trace")) return .debug;

    inline for (comptime std.enums.values(std.log.Level)) |level| {
        if (std.ascii.eqlIgnoreCase(trimmed, @tagName(level))) {
            return level;
        }
    }
    return null;
}
