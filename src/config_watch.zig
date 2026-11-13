//! Reload the config automatically when its file changes on disk.
//!
//! Editors save either by writing the file in place or by writing a temporary
//! file and renaming it over the original. A vnode source on the file only
//! sees the first kind; after a rename-over it keeps watching the orphaned
//! inode. The parent directory is therefore watched too, and the file source
//! is re-armed whenever the path resolves to a different inode. Opening the
//! path follows symlinks, so a config linked from a dotfiles checkout still
//! reports in-place edits to its target.

const std = @import("std");
const c = @import("c");
const cg_extra = @import("cg_extra");

const log = std.log.scoped(.config_watch);

/// Saves span several syscalls (truncate + write, or create + write + rename).
/// Coalescing events for this long reloads once per save instead of parsing a
/// half-written file and flashing a reload error.
const settle_delay_ns: i64 = 150 * c.NSEC_PER_MSEC;

const file_events: c_int = c.DISPATCH_VNODE_DELETE | c.DISPATCH_VNODE_WRITE |
    c.DISPATCH_VNODE_EXTEND | c.DISPATCH_VNODE_ATTRIB | c.DISPATCH_VNODE_RENAME;

/// Directory WRITE fires when entries are added, removed, or renamed.
const dir_events: c_int = c.DISPATCH_VNODE_WRITE;

/// Sources and the settle timer run on the main queue, which owns config
/// state, so `reload` may mutate it directly.
pub const Watcher = struct {
    path: [:0]const u8 = "",
    reload: *const fn () void = undefined,
    is_running: bool = false,
    dir_source: c.dispatch_source_t = null,
    file_source: c.dispatch_source_t = null,
    /// The file `file_source` watches; non-null exactly when it is armed.
    watched_file: ?Snapshot = null,
    last_seen: ?Snapshot = null,
    watched_dir: ?Snapshot = null,
    settle_source: c.dispatch_source_t = null,

    /// Start watching `path`. The sources keep a pointer to `self`, so it
    /// and `path` must stay valid while the main run loop runs. Watching is
    /// best effort: failures are logged and leave manual reload as the only
    /// way to apply changes.
    pub fn start(self: *Watcher, path: [:0]const u8, reload: *const fn () void) void {
        if (self.is_running) return;
        self.* = .{ .path = path, .reload = reload, .is_running = true, .last_seen = snapshot(path) };

        self.settle_source = c.dispatch_source_create(cg_extra.DISPATCH_SOURCE_TYPE_TIMER(), 0, 0, cg_extra.dispatch_get_main_queue());
        const timer = self.settle_source orelse {
            self.is_running = false;
            log.warn("cannot watch {s}; config changes need a manual reload", .{path});
            return;
        };
        c.dispatch_set_context(.{ ._ds = timer }, self);
        c.dispatch_source_set_event_handler_f(timer, settleTimerFired);
        c.dispatch_resume(.{ ._ds = timer });

        self.rearmDirectorySource();
        if (self.dir_source == null) log.warn("cannot watch parent of {s}; new files need a manual reload", .{path});
        self.rearmFileSource(self.last_seen);
    }

    /// Stop on the main queue. Cancelling the timer as well as the vnode
    /// sources makes it safe to release a dynamically owned watcher.
    pub fn stop(self: *Watcher) void {
        if (!self.is_running) return;
        if (self.dir_source != null) cancelSource(self.dir_source);
        if (self.file_source != null) cancelSource(self.file_source);
        if (self.settle_source) |timer| {
            c.dispatch_source_cancel(timer);
            c.dispatch_release(.{ ._ds = timer });
        }
        self.dir_source = null;
        self.file_source = null;
        self.settle_source = null;
        self.watched_file = null;
        self.watched_dir = null;
        self.is_running = false;
    }

    fn watch(self: *Watcher, path: [*:0]const u8, mask: c_int) c.dispatch_source_t {
        // O_EVTONLY keeps the descriptor from blocking unmounts of the volume.
        const fd = c.open(path, c.O_EVTONLY | c.O_CLOEXEC);
        if (fd < 0) return null;
        const source = c.dispatch_source_create(
            cg_extra.DISPATCH_SOURCE_TYPE_VNODE(),
            @intCast(fd),
            @intCast(mask),
            cg_extra.dispatch_get_main_queue(),
        ) orelse {
            _ = c.close(fd);
            return null;
        };
        c.dispatch_set_context(.{ ._ds = source }, self);
        c.dispatch_source_set_event_handler_f(source, sourceChanged);
        c.dispatch_resume(.{ ._ds = source });
        return source;
    }

    // Missing module directories may be created after a failed load. Watch
    // the nearest existing ancestor, then move closer as directories appear.
    fn rearmDirectorySource(self: *Watcher) void {
        var dir = std.fs.path.dirname(self.path) orelse ".";
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (true) {
            const path = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return;
            if (snapshot(path)) |now| {
                if (self.watched_dir) |watched| {
                    if (watched.sameFile(now)) return;
                }
                if (self.watch(path, dir_events)) |source| {
                    if (self.dir_source != null) cancelSource(self.dir_source);
                    self.dir_source = source;
                    self.watched_dir = now;
                    return;
                }
            }
            const parent = std.fs.path.dirname(dir) orelse ".";
            if (std.mem.eql(u8, parent, dir)) return;
            dir = parent;
        }
    }

    /// Point the file source at whatever inode the path names now.
    fn rearmFileSource(self: *Watcher, current: ?Snapshot) void {
        if (self.watched_file) |watched| {
            if (current) |now| {
                if (watched.sameFile(now)) return;
            }
            cancelSource(self.file_source);
            self.file_source = null;
            self.watched_file = null;
        }

        const now = current orelse return;
        self.file_source = self.watch(self.path, file_events);
        if (self.file_source != null) self.watched_file = now;
    }

    fn settle(self: *Watcher) void {
        if (!self.is_running) return;
        self.rearmDirectorySource();
        const current = snapshot(self.path);
        self.rearmFileSource(current);
        if (std.meta.eql(current, self.last_seen)) return;
        self.last_seen = current;

        // After the save debounce, deletion is a real change too: missing
        // config layers are empty, not a reason to retain stale overrides.
        log.debug("config file changed; reloading {s}", .{self.path});
        self.reload();
    }
};

/// Owns stable watcher contexts and paths for a changing set of required
/// modules. All operations run on the main queue, like Watcher callbacks.
pub const WatcherSet = struct {
    watchers: std.ArrayList(*Watcher) = .empty,

    pub fn deinit(self: *WatcherSet, allocator: std.mem.Allocator) void {
        for (self.watchers.items) |watcher| destroy(allocator, watcher);
        self.watchers.deinit(allocator);
        self.* = .{};
    }

    /// Add attempted modules after a failed reload without dropping the
    /// dependencies of the still-running configuration.
    pub fn add(self: *WatcherSet, allocator: std.mem.Allocator, paths: []const [:0]const u8, reload: *const fn () void) !void {
        for (paths) |path| {
            const known = for (self.watchers.items) |watcher| {
                if (std.mem.eql(u8, path, watcher.path)) break true;
            } else false;
            if (known) continue;
            const owned = try allocator.dupeSentinel(u8, path, 0);
            errdefer allocator.free(owned);
            const watcher = try allocator.create(Watcher);
            errdefer allocator.destroy(watcher);
            watcher.* = .{};
            try self.watchers.append(allocator, watcher);
            watcher.start(owned, reload);
        }
    }

    /// A successful load replaces the graph, so removed requires stop watching.
    pub fn replace(self: *WatcherSet, allocator: std.mem.Allocator, paths: []const [:0]const u8, reload: *const fn () void) !void {
        try self.add(allocator, paths, reload);
        var i: usize = 0;
        while (i < self.watchers.items.len) {
            const watcher = self.watchers.items[i];
            const keep = for (paths) |path| {
                if (std.mem.eql(u8, path, watcher.path)) break true;
            } else false;
            if (keep) {
                i += 1;
            } else destroy(allocator, self.watchers.swapRemove(i));
        }
    }

    fn destroy(allocator: std.mem.Allocator, watcher: *Watcher) void {
        watcher.stop();
        allocator.free(watcher.path);
        allocator.destroy(watcher);
    }
};

/// Which file the path names and when it was last written. Comparing these
/// filters directory events for unrelated entries such as editor swap files.
const Snapshot = struct {
    dev: @FieldType(std.c.Stat, "dev"),
    ino: @FieldType(std.c.Stat, "ino"),
    size: @FieldType(std.c.Stat, "size"),
    mtime: std.c.timespec,

    fn sameFile(self: Snapshot, other: Snapshot) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

fn snapshot(path: [*:0]const u8) ?Snapshot {
    var st: std.c.Stat = undefined;
    if (std.c.stat(path, &st) != 0) return null;
    return .{ .dev = st.dev, .ino = st.ino, .size = st.size, .mtime = st.mtimespec };
}

fn sourceChanged(context: ?*anyopaque) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(context.?));
    c.dispatch_source_set_timer(
        self.settle_source,
        c.dispatch_time(c.DISPATCH_TIME_NOW, settle_delay_ns),
        std.math.maxInt(u64),
        0,
    );
}

fn settleTimerFired(context: ?*anyopaque) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(context.?));
    self.settle();
}

fn cancelSource(source: c.dispatch_source_t) void {
    // Closing the descriptor before libdispatch unregisters the kevent could
    // deliver events to a reused fd, so the cancel handler closes it. No event
    // handler runs after cancel, so the context can carry the fd instead of
    // the watcher, offset by one so that descriptor 0 is not null.
    const fd = c.dispatch_source_get_handle(source);
    c.dispatch_set_context(.{ ._ds = source }, @ptrFromInt(fd + 1));
    c.dispatch_source_set_cancel_handler_f(source, closeSourceFd);
    c.dispatch_source_cancel(source);
    c.dispatch_release(.{ ._ds = source });
}

fn closeSourceFd(context: ?*anyopaque) callconv(.c) void {
    const fd: c_int = @intCast(@intFromPtr(context.?) - 1);
    _ = c.close(fd);
}

const TestEvents = struct {
    var count: usize = 0;
    var stop_on_reload: ?*WatcherSet = null;

    fn reload() void {
        count += 1;
        if (stop_on_reload) |watchers| watchers.deinit(std.testing.allocator);
    }

    fn runFor(seconds: f64) void {
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, seconds, 0);
    }

    fn expectReload() !void {
        const deadline = c.CFAbsoluteTimeGetCurrent() + 2;
        while (count == 0 and c.CFAbsoluteTimeGetCurrent() < deadline) runFor(0.05);
        try std.testing.expect(count > 0);
        // Drain any coalesced notifications before the next operation.
        runFor(0.2);
        try std.testing.expectEqual(1, count);
        count = 0;
    }

    fn expectQuiet() !void {
        runFor(0.3);
        try std.testing.expectEqual(0, count);
    }
};

test "watchers reload for saves deletion recreation and changed dependency graphs" {
    const osutil = @import("osutil.zig");
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrintSentinel(allocator, "/tmp/bobrwm-watch-{d}", .{std.c.getpid()}, 0);
    defer allocator.free(dir);
    try std.testing.expectEqual(0, std.c.mkdir(dir, 0o700));
    defer _ = std.c.rmdir(dir);
    const module = try std.fmt.allocPrintSentinel(allocator, "{s}/module.lua", .{dir}, 0);
    defer allocator.free(module);
    defer osutil.deleteFile(module);
    const settings = try std.fmt.allocPrintSentinel(allocator, "{s}/settings.json", .{dir}, 0);
    defer allocator.free(settings);
    defer osutil.deleteFile(settings);
    const nested_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/nested", .{dir}, 0);
    defer allocator.free(nested_dir);
    defer _ = std.c.rmdir(nested_dir);
    const missing = try std.fmt.allocPrintSentinel(allocator, "{s}/nested/missing.lua", .{dir}, 0);
    defer allocator.free(missing);
    defer osutil.deleteFile(missing);
    try std.testing.expect(osutil.writeFile(module, "return 1"));
    try std.testing.expect(osutil.writeFile(settings, "{}"));
    var watchers: WatcherSet = .{};
    defer watchers.deinit(allocator);
    TestEvents.count = 0;
    defer TestEvents.stop_on_reload = null;
    try watchers.replace(allocator, &.{ module, settings }, TestEvents.reload);
    try std.testing.expect(osutil.writeFile(module, "return 2"));
    try TestEvents.expectReload();
    try std.testing.expect(osutil.writeFileAtomically(allocator, module, "return 3"));
    try TestEvents.expectReload();
    osutil.deleteFile(settings);
    try TestEvents.expectReload();
    try std.testing.expect(osutil.writeFile(settings, "{}"));
    try TestEvents.expectReload();
    // Failed loads add attempted modules without discarding last-good ones.
    try watchers.add(allocator, &.{ module, missing, missing }, TestEvents.reload);
    try std.testing.expectEqual(0, std.c.mkdir(nested_dir, 0o700));
    try TestEvents.expectQuiet();
    try std.testing.expect(osutil.writeFile(missing, "return true"));
    try TestEvents.expectReload();
    try std.testing.expect(osutil.writeFile(module, "return 4"));
    try TestEvents.expectReload();
    // A successful graph replacement cancels even an armed settle timer.
    try std.testing.expect(osutil.writeFile(module, "return 5"));
    TestEvents.runFor(0.03);
    try watchers.replace(allocator, &.{missing}, TestEvents.reload);
    try TestEvents.expectQuiet();
    try std.testing.expect(osutil.writeFile(module, "return 6"));
    try TestEvents.expectQuiet();
    // Disabling reload from inside its own callback can free this watcher.
    TestEvents.stop_on_reload = &watchers;
    try std.testing.expect(osutil.writeFile(missing, "return false"));
    try TestEvents.expectReload();
    try std.testing.expect(osutil.writeFile(missing, "return 7"));
    try TestEvents.expectQuiet();
}
