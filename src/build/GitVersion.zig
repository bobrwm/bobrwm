const GitVersion = @This();

const std = @import("std");

short_hash: []const u8,
tag: ?[]const u8,
branch: []const u8,

/// Detect version metadata from the repository containing the build root.
/// Returned strings use the build allocator and live for the build's duration.
pub fn detect(b: *std.Build) !GitVersion {
    const root = b.build_root.path orelse ".";
    var exit_code: u8 = 0;

    const branch_output = b.runAllowFail(
        &.{ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" },
        &exit_code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => return error.GitNotRepository,
        else => return err,
    };
    const branch_trimmed = std.mem.trimEnd(u8, branch_output, "\r\n ");
    const branch = branch_output[0..branch_trimmed.len];
    for (branch) |*character| {
        if (!std.ascii.isAlphanumeric(character.*) and character.* != '-') character.* = '-';
    }

    const short_hash_output = b.runAllowFail(
        &.{
            "git",
            "-C",
            root,
            "-c",
            "log.showSignature=false",
            "log",
            "--pretty=format:%h",
            "-n",
            "1",
        },
        &exit_code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => return err,
    };
    const short_hash = std.mem.trimEnd(u8, short_hash_output, "\r\n ");

    const tag_output = b.runAllowFail(
        &.{ "git", "-C", root, "describe", "--exact-match", "--tags" },
        &exit_code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => "",
        else => return err,
    };
    const tag = std.mem.trimEnd(u8, tag_output, "\r\n ");

    return .{
        .short_hash = short_hash,
        .tag = if (tag.len == 0) null else tag,
        .branch = branch,
    };
}
