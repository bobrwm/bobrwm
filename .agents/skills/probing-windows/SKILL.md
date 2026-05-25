---
name: probing-windows
description: "Probes macOS window metadata (CG + AX) for a given app process over time. Use when debugging window management timing, role readiness, or Electron app AX behavior."
compatibility: "macOS only. Requires Xcode CLI tools and accessibility trust."
---

# Probing Windows

Periodically samples CGWindowList and AXUIElement attributes for every window belonging to a target process, emitting structured JSONL with diff events.

Use `tb__probe_windows` for sampling and state-timeline capture.
Use `tb__trigger_native_tabs` to generate repeatable native tab create/close activity while probing.

## Identity fields

- `wid` is the CG window ID from `kCGWindowNumber`. Treat this as the window identity when debugging bobrwm focus, tiling, and workspace state.
- `pid` is the owning process ID from `kCGWindowOwnerPID`. Multiple distinct windows, including Ghostty native tabs, can share one PID.
- Session-level `pid` is the probe filter. Per-window `pid` is emitted on each window sample so a CG window ID lookup can tell you which process owns it.

## Workflow

1. Determine the target: either an app name (will be killed and relaunched) or a running PID
2. Start `tb__probe_windows` against the target app/pid.
3. While probe is active, call `tb__trigger_native_tabs` to create/close tabs.
4. Analyze the probe output timeline for add/remove, on-screen, and role transitions.

For same-app multiwindow or native-tab bugs, prefer probing a running PID so the app state is not reset:

```bash
pid=$(ps ax -ww -o pid=,args= | rg -m1 '/Ghostty.app/Contents/MacOS/ghostty' | awk '{print $1}')
.agents/skills/probing-windows/scripts/probe --pid "$pid" --duration-ms 1500 --interval-ms 150
```

To query a specific CG window ID and resolve its owning PID:

```bash
.agents/skills/probing-windows/scripts/probe --wid 4301 --duration-ms 200 --interval-ms 100
```

## Native Tab Triggering

`tb__trigger_native_tabs` drives AppleScript commands for native tab lifecycle events.

- `new_window`: create one or more windows
- `create_tabs`: create one or more tabs (ensures a window exists)
- `close_tabs`: close selected tab repeatedly
- `pulse_tabs`: create then close repeatedly (good for stress testing)

## Manage state classification

- **ready**: `AXWindow` + `AXStandardWindow` (tileable window)
- **pending**: missing role/subrole or `AXUnknown` (still initializing)
- **reject**: any other combination (popups, menus, dialogs)

## Tool Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `app` | string | — | App name to kill, relaunch, and probe |
| `pid` | integer | — | PID to probe directly (skips app launch) |
| `wid` | integer | — | CG window ID to query directly; can be combined with `pid` to verify ownership |
| `duration_sec` | integer | 10 | How many seconds to sample |
| `interval_ms` | integer | 100 | Milliseconds between samples |
| `output_file` | string | — | Optional file path for raw JSONL output |

At least one of `app`, `pid`, or `wid` is required.

### `tb__trigger_native_tabs`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `app` | string | `Ghostty` | AppleScript app name |
| `operation` | string | `create_tabs` | `new_window`, `create_tabs`, `close_tabs`, or `pulse_tabs` |
| `count` | integer | `1` | How many operations to perform |
| `interval_ms` | integer | `200` | Delay between operations |
| `activate` | boolean | `true` | Activate app before running commands |
| `use_keystroke_fallback` | boolean | `true` | Fall back to `⌘N/⌘T/⌘W` keystrokes if app-specific AppleScript commands fail |

## Interpreting results

- **role_ready_ms** column shows when a window's AX role first became `ready`. This is the latency that bobrwm's role-polling system must cover.
- **pid** and **wid** columns are the process ID and CG window ID for each sampled window.
- **onscreen** comes from `kCGWindowIsOnscreen`; for Ghostty native tabs, the selected tab is usually the only ready on-screen member while inactive tabs remain off-screen or pending under the same PID.
- Windows stuck at `pending` after the full duration indicate apps whose AX interface never stabilizes (rare, usually a bug in the app).
- The change timeline at the bottom shows the exact sequence of state transitions with millisecond timestamps.
- For native tabs, run `pulse_tabs` during an active probe to generate deterministic create/close bursts for easier timeline analysis.
