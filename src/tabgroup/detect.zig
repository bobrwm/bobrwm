//! Native-tab detection: which window ids belong to one tabbed window, and
//! which of them is on screen.
//!
//! Every decision here is a pure function over a snapshot of OS facts. Nothing
//! in this file touches AX, WindowServer, or Bobrwm's state, so the heuristics
//! can be exercised in tests without a live desktop — which matters because
//! they are heuristics, and the interesting cases (a floating app whose windows
//! stack at identical frames) are the ones that are painful to reproduce by
//! hand. The window manager gathers the snapshot, calls in here, and applies
//! the outcome.

const std = @import("std");
const window_mod = @import("../window.zig");

const WindowId = window_mod.WindowId;
const Frame = window_mod.Window.Frame;

/// Native tabs of one group report the same frame, but CG and AX round
/// independently across process boundaries, so allow a couple of pixels.
pub const frame_tolerance: f64 = 2.0;

pub fn framesMatch(a: Frame, b: Frame) bool {
    return a.approxEqual(b, frame_tolerance);
}

/// A managed window as detection sees it: identity plus the OS facts the
/// heuristics read.
pub const Candidate = struct {
    wid: WindowId,
    pid: i32,
    /// WindowServer bounds. Null when WindowServer no longer knows the window,
    /// which is how a destroyed one looks.
    live_frame: ?Frame,
    /// Workspace-aware: false for a window parked on a hidden workspace, which
    /// is why raw CG on-screen state is not enough on its own.
    is_visible_on_screen: bool,
    /// Whether this window appears in a workspace window list. Suppressed tab
    /// members live only in the store, and must not be mistaken for a window
    /// that owns a slot.
    owns_workspace_slot: bool,
};

/// One window of an application, as reported by its AX window list.
pub const AppWindow = struct {
    wid: WindowId,
    live_frame: ?Frame,
    /// Raw CG on-screen state, without the workspace-visibility adjustment.
    is_on_screen: bool,
    is_managed: bool,
    /// Tabs in this window's own tab bar, from AXTabGroup. Zero when it has
    /// none: a standalone window, or a background tab, since only the selected
    /// tab of a group carries the bar.
    tab_count: usize,
};

/// Whether the app has any native tab group at all — some window of it carries a
/// tab bar with more than one tab.
///
/// This is the gate every tab decision hangs off. Without a bar somewhere in the
/// app, no window of it can be a background tab, so inference must not run: two
/// same-app windows at one frame are then just two windows, which is exactly
/// what a floating app whose windows stack looks like.
pub fn appHasTabGroup(app_windows: []const AppWindow) bool {
    for (app_windows) |app_window| {
        if (app_window.tab_count > 1) return true;
    }
    return false;
}

/// The window showing a tab group's selected tab: the one carrying the bar at
/// `group_frame`.
///
/// Reading this beats remembering it. macOS emits no notification of any kind
/// when the user switches native tabs, so a recorded active tab is stale from
/// that moment, while the bar moves to whichever window is selected.
///
/// Only an on-screen window qualifies: the window showing a tab is on screen by
/// definition, and without that a minimized window of another group at the same
/// frame makes the answer look ambiguous when it is not. Still declines when two
/// on-screen groups share a frame, since nothing then says which is which.
pub fn selectedTabWindow(app_windows: []const AppWindow, group_frame: Frame) ?WindowId {
    var found: ?WindowId = null;
    for (app_windows) |app_window| {
        if (app_window.tab_count <= 1) continue;
        if (!app_window.is_on_screen) continue;

        const live = app_window.live_frame orelse continue;
        if (!framesMatch(live, group_frame)) continue;

        if (found != null) return null;
        found = app_window.wid;
    }
    return found;
}

// ── New or newly-focused window ──────────────────────────────────────────────

pub const NewWindowOutcome = union(enum) {
    /// Nothing looks like a tab sibling; manage it as its own window.
    standalone,
    /// The named managed window just moved into the background at this
    /// window's frame, so the new window is a tab of that window's group.
    tab_of: WindowId,
};

/// Decide whether a window that just appeared — created, or focused while
/// unknown — is a native tab of an already-managed window.
///
/// A candidate qualifies when it belongs to the same app, is no longer visible,
/// owns a workspace slot, and WindowServer still puts it at the new window's
/// frame, since native tabs of one group share their window's frame.
///
/// `app_has_tab_group` gates the whole decision: with no tab bar anywhere in the
/// app there is nothing for the window to be a tab of, however well the frames
/// line up. That is what keeps a floating app whose windows stack at identical
/// frames from reading as a tab transition.
pub fn classifyNewWindow(
    pid: i32,
    new_wid: WindowId,
    new_frame: Frame,
    candidates: []const Candidate,
    app_has_tab_group: bool,
) NewWindowOutcome {
    if (!app_has_tab_group) return .standalone;
    if (new_frame.width <= 1 or new_frame.height <= 1) return .standalone;

    for (candidates) |candidate| {
        if (candidate.wid == new_wid) continue;
        if (candidate.pid != pid) continue;
        if (!candidate.owns_workspace_slot) continue;
        if (candidate.is_visible_on_screen) continue;

        const live = candidate.live_frame orelse continue;
        if (!framesMatch(new_frame, live)) continue;

        return .{ .tab_of = candidate.wid };
    }

    return .standalone;
}

/// A managed window of `pid` that is on screen at `frame`. Used both to veto
/// tab inference and to locate the active tab an off-screen window sits behind.
pub fn findVisibleSiblingAtFrame(
    pid: i32,
    exclude_wid: WindowId,
    frame: Frame,
    candidates: []const Candidate,
) ?WindowId {
    for (candidates) |candidate| {
        if (candidate.wid == exclude_wid) continue;
        if (candidate.pid != pid) continue;
        if (!candidate.is_visible_on_screen) continue;

        const live = candidate.live_frame orelse continue;
        if (!framesMatch(live, frame)) continue;

        return candidate.wid;
    }
    return null;
}

/// Managed windows of `pid` that WindowServer no longer knows: ghost store
/// entries the caller should reap. Collected separately from the decision above
/// so that stays a pure choice. Returns the number written to `out`.
pub fn staleCandidates(pid: i32, candidates: []const Candidate, out: []WindowId) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (count == out.len) break;
        if (candidate.pid != pid) continue;
        if (!candidate.owns_workspace_slot) continue;
        if (candidate.is_visible_on_screen) continue;
        if (candidate.live_frame != null) continue;

        out[count] = candidate.wid;
        count += 1;
    }
    return count;
}

// ── Off-screen managed window found by cleanup ───────────────────────────────

/// The action an off-screen managed window needs, without the payload — what a
/// caller reports back once it has applied the decision.
pub const OffscreenOutcomeKind = enum { keep, reap, adopt };

pub const OffscreenOutcome = union(enum) {
    /// Leave it alone: the app still exposes it, so it is a live window that is
    /// merely not on screen, not a ghost and not a tab.
    keep,
    /// Nothing claims it; the caller should remove it.
    reap,
    /// It is a background tab of the named window's group.
    adopt_into: WindowId,
};

/// Decide what to do with a managed window that cleanup found off-screen on a
/// visible workspace.
///
/// Tab inference happens at creation and focus time; when that is missed — event
/// races, mid-animation bounds, events dropped during a workspace transition — a
/// background tab remains managed as a standalone window that is now off-screen,
/// and reaping it would lose the tab.
///
/// `listed_in_app` is whether the app still exposes the window in `AXWindows`.
/// Being listed rules a window *out* as a background tab: macOS drops background
/// tabs from that list, which is measurable by arithmetic — a five-tab group
/// contributes exactly one listed window, and the other four tabs' titles appear
/// nowhere in it.
pub fn classifyOffscreenManaged(
    wid: WindowId,
    pid: i32,
    live_frame: ?Frame,
    listed_in_app: bool,
    app_has_tab_group: bool,
    candidates: []const Candidate,
) OffscreenOutcome {
    if (listed_in_app) return .keep;

    const frame = live_frame orelse return .reap;
    if (!app_has_tab_group) return .reap;

    const sibling = findVisibleSiblingAtFrame(pid, wid, frame, candidates) orelse return .reap;
    return .{ .adopt_into = sibling };
}

// ── Existing member drifting away from its group ─────────────────────────────

pub const MemberOutcome = enum {
    /// Still a tab of the group.
    keep,
    /// Dragged out of the tab bar into a window of its own.
    promote_to_standalone,
};

/// Decide whether a suppressed member has been torn out of its tab group.
/// Bounds that diverge from the group's frame while the window is on screen are
/// the drag-out signal; a member that is still off-screen has simply not been
/// placed.
pub fn classifyMember(
    live_frame: ?Frame,
    canonical_frame: Frame,
    is_visible_on_screen: bool,
) MemberOutcome {
    const frame = live_frame orelse return .keep;
    if (framesMatch(frame, canonical_frame)) return .keep;
    if (!is_visible_on_screen) return .keep;
    return .promote_to_standalone;
}

// ── Active tab after a member is removed ─────────────────────────────────────

/// The member that should become active after one is removed.
///
/// Removal picks a surviving member arbitrarily, but macOS selects the adjacent
/// tab, so prefer whatever the app itself reports as focused. Returns null when
/// the app's focused window is not a member, leaving the caller's guess in
/// place until the next focus notification corrects it.
pub fn activeAfterRemoval(app_focused_wid: ?WindowId, members: []const WindowId) ?WindowId {
    const focused = app_focused_wid orelse return null;
    for (members) |member| {
        if (member == focused) return focused;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const tiled_left: Frame = .{ .x = 0, .y = 0, .width = 400, .height = 800 };
const tiled_right: Frame = .{ .x = 400, .y = 0, .width = 400, .height = 800 };

fn managed(wid: WindowId, frame: Frame, visible: bool) Candidate {
    return .{
        .wid = wid,
        .pid = 100,
        .live_frame = frame,
        .is_visible_on_screen = visible,
        .owns_workspace_slot = true,
    };
}

/// An app window carrying a tab bar of `tabs` tabs.
fn appWin(wid: WindowId, frame: ?Frame, tabs: usize) AppWindow {
    return .{ .wid = wid, .live_frame = frame, .is_on_screen = true, .is_managed = true, .tab_count = tabs };
}

test "appHasTabGroup: only a bar with more than one tab counts" {
    try testing.expect(!appHasTabGroup(&[_]AppWindow{}));
    try testing.expect(!appHasTabGroup(&[_]AppWindow{ appWin(1, tiled_left, 0), appWin(2, tiled_left, 1) }));
    try testing.expect(appHasTabGroup(&[_]AppWindow{ appWin(1, tiled_left, 0), appWin(2, tiled_left, 2) }));
}

test "selectedTabWindow: the window carrying the bar at that frame" {
    const app_windows = [_]AppWindow{ appWin(1, tiled_left, 0), appWin(2, tiled_left, 3), appWin(3, tiled_right, 2) };
    try testing.expectEqual(@as(?WindowId, 2), selectedTabWindow(&app_windows, tiled_left));
    try testing.expectEqual(@as(?WindowId, 3), selectedTabWindow(&app_windows, tiled_right));
}

test "selectedTabWindow: declines when two on-screen groups share a frame" {
    const app_windows = [_]AppWindow{ appWin(2, tiled_left, 3), appWin(4, tiled_left, 2) };
    try testing.expectEqual(@as(?WindowId, null), selectedTabWindow(&app_windows, tiled_left));
}

test "selectedTabWindow: an off-screen group at the same frame is not a rival" {
    // A minimized window of another group reports the same frame; it cannot be
    // the window showing a tab, so it must not make the answer ambiguous.
    var minimized = appWin(4, tiled_left, 2);
    minimized.is_on_screen = false;
    const app_windows = [_]AppWindow{ appWin(2, tiled_left, 3), minimized };
    try testing.expectEqual(@as(?WindowId, 2), selectedTabWindow(&app_windows, tiled_left));
}

test "classifyNewWindow: a window replacing an off-screen sibling is its tab" {
    const candidates = [_]Candidate{managed(1, tiled_left, false)};
    const outcome = classifyNewWindow(100, 2, tiled_left, &candidates, true);
    try testing.expectEqual(@as(WindowId, 1), outcome.tab_of);
}

test "classifyNewWindow: no tab bar in the app means no tab, however the frames line up" {
    // The fix: this is the stacked floating case. Window 1 sits off-screen at
    // exactly the new window's frame, which used to be enough to group them.
    const candidates = [_]Candidate{managed(1, tiled_left, false)};
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, tiled_left, &candidates, false));
}

test "classifyNewWindow: a stacked floating app is never grouped" {
    // Several same-pid windows at pixel-identical frames, no tab bar anywhere:
    // a Ghostty-style sessionizer. Previously the on-screen sibling veto had to
    // catch this, and it also blocked real tabs; now the gate decides.
    const candidates = [_]Candidate{
        managed(1, tiled_left, false),
        managed(3, tiled_left, true),
        managed(4, tiled_left, true),
    };
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, tiled_left, &candidates, false));
}

test "classifyNewWindow: a real tab is found even with siblings stacked at its frame" {
    // The case the old veto got wrong: the app does have a tab bar, window 1
    // really did drop out of view at this frame, and unrelated on-screen windows
    // 3 and 4 share it. The tab must still be recognised.
    const candidates = [_]Candidate{
        managed(1, tiled_left, false),
        managed(3, tiled_left, true),
        managed(4, tiled_left, true),
    };
    const outcome = classifyNewWindow(100, 2, tiled_left, &candidates, true);
    try testing.expectEqual(@as(WindowId, 1), outcome.tab_of);
}

test "classifyNewWindow: a different app at the same frame is not a tab" {
    var other = managed(1, tiled_left, false);
    other.pid = 999;
    const candidates = [_]Candidate{other};
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, tiled_left, &candidates, true));
}

test "classifyNewWindow: a sibling at another frame is not a tab" {
    const candidates = [_]Candidate{managed(1, tiled_right, false)};
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, tiled_left, &candidates, true));
}

test "classifyNewWindow: unsettled bounds never match" {
    const degenerate: Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const candidates = [_]Candidate{managed(1, degenerate, false)};
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, degenerate, &candidates, true));
}

test "classifyNewWindow: a suppressed member does not own a slot to join" {
    var member = managed(1, tiled_left, false);
    member.owns_workspace_slot = false;
    const candidates = [_]Candidate{member};
    try testing.expectEqual(NewWindowOutcome.standalone, classifyNewWindow(100, 2, tiled_left, &candidates, true));
}

test "staleCandidates: collects same-app slots WindowServer forgot" {
    var gone = managed(1, tiled_left, false);
    gone.live_frame = null;
    var other_app = managed(2, tiled_left, false);
    other_app.pid = 999;
    other_app.live_frame = null;

    const candidates = [_]Candidate{ gone, other_app, managed(3, tiled_left, false) };
    var out: [4]WindowId = undefined;
    const count = staleCandidates(100, &candidates, &out);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(WindowId, 1), out[0]);
}

test "classifyOffscreenManaged: adopts a window the app has dropped from AXWindows" {
    const candidates = [_]Candidate{managed(3, tiled_left, true)};
    const outcome = classifyOffscreenManaged(1, 100, tiled_left, false, true, &candidates);
    try testing.expectEqual(@as(WindowId, 3), outcome.adopt_into);
}

test "classifyOffscreenManaged: a still-listed window is left alone" {
    // Being listed rules it out as a background tab, and reaping a live window
    // the app still exposes would lose it.
    const candidates = [_]Candidate{managed(3, tiled_left, true)};
    try testing.expectEqual(OffscreenOutcome.keep, classifyOffscreenManaged(1, 100, tiled_left, true, true, &candidates));
}

test "classifyOffscreenManaged: reaps when the app has no tab group" {
    // An Electron window that closed to background: nothing for it to be a tab of.
    const candidates = [_]Candidate{managed(3, tiled_left, true)};
    try testing.expectEqual(OffscreenOutcome.reap, classifyOffscreenManaged(1, 100, tiled_left, false, false, &candidates));
}

test "classifyOffscreenManaged: reaps when no sibling occupies the frame" {
    const candidates = [_]Candidate{managed(3, tiled_right, true)};
    try testing.expectEqual(OffscreenOutcome.reap, classifyOffscreenManaged(1, 100, tiled_left, false, true, &candidates));
}

test "classifyOffscreenManaged: reaps a window WindowServer forgot" {
    const candidates = [_]Candidate{managed(3, tiled_left, true)};
    try testing.expectEqual(OffscreenOutcome.reap, classifyOffscreenManaged(1, 100, null, false, true, &candidates));
}

test "classifyMember: diverged bounds while on screen is a drag-out" {
    try testing.expectEqual(MemberOutcome.promote_to_standalone, classifyMember(tiled_right, tiled_left, true));
    try testing.expectEqual(MemberOutcome.keep, classifyMember(tiled_right, tiled_left, false));
    try testing.expectEqual(MemberOutcome.keep, classifyMember(tiled_left, tiled_left, true));
    try testing.expectEqual(MemberOutcome.keep, classifyMember(null, tiled_left, true));
}

test "activeAfterRemoval: prefers the app's focused window when it is a member" {
    const members = [_]WindowId{ 1, 2, 3 };
    try testing.expectEqual(@as(?WindowId, 2), activeAfterRemoval(2, &members));
    try testing.expectEqual(@as(?WindowId, null), activeAfterRemoval(9, &members));
    try testing.expectEqual(@as(?WindowId, null), activeAfterRemoval(null, &members));
}
