const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const objc = @import("objc");
const shim = @cImport({
    @cInclude("shim.h");
});
const skylight = @import("skylight.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const workspace_mod = @import("workspace.zig");
const layout = @import("layout.zig");
const ipc = @import("ipc.zig");
const tabgroup = @import("tabgroup.zig");
const config_mod = @import("config.zig");
const statusbar = @import("statusbar.zig");

const NSPoint = extern struct {
    x: f64,
    y: f64,
};

const NSSize = extern struct {
    width: f64,
    height: f64,
};

const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const std_options = std.Options{
    .log_level = if (build_options.log_level_int) |l|
        @enumFromInt(l)
    else switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

const log = std.log.scoped(.bobrwm);

// ---------------------------------------------------------------------------
// Lock-free MPSC ring buffer
// ---------------------------------------------------------------------------

const EventRing = struct {
    const capacity = 256;

    buf: [capacity]event_mod.Event = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn push(self: *EventRing, ev: event_mod.Event) void {
        const t = self.tail.load(.acquire);
        const next = (t + 1) % capacity;
        if (next == self.head.load(.acquire)) return; // full, drop
        self.buf[t] = ev;
        self.tail.store(next, .release);
    }

    fn pop(self: *EventRing) ?event_mod.Event {
        const h = self.head.load(.acquire);
        if (h == self.tail.load(.acquire)) return null; // empty
        const ev = self.buf[h];
        self.head.store((h + 1) % capacity, .release);
        return ev;
    }
};

// ---------------------------------------------------------------------------
// Hidden-window position (as far off-screen and as small as possible)
// ---------------------------------------------------------------------------

const hide_x: f64 = -99999;
const hide_y: f64 = -99999;
const hide_w: f64 = 1;
const hide_h: f64 = 1;

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

var g_ring: EventRing = .{};
var g_sky: ?skylight.SkyLight = null;
var g_allocator: std.mem.Allocator = undefined;
var g_store: window_mod.WindowStore = undefined;
var g_workspaces: workspace_mod.WorkspaceManager = undefined;
var g_layout_roots: [workspace_mod.max_workspaces]?layout.Node =
    [1]?layout.Node{null} ** workspace_mod.max_workspaces;
var g_next_split_dir: layout.Direction = .horizontal;
var g_tab_groups: tabgroup.TabGroupManager = undefined;
var g_ipc: ipc.Server = undefined;
var g_config: config_mod.Config = .{};

// ---------------------------------------------------------------------------
// NSApp lifecycle (zig-objc)
// ---------------------------------------------------------------------------

/// Initialise NSApplication with accessory activation policy (menu bar icon,
/// no dock icon). Returns the shared application object for the run loop.
fn initApp() objc.Object {
    const NSApplication = objc.getClass("NSApplication") orelse
        @panic("NSApplication class not found");
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    // NSApplicationActivationPolicyAccessory = 1
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 1)});
    return app;
}

/// Get the usable display frame (menu bar / dock excluded), CG coordinates.
/// Exported for C callers while implemented in Zig via zig-objc.
export fn bw_get_display_frame() shim.bw_frame {
    const NSScreen = objc.getClass("NSScreen") orelse return .{
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
    };

    const screen = NSScreen.msgSend(objc.Object, "mainScreen", .{});
    if (screen.value == null) return .{
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
    };

    const visible = screen.msgSend(NSRect, "visibleFrame", .{});
    const full = screen.msgSend(NSRect, "frame", .{});

    std.debug.assert(visible.size.width >= 0);
    std.debug.assert(visible.size.height >= 0);

    // AppKit uses bottom-left origin; CG uses top-left.
    const cg_y = full.size.height - visible.origin.y - visible.size.height;
    const frame: shim.bw_frame = .{
        .x = visible.origin.x,
        .y = cg_y,
        .w = visible.size.width,
        .h = visible.size.height,
    };
    std.debug.assert(frame.w >= 0);
    std.debug.assert(frame.h >= 0);
    return frame;
}

/// Get the bundle identifier for a given PID.
/// Returns bytes written to `out` (excluding terminator), or 0 on failure.
export fn bw_get_app_bundle_id(pid: i32, out: [*c]u8, max_len: u32) u32 {
    std.debug.assert(max_len == 0 or out != null);

    if (pid <= 0) return 0;
    if (max_len == 0 or out == null) return 0;

    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return 0;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == null) return 0;

    const bundle_identifier = app.msgSend(objc.Object, "bundleIdentifier", .{});
    if (bundle_identifier.value == null) return 0;

    const utf8 = bundle_identifier.msgSend([*c]const u8, "UTF8String", .{});
    if (utf8 == null) return 0;

    const max_copy = max_len - 1;
    var copy_len: u32 = 0;
    while (copy_len < max_copy) : (copy_len += 1) {
        const ch = utf8[copy_len];
        if (ch == 0) break;
        out[copy_len] = ch;
    }
    out[copy_len] = 0;

    std.debug.assert(copy_len < max_len);
    std.debug.assert(out[copy_len] == 0);
    return copy_len;
}

// ---------------------------------------------------------------------------
// Event bridge (called from ObjC shim)
// ---------------------------------------------------------------------------

export fn bw_emit_event(kind: u8, pid: i32, wid: u32) void {
    g_ring.push(.{
        .kind = @enumFromInt(kind),
        .pid = pid,
        .wid = wid,
    });
    shim.bw_signal_waker();
}

// ---------------------------------------------------------------------------
// CLI client (sends command to running daemon)
// ---------------------------------------------------------------------------

fn runClient(cmd: []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/bobrwm_{d}.sock", .{std.c.getuid()}) catch {
        stderr.writeAll("error: socket path too long\n") catch {};
        return;
    };

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        stderr.writeAll("error: could not create socket\n") catch {};
        return;
    };
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memcpy(addr.path[0..path.len], path[0..path.len]);
    if (path.len < addr.path.len) addr.path[path.len] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        stderr.writeAll("error: bobrwm is not running\n") catch {};
        return;
    };

    _ = posix.write(fd, cmd) catch {
        stderr.writeAll("error: write failed\n") catch {};
        return;
    };

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        stdout.writeAll(buf[0..n]) catch break;
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    // -- Arg parsing (before anything else) --
    var cmd_buf: [512]u8 = undefined;
    const args = config_mod.parseArgs(&cmd_buf);

    // Client mode: forward command to running daemon via IPC
    if (args.command) |cmd| {
        runClient(cmd);
        return;
    }

    // -- Daemon mode --
    log.info("bobrwm starting...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();

    // -- Config --
    g_config = config_mod.load(g_allocator, args.config_path);
    g_config.applyKeybinds();

    // -- Accessibility check --
    if (!shim.bw_ax_is_trusted()) {
        log.warn("accessibility not trusted — prompting user", .{});
        shim.bw_ax_prompt();
    }

    // -- SkyLight (optional) --
    g_sky = skylight.SkyLight.init();

    // -- Core state --
    g_store = window_mod.WindowStore.init(g_allocator);
    defer g_store.deinit();
    g_workspaces = workspace_mod.WorkspaceManager.init(g_allocator);
    defer g_workspaces.deinit();
    g_tab_groups = tabgroup.TabGroupManager.init(g_allocator);
    defer g_tab_groups.deinit();

    // -- Apply workspace names from config --
    for (g_config.workspace_names, 0..) |name, i| {
        if (i >= workspace_mod.max_workspaces) break;
        g_workspaces.workspaces[i].name = name;
    }

    // -- Crash handlers (restore hidden windows on abnormal exit) --
    installCrashHandlers();
    errdefer restoreAllWindows();

    // -- Discover existing windows and tile --
    discoverWindows();
    log.info("discovered {} windows", .{g_store.count()});
    retile();

    // -- IPC server --
    g_ipc = ipc.Server.init(g_allocator) catch |err| {
        log.err("IPC init failed: {}", .{err});
        return err;
    };
    defer g_ipc.deinit(g_allocator);
    ipc.g_dispatch = ipcDispatch;

    // -- NSApp (zig-objc) --
    const NSApp = initApp();

    // -- Sources (observers, CGEventTap, waker, IPC) --
    shim.bw_setup_sources(g_ipc.fd);
    observeDiscoveredApps();

    // -- Status bar (zig-objc) --
    statusbar.init();
    const active = g_workspaces.active();
    statusbar.setTitle(active.name, active.id);

    // -- Enter NSApp run loop (never returns) --
    log.info("entering run loop", .{});
    defer restoreAllWindows();
    NSApp.msgSend(void, "run", .{});
}

// ---------------------------------------------------------------------------
// Exported callbacks (called from ObjC shim on main thread)
// ---------------------------------------------------------------------------

/// Drain the event ring buffer — called by the CFRunLoopSource waker.
export fn bw_drain_events() void {
    while (g_ring.pop()) |ev| {
        handleEvent(&ev);
    }
}

/// Accept and handle one IPC client connection — called by dispatch_source.
export fn bw_handle_ipc_client(server_fd: c_int) void {
    const client_fd = posix.accept(@intCast(server_fd), null, null, 0) catch |err| {
        log.err("accept failed: {}", .{err});
        return;
    };
    defer posix.close(client_fd);

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| {
        log.err("IPC read: {}", .{err});
        return;
    };
    if (n == 0) return;

    const cmd = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ', 0 });
    if (cmd.len == 0) return;

    if (ipc.g_dispatch) |dispatch| {
        dispatch(cmd, client_fd);
    }
}

/// Clean shutdown — called from status bar Quit action.
export fn bw_will_quit() void {
    restoreAllWindows();
}

/// Retile — called from status bar Retile action.
export fn bw_retile() void {
    retile();
}

// ---------------------------------------------------------------------------
// Event handling
// ---------------------------------------------------------------------------

fn handleEvent(ev: *const event_mod.Event) void {
    switch (ev.kind) {
        // -- Window / app events --
        .app_launched => {
            log.info("app launched pid={}", .{ev.pid});
            discoverWindows();
            shim.bw_observe_app(ev.pid);
            retile();
        },
        .app_terminated => {
            log.info("app terminated pid={}", .{ev.pid});
            shim.bw_unobserve_app(ev.pid);
            removeAppWindows(ev.pid);
            retile();
        },
        .window_focused => {
            log.info("window focused pid={}", .{ev.pid});
            const wid = shim.bw_ax_get_focused_window(ev.pid);
            if (wid != 0) {
                if (g_store.get(wid) == null) {
                    shim.bw_observe_app(ev.pid);
                    discoverWindows();
                    retile();
                }
                // Track leader in workspace, not raw active tab
                g_workspaces.active().focused_wid = g_tab_groups.resolveLeader(wid);
            }
        },
        .focused_window_changed => {
            log.info("focused window changed pid={}", .{ev.pid});
            reconcileAppTabs(ev.pid);
        },
        .window_created => {
            log.info("window created pid={} wid={}", .{ ev.pid, ev.wid });
            addNewWindow(ev.pid, ev.wid);
            retile();
        },
        .window_destroyed => {
            log.info("window destroyed wid={}", .{ev.wid});
            removeWindow(ev.wid);
            retile();
        },
        .window_minimized => {
            log.info("window minimized wid={}", .{ev.wid});
            removeWindow(ev.wid);
            retile();
        },
        .window_deminimized => {
            log.info("window deminimized wid={}", .{ev.wid});
            discoverWindows();
            retile();
        },
        .display_changed => {
            log.info("display changed", .{});
            retile();
        },
        .space_changed => log.info("space changed", .{}),
        .window_moved, .window_resized => {
            log.info("window {s} wid={}", .{
                if (ev.kind == .window_moved) "moved" else "resized",
                ev.wid,
            });
            // Snap fullscreen windows back to display frame
            if (g_store.get(ev.wid)) |win| {
                if (win.is_fullscreen) {
                    retile();
                    return;
                }
            }
            checkTabDragOut(ev.pid, ev.wid);
        },

        // -- Hotkey actions --
        .hk_focus_workspace => {
            const target: u8 = @intCast(ev.wid);
            log.info("hotkey: focus workspace {}", .{target});
            switchWorkspace(target);
        },
        .hk_move_to_workspace => {
            const target: u8 = @intCast(ev.wid);
            log.info("hotkey: move to workspace {}", .{target});
            moveWindowToWorkspace(target);
        },
        .hk_focus_left => focusDirection(.left),
        .hk_focus_right => focusDirection(.right),
        .hk_focus_up => focusDirection(.up),
        .hk_focus_down => focusDirection(.down),
        .hk_toggle_split => {
            g_next_split_dir = switch (g_next_split_dir) {
                .horizontal => .vertical,
                .vertical => .horizontal,
            };
            log.info("split direction: {s}", .{@tagName(g_next_split_dir)});
        },
        .hk_toggle_fullscreen => {
            const ws = g_workspaces.active();
            const focused = ws.focused_wid orelse return;
            var win = g_store.get(focused) orelse return;
            win.is_fullscreen = !win.is_fullscreen;
            g_store.put(win) catch {};
            log.info("fullscreen {s} wid={d}", .{
                if (win.is_fullscreen) "on" else "off", focused,
            });
            retile();
        },
        .hk_toggle_float => {
            const ws = g_workspaces.active();
            const focused = ws.focused_wid orelse return;
            const win = g_store.get(focused) orelse return;
            const target: window_mod.WindowMode = if (win.mode != .tiled) .tiled else .floating;
            setWindowMode(focused, target);
        },
    }
}

// ---------------------------------------------------------------------------
// Window mode (tiled / floating / fullscreen)
// ---------------------------------------------------------------------------

fn setWindowMode(wid: u32, target: window_mod.WindowMode) void {
    var win = g_store.get(wid) orelse return;
    const old = win.mode;
    if (old == target) return;

    const ws_idx: usize = win.workspace_id - 1;

    // Leaving tiled → remove from BSP so remaining windows fill the space
    if (old == .tiled) {
        if (g_layout_roots[ws_idx]) |root| {
            g_layout_roots[ws_idx] = layout.removeWindow(root, wid, g_allocator);
        }
    }

    // Entering tiled → re-insert into BSP
    if (target == .tiled) {
        g_layout_roots[ws_idx] = layout.insertWindow(
            g_layout_roots[ws_idx],
            wid,
            g_next_split_dir,
            g_allocator,
        ) catch return;
    }

    win.mode = target;
    g_store.put(win) catch {};
    log.info("window {d} mode: {s} → {s}", .{ wid, @tagName(old), @tagName(target) });
    retile();
}

// ---------------------------------------------------------------------------
// Window management helpers
// ---------------------------------------------------------------------------

fn discoverWindows() void {
    var buf: [256]shim.bw_window_info = undefined;
    const count = shim.bw_discover_windows(&buf, 256);

    // Sort windows by current x-position so the BSP tree order matches
    // their on-screen placement. Without this, windows discovered in
    // arbitrary order get swapped to the opposite side on the first retile.
    const slice = buf[0..count];
    std.mem.sortUnstable(shim.bw_window_info, slice, {}, struct {
        fn lessThan(_: void, a: shim.bw_window_info, b: shim.bw_window_info) bool {
            return a.x < b.x;
        }
    }.lessThan);

    for (slice) |info| {
        if (g_store.get(info.wid) != null) continue;

        const target_ws = resolveWorkspace(info.pid);
        const target_idx: usize = target_ws.id - 1;

        const win = window_mod.Window{
            .wid = info.wid,
            .pid = info.pid,
            .title = null,
            .frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h },
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = target_ws.id,
        };

        g_store.put(win) catch continue;
        target_ws.addWindow(info.wid) catch continue;
        g_layout_roots[target_idx] = layout.insertWindow(
            g_layout_roots[target_idx],
            info.wid,
            g_next_split_dir,
            g_allocator,
        ) catch continue;

        // If assigned to a non-visible workspace, hide immediately
        if (!target_ws.is_visible) {
            _ = shim.bw_ax_set_window_frame(
                info.pid,
                info.wid,
                hide_x,
                hide_y,
                hide_w,
                hide_h,
            );
        }
    }

    // Ensure a focused window is set on the active workspace
    const active_ws = g_workspaces.active();
    if (active_ws.focused_wid == null and active_ws.windows.items.len > 0) {
        active_ws.focused_wid = active_ws.windows.items[0];
    }
}

fn addNewWindow(pid: i32, wid: u32) void {
    log.debug("addNewWindow: pid={d} wid={d}", .{ pid, wid });
    if (g_store.get(wid) != null) {
        log.debug("addNewWindow: already in store, skipping", .{});
        return;
    }
    if (!shim.bw_should_manage_window(pid, wid)) {
        log.debug("addNewWindow: bw_should_manage_window=false, skipping", .{});
        return;
    }

    const on_screen = shim.bw_is_window_on_screen(wid);
    log.debug("addNewWindow: on_screen={}", .{on_screen});

    // Background tabs in native tab groups are not on screen — skip them.
    // However, brand-new windows from just-launched apps (Discord, Electron)
    // may not appear in the CG window list yet. Distinguish the two cases
    // by checking whether this app already has any tiled windows.
    if (!on_screen) {
        var app_has_tiled = false;
        for (&g_workspaces.workspaces) |*ws| {
            for (ws.windows.items) |existing_wid| {
                if (g_store.get(existing_wid)) |existing| {
                    if (existing.pid == pid) {
                        app_has_tiled = true;
                        break;
                    }
                }
            }
            if (app_has_tiled) break;
        }
        if (app_has_tiled) {
            log.info("addNewWindow: off-screen wid={d} with existing windows → background tab, skipping", .{wid});
            return;
        }
        log.debug("addNewWindow: off-screen wid={d}, first window for pid → CG timing, accepting", .{wid});
    }

    // Check if this new on-screen window replaces an existing same-PID window
    // that just went off-screen (i.e. a new tab was created and became active,
    // pushing the old tab to background). If so, form a tab group.
    if (tryFormTabGroupOnCreate(pid, wid)) return;

    const ws = resolveWorkspace(pid);
    const ws_idx: usize = ws.id - 1;

    const win = window_mod.Window{
        .wid = wid,
        .pid = pid,
        .title = null,
        .frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .is_minimized = false,
        .mode = .tiled,
        .workspace_id = ws.id,
    };

    g_store.put(win) catch return;
    ws.addWindow(wid) catch return;
    g_layout_roots[ws_idx] = layout.insertWindow(
        g_layout_roots[ws_idx],
        wid,
        g_next_split_dir,
        g_allocator,
    ) catch return;
    ws.focused_wid = wid;

    // If assigned to a non-visible workspace, hide immediately
    if (!ws.is_visible) {
        _ = shim.bw_ax_set_window_frame(pid, wid, hide_x, hide_y, hide_w, hide_h);
    }

    log.info("addNewWindow: tiled wid={d} on workspace {d}", .{ wid, ws.id });
}

/// When a new on-screen window appears, check if an existing managed window
/// from the same PID just went off-screen. If so, the new window is a tab
/// that replaced the old one — form a tab group instead of tiling independently.
/// Returns true if a tab group was formed (caller should NOT tile the window).
fn tryFormTabGroupOnCreate(pid: i32, new_wid: u32) bool {
    const sky = g_sky orelse return false;
    const conn = sky.mainConnectionID();

    // Get bounds of the new window
    var new_rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, new_wid, &new_rect) != 0) return false;

    const new_frame = window_mod.Window.Frame{
        .x = new_rect.origin.x,
        .y = new_rect.origin.y,
        .width = new_rect.size.width,
        .height = new_rect.size.height,
    };
    log.debug("tryFormTabGroup: new wid={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
        new_wid, new_frame.x, new_frame.y, new_frame.width, new_frame.height,
    });

    // Scan all workspaces for a same-PID window that is now off-screen
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |existing_wid| {
            const existing = g_store.get(existing_wid) orelse continue;
            if (existing.pid != pid) continue;

            const still_on_screen = shim.bw_is_window_on_screen(existing_wid);
            log.debug("tryFormTabGroup: existing wid={d} on_screen={} frame=({d:.0},{d:.0},{d:.0},{d:.0})", .{
                existing_wid,         still_on_screen,
                existing.frame.x,     existing.frame.y,
                existing.frame.width, existing.frame.height,
            });

            if (still_on_screen) continue;

            // Verify the window still exists in CG. A destroyed window
            // (e.g. a splash screen) fails the SkyLight lookup — skip it.
            var existing_rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, existing_wid, &existing_rect) != 0) {
                log.debug("tryFormTabGroup: existing wid={d} destroyed (SkyLight lookup failed), skipping", .{existing_wid});
                continue;
            }

            const existing_sky_frame = window_mod.Window.Frame{
                .x = existing_rect.origin.x,
                .y = existing_rect.origin.y,
                .width = existing_rect.size.width,
                .height = existing_rect.size.height,
            };
            log.debug("tryFormTabGroup: existing wid={d} SkyLight bounds=({d:.0},{d:.0},{d:.0},{d:.0})", .{
                existing_wid,
                existing_sky_frame.x,
                existing_sky_frame.y,
                existing_sky_frame.width,
                existing_sky_frame.height,
            });

            // Native tab members share the same frame. If bounds diverge
            // this is a different transition (splash→main, popup, etc.).
            if (!tabgroup.TabGroupManager.framesMatch(new_frame, existing_sky_frame)) {
                log.debug("tryFormTabGroup: bounds mismatch with wid={d}, not a tab", .{existing_wid});
                continue;
            }

            // Form tab group: existing_wid is the leader (already in layout),
            // new_wid is a member stored but NOT in the layout tree.
            const group_id = if (g_tab_groups.groupOf(existing_wid)) |g|
                g.id
            else
                g_tab_groups.createGroup(pid, existing_wid, existing.frame) catch return false;

            g_tab_groups.addMember(group_id, new_wid) catch return false;
            g_tab_groups.setActive(new_wid);

            // Store the new window (suppressed — not in workspace/layout)
            g_store.put(.{
                .wid = new_wid,
                .pid = pid,
                .title = null,
                .frame = new_frame,
                .is_minimized = false,
                .mode = .tiled,
                .workspace_id = ws.id,
            }) catch return false;

            // Also discover any other background tabs
            var ax_wids: [128]u32 = undefined;
            const ax_count = shim.bw_get_app_window_ids(pid, &ax_wids, 128);
            log.debug("tryFormTabGroup: AX found {d} windows for pid={d}", .{ ax_count, pid });
            for (ax_wids[0..ax_count]) |ax_wid| {
                if (ax_wid == existing_wid or ax_wid == new_wid) continue;
                if (g_store.get(ax_wid) != null) continue;

                var rect: skylight.CGRect = undefined;
                if (sky.getWindowBounds(conn, ax_wid, &rect) != 0) continue;
                const f = window_mod.Window.Frame{
                    .x = rect.origin.x,
                    .y = rect.origin.y,
                    .width = rect.size.width,
                    .height = rect.size.height,
                };

                g_tab_groups.addMember(group_id, ax_wid) catch continue;
                g_store.put(.{
                    .wid = ax_wid,
                    .pid = pid,
                    .title = null,
                    .frame = f,
                    .is_minimized = false,
                    .mode = .tiled,
                    .workspace_id = ws.id,
                }) catch continue;
            }

            ws.focused_wid = existing_wid; // leader stays
            log.info("tryFormTabGroup: formed group leader={d} active={d} members={d}", .{
                existing_wid,
                new_wid,
                if (g_tab_groups.groupOf(existing_wid)) |g| g.members.items.len else 1,
            });
            return true;
        }
    }

    log.debug("tryFormTabGroup: no off-screen sibling found, proceeding as standalone", .{});
    return false;
}

fn removeWindow(wid: u32) void {
    // Clean up tab group membership first
    const survivor = g_tab_groups.removeMember(wid);

    const win = g_store.get(wid) orelse return;
    const ws_idx: usize = win.workspace_id - 1;
    g_store.remove(wid);
    if (g_workspaces.get(win.workspace_id)) |ws| {
        ws.removeWindow(wid);
    }
    if (g_layout_roots[ws_idx]) |root| {
        g_layout_roots[ws_idx] = layout.removeWindow(root, wid, g_allocator);
    }

    // If the group dissolved, restore the survivor to workspace and layout
    if (survivor) |solo_wid| {
        if (g_workspaces.get(win.workspace_id)) |ws| {
            var in_ws = false;
            for (ws.windows.items) |w| {
                if (w == solo_wid) {
                    in_ws = true;
                    break;
                }
            }
            if (!in_ws) {
                log.info("removeWindow: restoring tab survivor wid={d} to workspace", .{solo_wid});
                ws.addWindow(solo_wid) catch {};
                g_layout_roots[ws_idx] = layout.insertWindow(
                    g_layout_roots[ws_idx],
                    solo_wid,
                    g_next_split_dir,
                    g_allocator,
                ) catch return;
            }
        }
    }
}

fn removeAppWindows(pid: i32) void {
    var wids: [128]u32 = undefined;
    var ws_ids: [128]u8 = undefined;
    var n: usize = 0;

    // Collect managed windows across all workspaces
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (win.pid == pid and n < wids.len) {
                    wids[n] = wid;
                    ws_ids[n] = ws.id;
                    n += 1;
                }
            }
        }
    }

    // Also collect suppressed tab members from the store
    var store_it = g_store.windows.iterator();
    while (store_it.next()) |entry| {
        if (entry.value_ptr.pid == pid and n < wids.len) {
            var already = false;
            for (wids[0..n]) |existing| {
                if (existing == entry.key_ptr.*) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                wids[n] = entry.key_ptr.*;
                ws_ids[n] = entry.value_ptr.workspace_id;
                n += 1;
            }
        }
    }

    for (wids[0..n], ws_ids[0..n]) |wid, ws_id| {
        _ = g_tab_groups.removeMember(wid);
        g_store.remove(wid);
        if (g_workspaces.get(ws_id)) |ws| {
            ws.removeWindow(wid);
        }
        const ws_idx: usize = ws_id - 1;
        if (g_layout_roots[ws_idx]) |root| {
            g_layout_roots[ws_idx] = layout.removeWindow(root, wid, g_allocator);
        }
    }
}

fn retile() void {
    const ws = g_workspaces.active();
    const ws_idx: usize = ws.id - 1;
    const root = g_layout_roots[ws_idx] orelse return;

    const display = shim.bw_get_display_frame();

    const outer = g_config.gaps.outer;
    const frame = window_mod.Window.Frame{
        .x = display.x + @as(f64, @floatFromInt(outer.left)),
        .y = display.y + @as(f64, @floatFromInt(outer.top)),
        .width = display.w - @as(f64, @floatFromInt(@as(u32, outer.left) + @as(u32, outer.right))),
        .height = display.h - @as(f64, @floatFromInt(@as(u32, outer.top) + @as(u32, outer.bottom))),
    };

    var buf: [256 * @sizeOf(layout.LayoutEntry)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var entries: std.ArrayList(layout.LayoutEntry) = .{};

    layout.applyLayout(root, frame, @floatFromInt(g_config.gaps.inner), &entries, fba.allocator()) catch return;

    for (entries.items) |entry| {
        const win = g_store.get(entry.wid) orelse continue;

        // Fullscreen windows fill the outer-gap-inset frame, skipping BSP splits and inner gaps
        const target_frame = if (win.is_fullscreen) frame else entry.frame;

        _ = shim.bw_ax_set_window_frame(
            win.pid,
            entry.wid,
            target_frame.x,
            target_frame.y,
            target_frame.width,
            target_frame.height,
        );
        // Two-pass for fullscreen to handle macOS size clamping
        if (win.is_fullscreen) {
            _ = shim.bw_ax_set_window_frame(
                win.pid,
                entry.wid,
                target_frame.x,
                target_frame.y,
                target_frame.width,
                target_frame.height,
            );
        }
        var updated = win;
        updated.frame = target_frame;
        g_store.put(updated) catch {};

        // If this is a tab group leader, apply the same frame to all members
        if (g_tab_groups.groupOfMut(entry.wid)) |g| {
            if (g.leader_wid == entry.wid) {
                g.canonical_frame = entry.frame;
                for (g.members.items) |member_wid| {
                    if (member_wid == entry.wid) continue;
                    if (g_store.get(member_wid)) |member| {
                        _ = shim.bw_ax_set_window_frame(
                            member.pid,
                            member_wid,
                            entry.frame.x,
                            entry.frame.y,
                            entry.frame.width,
                            entry.frame.height,
                        );
                        var m_updated = member;
                        m_updated.frame = entry.frame;
                        g_store.put(m_updated) catch {};
                    }
                }
            }
        }
    }
}

fn observeDiscoveredApps() void {
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                shim.bw_observe_app(win.pid);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Crash / exit recovery — restore all hidden windows to screen center
// ---------------------------------------------------------------------------

fn restoreAllWindows() void {
    const display = shim.bw_get_display_frame();

    for (&g_workspaces.workspaces) |*ws| {
        if (ws.is_visible) continue;
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                // Place at screen center with stored size (or sensible default)
                const w = if (win.frame.width > 1) win.frame.width else display.w * 0.5;
                const h = if (win.frame.height > 1) win.frame.height else display.h * 0.5;
                const x = display.x + (display.w - w) / 2.0;
                const y = display.y + (display.h - h) / 2.0;
                _ = shim.bw_ax_set_window_frame(win.pid, wid, x, y, w, h);
            }
        }
    }
}

fn crashSignalHandler(sig: c_int) callconv(.c) void {
    restoreAllWindows();

    // Re-raise with default handler so the OS produces a core dump / correct exit code
    const sig_u8: u8 = @intCast(sig);
    var default_sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig_u8, &default_sa, null);
    posix.raise(sig_u8) catch {};
}

fn installCrashHandlers() void {
    const signals = [_]u8{
        posix.SIG.INT,  posix.SIG.TERM,
        posix.SIG.HUP,  posix.SIG.QUIT,
        posix.SIG.ABRT, posix.SIG.SEGV,
        posix.SIG.BUS,  posix.SIG.TRAP,
    };

    for (signals) |sig| {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = crashSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESETHAND, // one-shot: avoid infinite re-entry
        };
        posix.sigaction(sig, &sa, null);
    }
}

// ---------------------------------------------------------------------------
// Tab group reconciliation
// ---------------------------------------------------------------------------

/// Called on kAXFocusedWindowChangedNotification — detects tab switches and
/// forms/updates tab groups so only the active tab occupies a layout slot.
fn reconcileAppTabs(pid: i32) void {
    const focused_wid = shim.bw_ax_get_focused_window(pid);
    log.debug("reconcile: pid={d} focused_wid={d}", .{ pid, focused_wid });
    if (focused_wid == 0) {
        log.debug("reconcile: focused_wid=0, aborting", .{});
        return;
    }

    const in_store = g_store.get(focused_wid) != null;
    const suppressed = g_tab_groups.isSuppressed(focused_wid);
    const in_group = g_tab_groups.groupOf(focused_wid) != null;
    log.debug("reconcile: wid={d} in_store={} suppressed={} in_group={}", .{
        focused_wid, in_store, suppressed, in_group,
    });

    // Case 1: focused wid is already managed and not suppressed → just update
    if (in_store and !suppressed) {
        g_tab_groups.setActive(focused_wid);
        const leader = g_tab_groups.resolveLeader(focused_wid);
        g_workspaces.active().focused_wid = leader;
        log.debug("reconcile case 1: known window, leader={d}", .{leader});
        return;
    }

    // Case 2: focused wid is suppressed → tab switch within existing group
    if (suppressed) {
        g_tab_groups.setActive(focused_wid);
        const leader = g_tab_groups.resolveLeader(focused_wid);
        g_workspaces.active().focused_wid = leader;
        log.info("reconcile case 2: tab switch, active={d} leader={d}", .{ focused_wid, leader });
        return;
    }

    // Case 3: focused wid is unknown — new tab becoming active, or new window.
    log.debug("reconcile case 3: unknown wid={d}, checking bounds", .{focused_wid});

    const sky = g_sky orelse {
        log.debug("reconcile: no SkyLight, falling back to addNewWindow", .{});
        addNewWindow(pid, focused_wid);
        retile();
        return;
    };
    const conn = sky.mainConnectionID();

    var focused_rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, focused_wid, &focused_rect) != 0) {
        log.debug("reconcile: SkyLight.getWindowBounds failed for wid={d}", .{focused_wid});
        addNewWindow(pid, focused_wid);
        retile();
        return;
    }

    const focused_frame = window_mod.Window.Frame{
        .x = focused_rect.origin.x,
        .y = focused_rect.origin.y,
        .width = focused_rect.size.width,
        .height = focused_rect.size.height,
    };
    log.debug("reconcile: focused bounds x={d:.0} y={d:.0} w={d:.0} h={d:.0}", .{
        focused_frame.x, focused_frame.y, focused_frame.width, focused_frame.height,
    });

    const on_screen = shim.bw_is_window_on_screen(focused_wid);
    log.debug("reconcile: on_screen={}", .{on_screen});

    // Look for a managed window (in any workspace) with same PID and matching bounds
    var matching_wid: ?u32 = null;
    var matching_ws_id: u8 = 0;
    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                if (win.pid == pid) {
                    const matches = tabgroup.TabGroupManager.framesMatch(win.frame, focused_frame);
                    log.debug("reconcile: candidate wid={d} ws={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) match={}", .{
                        wid, ws.id, win.frame.x, win.frame.y, win.frame.width, win.frame.height, matches,
                    });
                    if (matches) {
                        matching_wid = wid;
                        matching_ws_id = ws.id;
                        break;
                    }
                }
            }
        }
        if (matching_wid != null) break;
    }

    if (matching_wid) |managed_wid| {
        log.debug("reconcile: matched managed_wid={d} ws={d} → forming tab group", .{
            managed_wid, matching_ws_id,
        });

        const group_id = if (g_tab_groups.groupOf(managed_wid)) |g|
            g.id
        else
            g_tab_groups.createGroup(pid, managed_wid, focused_frame) catch return;

        g_tab_groups.addMember(group_id, focused_wid) catch return;
        g_tab_groups.setActive(focused_wid);

        g_store.put(.{
            .wid = focused_wid,
            .pid = pid,
            .title = null,
            .frame = focused_frame,
            .is_minimized = false,
            .mode = .tiled,
            .workspace_id = matching_ws_id,
        }) catch return;

        // Discover additional background tabs
        var ax_wids: [128]u32 = undefined;
        const ax_count = shim.bw_get_app_window_ids(pid, &ax_wids, 128);
        log.debug("reconcile: AX enumeration found {d} windows for pid={d}", .{ ax_count, pid });
        for (ax_wids[0..ax_count]) |ax_wid| {
            if (ax_wid == managed_wid or ax_wid == focused_wid) continue;
            if (g_store.get(ax_wid) != null) continue;

            var rect: skylight.CGRect = undefined;
            if (sky.getWindowBounds(conn, ax_wid, &rect) != 0) {
                log.debug("reconcile: SkyLight.getWindowBounds failed for ax_wid={d}", .{ax_wid});
                continue;
            }

            const f = window_mod.Window.Frame{
                .x = rect.origin.x,
                .y = rect.origin.y,
                .width = rect.size.width,
                .height = rect.size.height,
            };
            const bg_match = tabgroup.TabGroupManager.framesMatch(f, focused_frame);
            log.debug("reconcile: bg tab ax_wid={d} frame=({d:.0},{d:.0},{d:.0},{d:.0}) match={}", .{
                ax_wid, f.x, f.y, f.width, f.height, bg_match,
            });
            if (!bg_match) continue;

            g_tab_groups.addMember(group_id, ax_wid) catch continue;
            g_store.put(.{
                .wid = ax_wid,
                .pid = pid,
                .title = null,
                .frame = f,
                .is_minimized = false,
                .mode = .tiled,
                .workspace_id = matching_ws_id,
            }) catch continue;
        }

        const leader = g_tab_groups.resolveLeader(focused_wid);
        g_workspaces.active().focused_wid = leader;

        log.info("reconcile: tab group formed leader={d} active={d} members={d}", .{
            leader,
            focused_wid,
            if (g_tab_groups.groupOf(leader)) |g| g.members.items.len else 1,
        });
    } else {
        log.debug("reconcile: no matching managed window, treating as new window", .{});
        addNewWindow(pid, focused_wid);
        retile();
    }
}

/// Called on window_moved / window_resized — detects tab drag-out.
/// When a suppressed tab's bounds diverge from its group's canonical frame,
/// promote it to a standalone tiled window.
fn checkTabDragOut(_: i32, wid: u32) void {
    const g = g_tab_groups.groupOfMut(wid) orelse return;
    if (g.active_wid == wid) return; // only check suppressed members

    const sky = g_sky orelse return;
    const conn = sky.mainConnectionID();
    var rect: skylight.CGRect = undefined;
    if (sky.getWindowBounds(conn, wid, &rect) != 0) return;

    const frame = window_mod.Window.Frame{
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };

    if (tabgroup.TabGroupManager.framesMatch(frame, g.canonical_frame)) return;

    // Bounds diverged — this tab was dragged out to a standalone window
    if (!shim.bw_is_window_on_screen(wid)) return; // still off-screen, not a drag-out

    log.info("tab drag-out detected: wid={d} promoted to standalone", .{wid});
    const survivor = g_tab_groups.removeMember(wid);

    // Update stored frame and add to workspace + layout
    if (g_store.get(wid)) |win| {
        var updated = win;
        updated.frame = frame;
        g_store.put(updated) catch return;
    }

    const ws = g_workspaces.active();
    const ws_idx: usize = ws.id - 1;
    ws.addWindow(wid) catch return;
    g_layout_roots[ws_idx] = layout.insertWindow(
        g_layout_roots[ws_idx],
        wid,
        g_next_split_dir,
        g_allocator,
    ) catch return;
    ws.focused_wid = wid;

    // If the group dissolved, verify the survivor is still managed
    if (survivor) |solo_wid| {
        var in_ws = false;
        for (ws.windows.items) |w| {
            if (w == solo_wid) {
                in_ws = true;
                break;
            }
        }
        if (!in_ws) {
            log.info("drag-out: restoring survivor wid={d} to workspace", .{solo_wid});
            ws.addWindow(solo_wid) catch {};
            g_layout_roots[ws_idx] = layout.insertWindow(
                g_layout_roots[ws_idx],
                solo_wid,
                g_next_split_dir,
                g_allocator,
            ) catch return;
        }
    }

    retile();
}

// ---------------------------------------------------------------------------
// Workspace resolution (config-based app → workspace mapping)
// ---------------------------------------------------------------------------

/// Return the workspace a window should be placed on, checking
/// config workspace_assignments by bundle ID before falling back
/// to the active workspace.
fn resolveWorkspace(pid: i32) *workspace_mod.Workspace {
    if (g_config.workspace_assignments.len > 0) {
        var id_buf: [256]u8 = undefined;
        if (config_mod.getAppBundleId(pid, &id_buf)) |bundle_id| {
            if (g_config.workspaceForApp(bundle_id)) |ws_id| {
                if (g_workspaces.get(ws_id)) |ws| return ws;
            }
        }
    }
    return g_workspaces.active();
}

// ---------------------------------------------------------------------------
// Workspace switching
// ---------------------------------------------------------------------------

fn switchWorkspace(target_id: u8) void {
    if (target_id == g_workspaces.active_id) return;
    const target_ws = g_workspaces.get(target_id) orelse return;

    // Hide current workspace windows (move off-screen, shrink to 1×1)
    const old_ws = g_workspaces.active();
    for (old_ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            _ = shim.bw_ax_set_window_frame(
                win.pid,
                wid,
                hide_x,
                hide_y,
                hide_w,
                hide_h,
            );
        }
    }
    old_ws.is_visible = false;

    // Activate target
    g_workspaces.active_id = target_id;
    target_ws.is_visible = true;

    retile();
    statusbar.setTitle(target_ws.name, target_ws.id);

    // Focus the remembered window on the target workspace
    if (target_ws.focused_wid) |fwid| {
        const actual_wid = g_tab_groups.resolveActive(fwid);
        if (g_store.get(actual_wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, actual_wid);
        }
    }
}

fn moveWindowToWorkspace(target_id: u8) void {
    const ws = g_workspaces.active();
    const wid = ws.focused_wid orelse return;
    if (target_id == ws.id) return;
    const target_ws = g_workspaces.get(target_id) orelse return;
    const ws_idx: usize = ws.id - 1;
    const target_idx: usize = target_id - 1;

    // Remove from current workspace BSP + list
    ws.removeWindow(wid);
    if (g_layout_roots[ws_idx]) |root| {
        g_layout_roots[ws_idx] = layout.removeWindow(root, wid, g_allocator);
    }

    // Add to target workspace BSP + list
    target_ws.addWindow(wid) catch return;
    g_layout_roots[target_idx] = layout.insertWindow(
        g_layout_roots[target_idx],
        wid,
        g_next_split_dir,
        g_allocator,
    ) catch return;
    if (target_ws.focused_wid == null) {
        target_ws.focused_wid = wid;
    }

    // Update window's workspace_id
    if (g_store.get(wid)) |win| {
        var updated = win;
        updated.workspace_id = target_id;
        g_store.put(updated) catch {};
    }

    // If target is not visible, hide the window
    if (!target_ws.is_visible) {
        if (g_store.get(wid)) |win| {
            _ = shim.bw_ax_set_window_frame(
                win.pid,
                wid,
                hide_x,
                hide_y,
                hide_w,
                hide_h,
            );
        }
    }

    retile();
}

// ---------------------------------------------------------------------------
// Focus direction
// ---------------------------------------------------------------------------

const FocusDir = enum { left, right, up, down };

fn focusDirection(dir: FocusDir) void {
    const ws = g_workspaces.active();
    const focused_wid = ws.focused_wid orelse return;
    const focused = g_store.get(focused_wid) orelse return;

    const fc_x = focused.frame.x + focused.frame.width / 2.0;
    const fc_y = focused.frame.y + focused.frame.height / 2.0;

    var best_wid: ?u32 = null;
    var best_dist: f64 = std.math.inf(f64);

    for (ws.windows.items) |wid| {
        if (wid == focused_wid) continue;
        const win = g_store.get(wid) orelse continue;

        const wc_x = win.frame.x + win.frame.width / 2.0;
        const wc_y = win.frame.y + win.frame.height / 2.0;

        const dx = wc_x - fc_x;
        const dy = wc_y - fc_y;

        const in_direction = switch (dir) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };
        if (!in_direction) continue;

        const dist = @abs(dx) + @abs(dy);
        if (dist < best_dist) {
            best_dist = dist;
            best_wid = wid;
        }
    }

    if (best_wid) |wid| {
        // If target is a tab group leader, focus the active tab instead
        const actual_wid = g_tab_groups.resolveActive(wid);
        if (g_store.get(actual_wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, actual_wid);
            ws.focused_wid = wid; // track the leader
        }
    }
}

// ---------------------------------------------------------------------------
// IPC command dispatch
// ---------------------------------------------------------------------------

fn ipcDispatch(cmd: []const u8, client_fd: posix.socket_t) void {
    if (std.mem.eql(u8, cmd, "retile")) {
        retile();
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.eql(u8, cmd, "toggle-split")) {
        g_next_split_dir = switch (g_next_split_dir) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "focus-workspace ")) {
        const arg = cmd["focus-workspace ".len..];
        const n = std.fmt.parseInt(u8, arg, 10) catch {
            ipc.writeResponse(client_fd, "err: invalid workspace number\n");
            return;
        };
        switchWorkspace(n);
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "move-to-workspace ")) {
        const arg = cmd["move-to-workspace ".len..];
        const n = std.fmt.parseInt(u8, arg, 10) catch {
            ipc.writeResponse(client_fd, "err: invalid workspace number\n");
            return;
        };
        moveWindowToWorkspace(n);
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.startsWith(u8, cmd, "focus ")) {
        const dir_str = cmd["focus ".len..];
        if (std.mem.eql(u8, dir_str, "left")) {
            focusDirection(.left);
        } else if (std.mem.eql(u8, dir_str, "right")) {
            focusDirection(.right);
        } else if (std.mem.eql(u8, dir_str, "up")) {
            focusDirection(.up);
        } else if (std.mem.eql(u8, dir_str, "down")) {
            focusDirection(.down);
        } else {
            ipc.writeResponse(client_fd, "err: expected left|right|up|down\n");
            return;
        }
        ipc.writeResponse(client_fd, "ok\n");
    } else if (std.mem.eql(u8, cmd, "query windows")) {
        ipcQueryWindows(client_fd);
    } else if (std.mem.eql(u8, cmd, "query workspaces")) {
        ipcQueryWorkspaces(client_fd);
    } else if (std.mem.eql(u8, cmd, "query apps")) {
        ipcQueryApps(client_fd);
    } else {
        ipc.writeResponse(client_fd, "err: unknown command\n");
    }
}

fn ipcQueryWindows(fd: posix.socket_t) void {
    const ws = g_workspaces.active();
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    for (ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            var id_buf: [256]u8 = undefined;
            const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
            const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

            w.print("{d} {d} {s} {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{
                win.wid,     win.pid,     bundle_id,       win.workspace_id,
                win.frame.x, win.frame.y, win.frame.width, win.frame.height,
            }) catch break;
        }
    }

    ipc.writeResponse(fd, fbs.getWritten());
}

fn ipcQueryApps(fd: posix.socket_t) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    var seen_pids: [256]i32 = undefined;
    var seen_count: usize = 0;

    for (&g_workspaces.workspaces) |*ws| {
        for (ws.windows.items) |wid| {
            if (g_store.get(wid)) |win| {
                // Deduplicate by PID
                var already = false;
                for (seen_pids[0..seen_count]) |p| {
                    if (p == win.pid) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                if (seen_count >= seen_pids.len) break;
                seen_pids[seen_count] = win.pid;
                seen_count += 1;

                var id_buf: [256]u8 = undefined;
                const id_len = shim.bw_get_app_bundle_id(win.pid, &id_buf, 256);
                const bundle_id: []const u8 = if (id_len > 0) id_buf[0..id_len] else "(unknown)";

                w.print("{s}\t{d}\n", .{ bundle_id, win.pid }) catch break;
            }
        }
    }

    ipc.writeResponse(fd, fbs.getWritten());
}

fn ipcQueryWorkspaces(fd: posix.socket_t) void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    for (&g_workspaces.workspaces) |*ws| {
        const focused: u32 = ws.focused_wid orelse 0;
        w.print("{d} {s} {d} {d}\n", .{
            ws.id,
            if (ws.is_visible) "visible" else "hidden",
            focused,
            ws.windows.items.len,
        }) catch break;
    }

    ipc.writeResponse(fd, fbs.getWritten());
}
