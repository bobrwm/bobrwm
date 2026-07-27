//! Login-item registration through ServiceManagement.
//!
//! Registers the LaunchAgent bundled at
//! `Contents/Library/LaunchAgents/com.bobrwm.bobrwm.plist`, which replaces the
//! plist bobrwm used to hand-write into ~/Library/LaunchAgents: macOS owns the
//! registration, it shows up in System Settings under General > Login Items,
//! and the plist's `BundleProgram` is bundle-relative so nothing breaks when
//! the app moves.
//!
//! Registering an agent rather than the app itself is what keeps launchd
//! supervising the process, so a crash still gets restarted. That supervision
//! only exists while the agent is registered — a manually launched app that
//! never opted into `start_at_login` runs unsupervised.
//!
//! The plist lives in the app bundle, so this is inert when the executable
//! runs outside one.

const std = @import("std");
const objc = @import("objc");

const log = std.log.scoped(.loginitem);

/// Must match the basename installed under Contents/Library/LaunchAgents.
const plist_name = "com.bobrwm.bobrwm.plist";

/// SMAppServiceStatus. Non-exhaustive: macOS may add cases.
pub const Status = enum(i64) {
    not_registered = 0,
    enabled = 1,
    requires_approval = 2,
    not_found = 3,
    _,
};

pub fn status() Status {
    const service = agentService() orelse return .not_found;
    return @enumFromInt(service.msgSend(i64, "status", .{}));
}

/// Bring the registration in line with `enabled`.
///
/// Called on every config load, so it must stay idempotent: each transition is
/// guarded on current status rather than issued unconditionally.
pub fn reconcile(enabled: bool) void {
    const current = status();

    // No service definition to act on: either the executable is running
    // outside Bobrwm.app or the bundle is missing its LaunchAgent. Registering
    // would fail, so say why instead.
    if (current == .not_found) {
        if (enabled) {
            log.warn("start_at_login is set but {s} is not in the app bundle; " ++
                "run bobrwm from Bobrwm.app to manage the login item", .{plist_name});
        }
        return;
    }

    if (enabled) {
        switch (current) {
            .enabled => return,
            // The user denied or revoked approval in System Settings.
            // Re-registering cannot override that, and retrying on every
            // reload would just spam the log.
            .requires_approval => log.warn(
                "start_at_login is set but the login item awaits approval in System Settings",
                .{},
            ),
            else => setRegistered(true),
        }
        return;
    }

    switch (current) {
        .enabled, .requires_approval => setRegistered(false),
        else => return,
    }
}

fn setRegistered(register: bool) void {
    const service = agentService() orelse return;
    const selector = if (register) "registerAndReturnError:" else "unregisterAndReturnError:";

    var err_id: ?*anyopaque = null;
    if (service.msgSend(bool, selector, .{&err_id})) {
        log.info("login item {s}", .{if (register) "registered" else "unregistered"});
        return;
    }

    log.warn("login item {s} failed: {s}", .{
        if (register) "registration" else "removal",
        errorDescription(err_id),
    });
}

fn agentService() ?objc.Object {
    const SMAppService = objc.getClass("SMAppService") orelse {
        log.warn("SMAppService unavailable; not managing the login item", .{});
        return null;
    };
    const NSString = objc.getClass("NSString") orelse return null;
    const name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{plist_name.ptr});

    return SMAppService.msgSend(objc.Object, "agentServiceWithPlistName:", .{name});
}

/// Borrowed description of an NSError out-parameter. The string belongs to the
/// autoreleased error, so callers must consume it before returning.
fn errorDescription(err_id: ?*anyopaque) []const u8 {
    const err = objc.Object.fromId(err_id orelse return "unknown error");
    const description = err.msgSend(objc.Object, "localizedDescription", .{});
    if (description.value == null) return "unknown error";

    const utf8 = description.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return "unknown error";
    return std.mem.sliceTo(utf8, 0);
}
