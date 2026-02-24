const std = @import("std");
const log = std.log.scoped(.skylight);

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const CGPoint = extern struct {
    x: f64,
    y: f64,
};

pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

pub const SkyLight = struct {
    handle: *anyopaque,
    mainConnectionID: *const fn () callconv(.c) c_int,
    getWindowBounds: *const fn (c_int, u32, *CGRect) callconv(.c) c_int,

    pub fn init() ?SkyLight {
        var lib = std.DynLib.open("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") catch {
            log.err("failed to load SkyLight.framework", .{});
            return null;
        };

        const conn_id = lib.lookup(
            *const fn () callconv(.c) c_int,
            "SLSMainConnectionID",
        ) orelse {
            log.err("failed to resolve SLSMainConnectionID", .{});
            lib.close();
            return null;
        };

        const get_bounds = lib.lookup(
            *const fn (c_int, u32, *CGRect) callconv(.c) c_int,
            "SLSGetWindowBounds",
        ) orelse {
            log.err("failed to resolve SLSGetWindowBounds", .{});
            lib.close();
            return null;
        };

        log.info("SkyLight.framework loaded", .{});

        return SkyLight{
            .handle = lib.inner.handle,
            .mainConnectionID = conn_id,
            .getWindowBounds = get_bounds,
        };
    }
};
