#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <pthread.h>
#import "shim.h"

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

bool bw_ax_is_trusted(void) {
    return AXIsProcessTrusted();
}

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
    bw_emit_event(BW_EVENT_APP_LAUNCHED, app.processIdentifier, 0);
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
static dispatch_semaphore_t g_observer_ready_sem = NULL;

static uint32_t keycode_to_number(CGKeyCode keycode) {
    switch (keycode) {
        case kVK_ANSI_1: return 1;
        case kVK_ANSI_2: return 2;
        case kVK_ANSI_3: return 3;
        case kVK_ANSI_4: return 4;
        case kVK_ANSI_5: return 5;
        case kVK_ANSI_6: return 6;
        case kVK_ANSI_7: return 7;
        case kVK_ANSI_8: return 8;
        case kVK_ANSI_9: return 9;
        default: return 0;
    }
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

    bool has_alt   = (flags & kCGEventFlagMaskAlternate) != 0;
    bool has_shift = (flags & kCGEventFlagMaskShift) != 0;
    bool has_cmd   = (flags & kCGEventFlagMaskCommand) != 0;

    if (!has_alt || has_cmd) return event;

    // alt+1..9 / alt+shift+1..9 → workspace
    uint32_t ws_num = keycode_to_number(keycode);
    if (ws_num != 0) {
        if (has_shift) {
            bw_emit_event(BW_HK_MOVE_TO_WORKSPACE, 0, ws_num);
        } else {
            bw_emit_event(BW_HK_FOCUS_WORKSPACE, 0, ws_num);
        }
        return NULL;
    }

    // alt+h/j/k/l → focus direction
    if (!has_shift) {
        switch (keycode) {
            case kVK_ANSI_H:
                bw_emit_event(BW_HK_FOCUS_LEFT, 0, 0); return NULL;
            case kVK_ANSI_J:
                bw_emit_event(BW_HK_FOCUS_DOWN, 0, 0); return NULL;
            case kVK_ANSI_K:
                bw_emit_event(BW_HK_FOCUS_UP, 0, 0); return NULL;
            case kVK_ANSI_L:
                bw_emit_event(BW_HK_FOCUS_RIGHT, 0, 0); return NULL;
            default: break;
        }
    }

    // alt+return → toggle split direction
    if (keycode == kVK_Return && !has_shift) {
        bw_emit_event(BW_HK_TOGGLE_SPLIT, 0, 0);
        return NULL;
    }

    return event;
}

// ---------------------------------------------------------------------------
// Observer thread
// ---------------------------------------------------------------------------

static void *observer_thread(void *arg) {
    (void)arg;
    @autoreleasepool {
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

        // CGEventTap for global hotkeys
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), tap_source,
                             kCFRunLoopCommonModes);
            CFRelease(tap_source);
            CGEventTapEnable(g_tap_port, true);
        }

        // Publish run loop for AX observers registered from the main thread
        g_observer_runloop = CFRunLoopGetCurrent();
        if (g_observer_ready_sem) {
            dispatch_semaphore_signal(g_observer_ready_sem);
        }

        CFRunLoopRun();
    }
    return NULL;
}

void bw_start_observer(void) {
    g_observer_ready_sem = dispatch_semaphore_create(0);
    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&tid, &attr, observer_thread, NULL);
    pthread_attr_destroy(&attr);
}

void bw_wait_observer_ready(void) {
    if (g_observer_ready_sem) {
        dispatch_semaphore_wait(g_observer_ready_sem, DISPATCH_TIME_FOREVER);
        g_observer_ready_sem = NULL;
    }
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
// Display
// ---------------------------------------------------------------------------

bw_frame bw_get_display_frame(void) {
    NSScreen *screen = [NSScreen mainScreen];
    NSRect visible = screen.visibleFrame;
    NSRect full    = screen.frame;
    // AppKit uses bottom-left origin; CG uses top-left
    double cg_y = full.size.height - visible.origin.y - visible.size.height;
    return (bw_frame){
        .x = visible.origin.x,
        .y = cg_y,
        .w = visible.size.width,
        .h = visible.size.height,
    };
}

// ---------------------------------------------------------------------------
// AX window operations
// ---------------------------------------------------------------------------

bool bw_ax_set_window_frame(int32_t pid, uint32_t wid,
                            double x, double y, double w, double h) {
    AXUIElementRef win = find_ax_window((pid_t)pid, wid);
    if (!win) return false;

    // Position first, then size (order matters for min-size constraints)
    CGPoint pos = { x, y };
    AXValueRef pos_val = AXValueCreate(kAXValueTypeCGPoint, &pos);
    AXUIElementSetAttributeValue(win, kAXPositionAttribute, (CFTypeRef)pos_val);
    CFRelease(pos_val);

    CGSize size = { w, h };
    AXValueRef size_val = AXValueCreate(kAXValueTypeCGSize, &size);
    AXError err = AXUIElementSetAttributeValue(
        win, kAXSizeAttribute, (CFTypeRef)size_val);
    CFRelease(size_val);

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
// Per-app AX observers
// ---------------------------------------------------------------------------

#define MAX_OBSERVED_APPS 128

typedef struct {
    pid_t pid;
    AXObserverRef observer;
} bw_app_observer_entry;

static bw_app_observer_entry g_app_observers[MAX_OBSERVED_APPS];
static uint32_t g_app_observer_count = 0;

static void register_window_ax_notifications(AXObserverRef observer,
                                              AXUIElementRef window,
                                              void *refcon) {
    AXObserverAddNotification(observer, window, kAXMovedNotification, refcon);
    AXObserverAddNotification(observer, window, kAXResizedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXUIElementDestroyedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXWindowMiniaturizedNotification, refcon);
    AXObserverAddNotification(observer, window,
                              kAXWindowDeminiaturizedNotification, refcon);
}

static void ax_notification_handler(AXObserverRef observer,
                                    AXUIElementRef element,
                                    CFStringRef notification,
                                    void *refcon) {
    pid_t pid = (pid_t)(intptr_t)refcon;
    uint32_t wid = 0;
    _AXUIElementGetWindow(element, &wid);
    if (wid == 0) return;

    if (CFEqual(notification, kAXWindowCreatedNotification)) {
        register_window_ax_notifications(observer, element, refcon);
        bw_emit_event(BW_EVENT_WINDOW_CREATED, pid, wid);
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

    void *refcon = (void *)(intptr_t)pid;

    // App-level: detect new windows
    AXObserverAddNotification(observer, app,
                              kAXWindowCreatedNotification, refcon);

    // Per-window: move, resize, destroy, minimize, deminimize
    CFArrayRef windows = NULL;
    err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                        (CFTypeRef *)&windows);
    if (err == kAXErrorSuccess && windows) {
        CFIndex count = CFArrayGetCount(windows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win =
                (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            register_window_ax_notifications(observer, win, refcon);
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
