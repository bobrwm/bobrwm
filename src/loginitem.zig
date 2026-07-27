//! Login-item registration through ServiceManagement.
//!
//! SMAppService replaces the LaunchAgent plist bobrwm used to write into
//! ~/Library/LaunchAgents: macOS owns the registration, it appears in System
//! Settings under General > Login Items, and nothing has to be kept in sync
//! with the executable's path when the app moves.
//!
//! Registration is keyed to the enclosing app bundle, so this is inert when
//! the binary runs outside Bobrwm.app.

const std = @import("std");
const objc = @import("objc");

const log = std.log.scoped(.loginitem);

/// SMAppServiceStatus. Non-exhaustive: macOS may add cases.
pub const Status = enum(i64) {
    not_registered = 0,
    enabled = 1,
    requires_approval = 2,
    not_found = 3,
    _,
};

pub fn status() Status {
    const service = mainAppService() orelse return .not_found;
    return @enumFromInt(service.msgSend(i64, "status", .{}));
}

/// Bring the registration in line with `enabled`.
///
/// Called on every config load, so it must stay idempotent: each transition
/// is guarded on current status rather than issued unconditionally.
pub fn reconcile(enabled: bool) void {
    const current = status();

    if (enabled) {
        switch (current) {
            .enabled => return,
            // The user revoked approval in System Settings. Re-registering
            // cannot override that, and retrying on every reload would just
            // spam the log.
            .requires_approval => {
                log.warn("start_at_login is set but the login item awaits approval in System Settings", .{});
                return;
            },
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
    const service = mainAppService() orelse return;
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

fn mainAppService() ?objc.Object {
    const SMAppService = objc.getClass("SMAppService") orelse {
        log.warn("SMAppService unavailable; not managing the login item", .{});
        return null;
    };
    return SMAppService.msgSend(objc.Object, "mainAppService", .{});
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
