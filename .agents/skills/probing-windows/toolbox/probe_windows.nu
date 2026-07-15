#!/usr/bin/env nu

# Toolbox tool: probe macOS window metadata (CG + AX) over time

def describe [] {
    {
        name: "probe_windows"
        description: "Probe macOS window metadata (CG + AX) for a given app process over time, including bobrwm-owned dimming overlays. Samples CGWindowList and AXUIElement attributes periodically, emitting structured JSONL. Use to debug AX role readiness, window creation timing, focus changes, overlay transitions, or Electron app behavior."
        inputSchema: {
            type: "object"
            properties: {
                app: { type: "string", description: "App name to kill, relaunch, and probe (e.g. Discord, Safari)" }
                pid: { type: "integer", description: "PID to probe directly (skips app launch)" }
                wid: { type: "integer", description: "CG window ID to query directly. Can be combined with pid to verify ownership." }
                duration_sec: { type: "integer", description: "How many seconds to sample (default: 10)" }
                interval_ms: { type: "integer", description: "Milliseconds between samples (default: 100)" }
                include_dimming_overlays: { type: "boolean", description: "Include bobrwm-owned dimming overlay windows (default: true)" }
                output_file: { type: "string", description: "Optional file path to save raw JSONL output" }
            }
        }
    } | to json
}

# Locate an SDK + DEVELOPER_DIR pair that can build against ApplicationServices.
# The Nix-provided SDK lacks private AX symbols, so prefer a real Xcode install.
export def find-toolchain [] {
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
    print "error: no Xcode or CommandLineTools SDK found (looked in /Applications/Xcode.app, /Applications/Xcode-beta.app, /Library/Developer/CommandLineTools)"
    exit 1
}

export def skill-dir [] {
    let file_pwd = ($env | get -o FILE_PWD | default ([$env.HOME, ".config", "agents", "skills", "probing-windows"] | path join))
    if ($file_pwd | path basename) == "toolbox" { $file_pwd | path dirname } else { $file_pwd }
}

# Compile probe.swift once per source revision; reuse the cached binary after.
export def ensure-probe-binary [] {
    let swift_src = ([(skill-dir), "scripts", "probe.swift"] | path join)
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

def execute [] {
    let input = ($in | from json)

    let app = ($input | get -o app)
    let pid_arg = ($input | get -o pid)
    let wid_arg = ($input | get -o wid)
    let duration_sec = ($input | get -o duration_sec | default 10)
    let interval_ms_val = ($input | get -o interval_ms | default 100)
    let include_dimming_overlays = ($input | get -o include_dimming_overlays | default true)
    let output_file = ($input | get -o output_file)

    let duration_ms = $duration_sec * 1000

    # Resolve PID
    let target_pid = if $pid_arg != null {
        $pid_arg
    } else if $app != null {
        try { ^pkill -x $app }
        sleep 1sec
        ^open -a $app

        mut found_pid = null
        for _ in 1..200 {
            let exact_result = try { ^pgrep -x $app | lines | first } catch { "" }
            let result = if ($exact_result | is-not-empty) {
                $exact_result
            } else {
                let full_result = try { ^pgrep -f $app | lines | first } catch { "" }
                if ($full_result | is-not-empty) {
                    $full_result
                } else {
                    try {
                        ^ps ax -ww -o pid=,args=
                        | lines
                        | where {|line| $line | str downcase | str contains ($app | str downcase) }
                        | first
                        | str trim
                        | split row " "
                        | where {|part| $part | is-not-empty }
                        | first
                    } catch { "" }
                }
            }
            if ($result | is-not-empty) {
                $found_pid = ($result | into int)
                break
            }
            sleep 100ms
        }
        if $found_pid == null {
            print $"error: ($app) process did not appear after launch"
            exit 1
        }
        $found_pid
    } else {
        null
    }

    if $target_pid == null and $wid_arg == null {
        print "error: app, pid, or wid parameter is required"
        exit 1
    }

    let probe_bin = (ensure-probe-binary)

    # Run probe
    mut probe_args = [--duration-ms $"($duration_ms)" --interval-ms $"($interval_ms_val)"]
    if $target_pid != null { $probe_args = ($probe_args | append [--pid $"($target_pid)"]) }
    if $wid_arg != null { $probe_args = ($probe_args | append [--wid $"($wid_arg)"]) }
    if $include_dimming_overlays { $probe_args = ($probe_args | append "--include-dimming-overlays") }
    let raw_output = (^$probe_bin ...$probe_args)

    # Save raw JSONL if requested
    if $output_file != null {
        $raw_output | save -f $output_file
    }

    # Parse events
    let events = ($raw_output | lines | where {|line| $line | is-not-empty } | each {|line| $line | from json })

    let changes = ($events | where {|e| $e.type == "change" and $e.change == "changed" })
    let samples = ($events | where {|e| $e.type == "sample" })

    if ($samples | is-empty) {
        print "No samples collected."
        return
    }

    let last_sample = ($samples | last)
    let windows = ($last_sample | get windows)

    # Build summary
    let summary = ($windows | each {|w|
        let wid = ($w | get wid)
        let first_added = ($events | where {|e| $e.type == "change" and $e.change == "added" and ($e | get -o current | get -o wid) == $wid } | first)
        let first_seen_ms = if ($first_added | is-not-empty) { $first_added | get elapsed_ms } else { "?" }

        let ready_change = ($changes | where {|e| ($e | get -o current | get -o wid) == $wid and ($e | get -o current | get -o manage_state) == "ready" } | first)
        let ready_ms = if ($ready_change | is-not-empty) { $ready_change | get elapsed_ms } else { "-" }

        {
            pid: ($w | get pid)
            wid: $wid
            kind: ($w | get window_kind)
            owner: ($w | get -o owner_name | default "")
            cg_order: ($w | get cg_order)
            onscreen: ($w | get cg_onscreen)
            layer: ($w | get cg_layer)
            alpha: ($w | get cg_alpha)
            role: ($w | get -o role | default "null")
            subrole: ($w | get -o subrole | default "null")
            manage_state: ($w | get manage_state)
            focused: ($w | get -o focused | default false)
            minimized: ($w | get -o minimized | default "?")
            bounds: ($"x=($w.cg_bounds.x) y=($w.cg_bounds.y) w=($w.cg_bounds.w) h=($w.cg_bounds.h)")
            title: ($w | get -o title | default ($w | get -o window_name | default ""))
            first_seen_ms: $first_seen_ms
            role_ready_ms: $ready_ms
        }
    })

    # Output for model consumption
    let target_desc = if $target_pid != null and $wid_arg != null {
        $"pid=($target_pid) wid=($wid_arg)"
    } else if $target_pid != null {
        $"pid=($target_pid)"
    } else {
        $"wid=($wid_arg)"
    }
    print $"Probed ($target_desc) for ($duration_sec)s at ($interval_ms_val)ms intervals"
    print $"Total samples: ($samples | length), Windows in final sample: ($windows | length)"
    print ""
    $summary | to md | print
    print ""

    # Also output raw change timeline for detailed analysis
    let change_events = ($events | where {|e| $e.type == "change" })
    if ($change_events | is-not-empty) {
        print "Change timeline:"
        for event in $change_events {
            let wid = ($event | get -o wid | default ($event | get -o current | get -o wid | default "?"))
            let pid = ($event | get -o current | get -o pid | default ($event | get -o previous | get -o pid | default "?"))
            let state = ($event | get -o current | get -o manage_state | default "?")
            let kind = ($event | get -o current | get -o window_kind | default ($event | get -o previous | get -o window_kind | default "window"))
            let onscreen = ($event | get -o current | get -o cg_onscreen | default "?")
            let fields = ($event | get -o fields_changed | default [] | str join ",")
            let detail = if ($fields | is-empty) { "" } else {
                # Show old -> new for the fields that actually changed
                $fields | split row "," | each {|f|
                    let prev_val = ($event | get -o previous | get -o $f | default "?")
                    let cur_val = ($event | get -o current | get -o $f | default "?")
                    if $f == "cg_bounds" {
                        let p = ($event | get -o previous | get -o cg_bounds)
                        let c = ($event | get -o current | get -o cg_bounds)
                        $"cg_bounds: ($p.x),($p.y) ($p.w)x($p.h) -> ($c.x),($c.y) ($c.w)x($c.h)"
                    } else {
                        $"($f): ($prev_val) -> ($cur_val)"
                    }
                } | str join "; " | $" [($in)]"
            }
            print $"  ($event.elapsed_ms)ms: ($event.change) kind=($kind) pid=($pid) wid=($wid) onscreen=($onscreen) manage_state=($state)($detail)"
        }
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
