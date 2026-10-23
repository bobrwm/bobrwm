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
    settle_pending: bool = false,

    /// Start watching `path`. The sources keep a pointer to `self`, so it
    /// and `path` must stay valid while the main run loop runs. Watching is
    /// best effort: failures are logged and leave manual reload as the only
    /// way to apply changes.
    pub fn start(self: *Watcher, path: [:0]const u8, reload: *const fn () void) void {
        if (self.is_running) return;
        self.* = .{ .path = path, .reload = reload, .is_running = true, .last_seen = snapshot(path) };

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fs.path.dirname(path) orelse ".";
        const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0) catch "";
        self.dir_source = self.watch(dir_z, dir_events);
        if (self.dir_source == null) {
            log.warn("cannot watch {s}; config changes need a manual reload", .{dir});
        }

        self.rearmFileSource(self.last_seen);
    }

    /// Stop watching. A settle timer already in flight sees `is_running` and
    /// does nothing, so no reload runs after this returns.
    pub fn stop(self: *Watcher) void {
        if (!self.is_running) return;
        if (self.dir_source != null) cancelSource(self.dir_source);
        if (self.file_source != null) cancelSource(self.file_source);
        self.dir_source = null;
        self.file_source = null;
        self.watched_file = null;
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
        self.settle_pending = false;
        if (!self.is_running) return;

        const current = snapshot(self.path);
        self.rearmFileSource(current);
        if (std.meta.eql(current, self.last_seen)) return;
        self.last_seen = current;

        // A missing file is usually mid-save for editors that delete before
        // writing. Keep the running config and reload once the file reappears.
        if (current == null) return;
        log.debug("config file changed; reloading {s}", .{self.path});
        self.reload();
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
    if (self.settle_pending) return;
    self.settle_pending = true;
    c.dispatch_after_f(
        c.dispatch_time(c.DISPATCH_TIME_NOW, settle_delay_ns),
        cg_extra.dispatch_get_main_queue(),
        self,
        settleTimerFired,
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
