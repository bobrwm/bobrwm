#ifndef BOBRWM_SHIM_H
#define BOBRWM_SHIM_H

#include <stdint.h>
// ObjC selector callbacks exported by Zig.

extern void bw_will_quit(void);
extern void bw_retile(void);
extern void bw_workspace_app_launched(int32_t pid);
extern void bw_workspace_app_terminated(int32_t pid);
extern void bw_workspace_active_app_changed(int32_t pid);
extern void bw_workspace_space_changed(void);
extern void bw_workspace_display_changed(void);

#endif
