#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import "shim.h"

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// NSWorkspace observer
// ---------------------------------------------------------------------------

@interface BWObserver : NSObject
@end

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    pid_t pid = app.processIdentifier;
    bw_workspace_app_launched(pid);
}

- (void)appTerminated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    bw_workspace_app_terminated(app.processIdentifier);
}

- (void)spaceChanged:(NSNotification *)note {
    (void)note;
    bw_workspace_space_changed();
}

- (void)displayChanged:(NSNotification *)note {
    (void)note;
    bw_workspace_display_changed();
}

- (void)activeAppChanged:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app) {
        bw_workspace_active_app_changed(app.processIdentifier);
    }
}

@end

// ---------------------------------------------------------------------------
// Hotkey engine (CGEventTap)
// ---------------------------------------------------------------------------

static CFRunLoopRef g_observer_runloop = NULL;
static dispatch_source_t g_observe_retry_source = NULL;
static dispatch_source_t g_window_scan_source = NULL;

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
// Source setup (observer runtime state)
// ---------------------------------------------------------------------------

static void cancel_runtime_sources(void) {
    if (g_observe_retry_source) {
        dispatch_source_cancel(g_observe_retry_source);
        g_observe_retry_source = NULL;
    }

    if (g_window_scan_source) {
        dispatch_source_cancel(g_window_scan_source);
        g_window_scan_source = NULL;
    }
}

void bw_setup_sources(void) {
    // --- Observer run loop (AX observers use this) ---
    g_observer_runloop = CFRunLoopGetMain();

    // --- Runtime dispatch sources ---
    cancel_runtime_sources();
}

// ---------------------------------------------------------------------------
// Private API
// ---------------------------------------------------------------------------

extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *wid);

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
#define MAX_WID_RETRY_CONTEXTS (MAX_OBSERVED_APPS * 8)

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

static bool should_drop_observe_retry_entry(pid_t pid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated) return true;
    return app_observer_exists(pid);
}

static void process_observe_retry_tick(void) {
    uint32_t i = 0;
    while (i < g_observe_retry_count) {
        bw_observe_retry_entry *entry = &g_observe_retry_entries[i];

        if (should_drop_observe_retry_entry(entry->pid)) {
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

static bool scan_app_windows_for_new_entries(pid_t pid, AXObserverRef observer) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return false;

    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute, (CFTypeRef *)&windows);
    CFRelease(app);

    if (err != kAXErrorSuccess || !windows) return false;

    bool found_new = false;
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
    return found_new;
}

static void process_window_scan_tick(void) {
    bool found_new = false;

    for (uint32_t i = 0; i < g_app_observer_count; i++) {
        const pid_t pid = g_app_observers[i].pid;
        AXObserverRef observer = g_app_observers[i].observer;
        if (scan_app_windows_for_new_entries(pid, observer)) {
            found_new = true;
        }
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
    bool in_use;
    AXObserverRef observer;
    AXUIElementRef element;
    pid_t pid;
    uint8_t attempts_remaining;
} bw_wid_retry_ctx;

static bw_wid_retry_ctx g_wid_retry_contexts[MAX_WID_RETRY_CONTEXTS];

static void bw_retry_resolve_wid(void *context);

static bw_wid_retry_ctx *acquire_wid_retry_ctx(void) {
    for (uint32_t i = 0; i < MAX_WID_RETRY_CONTEXTS; i++) {
        bw_wid_retry_ctx *ctx = &g_wid_retry_contexts[i];
        if (ctx->in_use) continue;

        ctx->in_use = true;
        ctx->observer = NULL;
        ctx->element = NULL;
        ctx->pid = 0;
        ctx->attempts_remaining = 0;
        return ctx;
    }
    return NULL;
}

static void release_wid_retry_ctx(bw_wid_retry_ctx *ctx) {
    if (!ctx || !ctx->in_use) return;
    if (ctx->observer) CFRelease(ctx->observer);
    if (ctx->element) CFRelease(ctx->element);
    ctx->observer = NULL;
    ctx->element = NULL;
    ctx->pid = 0;
    ctx->attempts_remaining = 0;
    ctx->in_use = false;
}

static void schedule_wid_resolution_retry(AXObserverRef observer,
                                          AXUIElementRef element,
                                          pid_t pid) {
    bw_wid_retry_ctx *ctx = acquire_wid_retry_ctx();
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
    if (!ctx || !ctx->in_use) return;

    // Bail out if the owning app was unobserved or terminated while this
    // retry was in flight. Without this guard a stale callback can emit
    // WINDOW_CREATED for a pid we no longer track.
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:ctx->pid];
    if (!app_observer_exists(ctx->pid) || !app || app.terminated) {
        release_wid_retry_ctx(ctx);
        return;
    }

    uint32_t wid = 0;
    _AXUIElementGetWindow(ctx->element, &wid);

    if (wid != 0) {
        const bool is_new_window = app_track_window(ctx->pid, wid);
        if (!is_new_window) {
            release_wid_retry_ctx(ctx);
            return;
        }
        register_window_ax_notifications(ctx->observer,
                                          ctx->element, ctx->pid);
        bw_emit_event(BW_EVENT_WINDOW_CREATED, ctx->pid, wid);
        release_wid_retry_ctx(ctx);
        return;
    }

    if (ctx->attempts_remaining == 0) {
        release_wid_retry_ctx(ctx);
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

static bool register_app_level_ax_notifications(AXObserverRef observer,
                                                AXUIElementRef app,
                                                void *app_refcon) {
    // If the critical create notification fails, the app AX interface is not ready.
    AXError add_err = AXObserverAddNotification(
        observer, app, kAXWindowCreatedNotification, app_refcon);
    if (add_err != kAXErrorSuccess) return false;

    AXObserverAddNotification(observer, app,
                              kAXFocusedWindowChangedNotification, app_refcon);
    return true;
}

static void prime_observed_app_windows(pid_t pid,
                                       AXObserverRef observer,
                                       AXUIElementRef app) {
    // Emit WINDOW_CREATED for pre-existing windows so Zig can tile immediately.
    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                                (CFTypeRef *)&windows);
    if (err != kAXErrorSuccess || !windows) return;

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
            continue;
        }

        // Some apps expose AX windows before WindowServer assigns CGWindowID.
        schedule_wid_resolution_retry(observer, win, pid);
    }

    CFRelease(windows);
}

static void remove_app_observer_at_index(uint32_t index) {
    if (index >= g_app_observer_count) return;
    if (g_observer_runloop) {
        CFRunLoopRemoveSource(
            g_observer_runloop,
            AXObserverGetRunLoopSource(g_app_observers[index].observer),
            kCFRunLoopCommonModes);
    }
    CFRelease(g_app_observers[index].observer);
    g_app_observers[index] = g_app_observers[--g_app_observer_count];
    update_window_scan_source();
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

    if (!register_app_level_ax_notifications(observer, app, app_refcon)) {
        CFRelease(app);
        CFRelease(observer);
        return false;
    }

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

    prime_observed_app_windows(pid, observer, app);

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
        remove_app_observer_at_index(i);
        return;
    }
}
