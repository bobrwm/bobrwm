---
name: probing-windows
description: "Probes macOS window metadata (CG + AX) for a given app process over time. Use when debugging window management timing, role readiness, or Electron app AX behavior."
compatibility: "macOS only. Requires Xcode CLI tools and accessibility trust."
---

# Probing Windows

Periodically samples CGWindowList and AXUIElement attributes for every window belonging to a target process, emitting structured JSONL with diff events. Use the `tb__probe_windows` tool.

## Workflow

1. Determine the target: either an app name (will be killed and relaunched) or a running PID
2. Call `tb__probe_windows` with appropriate parameters
3. Analyze the output: summary table shows per-window role, subrole, manage_state, and timing
4. Look for `pending` → `ready` transitions to understand AX role readiness latency

## Manage state classification

- **ready**: `AXWindow` + `AXStandardWindow` (tileable window)
- **pending**: missing role/subrole or `AXUnknown` (still initializing)
- **reject**: any other combination (popups, menus, dialogs)

## Tool parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `app` | string | — | App name to kill, relaunch, and probe |
| `pid` | integer | — | PID to probe directly (skips app launch) |
| `duration_sec` | integer | 10 | How many seconds to sample |
| `interval_ms` | integer | 100 | Milliseconds between samples |
| `output_file` | string | — | Optional file path for raw JSONL output |

Either `app` or `pid` is required.

## Interpreting results

- **role_ready_ms** column shows when a window's AX role first became `ready`. This is the latency that bobrwm's role-polling system must cover.
- Windows stuck at `pending` after the full duration indicate apps whose AX interface never stabilizes (rare, usually a bug in the app).
- The change timeline at the bottom shows the exact sequence of state transitions with millisecond timestamps.
