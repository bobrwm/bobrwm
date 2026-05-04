//! Tiny libc wrappers for env-var, file-system, and clock operations.
//!
//! Zig 0.16 removed `std.posix.getenv` and `std.time.nanoTimestamp`, gutted
//! `std.fs` (most APIs moved to `std.Io.Dir` / `std.Io.File` and require an
//! `Io` instance), and retired the simple `std.fs.cwd()` helpers. The 0.16
//! release notes explicitly endorse two migration paths: "go higher" via
//! `std.Io`, or "go lower" via direct libc / `std.posix.system` calls.
//! Threading an `Io` through every call site in this single-binary daemon
//! is more disruption than is warranted, so we go lower.

const std = @import("std");

// fseek/ftell aren't surfaced by std.c; the rest of libc we need is
// available via std.c.* directly (open, read, write, fopen, etc.).
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

/// Look up an environment variable. Returns `null` if unset.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Monotonic wall clock in nanoseconds. `std.time.nanoTimestamp` was
/// removed in Zig 0.16 in favour of the `std.Io.Timestamp` API which we
/// don't thread through; call libc directly.
pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Read the entire contents of `path` into newly allocated memory.
/// Caller owns the returned slice. Returns `null` on any I/O error
/// (matching the previous "if file doesn't exist or isn't readable,
/// just return null" idiom used at config-load sites).
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path_z: [*:0]const u8,
    max_bytes: usize,
) ?[]u8 {
    const file = std.c.fopen(path_z, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const size_long = ftell(file);
    if (size_long < 0) return null;
    const size: usize = @intCast(size_long);
    if (size > max_bytes) return null;
    if (fseek(file, 0, SEEK_SET) != 0) return null;

    const buf = allocator.alloc(u8, size) catch return null;
    const read_n = std.c.fread(buf.ptr, 1, size, file);
    if (read_n != size) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

/// Read the entire contents of `path` into a newly allocated, NUL-terminated
/// slice. Suitable for `std.zon.parse` which requires a sentinel.
pub fn readFileAllocSentinel(
    allocator: std.mem.Allocator,
    path_z: [*:0]const u8,
    max_bytes: usize,
) ?[:0]u8 {
    const data = readFileAlloc(allocator, path_z, max_bytes) orelse return null;
    defer allocator.free(data);
    const out = allocator.allocSentinel(u8, data.len, 0) catch return null;
    @memcpy(out, data);
    return out;
}

pub fn deleteFile(path_z: [*:0]const u8) void {
    _ = std.c.unlink(path_z);
}

/// Write `bytes` to `path`, creating or truncating the file. Returns
/// `false` on any error.
pub fn writeFile(path_z: [*:0]const u8, bytes: []const u8) bool {
    const file = std.c.fopen(path_z, "wb") orelse return false;
    defer _ = std.c.fclose(file);
    const n = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    return n == bytes.len;
}

/// Returns true if `path` exists and is accessible.
pub fn pathExists(path_z: [*:0]const u8) bool {
    return std.c.access(path_z, 0) == 0;
}

/// Recursively create `path` and any missing parents (mode 0o755).
/// Returns true if the path exists or was created.
pub fn makePath(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    if (pathExists(path_z)) return true;

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, "/")) {
            if (!makePath(allocator, parent)) return false;
        }
    }
    if (std.c.mkdir(path_z, 0o755) == 0) return true;
    return pathExists(path_z);
}
