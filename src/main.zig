const std = @import("std");
const posix = std.posix;
const xev = @import("xev");
const shim = @cImport({
    @cInclude("shim.h");
});
const skylight = @import("skylight.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");
const workspace_mod = @import("workspace.zig");
const layout = @import("layout.zig");
const ipc = @import("ipc.zig");

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
var g_waker: xev.Async = undefined;
var g_sky: ?skylight.SkyLight = null;
var g_allocator: std.mem.Allocator = undefined;
var g_store: window_mod.WindowStore = undefined;
var g_workspaces: workspace_mod.WorkspaceManager = undefined;
var g_layout_roots: [workspace_mod.max_workspaces]?layout.Node =
    [1]?layout.Node{null} ** workspace_mod.max_workspaces;
var g_next_split_dir: layout.Direction = .horizontal;
var g_ipc: ipc.Server = undefined;

// ---------------------------------------------------------------------------
// Event bridge (called from ObjC observer thread)
// ---------------------------------------------------------------------------

export fn bw_emit_event(kind: u8, pid: i32, wid: u32) void {
    g_ring.push(.{
        .kind = @enumFromInt(kind),
        .pid = pid,
        .wid = wid,
    });
    g_waker.notify() catch {};
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    log.info("bobrwm starting...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();

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

    // -- Crash handlers (restore hidden windows on abnormal exit) --
    installCrashHandlers();
    errdefer restoreAllWindows();

    // -- Discover existing windows and tile --
    discoverWindows();
    log.info("discovered {} windows", .{g_store.count()});
    retile();

    // -- Async waker (mach port on macOS) --
    g_waker = try xev.Async.init();
    defer g_waker.deinit();

    // -- Start ObjC observer thread --
    shim.bw_start_observer();
    shim.bw_wait_observer_ready();
    observeDiscoveredApps();

    // -- IPC server --
    g_ipc = ipc.Server.init(g_allocator) catch |err| {
        log.err("IPC init failed: {}", .{err});
        return err;
    };
    defer g_ipc.deinit(g_allocator);
    ipc.g_dispatch = ipcDispatch;

    // -- xev loop --
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var waker_completion: xev.Completion = .{};
    g_waker.wait(&loop, &waker_completion, void, null, asyncCallback);
    g_ipc.startAccept(&loop);

    log.info("entering event loop", .{});
    defer restoreAllWindows();
    try loop.run(.until_done);
}

// ---------------------------------------------------------------------------
// Async callback (main thread, fired by mach port waker)
// ---------------------------------------------------------------------------

fn asyncCallback(
    _: ?*void,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch |err| {
        log.err("async wait error: {}", .{err});
        return .disarm;
    };

    while (g_ring.pop()) |ev| {
        handleEvent(&ev);
    }

    g_waker.wait(loop, completion, void, null, asyncCallback);
    return .disarm;
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
                    discoverWindows();
                    retile();
                }
                g_workspaces.active().focused_wid = wid;
            }
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
        .window_moved => log.info("window moved wid={}", .{ev.wid}),
        .window_resized => log.info("window resized wid={}", .{ev.wid}),

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
    }
}

// ---------------------------------------------------------------------------
// Window management helpers
// ---------------------------------------------------------------------------

fn discoverWindows() void {
    var buf: [256]shim.bw_window_info = undefined;
    const count = shim.bw_discover_windows(&buf, 256);

    const ws = g_workspaces.active();
    const ws_idx: usize = ws.id - 1;

    for (buf[0..count]) |info| {
        if (g_store.get(info.wid) != null) continue;

        const win = window_mod.Window{
            .wid = info.wid,
            .pid = info.pid,
            .title = null,
            .frame = .{ .x = info.x, .y = info.y, .width = info.w, .height = info.h },
            .is_minimized = false,
            .is_fullscreen = false,
            .workspace_id = ws.id,
        };

        g_store.put(win) catch continue;
        ws.addWindow(info.wid) catch continue;
        g_layout_roots[ws_idx] = layout.insertWindow(
            g_layout_roots[ws_idx],
            info.wid,
            g_next_split_dir,
            g_allocator,
        ) catch continue;
    }

    // Ensure a focused window is set (first discovery has no activeAppChanged event)
    if (ws.focused_wid == null and ws.windows.items.len > 0) {
        ws.focused_wid = ws.windows.items[0];
    }
}

fn addNewWindow(pid: i32, wid: u32) void {
    if (g_store.get(wid) != null) return;

    const ws = g_workspaces.active();
    const ws_idx: usize = ws.id - 1;

    const win = window_mod.Window{
        .wid = wid,
        .pid = pid,
        .title = null,
        .frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .is_minimized = false,
        .is_fullscreen = false,
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
}

fn removeWindow(wid: u32) void {
    g_store.remove(wid);
    const ws = g_workspaces.active();
    ws.removeWindow(wid);
    const ws_idx: usize = ws.id - 1;
    if (g_layout_roots[ws_idx]) |root| {
        g_layout_roots[ws_idx] = layout.removeWindow(root, wid, g_allocator);
    }
}

fn removeAppWindows(pid: i32) void {
    const ws = g_workspaces.active();
    const ws_idx: usize = ws.id - 1;

    var wids: [128]u32 = undefined;
    var n: usize = 0;
    for (ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            if (win.pid == pid and n < wids.len) {
                wids[n] = wid;
                n += 1;
            }
        }
    }

    for (wids[0..n]) |wid| {
        g_store.remove(wid);
        ws.removeWindow(wid);
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
    const frame = window_mod.Window.Frame{
        .x = display.x,
        .y = display.y,
        .width = display.w,
        .height = display.h,
    };

    var entries: std.ArrayList(layout.LayoutEntry) = .{};
    defer entries.deinit(g_allocator);

    layout.applyLayout(root, frame, &entries, g_allocator) catch return;

    for (entries.items) |entry| {
        const win = g_store.get(entry.wid) orelse continue;
        _ = shim.bw_ax_set_window_frame(
            win.pid,
            entry.wid,
            entry.frame.x,
            entry.frame.y,
            entry.frame.width,
            entry.frame.height,
        );
        // Persist computed frame in store (needed for focus-direction)
        var updated = win;
        updated.frame = entry.frame;
        g_store.put(updated) catch {};
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
                win.pid, wid, hide_x, hide_y, hide_w, hide_h,
            );
        }
    }
    old_ws.is_visible = false;

    // Activate target
    g_workspaces.active_id = target_id;
    target_ws.is_visible = true;

    retile();

    // Focus the remembered window on the target workspace
    if (target_ws.focused_wid) |fwid| {
        if (g_store.get(fwid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, fwid);
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
        g_layout_roots[target_idx], wid, g_next_split_dir, g_allocator,
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
                win.pid, wid, hide_x, hide_y, hide_w, hide_h,
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
        if (g_store.get(wid)) |win| {
            _ = shim.bw_ax_focus_window(win.pid, wid);
            ws.focused_wid = wid;
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
    } else {
        ipc.writeResponse(client_fd, "err: unknown command\n");
    }
}

fn ipcQueryWindows(fd: posix.socket_t) void {
    const ws = g_workspaces.active();
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    for (ws.windows.items) |wid| {
        if (g_store.get(wid)) |win| {
            w.print("{d} {d} {d} {d:.0} {d:.0} {d:.0} {d:.0}\n", .{
                win.wid, win.pid, win.workspace_id,
                win.frame.x, win.frame.y, win.frame.width, win.frame.height,
            }) catch break;
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
