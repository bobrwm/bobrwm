#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
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

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    pid_t pid = app.processIdentifier;
    bw_emit_event(BW_EVENT_APP_LAUNCHED, pid, 0);

    // Heavy apps (Electron/Discord) may not have a ready AX interface when
    // the launch notification fires. Re-emit after a delay so bw_observe_app
    // and discoverWindows get a second chance. The handler is idempotent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        bw_emit_event(BW_EVENT_APP_LAUNCHED, pid, 0);
    });
}

- (void)appTerminated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    bw_emit_event(BW_EVENT_APP_TERMINATED, app.processIdentifier, 0);
}

- (void)spaceChanged:(NSNotification *)note {
    (void)note;
    bw_emit_event(BW_EVENT_SPACE_CHANGED, 0, 0);
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
    // --- NSWorkspace observers (main run loop) ---
    BWObserver *obs = [[BWObserver alloc] init];
    NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];

    [wsnc addObserver:obs
             selector:@selector(appLaunched:)
                 name:NSWorkspaceDidLaunchApplicationNotification
               object:nil];

    [wsnc addObserver:obs
             selector:@selector(appTerminated:)
                 name:NSWorkspaceDidTerminateApplicationNotification
               object:nil];

    [wsnc addObserver:obs
             selector:@selector(spaceChanged:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
               object:nil];

    [wsnc addObserver:obs
             selector:@selector(activeAppChanged:)
                 name:NSWorkspaceDidActivateApplicationNotification
               object:nil];

    // --- CGEventTap for global hotkeys (main run loop) ---
    CGEventMask mask = (1 << kCGEventKeyDown);
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

    g_ipc_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)ipc_fd, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_ipc_source, ^{
        bw_handle_ipc_client(ipc_fd);
    });
    dispatch_resume(g_ipc_source);
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
// Window discovery (AX-first)
// ---------------------------------------------------------------------------

/// Check if an AX window element has kAXWindowRole + kAXStandardWindowSubrole.
static bool ax_element_is_standard_window(AXUIElementRef win) {
    CFStringRef role = NULL;
    AXUIElementCopyAttributeValue(win, kAXRoleAttribute, (CFTypeRef *)&role);
    if (role) {
        bool is_window = CFEqual(role, kAXWindowRole);
        CFRelease(role);
        if (!is_window) return false;
    }

    CFStringRef subrole = NULL;
    AXUIElementCopyAttributeValue(win, kAXSubroleAttribute,
                                  (CFTypeRef *)&subrole);
    bool is_standard = !subrole || CFEqual(subrole, kAXStandardWindowSubrole);
    if (subrole) CFRelease(subrole);

    return is_standard;
}

/// Get the AX position and size for a window element.
/// Returns false if attributes are unavailable.
static bool ax_element_get_frame(AXUIElementRef win,
                                  double *x, double *y,
                                  double *w, double *h) {
    AXValueRef pos_val = NULL;
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute,
                                  (CFTypeRef *)&pos_val);
    if (!pos_val) return false;
    CGPoint pos;
    AXValueGetValue(pos_val, kAXValueTypeCGPoint, &pos);
    CFRelease(pos_val);

    AXValueRef size_val = NULL;
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute,
                                  (CFTypeRef *)&size_val);
    if (!size_val) return false;
    CGSize size;
    AXValueGetValue(size_val, kAXValueTypeCGSize, &size);
    CFRelease(size_val);

    *x = pos.x;
    *y = pos.y;
    *w = size.width;
    *h = size.height;
    return true;
}

/// Build a set of on-screen CG window IDs for fast membership checks.
/// Caller must CFRelease the returned set (may be NULL on failure).
static CFSetRef copy_on_screen_wid_set(void) {
    CFArrayRef cg_list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!cg_list) return NULL;

    CFIndex total = CFArrayGetCount(cg_list);
    CFMutableSetRef set = CFSetCreateMutable(NULL, (CFIndex)total, NULL);

    for (CFIndex i = 0; i < total; i++) {
        CFDictionaryRef info =
            (CFDictionaryRef)CFArrayGetValueAtIndex(cg_list, i);
        CFNumberRef wid_ref = CFDictionaryGetValue(info, kCGWindowNumber);
        if (!wid_ref) continue;
        uint32_t wid = 0;
        CFNumberGetValue(wid_ref, kCFNumberSInt32Type, &wid);
        CFSetAddValue(set, (const void *)(uintptr_t)wid);
    }

    CFRelease(cg_list);
    return set;
}

uint32_t bw_discover_windows(bw_window_info *out, uint32_t max_count) {
    @autoreleasepool {
        // One CG query to know which windows are actually on screen.
        // Background tabs (native macOS tabs) are NOT on screen.
        CFSetRef on_screen = copy_on_screen_wid_set();

        NSArray<NSRunningApplication *> *apps =
            [[NSWorkspace sharedWorkspace] runningApplications];
        uint32_t count = 0;

        for (NSRunningApplication *app in apps) {
            if (count >= max_count) break;
            if (app.activationPolicy != NSApplicationActivationPolicyRegular)
                continue;

            pid_t pid = app.processIdentifier;
            AXUIElementRef ax_app = AXUIElementCreateApplication(pid);
            if (!ax_app) continue;

            CFArrayRef windows = NULL;
            AXError err = AXUIElementCopyAttributeValue(
                ax_app, kAXWindowsAttribute, (CFTypeRef *)&windows);
            CFRelease(ax_app);

            if (err != kAXErrorSuccess || !windows) continue;

            CFIndex win_count = CFArrayGetCount(windows);
            for (CFIndex i = 0; i < win_count && count < max_count; i++) {
                AXUIElementRef win =
                    (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);

                uint32_t wid = 0;
                _AXUIElementGetWindow(win, &wid);
                if (wid == 0) continue;

                // Skip background tabs / off-screen windows
                if (on_screen &&
                    !CFSetContainsValue(on_screen, (const void *)(uintptr_t)wid))
                    continue;

                if (!ax_element_is_standard_window(win)) continue;

                double x, y, w, h;
                if (!ax_element_get_frame(win, &x, &y, &w, &h)) continue;
                if (w < 1 || h < 1) continue;

                out[count++] = (bw_window_info){
                    .wid = wid,
                    .pid = (int32_t)pid,
                    .x   = x,
                    .y   = y,
                    .w   = w,
                    .h   = h,
                };
            }

            CFRelease(windows);
        }

        if (on_screen) CFRelease(on_screen);
        return count;
    }
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

bool bw_should_manage_window(int32_t pid, uint32_t wid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app ||
        app.activationPolicy != NSApplicationActivationPolicyRegular)
        return false;

    AXUIElementRef win = find_ax_window((pid_t)pid, wid);
    if (!win) return false;

    bool result = ax_element_is_standard_window(win);
    CFRelease(win);
    return result;
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

typedef struct {
    pid_t pid;
    AXObserverRef observer;
} bw_app_observer_entry;

static bw_app_observer_entry g_app_observers[MAX_OBSERVED_APPS];
static uint32_t g_app_observer_count = 0;

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

// ---------------------------------------------------------------------------
// Deferred wid resolution — retry when CGWindowID is not yet assigned
// ---------------------------------------------------------------------------

typedef struct {
    AXObserverRef observer;
    AXUIElementRef element;
    pid_t pid;
    uint8_t attempts_remaining;
} bw_wid_retry_ctx;

static void bw_retry_resolve_wid(void *context) {
    bw_wid_retry_ctx *ctx = (bw_wid_retry_ctx *)context;
    uint32_t wid = 0;
    _AXUIElementGetWindow(ctx->element, &wid);

    if (wid != 0) {
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
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                     dispatch_get_global_queue(0, 0),
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
            register_window_ax_notifications(observer, element, pid);
            bw_emit_event(BW_EVENT_WINDOW_CREATED, pid, wid);
            return;
        }
        // CGWindowID not assigned yet — schedule retries
        bw_wid_retry_ctx *ctx = malloc(sizeof(bw_wid_retry_ctx));
        if (!ctx) return;
        ctx->observer = (AXObserverRef)CFRetain(observer);
        ctx->element = (AXUIElementRef)CFRetain(element);
        ctx->pid = pid;
        ctx->attempts_remaining = 5;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                         dispatch_get_global_queue(0, 0),
                         ctx, bw_retry_resolve_wid);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        // App-level (wid=0 in refcon): emit so Zig can reconcile tab groups
        bw_emit_event(BW_EVENT_FOCUSED_WINDOW_CHANGED, pid, 0);
    } else if (wid == 0) {
        return; // Per-window notification but wid was unknown at registration
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
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

void bw_observe_app(int32_t pid) {
    for (uint32_t i = 0; i < g_app_observer_count; i++) {
        if (g_app_observers[i].pid == (pid_t)pid) return;
    }
    if (g_app_observer_count >= MAX_OBSERVED_APPS) return;
    if (!g_observer_runloop) return;

    AXObserverRef observer = NULL;
    AXError err = AXObserverCreate((pid_t)pid, ax_notification_handler,
                                   &observer);
    if (err != kAXErrorSuccess || !observer) return;

    AXUIElementRef app = AXUIElementCreateApplication((pid_t)pid);
    if (!app) {
        CFRelease(observer);
        return;
    }

    void *app_refcon = pack_refcon((pid_t)pid, 0);

    // App-level notifications (wid=0 in refcon).
    // If the critical notification fails, the app's AX interface isn't ready.
    // Bail out WITHOUT adding to g_app_observers so a future retry can succeed.
    AXError add_err = AXObserverAddNotification(
        observer, app, kAXWindowCreatedNotification, app_refcon);
    if (add_err != kAXErrorSuccess) {
        CFRelease(app);
        CFRelease(observer);
        return;
    }
    AXObserverAddNotification(observer, app,
                              kAXFocusedWindowChangedNotification, app_refcon);

    // Per-window: move, resize, destroy, minimize, deminimize.
    // Also emit WINDOW_CREATED for each pre-existing window so the Zig side
    // can tile windows that were created before the observer was registered
    // (common with Electron/Discord where AX readiness lags behind window
    // creation).
    CFArrayRef windows = NULL;
    err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                         (CFTypeRef *)&windows);
    if (err == kAXErrorSuccess && windows) {
        CFIndex count = CFArrayGetCount(windows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win =
                (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            register_window_ax_notifications(observer, win, (pid_t)pid);

            uint32_t wid = 0;
            _AXUIElementGetWindow(win, &wid);
            if (wid != 0) {
                bw_emit_event(BW_EVENT_WINDOW_CREATED, (int32_t)pid, wid);
            }
        }
        CFRelease(windows);
    }

    CFRelease(app);

    CFRunLoopAddSource(g_observer_runloop,
                       AXObserverGetRunLoopSource(observer),
                       kCFRunLoopCommonModes);
    CFRunLoopWakeUp(g_observer_runloop);

    g_app_observers[g_app_observer_count++] = (bw_app_observer_entry){
        .pid = (pid_t)pid,
        .observer = observer,
    };
}

void bw_unobserve_app(int32_t pid) {
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
        return;
    }
}

// ---------------------------------------------------------------------------
// App identity
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Debug: dump CG windows with AX properties
// ---------------------------------------------------------------------------

static bool str_contains_ci(const char *haystack, const char *needle) {
    size_t hlen = strlen(haystack);
    size_t nlen = strlen(needle);
    if (nlen > hlen) return false;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        if (strncasecmp(haystack + i, needle, nlen) == 0) return true;
    }
    return false;
}

uint32_t bw_debug_windows(char *out, uint32_t max_len, const char *filter) {
    CFArrayRef window_list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!window_list) return 0;

    uint32_t pos = 0;
    CFIndex total = CFArrayGetCount(window_list);

#define DPRINTF(...) do { \
    int n_ = snprintf(out + pos, max_len - pos, __VA_ARGS__); \
    if (n_ > 0) pos += (uint32_t)n_; \
    if (pos >= max_len) goto done; \
} while(0)

    for (CFIndex i = 0; i < total; i++) {
        @autoreleasepool {
            CFDictionaryRef info =
                (CFDictionaryRef)CFArrayGetValueAtIndex(window_list, i);

            uint32_t wid = 0;
            CFNumberRef wid_ref = CFDictionaryGetValue(info, kCGWindowNumber);
            if (!wid_ref) continue;
            CFNumberGetValue(wid_ref, kCFNumberSInt32Type, &wid);

            int32_t pid = 0;
            CFNumberRef pid_ref =
                CFDictionaryGetValue(info, kCGWindowOwnerPID);
            if (!pid_ref) continue;
            CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &pid);

            int32_t layer = 0;
            CFNumberRef layer_ref = CFDictionaryGetValue(info, kCGWindowLayer);
            if (layer_ref)
                CFNumberGetValue(layer_ref, kCFNumberSInt32Type, &layer);

            CFStringRef owner_name_ref =
                CFDictionaryGetValue(info, kCGWindowOwnerName);
            char owner_name[128] = "(unknown)";
            if (owner_name_ref)
                CFStringGetCString(owner_name_ref, owner_name, sizeof(owner_name),
                                   kCFStringEncodingUTF8);

            char bundle_id[256] = "(unknown)";
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:pid];
            if (app && app.bundleIdentifier) {
                const char *utf8 = [app.bundleIdentifier UTF8String];
                if (utf8) strlcpy(bundle_id, utf8, sizeof(bundle_id));
            }

            NSApplicationActivationPolicy policy =
                app ? app.activationPolicy : -1;

            if (filter) {
                if (layer != 0) continue;
                if (policy != NSApplicationActivationPolicyRegular) continue;
                if (!str_contains_ci(bundle_id, filter) &&
                    !str_contains_ci(owner_name, filter))
                    continue;
            }

            const char *policy_str = "(no app)";
            if (app) {
                switch (policy) {
                    case NSApplicationActivationPolicyRegular:
                        policy_str = "regular";
                        break;
                    case NSApplicationActivationPolicyAccessory:
                        policy_str = "accessory";
                        break;
                    case NSApplicationActivationPolicyProhibited:
                        policy_str = "prohibited";
                        break;
                    default:
                        policy_str = "unknown";
                        break;
                }
            }

            CGRect bounds = CGRectZero;
            CFDictionaryRef bounds_ref =
                CFDictionaryGetValue(info, kCGWindowBounds);
            if (bounds_ref)
                CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds);

            CFStringRef win_name_ref =
                CFDictionaryGetValue(info, kCGWindowName);
            char win_name[256] = "";
            if (win_name_ref)
                CFStringGetCString(win_name_ref, win_name, sizeof(win_name),
                                   kCFStringEncodingUTF8);

            bool on_screen = bw_is_window_on_screen(wid);

            char ax_role[64] = "(n/a)";
            char ax_subrole[64] = "(n/a)";
            AXUIElementRef ax_win = find_ax_window((pid_t)pid, wid);
            if (ax_win) {
                CFStringRef role = NULL;
                AXUIElementCopyAttributeValue(ax_win, kAXRoleAttribute,
                                              (CFTypeRef *)&role);
                if (role) {
                    CFStringGetCString(role, ax_role, sizeof(ax_role),
                                       kCFStringEncodingUTF8);
                    CFRelease(role);
                }

                CFStringRef subrole = NULL;
                AXUIElementCopyAttributeValue(ax_win, kAXSubroleAttribute,
                                              (CFTypeRef *)&subrole);
                if (subrole) {
                    CFStringGetCString(subrole, ax_subrole, sizeof(ax_subrole),
                                       kCFStringEncodingUTF8);
                    CFRelease(subrole);
                }
                CFRelease(ax_win);
            }

            bool should_manage = bw_should_manage_window(pid, wid);

            DPRINTF("wid=%u pid=%d layer=%d on_screen=%s\n"
                    "  app=%s bundle=%s policy=%s\n"
                    "  title=%s\n"
                    "  bounds=(%.0f,%.0f,%.0f,%.0f)\n"
                    "  ax_role=%s ax_subrole=%s\n"
                    "  should_manage=%s\n\n",
                    wid, pid, layer, on_screen ? "yes" : "no",
                    owner_name, bundle_id, policy_str,
                    win_name[0] ? win_name : "(none)",
                    bounds.origin.x, bounds.origin.y,
                    bounds.size.width, bounds.size.height,
                    ax_role, ax_subrole,
                    should_manage ? "yes" : "no");
        }
    }

done:
    CFRelease(window_list);
    return pos;

#undef DPRINTF
}

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
