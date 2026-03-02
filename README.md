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
bobrwm query workspaces   # IPC: list workspaces
bobrwm query displays     # IPC: list connected displays
bobrwm query apps         # IPC: list observed apps
bobrwm move-to-display 2  # IPC: move focused window to display slot 2
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
},
```

**Available modifiers:** `alt`, `shift`, `cmd`, `ctrl`

**Available actions:**

| Action | Description | `arg` |
| --- | --- | --- |
| `focus_workspace` | Switch to workspace N | workspace number |
| `move_to_workspace` | Move focused window to workspace N | workspace number |
| `focus_left` | Focus window to the left | — |
| `focus_right` | Focus window to the right | — |
| `focus_up` | Focus window above | — |
| `focus_down` | Focus window below | — |
| `toggle_split` | Toggle next split direction | — |
| `toggle_fullscreen` | Toggle focused window fullscreen | — |
| `toggle_float` | Toggle focused window floating | — |

### Gaps

Pixel spacing between and around windows:

```zon
.gaps = .{
    .inner = 4,
    .outer = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
},
```

### Workspace Assignments

Pin apps to specific workspaces by bundle ID:

```zon
.workspace_assignments = .{
    .{ .app_id = "com.mitchellh.ghostty", .workspace = 1 },
    .{ .app_id = "com.brave.Browser", .workspace = 2 },
},
```
