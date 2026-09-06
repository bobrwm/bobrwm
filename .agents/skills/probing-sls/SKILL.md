---
name: probing-sls
description: Probes macOS SkyLight (SLS/CGS) exported symbols and native Space state over time. Use when debugging native Space transitions, display animation settlement, or private WindowServer API availability.
---

# Probing SLS

macOS only. Requires Xcode CLI tools and Nushell for the toolbox wrapper.

`tb__probe_sls` samples current native Space IDs and display animation state, or checks symbol availability without invoking unknown APIs. The Swift probe is read-only; gesture posting and app restarts belong in separate repro drivers.

For daemon-side state, use the sibling `bobrwm-state` skill. For CG+AX window metadata, use `probing-windows`.

## Workflow

1. Get physical display IDs from `bobrwm query displays --json`; these are not display menu ordinals.
2. Start `tb__probe_sls` with a bounded duration and the relevant `display_ids`.
3. Reproduce the authorized action while sampling, using bobrwm IPC commands or the relevant app.
4. Correlate Space and animation changes with daemon logs, reducer epochs, and window observations.

Use `duration_sec: 0` for a snapshot. Default captures emit the initial state and changes; enable `all_samples` when unchanged observations matter. `output_file` saves raw JSONL for later comparison.

## Tool Parameters

### `tb__probe_sls`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `display_ids` | integer array | main display | Physical CG display IDs to sample |
| `duration_sec` | number | 10 | Capture seconds; zero takes one snapshot |
| `interval_ms` | number | 100 | Positive sampling interval in milliseconds |
| `all_samples` | boolean | false | Include unchanged observations |
| `symbols` | string array | — | Inspect exports instead of sampling displays |
| `output_file` | string | — | Save raw JSONL output |

## Direct execution

The toolbox wrapper compiles `scripts/probe.swift` once per source revision, caching it as `~/.cache/bobrwm-skills/sls-probe-<hash>`. It prefers the standalone Command Line Tools SDK, then checks Xcode installations.

From the repository root:

```nu
with-env {TOOLBOX_ACTION: execute} {
    {duration_sec: 0} | to json | nu --stdin .agents/skills/probing-sls/toolbox/probe_sls.nu
}

with-env {TOOLBOX_ACTION: execute} {
    {symbols: [SLSManagedDisplayIsAnimating CGDisplayCreateUUIDFromDisplayID]} | to json | nu --stdin .agents/skills/probing-sls/toolbox/probe_sls.nu
}
```

The cached binary also accepts `--display ID` (repeatable), `--duration SEC`, `--interval-ms MS`, `--all-samples`, and `--symbol NAME` (repeatable). Its default duration is zero. Resolve the exact cached binary path rather than invoking a glob that may match multiple revisions.

## Output and interpretation

- Samples include `display_id`, `space_id`, `is_animating`, UTC `wall_time`, and monotonic `elapsed_ms`. A final summary counts sampled and emitted observations.
- Missing observation symbols produce null fields and an `unavailable` explanation. Invalid displays and required-symbol failures exit nonzero.
- Native Space IDs are not workspace ordinals. Gesture delivery, target observation, and animation settlement are distinct facts.
- A false animation sample does not prove a gesture was delivered or accepted. A capture that never sees animation cannot establish that non-instant animation was tested.
- Space and animation queries are sequential, not atomic. Confirm transitions across samples and cross-check daemon/window state.

## Extending the probe

Some `CG*` symbols, including `CGDisplayCreateUUIDFromDisplayID` on the tested OS, are exported by SkyLight. Symbol mode searches SkyLight, CoreGraphics, then CoreFoundation and reports the resolving library.

Before adding a callable query, verify its exact ABI in local declarations or a primary implementation such as [yabai's declarations](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h). Presence does not establish a safe signature or useful behavior. Add narrowly typed read-only queries to the Swift probe rather than a generic arbitrary-function invoker.
