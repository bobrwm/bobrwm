#!/usr/bin/env nu

# Toolbox tool: cross-check bobrwm's internal state against OS ground truth.
#
# bobrwm reconciles AX, WindowServer/CG, and internal workspace state; bugs
# usually show up as divergence between those sources. This tool queries the
# running daemon over IPC and diffs the result against a CG+AX snapshot,
# reporting each divergence class with the invariant it violates.

def describe [] {
    {
        name: "compare_state"
        description: "Cross-check bobrwm daemon state (query workspaces/displays --json) against a CGWindowList+AX snapshot. Reports stale store entries, frame drift, hidden-workspace windows that are not parked, visible unmanaged windows, focus divergence, fully-transparent managed windows, and missing or unexpected dimming overlays. Run after reproducing a bug to see which state source diverged."
        inputSchema: {
            type: "object"
            properties: {
                bobrwm_bin: { type: "string", description: "Path to the bobrwm binary (default: PATH, then <repo>/zig-out/bin/bobrwm)" }
                frame_tolerance: { type: "number", description: "Max px difference between bobrwm frame and CG bounds before flagging drift (default: 2)" }
                expect_dimming_overlays: { type: "boolean", description: "Require overlays for every inactive visible window, including when none are present (default: false; use when dimming is known enabled)" }
                output_file: { type: "string", description: "Optional file path to save the raw snapshot + query JSON" }
            }
        }
    } | to json
}

def skill-dir [] {
    let file_pwd = ($env | get -o FILE_PWD | default ([$env.HOME, ".config", "agents", "skills", "bobrwm-state"] | path join))
    if ($file_pwd | path basename) == "toolbox" { $file_pwd | path dirname } else { $file_pwd }
}

def find-bobrwm [explicit] {
    if $explicit != null { return $explicit }
    let from_path = (which bobrwm | get -o 0 | get -o path)
    if $from_path != null { return $from_path }
    # Repo checkout: this skill lives at <repo>/.agents/skills/bobrwm-state
    let repo_bin = ([(skill-dir), "..", "..", "..", "zig-out", "bin", "bobrwm"] | path join | path expand)
    if ($repo_bin | path exists) { return $repo_bin }
    print "error: bobrwm binary not found on PATH or in zig-out/bin. Pass bobrwm_bin."
    exit 1
}

def probe-src [] {
    # The probe lives in the sibling probing-windows skill.
    let sibling = ([(skill-dir), "..", "probing-windows", "scripts", "probe.swift"] | path join | path expand)
    if ($sibling | path exists) { return $sibling }
    let installed = ([$env.HOME, ".config", "agents", "skills", "probing-windows", "scripts", "probe.swift"] | path join)
    if ($installed | path exists) { return $installed }
    print "error: probing-windows skill not found; its probe.swift provides the CG+AX snapshot"
    exit 1
}

def find-toolchain [] {
    let candidates = [
        "/Applications/Xcode.app/Contents/Developer"
        "/Applications/Xcode-beta.app/Contents/Developer"
        "/Library/Developer/CommandLineTools"
    ]
    for dev_dir in $candidates {
        let sdk = ([$dev_dir, "Platforms", "MacOSX.platform", "Developer", "SDKs", "MacOSX.sdk"] | path join)
        let clt_sdk = ([$dev_dir, "SDKs", "MacOSX.sdk"] | path join)
        if ($sdk | path exists) {
            return { developer_dir: $dev_dir, sdk: $sdk }
        }
        if ($clt_sdk | path exists) {
            return { developer_dir: $dev_dir, sdk: $clt_sdk }
        }
    }
    print "error: no Xcode or CommandLineTools SDK found"
    exit 1
}

# Same cache as probing-windows/probe_windows.nu so the binary is shared.
def ensure-probe-binary [] {
    let swift_src = (probe-src)
    let cache_dir = ([$env.HOME, ".cache", "bobrwm-skills"] | path join)
    mkdir $cache_dir
    let src_hash = (open --raw $swift_src | hash sha256 | str substring 0..15)
    let probe_bin = ([$cache_dir, $"window-probe-($src_hash)"] | path join)

    if not ($probe_bin | path exists) {
        let toolchain = (find-toolchain)
        with-env {DEVELOPER_DIR: $toolchain.developer_dir} {
            ^/usr/bin/swiftc -O -sdk $toolchain.sdk -o $probe_bin $swift_src
        }
    }
    $probe_bin
}

def os-window [os_windows, wid: int] {
    $os_windows | where {|w| $w.wid == $wid } | get -o 0
}

def bounds-match [a, b, tolerance: number] {
    (($a.x - $b.x | math abs) <= $tolerance)
    and (($a.y - $b.y | math abs) <= $tolerance)
    and (($a.w - $b.w | math abs) <= $tolerance)
    and (($a.h - $b.h | math abs) <= $tolerance)
}

# Overlap of a CG rect with a display's visible frame, as {w, h}.
def overlap-with-display [bounds, frame] {
    let right = ([($bounds.x + $bounds.w), ($frame.x + $frame.width)] | math min)
    let left = ([$bounds.x, $frame.x] | math max)
    let bottom = ([($bounds.y + $bounds.h), ($frame.y + $frame.height)] | math min)
    let top = ([$bounds.y, $frame.y] | math max)
    let ow = $right - $left
    let oh = $bottom - $top
    { w: ([$ow, 0] | math max), h: ([$oh, 0] | math max) }
}

def execute [] {
    let input = ($in | from json)
    let tolerance = ($input | get -o frame_tolerance | default 2)
    let expect_dimming_overlays = ($input | get -o expect_dimming_overlays | default false)
    let output_file = ($input | get -o output_file)

    let bobrwm = (find-bobrwm ($input | get -o bobrwm_bin))

    let ws_result = (^$bobrwm query workspaces --json | complete)
    if $ws_result.exit_code != 0 {
        print $"error: could not query the bobrwm daemon via ($bobrwm). Is it running? \(check /tmp/bobrwm_<uid>.sock\)"
        print ($ws_result.stderr | str trim)
        exit 1
    }
    let workspaces = ($ws_result.stdout | from json)
    let displays = (^$bobrwm query displays --json | from json)

    # Flatten managed windows, annotated with workspace visibility and focus.
    let managed = ($workspaces | each {|ws|
        $ws.windows | each {|w|
            $w
            | insert ws_visible $ws.visible
            | insert ws_focused ($ws.focused_window == $w.window_id)
        }
    } | flatten)
    let managed_wids = ($managed | get window_id)
    let pids = ($managed | get process_id | uniq)

    # One CG pass over every window on the system; AX only for managed pids.
    let probe_bin = (ensure-probe-binary)
    let snap_raw = if ($pids | is-empty) {
        ^$probe_bin --snapshot
    } else {
        ^$probe_bin --snapshot --ax-pids ($pids | each {|p| $p | into string } | str join ",")
    }
    let os_windows = ($snap_raw | from json | get windows)

    if $output_file != null {
        {
            workspaces: $workspaces
            displays: $displays
            snapshot: ($snap_raw | from json)
        } | to json | save -f $output_file
    }

    print $"bobrwm state: ($workspaces | length) workspaces, ($managed | length) managed windows, ($pids | length) app pids"
    print $"OS snapshot: ($os_windows | length) CG windows system-wide"
    print ""

    mut issues = 0

    # 1. Managed windows whose CG window no longer exists (stale store entries).
    let stale = ($managed | where {|m| (os-window $os_windows $m.window_id) == null })
    if ($stale | is-empty) {
        print "[ok] stale entries: none — every managed window still exists in CG"
    } else {
        $issues += ($stale | length)
        print $"[ISSUE] stale entries: ($stale | length) managed windows no longer exist in CG \(store/cleanup bug or destroyed native tab\):"
        $stale | select window_id process_id bundle_id workspace_id | to md | print
    }

    # 2. Frame drift on visible workspaces: bobrwm's stored frame vs CG bounds.
    let drift = ($managed | where ws_visible | each {|m|
        let os = (os-window $os_windows $m.window_id)
        if $os == null { null } else {
            let minimized = ($os | get -o minimized | default false)
            let dx = ($m.frame.x - $os.cg_bounds.x | math abs)
            let dy = ($m.frame.y - $os.cg_bounds.y | math abs)
            let dw = ($m.frame.width - $os.cg_bounds.w | math abs)
            let dh = ($m.frame.height - $os.cg_bounds.h | math abs)
            if (not $minimized) and ($dx > $tolerance or $dy > $tolerance or $dw > $tolerance or $dh > $tolerance) {
                {
                    window_id: $m.window_id
                    bundle_id: $m.bundle_id
                    bobrwm_frame: $"($m.frame.x),($m.frame.y) ($m.frame.width)x($m.frame.height)"
                    cg_bounds: $"($os.cg_bounds.x),($os.cg_bounds.y) ($os.cg_bounds.w)x($os.cg_bounds.h)"
                }
            } else { null }
        }
    } | compact)
    if ($drift | is-empty) {
        print $"[ok] frame drift: none over ($tolerance)px on visible workspaces"
    } else {
        $issues += ($drift | length)
        print $"[ISSUE] frame drift: ($drift | length) visible windows where bobrwm's stored frame disagrees with CG \(missed retile, failed AX write, or in-flight transition — re-run to rule out animation\):"
        $drift | to md | print
    }

    # 3. Hidden-workspace windows must be parked (only peek pixels on screen).
    let unparked = ($managed | where {|m| not $m.ws_visible } | each {|m|
        let os = (os-window $os_windows $m.window_id)
        if $os == null or (not $os.cg_onscreen) { null } else {
            let visible_overlap = ($displays | each {|d|
                let o = (overlap-with-display $os.cg_bounds $d.visible_frame)
                [$o.w, $o.h] | math min
            } | append 0 | math max)
            # Parked windows keep <=5 peek pixels visible; anything clearly
            # inside a display while its workspace is hidden was left behind.
            if $visible_overlap > 10 {
                {
                    window_id: $m.window_id
                    bundle_id: $m.bundle_id
                    workspace_id: $m.workspace_id
                    cg_bounds: $"($os.cg_bounds.x),($os.cg_bounds.y) ($os.cg_bounds.w)x($os.cg_bounds.h)"
                    overlap_px: $visible_overlap
                }
            } else { null }
        }
    } | compact)
    if ($unparked | is-empty) {
        print "[ok] hidden workspaces: all hidden-workspace windows are parked off-screen"
    } else {
        $issues += ($unparked | length)
        print $"[ISSUE] hidden workspaces: ($unparked | length) windows on hidden workspaces are still visible on a display \(workspace transition or hide/retile bug\):"
        $unparked | to md | print
    }

    # 4. Visible, AX-ready windows of managed apps that bobrwm does not manage.
    let unmanaged = ($os_windows | where {|w|
        (
            ($w.pid in $pids) and $w.cg_layer == 0 and $w.cg_onscreen
            and $w.cg_alpha > 0.05 and $w.manage_state == "ready"
            and (not ($w.wid in $managed_wids))
        )
    })
    if ($unmanaged | is-empty) {
        print "[ok] unmanaged visible: none — every visible standard window of managed apps is tracked"
    } else {
        $issues += ($unmanaged | length)
        print $"[ISSUE] unmanaged visible: ($unmanaged | length) visible AX-ready windows of managed apps are not in any workspace \(missed adoption, creation race, or a suppressed tab member that became visible\):"
        $unmanaged | select wid pid title | to md | print
    }

    # 5. Focus divergence: bobrwm's focused window vs the app's AXFocusedWindow.
    for ws in ($workspaces | where visible) {
        let fwid = ($ws | get -o focused_window)
        if $fwid == null { continue }
        let os = (os-window $os_windows $fwid)
        if $os == null {
            $issues += 1
            print $"[ISSUE] focus: workspace ($ws.workspace_id) focused window ($fwid) does not exist in CG \(stale focus after close?\)"
            continue
        }
        # Apps can swap the active native-tab CG window ID under bobrwm; the
        # app's own AXFocusedWindow is the tell.
        let ax_focused = ($os_windows | where {|w| $w.pid == $os.pid and $w.focused } | get -o 0 | get -o wid)
        if $ax_focused != null and $ax_focused != $fwid {
            $issues += 1
            print $"[ISSUE] focus: workspace ($ws.workspace_id) focused window ($fwid) but its app \(pid ($os.pid)\) reports AXFocusedWindow ($ax_focused) — possible stale native-tab window ID"
        } else {
            print $"[ok] focus: workspace ($ws.workspace_id) focused window ($fwid) exists and matches its app's AXFocusedWindow"
        }
    }

    # 6. Fully transparent managed windows indicate an app/restore ghost. The
    # dimmer does not change target alpha; it draws a separate overlay panel.
    let transparent = ($managed | where ws_visible | each {|m|
        let os = (os-window $os_windows $m.window_id)
        if $os != null and $os.cg_alpha < 0.05 and (($os | get -o minimized | default false) == false) {
            { window_id: $m.window_id, bundle_id: $m.bundle_id, cg_alpha: $os.cg_alpha }
        } else { null }
    } | compact)
    if ($transparent | is-empty) {
        print "[ok] target alpha: no managed visible-workspace window is fully transparent"
    } else {
        $issues += ($transparent | length)
        print $"[ISSUE] target alpha: ($transparent | length) managed windows on visible workspaces are fully transparent \(app ghost or restore bug?\):"
        $transparent | to md | print
    }

    # 7. A visible inactive managed window must have one bobrwm-owned layer-0
    # overlay with the same frame. Focused windows must have no overlay. CG's
    # global list index is captured for timelines but is not a reliable
    # cross-process above/below assertion for AppKit panels.
    let overlays = ($os_windows | where {|w|
        $w.window_kind == "dimming_overlay" and $w.cg_onscreen and $w.cg_alpha > 0.01
    })
    let has_visible_focus = not ($workspaces | where {|ws| $ws.visible and (($ws | get -o focused_window) != null) } | is-empty)
    let expected_dim_targets = ($managed | where {|m| $has_visible_focus and $m.ws_visible and (not $m.ws_focused) } | each {|m|
        let os = (os-window $os_windows $m.window_id)
        if $os == null or (not $os.cg_onscreen) or $os.cg_alpha <= 0.01 or (($os | get -o minimized | default false) == true) {
            null
        } else { $m | insert os_window $os }
    } | compact)

    let missing_overlays = if $expect_dimming_overlays or (not ($overlays | is-empty)) {
        $expected_dim_targets | where {|m|
            ($overlays | where {|o| bounds-match $o.cg_bounds $m.os_window.cg_bounds $tolerance } | is-empty)
        } | each {|m| {
            window_id: $m.window_id
            bundle_id: $m.bundle_id
            target_bounds: $"($m.os_window.cg_bounds.x),($m.os_window.cg_bounds.y) ($m.os_window.cg_bounds.w)x($m.os_window.cg_bounds.h)"
        }}
    } else { [] }

    let unexpected_overlays = ($overlays | where {|o|
        ($expected_dim_targets | where {|m| bounds-match $o.cg_bounds $m.os_window.cg_bounds $tolerance } | is-empty)
    } | each {|o| {
        overlay_wid: $o.wid
        alpha: $o.cg_alpha
        overlay_bounds: $"($o.cg_bounds.x),($o.cg_bounds.y) ($o.cg_bounds.w)x($o.cg_bounds.h)"
    }})

    let overlay_issues = ($missing_overlays | length) + ($unexpected_overlays | length)
    if $overlay_issues == 0 and ($overlays | is-empty) {
        print "[info] dimming overlays: none visible; pass expect_dimming_overlays=true when dimming is known enabled"
    } else if $overlay_issues == 0 {
        print $"[ok] dimming overlays: ($overlays | length) visible overlays match inactive window frames"
    } else {
        $issues += $overlay_issues
        if not ($missing_overlays | is-empty) {
            print $"[ISSUE] dimming overlays: ($missing_overlays | length) inactive visible windows have no matching overlay:"
            $missing_overlays | to md | print
        }
        if not ($unexpected_overlays | is-empty) {
            print $"[ISSUE] dimming overlays: ($unexpected_overlays | length) visible overlays do not match an inactive visible window:"
            $unexpected_overlays | to md | print
        }
    }

    print ""
    if $issues == 0 {
        print "Result: bobrwm state and OS state are consistent."
    } else {
        print $"Result: ($issues) divergences found. Cross-reference AGENTS.md 'Window Management Invariants' and use probe_windows to capture the transition timeline."
    }
}

def main [] {
    let input_json = $in
    let action = ($env | get -o TOOLBOX_ACTION | default "describe")
    match $action {
        "describe" => { describe }
        "execute" => { $input_json | execute }
        _ => {
            $"Unknown action: ($action)\n" | save --raw --append /dev/stderr
            exit 1
        }
    }
}
