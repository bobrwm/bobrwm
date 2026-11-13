//! Root of the unit test binary: every file with tests is imported here.
//! Not src/main.zig, because its `export fn`s pull in the Swift side, which
//! only exists in the app link.

const std = @import("std");

test {
    // Anything a passing test logs below error turns into noise in
    // `zig build test`; Ghostty quiets it the same way.
    std.testing.log_level = .err;
    _ = @import("app_queue.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("config_apply.zig");
    _ = @import("config_format.zig");
    _ = @import("config_json.zig");
    _ = @import("config_layer.zig");
    _ = @import("config_load.zig");
    _ = @import("config_lua.zig");
    _ = @import("config_watch.zig");
    _ = @import("dim.zig");
    _ = @import("focus_follows_mouse.zig");
    _ = @import("geometry.zig");
    _ = @import("ipc.zig");
    _ = @import("logging.zig");
    _ = @import("lua_sandbox.zig");
    _ = @import("os_log.zig");
    _ = @import("osutil.zig");
    _ = @import("skylight.zig");
    _ = @import("space.zig");
    _ = @import("spsc_queue.zig");
    _ = @import("state.zig");
    _ = @import("statusbar.zig");
    _ = @import("swipe.zig");
    _ = @import("tabgroup.zig");
    _ = @import("tabgroup/detect.zig");
    _ = @import("tiling.zig");
    _ = @import("trace.zig");
    _ = @import("watchdog.zig");
    _ = @import("window_server.zig");
}
