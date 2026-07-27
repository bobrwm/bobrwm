//! Shared `std.Options` for both binaries.
//!
//! The window manager and the client are separate root modules, so each has
//! to declare `std_options` itself. Keeping the level in one place stops the
//! two from drifting: a client that ignores `-Dlog_level` prints debug lines
//! into the user's terminal, interleaved with query output.

const std = @import("std");
const build_options = @import("build_options");

pub const level: std.log.Level = if (build_options.log_level_int) |l|
    @enumFromInt(l)
else switch (@import("builtin").mode) {
    .Debug => .debug,
    else => .info,
};
