#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <float.h>
#import "shim.h"

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

void bw_ax_prompt(void) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

// ---------------------------------------------------------------------------
// NSWorkspace observer
// ---------------------------------------------------------------------------

@interface BWObserver : NSObject
@end

static CFAbsoluteTime g_last_space_changed_at = 0;
static CFAbsoluteTime g_last_display_changed_at = 0;

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    pid_t pid = app.processIdentifier;
    bw_emit_event(BW_EVENT_APP_LAUNCHED, pid, 0);

    // Heavy apps (Electron/Discord) may not have a ready AX interface when
    // the launch notification fires. Re-emit after a delay so bw_observe_app
    // and discoverWindows get a second chance. The handler is idempotent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        bw_emit_event(BW_EVENT_APP_LAUNCHED, pid, 0);
    });
}

- (void)appTerminated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    bw_emit_event(BW_EVENT_APP_TERMINATED, app.processIdentifier, 0);
}

- (void)spaceChanged:(NSNotification *)note {
(void)note;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_last_space_changed_at != 0 && fabs(now - g_last_space_changed_at) < 0.05) {
        return;
    }
    g_last_space_changed_at = now;
bw_emit_event(BW_EVENT_SPACE_CHANGED, 0, 0);
}

- (void)displayChanged:(NSNotification *)note {
    (void)note;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_last_display_changed_at != 0 && fabs(now - g_last_display_changed_at) < 0.05) {
        return;
    }
    g_last_display_changed_at = now;
    bw_emit_event(BW_EVENT_DISPLAY_CHANGED, 0, 0);
}

- (void)activeAppChanged:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app) {
        bw_emit_event(BW_EVENT_WINDOW_FOCUSED, app.processIdentifier, 0);
    }
}

@end

// ---------------------------------------------------------------------------
// Hotkey engine (CGEventTap)
// ---------------------------------------------------------------------------

static CFMachPortRef g_tap_port = NULL;
static CFRunLoopRef g_observer_runloop = NULL;
static dispatch_source_t g_ipc_source = NULL;
static dispatch_source_t g_role_poll_source = NULL;
static dispatch_source_t g_observe_retry_source = NULL;
static dispatch_source_t g_window_scan_source = NULL;
static NSPanel *g_tile_preview_panel = nil;

// Configurable keybind table (set from Zig via bw_set_keybinds)
#define MAX_KEYBINDS 128
static bw_keybind g_keybinds[MAX_KEYBINDS];
static uint32_t   g_keybind_count = 0;

void bw_set_keybinds(const bw_keybind *binds, uint32_t count) {
    if (count > MAX_KEYBINDS) count = MAX_KEYBINDS;
    memcpy(g_keybinds, binds, count * sizeof(bw_keybind));
    g_keybind_count = count;
}

static CGEventRef hotkey_callback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (g_tap_port) CGEventTapEnable(g_tap_port, true);
        return event;
    }

    if (type == kCGEventLeftMouseDown) {
        bw_emit_event(BW_EVENT_MOUSE_DOWN, 0, 0);
        return event;
    }
    if (type == kCGEventLeftMouseUp) {
        bw_emit_event(BW_EVENT_MOUSE_UP, 0, 0);
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode);

    uint8_t current_mods = 0;
    if (flags & kCGEventFlagMaskAlternate) current_mods |= BW_MOD_ALT;
    if (flags & kCGEventFlagMaskShift)     current_mods |= BW_MOD_SHIFT;
    if (flags & kCGEventFlagMaskCommand)   current_mods |= BW_MOD_CMD;
    if (flags & kCGEventFlagMaskControl)   current_mods |= BW_MOD_CTRL;

    for (uint32_t i = 0; i < g_keybind_count; i++) {
        if (g_keybinds[i].keycode == keycode && g_keybinds[i].mods == current_mods) {
            bw_emit_event(g_keybinds[i].action, 0, g_keybinds[i].arg);
            return NULL;
        }
    }

    return event;
}

// ---------------------------------------------------------------------------
// Waker — CFRunLoopSource to drain the event ring on the main thread
// ---------------------------------------------------------------------------

static CFRunLoopSourceRef g_waker_source = NULL;

static void waker_perform(void *info) {
    (void)info;
    bw_drain_events();
}

void bw_signal_waker(void) {
    if (g_waker_source) CFRunLoopSourceSignal(g_waker_source);
    CFRunLoopRef rl = CFRunLoopGetMain();
    if (rl) CFRunLoopWakeUp(rl);
}

// ---------------------------------------------------------------------------
// Tiling destination preview overlay
// ---------------------------------------------------------------------------

static NSRect bw_ns_rect_from_cg(double x, double y, double w, double h) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) {
        return NSMakeRect(x, y, w, h);
    }

    double global_top = -DBL_MAX;
    for (NSScreen *screen in screens) {
        const NSRect frame = screen.frame;
        const double top = frame.origin.y + frame.size.height;
        if (top > global_top) global_top = top;
    }
    const double ns_y = global_top - (y + h);
    return NSMakeRect(x, ns_y, w, h);
}

static NSPanel *bw_tile_preview_panel(void) {
    if (g_tile_preview_panel) return g_tile_preview_panel;

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 100, 100)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.level = NSStatusWindowLevel + 1;
    panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient;

    NSView *content = [[NSView alloc] initWithFrame:panel.contentView.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    content.wantsLayer = YES;
    content.layer.cornerRadius = 10.0;
    content.layer.borderWidth = 3.0;
    content.layer.borderColor =
        [[NSColor colorWithSRGBRed:0.13 green:0.62 blue:1.0 alpha:0.95] CGColor];
    content.layer.backgroundColor =
        [[NSColor colorWithSRGBRed:0.13 green:0.62 blue:1.0 alpha:0.18] CGColor];
    panel.contentView = content;

    g_tile_preview_panel = panel;
    return g_tile_preview_panel;
}

void bw_show_tile_preview(double x, double y, double w, double h) {
    if (w <= 0 || h <= 0) return;
    NSPanel *panel = bw_tile_preview_panel();
    const NSRect frame = bw_ns_rect_from_cg(x, y, w, h);
    [panel setFrame:frame display:YES];
    [panel orderFront:nil];
}

void bw_hide_tile_preview(void) {
    if (!g_tile_preview_panel) return;
    [g_tile_preview_panel orderOut:nil];
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

@interface BWStatusBarDelegate : NSObject
- (void)retile:(id)sender;
- (void)quit:(id)sender;
@end

@implementation BWStatusBarDelegate

- (void)retile:(id)sender {
    (void)sender;
    bw_retile();
}

- (void)quit:(id)sender {
    (void)sender;
    bw_will_quit();
    [NSApp terminate:nil];
}

@end

// ---------------------------------------------------------------------------
// Source setup (observers, waker, IPC)
// ---------------------------------------------------------------------------

void bw_setup_sources(int ipc_fd) {
    // --- CGEventTap for global hotkeys (main run loop) ---
    CGEventMask mask = (1 << kCGEventKeyDown) |
                       (1 << kCGEventLeftMouseDown) |
                       (1 << kCGEventLeftMouseUp);
    g_tap_port = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        hotkey_callback,
        NULL);

    if (g_tap_port) {
        CFRunLoopSourceRef tap_source =
            CFMachPortCreateRunLoopSource(NULL, g_tap_port, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), tap_source,
                         kCFRunLoopCommonModes);
        CFRelease(tap_source);
        CGEventTapEnable(g_tap_port, true);
    }

    // --- Observer run loop (AX observers use this) ---
    g_observer_runloop = CFRunLoopGetMain();

    // --- Waker source (drains event ring on main thread) ---
    CFRunLoopSourceContext ctx = {0};
    ctx.perform = waker_perform;
    g_waker_source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_waker_source,
                      kCFRunLoopCommonModes);

    // --- IPC dispatch source ---
    if (g_ipc_source) {
        dispatch_source_cancel(g_ipc_source);
        g_ipc_source = NULL;
    }

    if (g_role_poll_source) {
        dispatch_source_cancel(g_role_poll_source);
        g_role_poll_source = NULL;
    }

    if (g_observe_retry_source) {
        dispatch_source_cancel(g_observe_retry_source);
        g_observe_retry_source = NULL;
    }

    if (g_window_scan_source) {
        dispatch_source_cancel(g_window_scan_source);
        g_window_scan_source = NULL;
    }

    g_ipc_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)ipc_fd, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_ipc_source, ^{
        bw_handle_ipc_client(ipc_fd);
    });
    dispatch_resume(g_ipc_source);
}

void bw_set_role_polling(bool enabled) {
    if (!enabled) {
        if (g_role_poll_source) {
            dispatch_source_cancel(g_role_poll_source);
            g_role_poll_source = NULL;
        }
        return;
    }

    if (g_role_poll_source) return;

    g_role_poll_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!g_role_poll_source) return;

    dispatch_source_set_timer(
        g_role_poll_source,
        dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        100 * NSEC_PER_MSEC,
        20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_role_poll_source, ^{
        bw_emit_event(BW_EVENT_ROLE_POLL_TICK, 0, 0);
    });
    dispatch_resume(g_role_poll_source);
}

// ---------------------------------------------------------------------------
// Private API
// ---------------------------------------------------------------------------

extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *wid);

// ---------------------------------------------------------------------------
// AX helpers
// ---------------------------------------------------------------------------

/// Find the AXUIElementRef for a window by PID + CGWindowID.
/// Caller must CFRelease the result.
static AXUIElementRef find_ax_window(pid_t pid, uint32_t target_wid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return NULL;

    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute, (CFTypeRef *)&windows);
    CFRelease(app);

    if (err != kAXErrorSuccess || !windows) return NULL;

    AXUIElementRef result = NULL;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        uint32_t wid = 0;
        if (_AXUIElementGetWindow(win, &wid) == kAXErrorSuccess &&
            wid == target_wid) {
            result = (AXUIElementRef)CFRetain(win);
            break;
        }
    }

    CFRelease(windows);
    return result;
}

// ---------------------------------------------------------------------------
// Window discovery
// ---------------------------------------------------------------------------

uint32_t bw_discover_windows(bw_window_info *out, uint32_t max_count) {
    CFArrayRef window_list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!window_list) return 0;

    uint32_t count = 0;
    CFIndex total = CFArrayGetCount(window_list);

    for (CFIndex i = 0; i < total && count < max_count; i++) {
        @autoreleasepool {
            CFDictionaryRef info =
                (CFDictionaryRef)CFArrayGetValueAtIndex(window_list, i);

            // Layer filter — only normal windows (layer 0)
            int32_t layer = 0;
            CFNumberRef layer_ref = CFDictionaryGetValue(info, kCGWindowLayer);
            if (layer_ref)
                CFNumberGetValue(layer_ref, kCFNumberSInt32Type, &layer);
            if (layer != 0) continue;

            // Window ID
            uint32_t wid = 0;
            CFNumberRef wid_ref = CFDictionaryGetValue(info, kCGWindowNumber);
            if (!wid_ref) continue;
            CFNumberGetValue(wid_ref, kCFNumberSInt32Type, &wid);

            // Owner PID
            int32_t pid = 0;
            CFNumberRef pid_ref =
                CFDictionaryGetValue(info, kCGWindowOwnerPID);
            if (!pid_ref) continue;
            CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &pid);

            // Activation policy — only regular apps (with dock icon)
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:pid];
            if (!app ||
                app.activationPolicy !=
                    NSApplicationActivationPolicyRegular)
                continue;

            // Bounds
            CGRect bounds = CGRectZero;
            CFDictionaryRef bounds_ref =
                CFDictionaryGetValue(info, kCGWindowBounds);
            if (bounds_ref)
                CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds);
            if (bounds.size.width < 1 || bounds.size.height < 1) continue;

            out[count++] = (bw_window_info){
                .wid = wid,
                .pid = pid,
                .x   = bounds.origin.x,
                .y   = bounds.origin.y,
                .w   = bounds.size.width,
                .h   = bounds.size.height,
            };
        }
    }

    CFRelease(window_list);
    return count;
}

// ---------------------------------------------------------------------------
// AX window operations
// ---------------------------------------------------------------------------

bool bw_ax_set_window_frame(int32_t pid, uint32_t wid,
                            double x, double y, double w, double h) {
    AXUIElementRef win = find_ax_window((pid_t)pid, wid);
    if (!win) return false;

    // Shrink first so the window fits at its new position, then reposition.
    // A second position pass handles the case where the window grew and the
    // initial position was clamped by screen edges.
    CGSize size = { w, h };
    AXValueRef size_val = AXValueCreate(kAXValueTypeCGSize, &size);
    AXUIElementSetAttributeValue(win, kAXSizeAttribute, (CFTypeRef)size_val);
    CFRelease(size_val);

    CGPoint pos = { x, y };
    AXValueRef pos_val = AXValueCreate(kAXValueTypeCGPoint, &pos);
    AXError err = AXUIElementSetAttributeValue(
        win, kAXPositionAttribute, (CFTypeRef)pos_val);
    CFRelease(pos_val);

    CFRelease(win);
    return err == kAXErrorSuccess;
}

bool bw_ax_focus_window(int32_t pid, uint32_t wid) {
    AXUIElementRef win = find_ax_window((pid_t)pid, wid);
    if (!win) return false;

    AXUIElementPerformAction(win, kAXRaiseAction);
    AXUIElementSetAttributeValue(win, kAXMainAttribute, kCFBooleanTrue);
    CFRelease(win);

    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];

    return true;
}

static enum bw_manage_state bw_manage_state_for_window(int32_t pid,
                                                        uint32_t wid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app ||
        app.activationPolicy != NSApplicationActivationPolicyRegular)
        return BW_MANAGE_REJECT;

    // AX element may not be queryable yet for a brand-new window.
    // Mark as pending so callers can retry without silently dropping.
    AXUIElementRef win = find_ax_window((pid_t)pid, wid);
    if (!win) return BW_MANAGE_PENDING;

    CFStringRef role = NULL;
    AXUIElementCopyAttributeValue(win, kAXRoleAttribute, (CFTypeRef *)&role);
    if (!role) {
        CFRelease(win);
        return BW_MANAGE_PENDING;
    }

    const bool is_window = CFEqual(role, kAXWindowRole);
    const bool is_unknown_role = CFEqual(role, kAXUnknownRole);
    CFRelease(role);
    if (!is_window) {
        CFRelease(win);
        return is_unknown_role ? BW_MANAGE_PENDING : BW_MANAGE_REJECT;
    }

    CFStringRef subrole = NULL;
    AXUIElementCopyAttributeValue(win, kAXSubroleAttribute,
                                  (CFTypeRef *)&subrole);
    if (!subrole) {
        CFRelease(win);
        return BW_MANAGE_PENDING;
    }

    const bool is_standard = CFEqual(subrole, kAXStandardWindowSubrole);
    const bool is_unknown_subrole = CFEqual(subrole, kAXUnknownSubrole);
    CFRelease(subrole);

    if (!is_standard && is_unknown_subrole) {
        CFRelease(win);
        return BW_MANAGE_PENDING;
    }

    CFRelease(win);
    return is_standard ? BW_MANAGE_READY : BW_MANAGE_REJECT;
}

bool bw_should_manage_window(int32_t pid, uint32_t wid) {
    const enum bw_manage_state state = bw_manage_state_for_window(pid, wid);
    return state != BW_MANAGE_REJECT;
}

uint8_t bw_window_manage_state(int32_t pid, uint32_t wid) {
    return (uint8_t)bw_manage_state_for_window(pid, wid);
}

uint32_t bw_ax_get_focused_window(int32_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication((pid_t)pid);
    if (!app) return 0;

    AXUIElementRef focused = NULL;
    AXError err = AXUIElementCopyAttributeValue(
        app, kAXFocusedWindowAttribute, (CFTypeRef *)&focused);
    CFRelease(app);

    if (err != kAXErrorSuccess || !focused) return 0;

    uint32_t wid = 0;
    _AXUIElementGetWindow(focused, &wid);
    CFRelease(focused);
    return wid;
}

// ---------------------------------------------------------------------------
// On-screen check (tab detection)
// ---------------------------------------------------------------------------

bool bw_is_window_on_screen(uint32_t target_wid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return false;

    bool found = false;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info =
            (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef wid_ref = CFDictionaryGetValue(info, kCGWindowNumber);
        if (!wid_ref) continue;
        uint32_t wid = 0;
        CFNumberGetValue(wid_ref, kCFNumberSInt32Type, &wid);
        if (wid == target_wid) { found = true; break; }
    }

    CFRelease(list);
    return found;
}

// ---------------------------------------------------------------------------
// AX window enumeration (includes background tabs)
// ---------------------------------------------------------------------------

uint32_t bw_get_app_window_ids(int32_t pid, uint32_t *out,
                                uint32_t max_count) {
    AXUIElementRef app = AXUIElementCreateApplication((pid_t)pid);
    if (!app) return 0;

    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute, (CFTypeRef *)&windows);
    CFRelease(app);

    if (err != kAXErrorSuccess || !windows) return 0;

    uint32_t count = 0;
    CFIndex total = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < total && count < max_count; i++) {
        AXUIElementRef win =
            (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        uint32_t wid = 0;
        if (_AXUIElementGetWindow(win, &wid) == kAXErrorSuccess && wid != 0) {
            out[count++] = wid;
        }
    }

    CFRelease(windows);
    return count;
}

// ---------------------------------------------------------------------------
// Per-app AX observers
// ---------------------------------------------------------------------------

#define MAX_OBSERVED_APPS 128
#define MAX_KNOWN_WINDOWS_PER_APP 256
#define BW_OBSERVE_RETRY_INTERVAL_MS 500
#define BW_OBSERVE_RETRY_ATTEMPTS 40
#define BW_WINDOW_SCAN_INTERVAL_MS 500
#define BW_WINDOW_SCAN_IDLE_LIMIT 10
#define BW_WID_RETRY_DELAY_MS 50
#define BW_WID_RETRY_ATTEMPTS 60

typedef struct {
    pid_t pid;
    AXObserverRef observer;
    uint32_t known_window_count;
    uint32_t known_windows[MAX_KNOWN_WINDOWS_PER_APP];
} bw_app_observer_entry;

typedef struct {
    pid_t pid;
    uint8_t attempts_remaining;
} bw_observe_retry_entry;

static bw_app_observer_entry g_app_observers[MAX_OBSERVED_APPS];
static uint32_t g_app_observer_count = 0;
static bw_observe_retry_entry g_observe_retry_entries[MAX_OBSERVED_APPS];
static uint32_t g_observe_retry_count = 0;
static uint32_t g_window_scan_idle_ticks = 0;

static bool bw_try_observe_app(pid_t pid);
static void process_window_scan_tick(void);
static void update_window_scan_source(void);

static int32_t app_observer_index(pid_t pid) {
    for (uint32_t i = 0; i < g_app_observer_count; i++) {
        if (g_app_observers[i].pid == pid) return (int32_t)i;
    }
    return -1;
}

static bool app_track_window(pid_t pid, uint32_t wid) {
    if (wid == 0) return false;

    const int32_t index = app_observer_index(pid);
    if (index < 0) return false;

    bw_app_observer_entry *entry = &g_app_observers[(uint32_t)index];
    for (uint32_t i = 0; i < entry->known_window_count; i++) {
        if (entry->known_windows[i] == wid) return false;
    }

    if (entry->known_window_count < MAX_KNOWN_WINDOWS_PER_APP) {
        entry->known_windows[entry->known_window_count++] = wid;
        return true;
    }

    // Preserve progress when an app has unusually many windows.
    entry->known_windows[entry->known_window_count - 1] = wid;
    return true;
}

static void app_untrack_window(pid_t pid, uint32_t wid) {
    if (wid == 0) return;

    const int32_t index = app_observer_index(pid);
    if (index < 0) return;

    bw_app_observer_entry *entry = &g_app_observers[(uint32_t)index];
    for (uint32_t i = 0; i < entry->known_window_count; i++) {
        if (entry->known_windows[i] != wid) continue;
        entry->known_windows[i] = entry->known_windows[entry->known_window_count - 1];
        entry->known_window_count--;
        return;
    }
}

static bool app_observer_exists(pid_t pid) {
    return app_observer_index(pid) >= 0;
}

static int32_t observe_retry_index(pid_t pid) {
    for (uint32_t i = 0; i < g_observe_retry_count; i++) {
        if (g_observe_retry_entries[i].pid == pid) return (int32_t)i;
    }
    return -1;
}

static void observe_retry_remove_index(uint32_t index) {
    if (index >= g_observe_retry_count) return;
    g_observe_retry_entries[index] = g_observe_retry_entries[--g_observe_retry_count];
}

static void observe_retry_stop_if_idle(void) {
    if (g_observe_retry_count != 0) return;
    if (!g_observe_retry_source) return;
    dispatch_source_cancel(g_observe_retry_source);
    g_observe_retry_source = NULL;
}

static void process_observe_retry_tick(void) {
    uint32_t i = 0;
    while (i < g_observe_retry_count) {
        bw_observe_retry_entry *entry = &g_observe_retry_entries[i];

        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:entry->pid];
        if (!app || app.terminated) {
            observe_retry_remove_index(i);
            continue;
        }

        if (app_observer_exists(entry->pid)) {
            observe_retry_remove_index(i);
            continue;
        }

        if (bw_try_observe_app(entry->pid)) {
            observe_retry_remove_index(i);
            continue;
        }

        if (entry->attempts_remaining == 0) {
            observe_retry_remove_index(i);
            continue;
        }
        entry->attempts_remaining--;
        i++;
    }

    observe_retry_stop_if_idle();
}

static void schedule_observe_retry(pid_t pid) {
    if (app_observer_exists(pid)) return;

    const int32_t existing = observe_retry_index(pid);
    if (existing >= 0) {
        g_observe_retry_entries[(uint32_t)existing].attempts_remaining =
            BW_OBSERVE_RETRY_ATTEMPTS;
    } else {
        if (g_observe_retry_count >= MAX_OBSERVED_APPS) return;
        g_observe_retry_entries[g_observe_retry_count++] = (bw_observe_retry_entry){
            .pid = pid,
            .attempts_remaining = BW_OBSERVE_RETRY_ATTEMPTS,
        };
    }

    if (g_observe_retry_source) return;

    g_observe_retry_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!g_observe_retry_source) return;

    dispatch_source_set_timer(
        g_observe_retry_source,
        dispatch_time(DISPATCH_TIME_NOW,
                      BW_OBSERVE_RETRY_INTERVAL_MS * NSEC_PER_MSEC),
        BW_OBSERVE_RETRY_INTERVAL_MS * NSEC_PER_MSEC,
        100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_observe_retry_source, ^{
        process_observe_retry_tick();
    });
    dispatch_resume(g_observe_retry_source);
}

static void cancel_observe_retry(pid_t pid) {
    const int32_t index = observe_retry_index(pid);
    if (index < 0) return;
    observe_retry_remove_index((uint32_t)index);
    observe_retry_stop_if_idle();
}

static void update_window_scan_source(void) {
    if (g_app_observer_count == 0) {
        if (g_window_scan_source) {
            dispatch_source_cancel(g_window_scan_source);
            g_window_scan_source = NULL;
        }
        return;
    }

    if (g_window_scan_source) return;

    g_window_scan_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!g_window_scan_source) return;

    dispatch_source_set_timer(
        g_window_scan_source,
        dispatch_time(DISPATCH_TIME_NOW,
                      BW_WINDOW_SCAN_INTERVAL_MS * NSEC_PER_MSEC),
        BW_WINDOW_SCAN_INTERVAL_MS * NSEC_PER_MSEC,
        100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_window_scan_source, ^{
        process_window_scan_tick();
    });
    dispatch_resume(g_window_scan_source);
}

// Pack pid (low 32) + wid (high 32) into a single pointer-sized refcon.
// Per-window notifications store the wid at registration time so it's
// available when the element is already invalid (e.g. destroyed).
static inline void *pack_refcon(pid_t pid, uint32_t wid) {
    return (void *)(((uint64_t)wid << 32) | (uint32_t)pid);
}

static inline pid_t refcon_pid(void *refcon) {
    return (pid_t)(int32_t)((uint64_t)refcon & 0xFFFFFFFF);
}

static inline uint32_t refcon_wid(void *refcon) {
    return (uint32_t)((uint64_t)refcon >> 32);
}

static void register_window_ax_notifications(AXObserverRef observer,
                                              AXUIElementRef window,
                                              pid_t pid) {
    uint32_t wid = 0;
    _AXUIElementGetWindow(window, &wid);
    void *refcon = pack_refcon(pid, wid);

    AXObserverAddNotification(observer, window, kAXMovedNotification, refcon);
    AXObserverAddNotification(observer, window, kAXResizedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXUIElementDestroyedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXWindowMiniaturizedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXWindowDeminiaturizedNotification, refcon);
}

static void process_window_scan_tick(void) {
    bool found_new = false;

    for (uint32_t i = 0; i < g_app_observer_count; i++) {
        const pid_t pid = g_app_observers[i].pid;
        AXObserverRef observer = g_app_observers[i].observer;

        AXUIElementRef app = AXUIElementCreateApplication(pid);
        if (!app) continue;

        CFArrayRef windows = NULL;
        AXError err = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute, (CFTypeRef *)&windows);
        CFRelease(app);

        if (err != kAXErrorSuccess || !windows) continue;

        const CFIndex count = CFArrayGetCount(windows);
        for (CFIndex wi = 0; wi < count; wi++) {
            AXUIElementRef win =
                (AXUIElementRef)CFArrayGetValueAtIndex(windows, wi);
            uint32_t wid = 0;
            _AXUIElementGetWindow(win, &wid);
            if (wid == 0) continue;

            if (!app_track_window(pid, wid)) continue;

            found_new = true;
            register_window_ax_notifications(observer, win, pid);
            bw_emit_event(BW_EVENT_WINDOW_CREATED, (int32_t)pid, wid);
        }

        CFRelease(windows);
    }

    // Stop the repeating scan after consecutive idle ticks to avoid
    // paying the AX enumeration cost forever at steady state.
    if (found_new) {
        g_window_scan_idle_ticks = 0;
    } else {
        g_window_scan_idle_ticks++;
        if (g_window_scan_idle_ticks >= BW_WINDOW_SCAN_IDLE_LIMIT) {
            if (g_window_scan_source) {
                dispatch_source_cancel(g_window_scan_source);
                g_window_scan_source = NULL;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Deferred wid resolution — retry when CGWindowID is not yet assigned
// ---------------------------------------------------------------------------

typedef struct {
    AXObserverRef observer;
    AXUIElementRef element;
    pid_t pid;
    uint8_t attempts_remaining;
} bw_wid_retry_ctx;

static void bw_retry_resolve_wid(void *context);

static void schedule_wid_resolution_retry(AXObserverRef observer,
                                          AXUIElementRef element,
                                          pid_t pid) {
    bw_wid_retry_ctx *ctx = malloc(sizeof(bw_wid_retry_ctx));
    if (!ctx) return;

    ctx->observer = (AXObserverRef)CFRetain(observer);
    ctx->element = (AXUIElementRef)CFRetain(element);
    ctx->pid = pid;
    ctx->attempts_remaining = BW_WID_RETRY_ATTEMPTS;
    dispatch_after_f(
        dispatch_time(DISPATCH_TIME_NOW, BW_WID_RETRY_DELAY_MS * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ctx,
        bw_retry_resolve_wid);
}

static void bw_retry_resolve_wid(void *context) {
    bw_wid_retry_ctx *ctx = (bw_wid_retry_ctx *)context;

    // Bail out if the owning app was unobserved or terminated while this
    // retry was in flight. Without this guard a stale callback can emit
    // WINDOW_CREATED for a pid we no longer track.
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:ctx->pid];
    if (!app_observer_exists(ctx->pid) || !app || app.terminated) {
        CFRelease(ctx->observer);
        CFRelease(ctx->element);
        free(ctx);
        return;
    }

    uint32_t wid = 0;
    _AXUIElementGetWindow(ctx->element, &wid);

    if (wid != 0) {
        const bool is_new_window = app_track_window(ctx->pid, wid);
        if (!is_new_window) {
            CFRelease(ctx->observer);
            CFRelease(ctx->element);
            free(ctx);
            return;
        }
        register_window_ax_notifications(ctx->observer,
                                          ctx->element, ctx->pid);
        bw_emit_event(BW_EVENT_WINDOW_CREATED, ctx->pid, wid);
        CFRelease(ctx->observer);
        CFRelease(ctx->element);
        free(ctx);
        return;
    }

    if (ctx->attempts_remaining == 0) {
        CFRelease(ctx->observer);
        CFRelease(ctx->element);
        free(ctx);
        return;
    }

    ctx->attempts_remaining--;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, BW_WID_RETRY_DELAY_MS * NSEC_PER_MSEC),
                     dispatch_get_main_queue(),
                     ctx, bw_retry_resolve_wid);
}

// ---------------------------------------------------------------------------

static void ax_notification_handler(AXObserverRef observer,
                                    AXUIElementRef element,
                                    CFStringRef notification,
                                    void *refcon) {
    pid_t pid = refcon_pid(refcon);
    uint32_t wid = refcon_wid(refcon);

    if (CFEqual(notification, kAXWindowCreatedNotification)) {
        // App-level: wid is 0 in refcon, resolve from the new element
        _AXUIElementGetWindow(element, &wid);
        if (wid != 0) {
            if (!app_track_window(pid, wid)) return;
            register_window_ax_notifications(observer, element, pid);
            bw_emit_event(BW_EVENT_WINDOW_CREATED, pid, wid);
            return;
        }
        // CGWindowID not assigned yet — schedule retries
        schedule_wid_resolution_retry(observer, element, pid);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        // App-level (wid=0 in refcon): emit so Zig can reconcile tab groups
        bw_emit_event(BW_EVENT_FOCUSED_WINDOW_CHANGED, pid, 0);
    } else if (wid == 0) {
        return; // Per-window notification but wid was unknown at registration
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        app_untrack_window(pid, wid);
        bw_emit_event(BW_EVENT_WINDOW_DESTROYED, pid, wid);
    } else if (CFEqual(notification, kAXMovedNotification)) {
        bw_emit_event(BW_EVENT_WINDOW_MOVED, pid, wid);
    } else if (CFEqual(notification, kAXResizedNotification)) {
        bw_emit_event(BW_EVENT_WINDOW_RESIZED, pid, wid);
    } else if (CFEqual(notification, kAXWindowMiniaturizedNotification)) {
        bw_emit_event(BW_EVENT_WINDOW_MINIMIZED, pid, wid);
    } else if (CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        bw_emit_event(BW_EVENT_WINDOW_DEMINIMIZED, pid, wid);
    }
}

static bool bw_try_observe_app(pid_t pid) {
    if (app_observer_exists(pid)) return true;
    if (g_app_observer_count >= MAX_OBSERVED_APPS) return false;
    if (!g_observer_runloop) return false;

    AXObserverRef observer = NULL;
    AXError err = AXObserverCreate(pid, ax_notification_handler, &observer);
    if (err != kAXErrorSuccess || !observer) return false;

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) {
        CFRelease(observer);
        return false;
    }

    void *app_refcon = pack_refcon(pid, 0);

    // App-level notifications (wid=0 in refcon).
    // If the critical notification fails, the app's AX interface isn't ready.
    AXError add_err = AXObserverAddNotification(
        observer, app, kAXWindowCreatedNotification, app_refcon);
    if (add_err != kAXErrorSuccess) {
        CFRelease(app);
        CFRelease(observer);
        return false;
    }
    AXObserverAddNotification(observer, app,
                              kAXFocusedWindowChangedNotification, app_refcon);

    CFRunLoopAddSource(g_observer_runloop,
                       AXObserverGetRunLoopSource(observer),
                       kCFRunLoopCommonModes);
    CFRunLoopWakeUp(g_observer_runloop);

    g_app_observers[g_app_observer_count++] = (bw_app_observer_entry){
        .pid = pid,
        .observer = observer,
        .known_window_count = 0,
    };
    g_window_scan_idle_ticks = 0;
    update_window_scan_source();

    // Per-window: move, resize, destroy, minimize, deminimize.
    // Also emit WINDOW_CREATED for each pre-existing window so the Zig side
    // can tile windows that were created before the observer was registered.
    CFArrayRef windows = NULL;
    err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                        (CFTypeRef *)&windows);
    if (err == kAXErrorSuccess && windows) {
        CFIndex count = CFArrayGetCount(windows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win =
                (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            uint32_t wid = 0;
            _AXUIElementGetWindow(win, &wid);
            if (wid != 0) {
                if (!app_track_window(pid, wid)) continue;
                register_window_ax_notifications(observer, win, pid);
                bw_emit_event(BW_EVENT_WINDOW_CREATED, (int32_t)pid, wid);
            } else {
                // Some apps expose the AX window before WindowServer assigns
                // a CGWindowID. Retry so this pre-existing window is not lost.
                schedule_wid_resolution_retry(observer, win, pid);
            }
        }
        CFRelease(windows);
    }

    CFRelease(app);
    return true;
}

void bw_observe_app(int32_t pid) {
    if (bw_try_observe_app((pid_t)pid)) {
        cancel_observe_retry((pid_t)pid);
        return;
    }
    schedule_observe_retry((pid_t)pid);
}

void bw_unobserve_app(int32_t pid) {
    cancel_observe_retry((pid_t)pid);
    for (uint32_t i = 0; i < g_app_observer_count; i++) {
        if (g_app_observers[i].pid != (pid_t)pid) continue;
        if (g_observer_runloop) {
            CFRunLoopRemoveSource(
                g_observer_runloop,
                AXObserverGetRunLoopSource(g_app_observers[i].observer),
                kCFRunLoopCommonModes);
        }
        CFRelease(g_app_observers[i].observer);
        g_app_observers[i] = g_app_observers[--g_app_observer_count];
        update_window_scan_source();
        return;
    }
}

// ---------------------------------------------------------------------------
// App identity
// ---------------------------------------------------------------------------

uint32_t bw_get_app_bundle_id(int32_t pid, char *out, uint32_t max_len) {
    @autoreleasepool {
        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
        if (!app || !app.bundleIdentifier) return 0;

        const char *utf8 = [app.bundleIdentifier UTF8String];
        if (!utf8) return 0;

        uint32_t len = (uint32_t)strlen(utf8);
        if (len >= max_len) len = max_len - 1;
        memcpy(out, utf8, len);
        out[len] = '\0';
        return len;
    }
}
