// C ABI between the Zig window manager and the Swift menu bar UI.
//
// This header is the single source of truth for the boundary: Swift imports
// it through module.modulemap so its structs get guaranteed C layout, and
// src/statusbar.zig mirrors it with `extern struct`. Changing a declaration
// here means changing both sides.

#ifndef BOBRWM_UI_H
#define BOBRWM_UI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint8_t layout;
  uint8_t bsp_split;
  uint8_t bsp_insert_point;
  double bsp_split_ratio;
  uint8_t new_window_split;
  bool dimming_enabled;
  float dimming_level;
  uint16_t inner_gap;
  uint16_t outer_gap_left;
  uint16_t outer_gap_right;
  uint16_t outer_gap_top;
  uint16_t outer_gap_bottom;
  bool animation_enabled;
  uint64_t animation_duration_ms;
  uint8_t animation_easing;
  bool start_at_login;
} BWSettings;

typedef struct {
  void (*retile)(void);
  void (*open_config)(void);
  bool (*reload_config)(void);
  bool (*set_settings)(const BWSettings *settings);
  void (*previous_workspace)(void);
  void (*next_workspace)(void);
  void (*switch_to_workspace)(uint8_t workspace_id);
  void (*quit)(void);
} BWMenuBarCallbacks;

typedef struct {
  const char *name;
  const char *shortcut;
  uint8_t id;
} BWWorkspace;

typedef struct {
  const int32_t *process_ids;
  size_t process_count;
  uint32_t window_count;
  uint8_t id;
  bool is_active;
  bool is_focused;
  uint8_t display_order;
} BWWorkspaceState;

typedef struct {
  const char *previous_workspace;
  const char *next_workspace;
} BWActionShortcuts;

// Swift owns NSApplication. It starts and stops the embedded Zig core from
// its application delegate, while Zig can request normal AppKit termination.
int bw_core_start(const char *config_path);
void bw_core_stop(void);
void bw_app_terminate(void);

void bw_menubar_init(BWMenuBarCallbacks callbacks, const char *config_path);
void bw_menubar_deinit(void);
void bw_menubar_set_workspaces(const BWWorkspace *workspaces, size_t count,
                               BWActionShortcuts shortcuts);
void bw_menubar_set_state(const BWWorkspaceState *states, size_t count);
void bw_menubar_set_settings(BWSettings settings);
void bw_menubar_set_message(const char *message);
void bw_menubar_set_config_status(bool success, const char *message);

#endif // BOBRWM_UI_H
