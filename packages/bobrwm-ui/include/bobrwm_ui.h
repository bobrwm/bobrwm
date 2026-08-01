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
  void (*retile)(void);
  void (*open_config)(void);
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
  uint32_t window_count;
  uint8_t id;
  bool is_active;
  bool is_focused;
} BWWorkspaceState;

typedef struct {
  const char *previous_workspace;
  const char *next_workspace;
} BWActionShortcuts;

void bw_menubar_init(BWMenuBarCallbacks callbacks);
void bw_menubar_deinit(void);
void bw_menubar_set_workspaces(const BWWorkspace *workspaces, size_t count,
                               BWActionShortcuts shortcuts);
void bw_menubar_set_state(const BWWorkspaceState *states, size_t count);
void bw_menubar_set_message(const char *message);

#endif // BOBRWM_UI_H
