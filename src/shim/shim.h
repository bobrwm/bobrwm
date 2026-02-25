#ifndef BOBRWM_SHIM_H
#define BOBRWM_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// --- Event kinds (must match event.zig) ---

enum bw_event_kind {
    BW_EVENT_WINDOW_CREATED       = 1,
    BW_EVENT_WINDOW_DESTROYED     = 2,
    BW_EVENT_WINDOW_FOCUSED       = 3,
    BW_EVENT_WINDOW_MOVED         = 4,
    BW_EVENT_WINDOW_RESIZED       = 5,
    BW_EVENT_WINDOW_MINIMIZED     = 6,
    BW_EVENT_WINDOW_DEMINIMIZED   = 7,
    BW_EVENT_APP_LAUNCHED         = 8,
    BW_EVENT_APP_TERMINATED       = 9,
    BW_EVENT_SPACE_CHANGED        = 10,
    BW_EVENT_DISPLAY_CHANGED      = 11,
    BW_EVENT_FOCUSED_WINDOW_CHANGED = 12,

    BW_HK_FOCUS_WORKSPACE        = 20,
    BW_HK_MOVE_TO_WORKSPACE      = 21,
    BW_HK_FOCUS_LEFT              = 22,
    BW_HK_FOCUS_RIGHT             = 23,
    BW_HK_FOCUS_UP                = 24,
    BW_HK_FOCUS_DOWN              = 25,
    BW_HK_TOGGLE_SPLIT            = 26,
    BW_HK_TOGGLE_FULLSCREEN       = 27,
    BW_HK_TOGGLE_FLOAT            = 28,
};

// --- Modifier flags for configurable keybinds ---

#define BW_MOD_ALT   (1 << 0)
#define BW_MOD_SHIFT (1 << 1)
#define BW_MOD_CMD   (1 << 2)
#define BW_MOD_CTRL  (1 << 3)

typedef struct {
    uint16_t keycode;
    uint8_t  mods;     // BW_MOD_* bitmask
    uint8_t  action;   // bw_event_kind value
    uint32_t arg;
} bw_keybind;

// --- Data types ---

typedef struct {
    uint32_t wid;
    int32_t  pid;
    double x;
    double y;
    double w;
    double h;
} bw_window_info;

typedef struct {
    double x;
    double y;
    double w;
    double h;
} bw_frame;

// --- Event bridge (Zig → C) ---

extern void bw_emit_event(uint8_t kind, int32_t pid, uint32_t wid);

// --- Zig callbacks (called from ObjC into Zig) ---

extern void bw_drain_events(void);
extern void bw_handle_ipc_client(int server_fd);
extern void bw_will_quit(void);
extern void bw_retile(void);

// --- Accessibility ---

bool bw_ax_is_trusted(void);
void bw_ax_prompt(void);

// --- Source setup ---

/// Set up observers, CGEventTap, waker, IPC source, and status bar on the
/// main run loop. Call after NSApp is initialised (from Zig via zig-objc).
void bw_setup_sources(int ipc_fd);

/// Signal the main run loop to drain the event ring.
void bw_signal_waker(void);

// --- Window discovery ---

/// Enumerate on-screen windows (layer 0, regular apps only).
/// Returns the number of entries written to `out`.
uint32_t bw_discover_windows(bw_window_info *out, uint32_t max_count);

// --- Display ---

/// Get the usable display frame (menu bar / dock excluded), CG coordinates.
bw_frame bw_get_display_frame(void);

// --- AX window operations ---

/// Move and resize a window (CG coordinates, top-left origin).
bool bw_ax_set_window_frame(int32_t pid, uint32_t wid,
                            double x, double y, double w, double h);

/// Raise and focus a window, activating its owning application.
bool bw_ax_focus_window(int32_t pid, uint32_t wid);

/// Get the CGWindowID of the focused window for a given app PID.
/// Returns 0 on failure.
uint32_t bw_ax_get_focused_window(int32_t pid);

/// Check if a window should be managed (regular app, standard AX window role).
bool bw_should_manage_window(int32_t pid, uint32_t wid);

/// Check if a window is currently on screen (CGWindowList cross-check).
/// Background tabs in native macOS tab groups are NOT on screen.
bool bw_is_window_on_screen(uint32_t wid);

/// Get all AX window IDs for a given PID (includes background tabs).
/// Returns the number of entries written to `out`.
uint32_t bw_get_app_window_ids(int32_t pid, uint32_t *out, uint32_t max_count);

// --- Per-app AX observers ---

/// Start watching a specific app for window events (move, resize, create, destroy).
void bw_observe_app(int32_t pid);

/// Stop watching a specific app (call on app termination).
void bw_unobserve_app(int32_t pid);

// --- Configurable keybinds ---

/// Set the keybind table. The shim copies the data internally.
void bw_set_keybinds(const bw_keybind *binds, uint32_t count);

// --- App identity ---

/// Get the bundle identifier for a given PID.
/// Returns the number of bytes written to `out` (0 on failure).
uint32_t bw_get_app_bundle_id(int32_t pid, char *out, uint32_t max_len);

#endif
