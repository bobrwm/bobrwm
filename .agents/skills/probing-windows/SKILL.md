---
name: probing-windows
description: "Probes macOS window metadata (CG + AX) for a given app process over time. Use when debugging window management timing, role readiness, focus changes, dim/alpha transitions, or Electron app AX behavior."
compatibility: "macOS only. Requires Xcode CLI tools and accessibility trust."
---

# Probing Windows

Periodically samples CGWindowList and AXUIElement attributes for every window belonging to a target process, emitting structured JSONL with diff events.

- `tb__probe_windows` — sampling and state-timeline capture.
- `tb__trigger_native_tabs` — repeatable native tab create/close activity while probing.
- `tb__trigger_window_events` — repeatable focus/hide/minimize/close/move/resize events while probing.

For diffing bobrwm's *internal* state against this OS-side truth, use the sibling `bobrwm-state` skill (`tb__compare_state`).

## Identity fields

- `wid` is the CG window ID from `kCGWindowNumber`. Treat this as the window identity when debugging bobrwm focus, tiling, and workspace state. It equals `window_id` in `bobrwm query ... --json` output.
- `pid` is the owning process ID from `kCGWindowOwnerPID`. Multiple distinct windows, including Ghostty native tabs, can share one PID.
- Session-level `pid` is the probe filter. Per-window `pid` is emitted on each window sample so a CG window ID lookup can tell you which process owns it.

## Per-window fields

Each sample row carries CG data (`cg_layer`, `cg_alpha`, `cg_onscreen`, `cg_bounds`) and AX data (`role`, `subrole`, `title`, `ax_frame`, `minimized`, `fullscreen`, `focused`, `manage_state`):

- `ax_frame` is the frame reported by AX (`kAXPosition`/`kAXSize`). Compare against `cg_bounds`: AX can lag CG after moves/retiles, and a persistent mismatch means the AX server serves stale geometry (or the stored window ID is stale).
- `focused` is true when the window is its own app's `AXFocusedWindow`. Useful for catching apps that swap the active native-tab CG window ID: the AX focus moves to a `wid` bobrwm does not know yet.
- `minimized` / `fullscreen` come from `AXMinimized` / `AXFullScreen`. Null when the app did not answer (AX calls are bounded by a 250ms per-app timeout so hung apps cannot stall the sampler).
- `cg_alpha` is the WindowServer alpha. Inactive-window dimming shows up here; a "fully transparent but still on-screen" window is an Electron close-to-background ghost or a dim bug.

## Workflow

1. Determine the target: either an app name (will be killed and relaunched) or a running PID
2. Start `tb__probe_windows` against the target app/pid.
3. While probe is active, generate events: `tb__trigger_native_tabs` for tab lifecycle, `tb__trigger_window_events` for focus/visibility/geometry, or bobrwm IPC commands (`bobrwm focus-workspace next`, `retile`, ...) for workspace transitions.
4. Analyze the probe output timeline for add/remove, on-screen, role, focus, alpha, and bounds transitions.

For same-app multiwindow or native-tab bugs, prefer probing a running PID so the app state is not reset:

```bash
pid=$(ps ax -ww -o pid=,args= | rg -m1 '/Ghostty.app/Contents/MacOS/ghostty' | awk '{print $1}')
# The compiled probe is cached in ~/.cache/bobrwm-skills/ keyed by source hash.
~/.cache/bobrwm-skills/window-probe-* --pid "$pid" --duration-ms 1500 --interval-ms 150
```

To query a specific CG window ID and resolve its owning PID:

```bash
~/.cache/bobrwm-skills/window-probe-* --wid 4301 --duration-ms 200 --interval-ms 100
```

Snapshot mode takes one CG pass over *every* window on the system (AX limited to the listed pids, so it stays fast) and emits a single `sample` event:

```bash
~/.cache/bobrwm-skills/window-probe-* --snapshot --ax-pids 2910,53098
```

## Native Tab Triggering

`tb__trigger_native_tabs` drives AppleScript commands for native tab lifecycle events.

- `new_window`: create one or more windows
- `create_tabs`: create one or more tabs (ensures a window exists)
- `close_tabs`: close selected tab repeatedly
- `pulse_tabs`: create then close repeatedly (good for stress testing)

## Window Event Triggering

`tb__trigger_window_events` drives app-level events through System Events, for exercising bobrwm's focus reconciliation, cleanup, dimming, and retile paths:

- `activate`: bring the app frontmost
- `hide` / `unhide`: Cmd-H-style app visibility toggle
- `minimize` / `unminimize`: front window `AXMinimized`
- `close_front`: click the front window's close button (Electron close-to-background repros)
- `move_front` / `resize_front`: set front window position/size (bobrwm will see an external move and may fight it — that is often the point)
- `cycle_focus`: alternate activation between two apps (dim + focus reconciliation repros)

## Manage state classification

- **ready**: `AXWindow` + `AXStandardWindow` (tileable window)
- **pending**: missing role/subrole or `AXUnknown` (still initializing)
- **reject**: any other combination (popups, menus, dialogs)

## Tool Parameters

### `tb__probe_windows`

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

### `tb__trigger_window_events`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `app` | string | — | App name as seen by System Events (required) |
| `operation` | string | — | `activate`, `hide`, `unhide`, `minimize`, `unminimize`, `close_front`, `move_front`, `resize_front`, `cycle_focus` (required) |
| `x`, `y` | integer | — | Target position for `move_front` |
| `width`, `height` | integer | — | Target size for `resize_front` |
| `other_app` | string | `Finder` | Second app for `cycle_focus` |
| `count` | integer | `1` | How many times to repeat |
| `interval_ms` | integer | `300` | Delay between repeats |

## Interpreting results

- **role_ready_ms** column shows when a window's AX role first became `ready`. This is the latency that bobrwm's role-polling system must cover.
- **pid** and **wid** columns are the process ID and CG window ID for each sampled window.
- **onscreen** comes from `kCGWindowIsOnscreen`; for Ghostty native tabs, the selected tab is usually the only ready on-screen member while inactive tabs remain off-screen or pending under the same PID. A probe of a long-lived terminal PID will also show dozens of dead off-screen CG residue windows with no AX data — expect only a handful of `ready` rows.
- Windows stuck at `pending` after the full duration indicate apps whose AX interface never stabilizes (rare, usually a bug in the app).
- The change timeline at the bottom shows the exact sequence of transitions with millisecond timestamps; `change` events carry `fields_changed` (`manage_state`, `role`, `subrole`, `cg_onscreen`, `cg_alpha`, `cg_bounds`, `minimized`, `fullscreen`, `focused`) with previous → current values. Alpha changes use a 0.01 epsilon and bounds a 1px epsilon so animation jitter does not flood the output.
- For dim debugging, run `cycle_focus` during an active probe and watch `cg_alpha` transitions on the inactive window.
- For native tabs, run `pulse_tabs` during an active probe to generate deterministic create/close bursts; watch `focused` flips to catch active-tab window ID swaps.
