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
bobrwm toggle-keep-above  # IPC: keep focused floating window above its workspace
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

### Keybinds

Map a key + modifiers to an action:

```zon
.keybinds = .{
    .{ .key = "1", .mods = .{ .alt = true }, .action = .focus_workspace, .arg = 1 },
    .{ .key = "h", .mods = .{ .alt = true }, .action = .focus_left },
    .{ .key = "return", .mods = .{ .alt = true }, .action = .toggle_split },
    .{ .key = "f", .mods = .{ .alt = true, .shift = true }, .action = .toggle_keep_above },
},
```

**Available modifiers:** `alt`, `shift`, `cmd`, `ctrl`

Built-in defaults include `alt+shift+f` for `toggle_keep_above`.

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
| `toggle_keep_above` | Toggle focused window floating above other windows in its workspace | — |

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

### App rules

Configure per-app behavior keyed by bundle ID. Either or both fields may
be set on a rule, and the two concerns (workspace pin, default mode) can
be combined on the same `app_id`:

```zon
.app_rules = .{
    // pin Safari to workspace 2
    .{ .app_id = "com.apple.Safari", .workspace = 2 },
    // open System Settings as floating-above
    .{ .app_id = "com.apple.systempreferences", .mode = .floating_above },
    // both: pin Brave to workspace 1 and float it above
    .{ .app_id = "com.brave.Browser", .workspace = 1, .mode = .floating_above },
},
```

| Mode | Behavior |
| --- | --- |
| `.tiled` | Participate in BSP/monocle layout (default for unmatched windows). |
| `.floating` | Excluded from layout. |
| `.floating_above` | Excluded from layout and re-raised after retile, focus, and workspace switches. |

A matching rule overrides the built-in small-non-resizable auto-float
heuristic, so set `.mode = .tiled` to force-tile apps that bobrwm would
otherwise float by default.

> **Deprecated:** the older `workspace_assignments` field is still parsed
> and merged into the lookup for backward compatibility, but logs a
> warning at startup. Migrate entries to `app_rules` with `.workspace = N`.

### Swipe companion

The optional `bobrwm-swipe` companion reads its opt-in flag from the main bobrwm config:

```zon
.swipe = .{
    .enabled = true,
    .fingers = 3,
    .distance_pct = 0.08,
},
```

`distance_pct` is the average horizontal movement threshold as a normalized fraction of the trackpad width; `0.08` means roughly 8% of the trackpad.

Core bobrwm does not start a gesture listener from this flag. It only defines the shared config shape and exposes `focus-workspace next|prev` over IPC. Run `bobrwm-swipe` as the companion process after enabling the field. macOS grants Accessibility permissions per executable, so `bobrwm-swipe` needs its own grant even if bobrwm is already trusted.

When bobrwm has an adjacent workspace, the swipe listener consumes the matching macOS gesture. At the first or last bobrwm workspace, it passes the gesture through so native Spaces can handle it.
