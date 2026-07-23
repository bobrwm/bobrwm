# bobrwm

A tiling window manager for macOS, written in Zig.

## Installation
Bobrwm is still in early development, meaning you'll need to build it from source.
There's also a release available on Homebrew that'll build from source for you:

```
brew install --HEAD bobrwm/tap/bobrwm
```

## Usage

```
bobrwm                    # start daemon
bobrwm -c /path/to/config.zon  # start with explicit config
bobrwm query windows      # IPC: list managed windows
bobrwm query windows --json  # IPC: list managed windows as JSON
bobrwm query workspaces   # IPC: list workspaces
bobrwm query workspaces --json # IPC: list workspaces as JSON
bobrwm query displays     # IPC: list connected displays
bobrwm query displays --json # IPC: list connected displays as JSON
bobrwm query apps         # IPC: list observed apps
bobrwm query apps --json  # IPC: list observed apps as JSON
bobrwm focus-workspace next # IPC: switch to next workspace without wrapping
bobrwm focus-workspace prev # IPC: switch to previous workspace without wrapping
bobrwm move-to-display 2  # IPC: move focused window to display slot 2
bobrwm bsp insert-mode stack          # IPC: split | stack
bobrwm bsp insert-point min_depth     # IPC: focused | first | last | min_depth
bobrwm bsp ratio rel 0.05             # IPC: adjust focused parent split ratio
bobrwm bsp ratio abs 0.6              # IPC: set focused parent split ratio
bobrwm bsp mirror horizontal          # IPC: horizontal | vertical
bobrwm bsp equalize                   # IPC: set all split ratios to config ratio
bobrwm bsp balance                    # IPC: proportional balance by subtree size
bobrwm bsp rotate 90                  # IPC: 90 | 180 | 270
bobrwm-swipe                          # optional trackpad swipe companion
```

### Logging

Log level is compile-time configurable. Default follows build mode (`debug` in Debug, `info` otherwise).

```bash
zig build -Dlog_level=debug
LOG_LEVEL=debug zig build
LOG_LEVEL=trace zig build   # alias of debug (extra trace-style diagnostics)
```

## Configuration

Config is loaded from (in order):

1. `-c` / `--config` CLI argument
2. `$XDG_CONFIG_HOME/bobrwm/config.zon`
3. `~/.config/bobrwm/config.zon`

If no config file is found, built-in defaults are used. See [`examples/config.zon`](examples/config.zon) for a full example.

Press `Alt+Shift+R` (the default `reload_config` binding) to apply changes
without restarting. If the file contains invalid ZON, bobrwm keeps the last valid configuration.
Changing the number of workspaces still requires a restart; other settings,
including keybinds, rules, layouts, gaps, animation, and dimming, reload live.

### Keybinds

Map a key + modifiers to an action. Configured keybinds are merged with the
built-in defaults; use the same key + modifiers to override a default binding.

```zon
.keybinds = .{
    .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 },
    .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left },
    .{ .key = "return", .mods = .{ .alt = true }, .action = .toggle_split },
},
```

**Available modifiers:** `alt`, `shift`, `cmd`, `ctrl`

**Available actions:**

| Action | Description | `arg` |
| --- | --- | --- |
| `focus_workspace` | Switch to workspace N | workspace number |
| `focus_previous_workspace` | Switch to the previous workspace; if already at the first workspace, pass the key through | — |
| `focus_next_workspace` | Switch to the next workspace; if already at the last workspace, pass the key through | — |
| `move_to_workspace` | Move focused window to workspace N | workspace number |
| `focus_left` | Focus window to the left | — |
| `focus_right` | Focus window to the right | — |
| `focus_up` | Focus window above | — |
| `focus_down` | Focus window below | — |
| `toggle_split` | Toggle next split direction | — |
| `toggle_fullscreen` | Toggle focused window fullscreen | — |
| `toggle_float` | Toggle focused window floating | — |
| `reload_config` | Reload the config file, keeping the current config if parsing fails | — |

### Gaps

Pixel spacing between and around windows:

```zon
.gaps = .{
    .inner = 4,
    .outer = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
},
```

### Layout

Choose the tiling algorithm:

```zon
.layout = .bsp, // .bsp | .monocle
```

### Workspaces

bobrwm uses virtual workspaces. They are not native macOS Spaces; hidden workspace windows are parked off-screen and restored when that workspace is focused.

By default, bobrwm creates 10 workspaces. To configure a smaller count, provide `.workspace_names`; the number of names is the workspace count:

```zon
.workspace_names = .{
    "term",
    "web",
    "code",
    "chat",
},
```

Workspace IDs are still 1-based, so the example above creates workspaces 1 through 4. Keybinds and app assignments should only reference workspaces in that range. The current maximum is 10 workspaces.

### Workspace Assignments

Pin apps to specific workspaces by bundle ID:

```zon
.workspace_assignments = .{
    .{ .app_id = "com.mitchellh.ghostty", .workspace = 1 },
    .{ .app_id = "com.brave.Browser", .workspace = 2 },
},
```

### Swipe companion

The optional `bobrwm-swipe` companion reads its opt-in flag from the main bobrwm config:

```zon
.swipe = .{
    .enabled = true,
    .fingers = 3,
    .distance_pct = 0.08,
    .reverse = false,
},
```

`distance_pct` is the average horizontal movement threshold as a normalized fraction of the trackpad width; `0.08` means roughly 8% of the trackpad.

Core bobrwm does not start a gesture listener from this flag. It only defines the shared config shape and exposes `focus-workspace next|prev` over IPC. Run `bobrwm-swipe` as the companion process after enabling the field. macOS grants Accessibility permissions per executable, so `bobrwm-swipe` needs its own grant even if bobrwm is already trusted.

When bobrwm has an adjacent workspace, the swipe listener consumes the matching macOS gesture. At the first or last bobrwm workspace, it passes the gesture through so native Spaces can handle it.
