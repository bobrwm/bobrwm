#!/usr/bin/env nu

# Toolbox tool: probe macOS window metadata (CG + AX) over time

def describe [] {
    {
        name: "probe_windows"
        description: "Probe macOS window metadata (CG + AX) for a given app process over time. Samples CGWindowList and AXUIElement attributes periodically, emitting structured JSONL. Use to debug AX role readiness, window creation timing, or Electron app behavior."
        inputSchema: {
            type: "object"
            properties: {
                app: { type: "string", description: "App name to kill, relaunch, and probe (e.g. Discord, Safari)" }
                pid: { type: "integer", description: "PID to probe directly (skips app launch)" }
                duration_sec: { type: "integer", description: "How many seconds to sample (default: 10)" }
                interval_ms: { type: "integer", description: "Milliseconds between samples (default: 100)" }
                output_file: { type: "string", description: "Optional file path to save raw JSONL output" }
            }
        }
    } | to json
}

def execute [] {
    let input = ($in | from json)

    let app = ($input | get -o app)
    let pid_arg = ($input | get -o pid)
    let duration_sec = ($input | get -o duration_sec | default 10)
    let interval_ms_val = ($input | get -o interval_ms | default 100)
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
            let result = try { ^pgrep -x $app | lines | first } catch { "" }
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
        print "error: either app or pid parameter is required"
        exit 1
    }

    # Build swift probe (use Xcode toolchain to avoid Nix SDK conflicts)
    let skill_dir = ($env | get -o FILE_PWD | default ([$env.HOME, ".config", "agents", "skills", "probing-windows"] | path join))
    let swift_src = ([$skill_dir, "scripts", "probe.swift"] | path join)
    let tmp_dir = (mktemp -d)
    let probe_bin = ([$tmp_dir, "window-probe"] | path join)

    let xcode_sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    with-env {DEVELOPER_DIR: "/Applications/Xcode.app/Contents/Developer"} {
        ^/usr/bin/swiftc -O -sdk $xcode_sdk -o $probe_bin $swift_src
    }

    # Run probe
    let raw_output = (^$probe_bin --pid $"($target_pid)" --duration-ms $"($duration_ms)" --interval-ms $"($interval_ms_val)")

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
            wid: $wid
            role: ($w | get -o role | default "null")
            subrole: ($w | get -o subrole | default "null")
            manage_state: ($w | get manage_state)
            first_seen_ms: $first_seen_ms
            role_ready_ms: $ready_ms
        }
    })

    # Output for model consumption
    print $"Probed pid=($target_pid) for ($duration_sec)s at ($interval_ms_val)ms intervals"
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
            let state = ($event | get -o current | get -o manage_state | default "?")
            print $"  ($event.elapsed_ms)ms: ($event.change) wid=($wid) manage_state=($state)"
        }
    }

    # Cleanup
    rm -rf $tmp_dir
}

def main [] {
    let action = ($env | get -o TOOLBOX_ACTION | default "describe")
    match $action {
        "describe" => { describe }
        "execute" => { execute }
        _ => {
            $"Unknown action: ($action)\n" | save --raw --append /dev/stderr
            exit 1
        }
    }
}
