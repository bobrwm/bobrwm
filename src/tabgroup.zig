//! Tab group management for native macOS tabbed applications.
//!
//! Apps like Ghostty, Finder, and Safari use native macOS tabs where each tab
//! is a separate AXWindow. Only the active tab per tab group is on-screen;
//! background tabs are tracked here as "suppressed" — present in the window
//! store but excluded from workspace window lists and BSP layout trees.

const std = @import("std");
const WindowId = @import("window.zig").WindowId;

const log = std.log.scoped(.tabgroup);

/// Well-known apps that use native macOS tabs (each tab = separate AXWindow).
pub const builtin_tabbed_apps: []const []const u8 = &.{
    "com.mitchellh.ghostty",
    "com.apple.finder",
};

/// Check if a bundle ID is a known tabbed app (built-in or user config).
pub fn isTabbedApp(bundle_id: []const u8, config_apps: []const []const u8) bool {
    for (builtin_tabbed_apps) |app| {
        if (std.mem.eql(u8, bundle_id, app)) return true;
    }
    for (config_apps) |app| {
        if (std.mem.eql(u8, bundle_id, app)) return true;
    }
    return false;
}

/// Tracks suppressed (background) tab window IDs.
///
/// Suppressed windows live in the WindowStore with a workspace_id but are NOT
/// in any workspace window list or BSP layout tree. When the user switches
/// tabs, the newly active tab is unsuppressed and swapped into the BSP slot
/// of the previously active tab, which becomes suppressed.
pub const TabGroupManager = struct {
    /// Set of window IDs currently suppressed (background tabs).
    suppressed: std.AutoHashMapUnmanaged(WindowId, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TabGroupManager {
        return .{
            .suppressed = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabGroupManager) void {
        self.suppressed.deinit(self.allocator);
    }

    pub fn suppress(self: *TabGroupManager, wid: WindowId) void {
        self.suppressed.put(self.allocator, wid, {}) catch {};
        log.debug("suppressed wid={d}", .{wid});
    }

    pub fn unsuppress(self: *TabGroupManager, wid: WindowId) void {
        _ = self.suppressed.remove(wid);
        log.debug("unsuppressed wid={d}", .{wid});
    }

    pub fn isSuppressed(self: *const TabGroupManager, wid: WindowId) bool {
        return self.suppressed.contains(wid);
    }

    pub fn remove(self: *TabGroupManager, wid: WindowId) void {
        _ = self.suppressed.remove(wid);
    }
};
