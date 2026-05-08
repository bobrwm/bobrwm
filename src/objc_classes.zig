//! Runtime-defined Objective-C classes used by bobrwm.
//!
//! Three BW* classes are registered with the ObjC runtime via zig-objc's
//! `allocateClassPair` / `addMethod` helpers:
//!
//!   - `BWStatusBarDelegate` — Retile / Quit menu actions
//!   - `BWObserver` — NSWorkspace + NSApplication notification target
//!   - `BWLaunchGate` — per-pid KVO gate that defers app-launched events
//!     until the process is finished launching AND has Regular activation
//!     policy (Electron apps need both).
//!
//! Memory management is MRR (no ARC). Every `alloc/init` pair owns a +1
//! retain that we balance manually, and every custom `dealloc` calls
//! `[super dealloc]`.

const std = @import("std");
const objc = @import("objc");
const c = objc.c;

const main = @import("main.zig");

/// `NSWorkspaceApplicationKey` is an `NSString * const` exported by AppKit.
/// Declared `extern var` (not `extern const`) because Zig's `extern const`
/// lowers to a constant in this object's data segment rather than a
/// reference to the framework's exported variable.
extern var NSWorkspaceApplicationKey: c.id;

/// Allocate and register all bobrwm ObjC classes. Must be called before any
/// `objc.getClass("BW…")` lookup (i.e. before `initWorkspaceObservers()`
/// and `statusbar.init()`).
pub fn register(allocator: std.mem.Allocator) void {
    g_launch_gates = .init(allocator);
    registerStatusBarDelegate();
    registerObserver();
    registerLaunchGate();
}

// BWStatusBarDelegate

fn registerStatusBarDelegate() void {
    const NSObject = objc.getClass("NSObject").?;
    var cls = objc.allocateClassPair(NSObject, "BWStatusBarDelegate").?;
    _ = cls.addMethod("retile:", statusBarRetile);
    _ = cls.addMethod("quit:", statusBarQuit);
    objc.registerClassPair(cls);
}

fn statusBarRetile(_: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    main.bw_retile();
}

fn statusBarQuit(_: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    main.bw_will_quit();
    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "terminate:", .{@as(objc.Object, .{ .value = null })});
}

// BWObserver

fn registerObserver() void {
    const NSObject = objc.getClass("NSObject").?;
    var cls = objc.allocateClassPair(NSObject, "BWObserver").?;
    _ = cls.addMethod("appLaunched:", observerAppLaunched);
    _ = cls.addMethod("appTerminated:", observerAppTerminated);
    _ = cls.addMethod("activeAppChanged:", observerActiveAppChanged);
    _ = cls.addMethod("spaceChanged:", observerSpaceChanged);
    _ = cls.addMethod("displayChanged:", observerDisplayChanged);
    objc.registerClassPair(cls);
}

/// Extract the NSRunningApplication from a workspace notification's userInfo.
fn notificationApp(note_id: c.id) objc.Object {
    const note: objc.Object = .{ .value = note_id };
    const user_info = note.msgSend(objc.Object, "userInfo", .{});
    const key: objc.Object = .{ .value = NSWorkspaceApplicationKey };
    return user_info.msgSend(objc.Object, "objectForKey:", .{key});
}

fn observerAppLaunched(_: c.id, _: c.SEL, note_id: c.id) callconv(.c) void {
    const app = notificationApp(note_id);
    const pid = app.msgSend(i32, "processIdentifier", .{});

    const launched = app.msgSend(bool, "isFinishedLaunching", .{});
    const policy = app.msgSend(i64, "activationPolicy", .{});
    if (launched and policy == 0) {
        main.bw_workspace_app_launched(pid);
        return;
    }

    // Otherwise install a per-pid KVO gate that fires once both conditions
    // hold. Keeps premature AX observer registration off the retry budget.
    spawnLaunchGate(app, pid);
}

fn observerAppTerminated(_: c.id, _: c.SEL, note_id: c.id) callconv(.c) void {
    const pid = notificationApp(note_id).msgSend(i32, "processIdentifier", .{});
    dropLaunchGate(pid);
    main.bw_workspace_app_terminated(pid);
}

fn observerActiveAppChanged(_: c.id, _: c.SEL, note_id: c.id) callconv(.c) void {
    const pid = notificationApp(note_id).msgSend(i32, "processIdentifier", .{});
    main.bw_workspace_active_app_changed(pid);
}

fn observerSpaceChanged(_: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    main.bw_workspace_space_changed();
}

fn observerDisplayChanged(_: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    main.bw_workspace_display_changed();
}

// BWLaunchGate

const LaunchGate = struct {
    /// +1 retain on the BWLaunchGate instance. Released in dropLaunchGate.
    gate: objc.Object,
    /// +1 retain on the NSRunningApplication so it stays alive while
    /// observed. Released in dropLaunchGate after removing observers.
    app: objc.Object,
};

/// `pid → LaunchGate`. Holds owning references outside ObjC.
var g_launch_gates: std.AutoHashMap(i32, LaunchGate) = undefined;

fn registerLaunchGate() void {
    const NSObject = objc.getClass("NSObject").?;
    var cls = objc.allocateClassPair(NSObject, "BWLaunchGate").?;
    _ = cls.addMethod(
        "observeValueForKeyPath:ofObject:change:context:",
        launchGateObserveValue,
    );
    _ = cls.addMethod("dealloc", launchGateDealloc);
    objc.registerClassPair(cls);
}

/// Allocate, init, and register a `BWLaunchGate` for `app` (pid). Always
/// observes both keypaths; whichever fires first triggers re-evaluation.
fn spawnLaunchGate(app: objc.Object, pid: i32) void {
    if (g_launch_gates.contains(pid)) return; // already pending

    const BWLaunchGate = objc.getClass("BWLaunchGate").?;
    const gate = BWLaunchGate.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    _ = app.msgSend(objc.Object, "retain", .{});
    g_launch_gates.put(pid, .{ .gate = gate, .app = app }) catch
        @panic("launch-gate map OOM");

    // NSKeyValueObservingOptionNew = 0x01
    const new_only: u64 = 1;
    app.msgSend(void, "addObserver:forKeyPath:options:context:", .{
        gate, nsString("isFinishedLaunching"), new_only, @as(?*anyopaque, null),
    });
    app.msgSend(void, "addObserver:forKeyPath:options:context:", .{
        gate, nsString("activationPolicy"), new_only, @as(?*anyopaque, null),
    });
}

fn launchGateObserveValue(
    _: c.id,
    _: c.SEL,
    _: c.id, // keyPath
    obj_id: c.id,
    _: c.id, // change
    _: ?*anyopaque,
) callconv(.c) void {
    const app: objc.Object = .{ .value = obj_id };
    const finished = app.msgSend(bool, "isFinishedLaunching", .{});
    const policy = app.msgSend(i64, "activationPolicy", .{});
    if (!finished or policy != 0) return;

    const pid = app.msgSend(i32, "processIdentifier", .{});
    main.bw_workspace_app_launched(pid);
    dropLaunchGate(pid);
}

fn launchGateDealloc(self_id: c.id, _: c.SEL) callconv(.c) void {
    // [super dealloc] — Zig-defined classes have no ARC, so this is required.
    const self: objc.Object = .{ .value = self_id };
    self.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
}

/// Tear down the gate for `pid` if any. Safe to call when no gate exists.
fn dropLaunchGate(pid: i32) void {
    const entry = g_launch_gates.fetchRemove(pid) orelse return;
    const gate = entry.value.gate;
    const app = entry.value.app;

    // Detach observers before releasing the app — KVO will crash if the
    // observed object is deallocated with observers still attached.
    app.msgSend(void, "removeObserver:forKeyPath:", .{ gate, nsString("isFinishedLaunching") });
    app.msgSend(void, "removeObserver:forKeyPath:", .{ gate, nsString("activationPolicy") });
    app.msgSend(void, "release", .{});
    gate.msgSend(void, "release", .{});
}

fn nsString(literal: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{literal});
}
