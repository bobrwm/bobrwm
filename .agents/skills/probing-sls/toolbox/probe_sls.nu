#!/usr/bin/env nu

def find-toolchain [] {
    for dev_dir in ["/Library/Developer/CommandLineTools" "/Applications/Xcode.app/Contents/Developer" "/Applications/Xcode-beta.app/Contents/Developer"] {
        for suffix in ["Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" "SDKs/MacOSX.sdk"] {
            let sdk = ([$dev_dir, $suffix] | path join)
            if ($sdk | path exists) { return {developer_dir: $dev_dir, sdk: $sdk} }
        }
    }
    print --stderr "error: no Xcode or CommandLineTools SDK found"
    exit 1
}

def describe [] {
    {
        name: "probe_sls"
        description: "Read-only SkyLight probe: sample native Space IDs and display animation state over time, or inspect exported symbols without invoking them. Reports unavailable observations explicitly."
        inputSchema: {
            type: "object"
            properties: {
                display_ids: { type: "array", items: { type: "integer", minimum: 1 }, description: "Physical CG display IDs (default: main display)" }
                duration_sec: { type: "number", minimum: 0, description: "Capture seconds; 0 takes one snapshot (default: 10)" }
                interval_ms: { type: "number", exclusiveMinimum: 0, description: "Milliseconds between samples (default: 100)" }
                all_samples: { type: "boolean", description: "Include unchanged samples (default: false)" }
                symbols: { type: "array", items: { type: "string" }, description: "Inspect these exports instead of sampling displays" }
                output_file: { type: "string", description: "Optional file path to save raw JSONL output" }
            }
        }
    } | to json
}

def ensure-probe-binary [] {
    let swift_src = ([$env.FILE_PWD, "..", "scripts", "probe.swift"] | path join | path expand)
    let cache_dir = ([$env.HOME, ".cache", "bobrwm-skills"] | path join)
    mkdir $cache_dir
    let src_hash = (open --raw $swift_src | hash sha256 | str substring 0..15)
    let probe_bin = ([$cache_dir, $"sls-probe-($src_hash)"] | path join)
    if ($probe_bin | path exists) { return $probe_bin }

    let toolchain = (find-toolchain)
    let result = (with-env {DEVELOPER_DIR: $toolchain.developer_dir} {
        ^/usr/bin/swiftc -O -sdk $toolchain.sdk -o $probe_bin $swift_src | complete
    })
    if $result.exit_code != 0 {
        print --stderr $result.stderr
        exit $result.exit_code
    }
    $probe_bin
}

def execute [] {
    let input = ($in | from json)
    mut args = [--duration ($input | get -o duration_sec | default 10 | into string) --interval-ms ($input | get -o interval_ms | default 100 | into string)]
    for display in ($input | get -o display_ids | default []) {
        $args = ($args | append [--display ($display | into string)])
    }
    for symbol in ($input | get -o symbols | default []) {
        $args = ($args | append [--symbol $symbol])
    }
    if ($input | get -o all_samples | default false) { $args = ($args | append "--all-samples") }

    let probe_bin = (ensure-probe-binary)
    let result = (^$probe_bin ...$args | complete)
    let output_file = ($input | get -o output_file)
    if $output_file != null { $result.stdout | save -f $output_file }
    if $result.exit_code != 0 {
        print --stderr $result.stderr
        exit $result.exit_code
    }

    let events = ($result.stdout | lines | where {|line| $line | is-not-empty } | each {|line| $line | from json })
    let symbols = ($events | where type == "symbol")
    if ($symbols | is-not-empty) {
        $symbols | select symbol available library | to md | print
        return
    }
    let summary = ($events | where type == "summary" | first)
    print $"SLS probe: ($summary.sample_count) samples, ($summary.emitted_count) emitted observations"
    $events | where type == "sample" | select elapsed_ms wall_time display_id space_id is_animating unavailable | to md | print
}

def main [] {
    let input_json = $in
    let action = ($env | get -o TOOLBOX_ACTION | default "describe")
    match $action {
        "describe" => { describe }
        "execute" => { $input_json | execute }
        _ => {
            print --stderr $"Unknown action: ($action)"
            exit 1
        }
    }
}
