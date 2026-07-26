const std = @import("std");
const GitVersion = @import("GitVersion.zig");

/// Resolve the semantic version exposed by this build.
pub fn resolve(b: *std.Build, base_version: []const u8) !std.SemanticVersion {
    if (b.option(
        []const u8,
        "version-string",
        "Specific semantic version for this build; otherwise derive it from Git",
    )) |version_string| {
        return std.SemanticVersion.parse(version_string);
    }

    const base = try std.SemanticVersion.parse(base_version);
    if (b.dep_prefix.len > 0) return .{
        .major = base.major,
        .minor = base.minor,
        .patch = base.patch,
    };

    const detected = GitVersion.detect(b) catch |err| switch (err) {
        error.GitNotFound, error.GitNotRepository => return .{
            .major = base.major,
            .minor = base.minor,
            .patch = base.patch,
            .pre = "dev",
            .build = "0000000",
        },
        else => return err,
    };

    if (detected.tag) |tag| {
        if (!std.mem.eql(u8, tag, "tip")) {
            const expected = b.fmt("v{d}.{d}.{d}", .{ base.major, base.minor, base.patch });
            if (!std.mem.eql(u8, tag, expected)) {
                @panic("tagged releases must match build.zig.zon's vX.Y.Z version");
            }
            return .{
                .major = base.major,
                .minor = base.minor,
                .patch = base.patch,
            };
        }
    }

    return .{
        .major = base.major,
        .minor = base.minor,
        .patch = base.patch,
        .pre = detected.branch,
        .build = detected.short_hash,
    };
}
