//! Build-mode switches shared by the core.

const std = @import("std");
const builtin = @import("builtin");

/// Enables whole-model integrity checks that scan every window, node, or
/// space after each transition. They are quadratic in window count, so they
/// run only in Debug and tests. In ReleaseFast a failed `std.debug.assert` is
/// undefined behavior rather than a panic, so these scans would cost time
/// without checking anything.
pub const slow_runtime_safety = std.debug.runtime_safety and builtin.mode == .debug;
