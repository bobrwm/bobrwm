---
name: bobrwm-state
description: "Introspects and cross-checks the running bobrwm daemon: IPC queries, log capture, dimming-overlay capture, and divergence detection between bobrwm's internal state and CG/AX ground truth. Use when debugging window management, workspace, focus, tiling, or dimming bugs in bobrwm."
compatibility: "macOS only. Requires a running bobrwm daemon for IPC queries; compare_state additionally needs the probing-windows skill and Xcode CLI tools."
---

# Bobrwm State

bobrwm reconciles four state sources — AX, WindowServer/CG, SkyLight, and its internal workspace/layout state — and most bugs appear as divergence between them (see `AGENTS.md` → "Window Management Invariants"). This skill covers reading the daemon side and diffing it against OS truth. Use the sibling `probing-windows` skill for OS-side timelines (probe over time) and event triggering.

## Querying the daemon (IPC)

The daemon listens on `/tmp/bobrwm_<uid>.sock`. Any `bobrwm` binary acts as an IPC client (during development use `zig-out/bin/bobrwm`; the daemon may be running from there rather than PATH — check `ps ax | rg bobrwm`).

```bash
bobrwm query workspaces --json   # ALL workspaces with their windows, frames, focused_window, visible flag
bobrwm query windows --json      # windows on the ACTIVE workspace only
bobrwm query displays --json     # display slots, ids, visible frames, active workspace per display
bobrwm query apps --json         # observed apps
```

Prefer `query workspaces --json` when investigating: it is the only query that includes hidden workspaces, and hidden workspaces are where parked windows and stale entries hide.

Key JSON fields per window: `window_id` (CG window ID — the same `wid` the probe reports), `process_id`, `bundle_id`, `workspace_id`, `display_id`, `frame` (bobrwm's stored frame, in CG top-left coordinates).

Mutating IPC commands are also useful as repro drivers: `bobrwm focus-workspace <n|prev|next>`, `move-to-workspace <n>`, `move-to-display <n>`, `retile`. Driving a workspace switch while a probe is running is the standard way to capture transition bugs.

## compare_state: divergence detection

`tb__compare_state` queries the daemon and takes a one-shot CG+AX snapshot of the whole system (AX limited to managed pids), then reports per-invariant divergences:

| Check | Diverges when | Usual suspect |
|---|---|---|
| stale entries | managed `window_id` no longer exists in CG | cleanup missed a destroyed window / native tab |
| frame drift | bobrwm's stored frame ≠ CG bounds on a visible workspace | missed retile, failed AX frame write (stale tab wid), in-flight animation |
| hidden not parked | hidden-workspace window clearly visible on a display | workspace transition or hide/retile bug |
| unmanaged visible | visible AX-ready window of a managed app not in any workspace | missed adoption, creation race, suppressed tab member turned visible |
| focus divergence | workspace `focused_window` ≠ the app's `AXFocusedWindow` | app replaced the active native-tab CG window ID (known bug class) |
| target alpha | managed visible-workspace window fully transparent | app ghost or restore bug; overlay dimming does not alter target alpha |
| dimming overlays | bobrwm layer-0 overlay is missing or does not match an inactive target frame | overlay apply/reset/frame bug |

Run it once for a baseline, reproduce the bug, then run it again — the delta tells you which reconciliation path failed. One-off `frame drift` findings can be animation in flight; re-run before trusting them.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `bobrwm_bin` | string | PATH, then `<repo>/zig-out/bin/bobrwm` | IPC client binary |
| `frame_tolerance` | number | 2 | px slack before flagging frame drift |
| `expect_dimming_overlays` | boolean | `false` | Require overlays even if none are visible; set when dimming is known enabled |
| `output_file` | string | — | Save raw queries + snapshot JSON for offline diffing |

The raw snapshot includes `window_kind`, `owner_name`, and `cg_order` for every CG window. Visible bobrwm-owned layer-0 panels are classified as `dimming_overlay` and matched to inactive managed windows by frame. With the default `expect_dimming_overlays=false`, an entirely absent overlay set is informational because the tool cannot query the runtime toggle; once any overlay is visible, partial coverage is checked automatically.

## Logs

Where the daemon logs depends on how it was started:

- **launchd service** (`bobrwm service install`): `/tmp/bobrwm_<user>.out.log` and `/tmp/bobrwm_<user>.err.log`
- **manual / `zig build run`**: stdout/stderr of that terminal

Log level is **compile-time**: a release binary has no `log.debug` output at all. To get the high-signal transition/cleanup/tab/AX-reconciliation logs, rebuild:

```bash
zig build -Dlog_level=debug        # or: LOG_LEVEL=debug zig build
LOG_LEVEL=trace zig build          # alias of debug with extra trace diagnostics
```

Logs are scoped (`.launchd`, per-module scopes); grep for the module you are debugging. `[trace]`-prefixed debug lines time IPC queries.

## Restarting the daemon safely

Restarting bobrwm resets workspace assignments and re-adopts windows — it destroys the buggy state you are inspecting. Capture state first (`compare_state` with `output_file`, plus the relevant queries), then:

```bash
bobrwm service restart        # if running as a launchd service
# or kill the manual process and rerun zig-out/bin/bobrwm
```

If the daemon is running from `zig-out/bin/bobrwm` via `zig build run`, rebuilding while it runs is fine; the new binary takes effect on next restart.

## Debugging workflow

1. **Snapshot the divergence**: `tb__compare_state` (with `output_file`) to see which state source disagrees.
2. **Capture the timeline**: start `tb__probe_windows` (probing-windows skill) against the affected pid, reproduce with `tb__trigger_native_tabs` / `tb__trigger_window_events` or the mutating IPC commands, and read the change timeline.
3. **Correlate with daemon logs**: with a `-Dlog_level=debug` build, match probe timestamps against transition/cleanup/reconciliation log lines.
4. **Check the invariant**: map the divergence to `AGENTS.md` → "Window Management Invariants" to identify which reconciliation rule was violated.
