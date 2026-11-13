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
extern "c" fn fileno(stream: *std.c.FILE) c_int;
extern "c" fn fflush(stream: *std.c.FILE) c_int;
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

/// Durably replace a file without exposing a partial write. Symlinks survive
/// and the file keeps its permissions.
pub fn writeFileAtomically(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) bool {
    std.debug.assert(path.len > 0);
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return false;
    defer allocator.free(path_z);

    // realpath fails for a file that does not exist yet; create it as named.
    var resolved: [std.c.PATH_MAX]u8 = undefined;
    const target = std.c.realpath(path_z, &resolved) orelse path_z.ptr;
    var existing: std.c.Stat = undefined;
    const mode: ?std.c.mode_t = if (std.c.stat(target, &existing) == 0) existing.mode & 0o7777 else null;

    const temporary_path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}.tmp-{d}",
        .{ std.mem.span(target), std.c.getpid() },
        0,
    ) catch return false;
    defer allocator.free(temporary_path);
    defer deleteFile(temporary_path.ptr);

    const file = std.c.fopen(temporary_path.ptr, "wb") orelse return false;
    var open = true;
    defer {
        if (open) _ = std.c.fclose(file);
    }
    if (mode) |m| {
        if (std.c.fchmod(fileno(file), m) != 0) return false;
    }
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return false;
    if (fflush(file) != 0) return false;
    if (std.c.fsync(fileno(file)) != 0) return false;
    if (std.c.fclose(file) != 0) return false;
    open = false;
    return std.c.rename(temporary_path.ptr, target) == 0;
}

test "writeFileAtomically replaces a symlink's target and keeps its mode" {
    const target: [:0]const u8 = "/tmp/bobrwm_test_atomic_target.zon";
    const link: [:0]const u8 = "/tmp/bobrwm_test_atomic_link.zon";
    defer deleteFile(target.ptr);
    defer deleteFile(link.ptr);
    deleteFile(link.ptr);

    if (!writeFile(target.ptr, "old")) return error.TestUnexpectedResult;
    if (std.c.chmod(target.ptr, 0o600) != 0) return error.TestUnexpectedResult;
    if (std.c.symlink(target.ptr, link.ptr) != 0) return error.TestUnexpectedResult;

    try std.testing.expect(writeFileAtomically(std.testing.allocator, link, "new"));

    var buf: [16]u8 = undefined;
    try std.testing.expect(std.c.readlink(link.ptr, &buf, buf.len) > 0);
    const written = readFileAllocSentinel(std.testing.allocator, target.ptr, 16) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("new", written);
    var st: std.c.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.stat(target.ptr, &st));
    try std.testing.expectEqual(@as(std.c.mode_t, 0o600), st.mode & 0o7777);
}

/// Returns true if `path` exists and is accessible.
pub fn pathExists(path_z: [*:0]const u8) bool {
    return std.c.access(path_z, 0) == 0;
}

/// Recursively create `path` and any missing parents (mode 0o755).
/// Returns true if the path exists or was created.
pub fn makePath(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return false;
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

// Process identity

/// Start time of a running process in microseconds since the epoch, or null
/// when the PID has no live process. The kernel reuses PIDs, but never a PID
/// and start time pair, so the two together name one process. A failed query
/// is an error, not null, so callers never release a live process over it.
pub fn processStartTimeUs(pid: i32) error{QueryFailed}!?u64 {
    std.debug.assert(pid > 0);

    // proc_pidinfo is the cheap path but refuses other users' processes and
    // exited ones awaiting reap.
    var info: ProcBsdInfo = undefined;
    const info_size: c_int = @sizeOf(ProcBsdInfo);
    if (proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, info_size) == info_size) {
        return info.start_tvsec * std.time.us_per_s + info.start_tvusec;
    }
    return sysctlStartTimeUs(pid);
}

fn sysctlStartTimeUs(pid: i32) error{QueryFailed}!?u64 {
    const ctl_kern: c_int = 1;
    const kern_proc: c_int = 14;
    const kern_proc_pid: c_int = 1;
    const mib = [_]c_int{ ctl_kern, kern_proc, kern_proc_pid, pid };

    // kinfo_proc is 648 bytes. It starts with kp_proc.p_starttime, a
    // timeval, and kp_proc.p_stat sits at byte 36.
    var info: [648]u8 align(@alignOf(std.c.timeval)) = undefined;
    var info_len: usize = info.len;
    if (std.c.sysctl(&mib, mib.len, &info, &info_len, null, 0) != 0) return error.QueryFailed;

    // A missing PID succeeds with nothing written.
    if (info_len == 0) return null;
    if (info_len != info.len) return error.QueryFailed;

    // An exited process lingers as a zombie until its parent reaps it.
    const p_stat_offset = 36;
    const szomb: u8 = 5;
    if (info[p_stat_offset] == szomb) return null;

    const start: *const std.c.timeval = @ptrCast(&info);
    if (start.sec < 0 or start.usec < 0) return error.QueryFailed;
    return @as(u64, @intCast(start.sec)) * std.time.us_per_s + @as(u64, @intCast(start.usec));
}

// <sys/proc_info.h>
const proc_pidtbsdinfo: c_int = 3;
const ProcBsdInfo = extern struct {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu_1: u32,
    comm: [16]u8,
    name: [32]u8,
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
};

comptime {
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@offsetOf(ProcBsdInfo, "start_tvsec") == 120);
}

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffer_size: c_int) c_int;

// App metadata

/// Look up the bundle identifier for a PID via NSRunningApplication.
/// Copies it into `buf` and returns the written slice, or null when the
/// PID has no running application or no bundle identifier.
pub fn appBundleId(pid: i32, buf: []u8) ?[]const u8 {
    std.debug.assert(pid > 0);
    if (buf.len == 0) return null;

    const objc = @import("objc");
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return null;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return null;

    const bundle_identifier = app.msgSend(objc.Object, "bundleIdentifier", .{});
    if (bundle_identifier.value == null) return null;

    const utf8 = bundle_identifier.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    const bundle_id = std.mem.sliceTo(utf8, 0);
    if (bundle_id.len == 0) return null;

    const copy_len = @min(bundle_id.len, buf.len);
    @memcpy(buf[0..copy_len], bundle_id[0..copy_len]);
    return buf[0..copy_len];
}

/// Whether the process is a regular app, one with a Dock icon. Helpers,
/// agents, and background processes are not tiled. An app can change its
/// policy at runtime, so callers ask again rather than keep the answer.
/// Safe off the main thread.
pub fn isRegularApp(pid: i32) bool {
    std.debug.assert(pid > 0);

    const objc = @import("objc");
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return false;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return false;

    // NSApplicationActivationPolicyRegular == 0.
    return app.msgSend(i64, "activationPolicy", .{}) == 0;
}

/// Bundle identifiers of processes, keyed by PID and start time so a reused
/// PID never reads the previous process's identifier. An identifier is
/// fixed for a process's lifetime, so entries leave only when the process
/// ends.
pub const BundleIdCache = struct {
    entries: std.AutoHashMapUnmanaged(i32, Entry) = .empty,

    const Entry = struct {
        started_at_us: u64,
        len: u16,
        bytes: [max_len]u8,
    };

    pub const max_len = 256;

    pub fn deinit(self: *BundleIdCache, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Copy the cached identifier into `buf`. Null on a miss or when the PID
    /// now belongs to a different process.
    pub fn get(self: *const BundleIdCache, pid: i32, started_at_us: u64, buf: *[max_len]u8) ?[]const u8 {
        const entry = self.entries.get(pid) orelse return null;
        if (entry.started_at_us != started_at_us) return null;

        @memcpy(buf[0..entry.len], entry.bytes[0..entry.len]);
        return buf[0..entry.len];
    }

    /// Cache only identifiers that were found: a process can report none
    /// while it is still registering with the system. Out of memory only
    /// costs the next lookup a query.
    pub fn put(self: *BundleIdCache, allocator: std.mem.Allocator, pid: i32, started_at_us: u64, bundle_id: []const u8) void {
        std.debug.assert(bundle_id.len <= max_len);
        var entry: Entry = .{ .started_at_us = started_at_us, .len = @intCast(bundle_id.len), .bytes = undefined };
        @memcpy(entry.bytes[0..bundle_id.len], bundle_id);
        self.entries.put(allocator, pid, entry) catch {};
    }

    pub fn forget(self: *BundleIdCache, pid: i32) void {
        _ = self.entries.remove(pid);
    }
};

test "bundle ID cache serves a known process and never a reused PID" {
    const testing = std.testing;
    var cache: BundleIdCache = .{};
    defer cache.deinit(testing.allocator);

    var buf: [BundleIdCache.max_len]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), cache.get(42, 100, &buf));

    cache.put(testing.allocator, 42, 100, "com.example.First");
    try testing.expectEqualStrings("com.example.First", cache.get(42, 100, &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), cache.get(42, 200, &buf));

    cache.put(testing.allocator, 42, 200, "com.example.Second");
    try testing.expectEqualStrings("com.example.Second", cache.get(42, 200, &buf).?);

    cache.forget(42);
    try testing.expectEqual(@as(?[]const u8, null), cache.get(42, 200, &buf));
}

test "process start time is stable for a live PID and null for a missing one" {
    const pid = std.c.getpid();
    const first = (try processStartTimeUs(pid)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u64, first), try processStartTimeUs(pid));
    try std.testing.expect(first > 0);

    // macOS PIDs never exceed PID_MAX, 99999.
    try std.testing.expectEqual(@as(?u64, null), try processStartTimeUs(99_999_999));
}

test "both process start time sources agree" {
    const pid = std.c.getpid();
    try std.testing.expectEqual(try processStartTimeUs(pid), try sysctlStartTimeUs(pid));

    // launchd runs as root, which proc_pidinfo refuses.
    try std.testing.expect((try processStartTimeUs(1)) != null);
}

test "a zombie process has no start time" {
    const libc = struct {
        extern "c" fn fork() std.c.pid_t;
        extern "c" fn usleep(microseconds: c_uint) c_int;
    };
    const child = libc.fork();
    if (child == 0) std.c._exit(0);
    try std.testing.expect(child > 0);
    defer _ = std.c.waitpid(child, null, 0);

    // Unreaped, the child stays a zombie; give it time to exit.
    var attempts: u32 = 0;
    while ((try processStartTimeUs(child)) != null) : (attempts += 1) {
        if (attempts == 200) return error.TestUnexpectedResult;
        _ = libc.usleep(5 * std.time.us_per_ms);
    }
}
