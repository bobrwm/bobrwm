#!/usr/bin/env nu

# Toolbox tool: trigger native tab creation/deletion via AppleScript

def describe [] {
    {
        name: "trigger_native_tabs"
        description: "Trigger native tab create/close operations for AppleScript-enabled macOS apps. Use during window-manager debugging to generate repeatable tab lifecycle events while a probe is running."
        inputSchema: {
            type: "object"
            properties: {
                app: { type: "string", description: "AppleScript app name (default: Ghostty)" }
                operation: { type: "string", description: "One of: new_window, create_tabs, close_tabs, pulse_tabs" }
                count: { type: "integer", description: "How many operations to perform (default: 1)" }
                interval_ms: { type: "integer", description: "Delay between operations in milliseconds (default: 200)" }
                activate: { type: "boolean", description: "Activate app before operations (default: true)" }
                use_keystroke_fallback: { type: "boolean", description: "Fallback to Command-key shortcuts if app-specific AppleScript commands fail (default: true)" }
            }
        }
    } | to json
}

def validate-operation [operation: string] {
    if $operation in ["new_window", "create_tabs", "close_tabs", "pulse_tabs"] {
        return
    }

    print $"error: invalid operation '($operation)'. expected one of: new_window, create_tabs, close_tabs, pulse_tabs"
    exit 1
}

def run-applescript [lines: list<string>] {
    let script_path = (mktemp)
    ($lines | str join (char nl)) | save -f $script_path

    let result = (try {
        {
            ok: true
            output: (^/usr/bin/osascript $script_path)
            error: ""
        }
    } catch {|err|
        {
            ok: false
            output: ""
            error: ($err.msg | default "unknown osascript failure")
        }
    })

    rm -f $script_path
    $result
}

def build-keystroke-fallback [app: string, operation: string, count: int, interval_sec: float, activate: bool] {
    mut lines = [ $"tell application \"($app)\"" ]
    if $activate {
        $lines ++= ["activate"]
    }
    $lines ++= ["end tell"]

    $lines ++= [
        "tell application \"System Events\"",
        $"repeat with i from 1 to ($count)",
    ]

    match $operation {
        "new_window" => {
            $lines ++= [
                "keystroke \"n\" using {command down}",
                $"delay ($interval_sec)",
            ]
        }
        "create_tabs" => {
            $lines ++= [
                "keystroke \"t\" using {command down}",
                $"delay ($interval_sec)",
            ]
        }
        "close_tabs" => {
            $lines ++= [
                "keystroke \"w\" using {command down}",
                $"delay ($interval_sec)",
            ]
        }
        "pulse_tabs" => {
            $lines ++= [
                "keystroke \"t\" using {command down}",
                $"delay ($interval_sec)",
                "keystroke \"w\" using {command down}",
                $"delay ($interval_sec)",
            ]
        }
    }

    $lines ++= [
        "end repeat",
        "end tell",
    ]

    $lines
}

def execute [] {
    let input = ($in | from json)

    let app = ($input | get -o app | default "Ghostty")
    let operation = ($input | get -o operation | default "create_tabs")
    let count = ($input | get -o count | default 1)
    let interval_ms = ($input | get -o interval_ms | default 200)
    let activate = ($input | get -o activate | default true)
    let use_keystroke_fallback = ($input | get -o use_keystroke_fallback | default true)

    validate-operation $operation

    if $count <= 0 {
        print "error: count must be > 0"
        exit 1
    }

    if $interval_ms < 0 {
        print "error: interval_ms must be >= 0"
        exit 1
    }

    let interval_sec = (($interval_ms | into float) / 1000.0)
    mut script_lines = [ $"tell application \"($app)\"" ]

    if $activate {
        $script_lines ++= ["activate"]
    }

    match $operation {
        "new_window" => {
            $script_lines ++= [
                $"repeat with i from 1 to ($count)",
                "new window",
                $"delay ($interval_sec)",
                "end repeat",
            ]
        }
        "create_tabs" => {
            $script_lines ++= [
                $"repeat with i from 1 to ($count)",
                "try",
                "new tab",
                "on error",
                "new window",
                "delay 0.1",
                "new tab",
                "end try",
                $"delay ($interval_sec)",
                "end repeat",
            ]
        }
        "close_tabs" => {
            $script_lines ++= [
                $"repeat with i from 1 to ($count)",
                "try",
                "close tab (selected tab of front window)",
                "on error",
                "exit repeat",
                "end try",
                $"delay ($interval_sec)",
                "end repeat",
            ]
        }
        "pulse_tabs" => {
            $script_lines ++= [
                $"repeat with i from 1 to ($count)",
                "try",
                "new tab",
                "on error",
                "new window",
                "delay 0.1",
                "new tab",
                "end try",
                $"delay ($interval_sec)",
                "try",
                "close tab (selected tab of front window)",
                "on error",
                "exit repeat",
                "end try",
                $"delay ($interval_sec)",
                "end repeat",
            ]
        }
    }

    $script_lines ++= ["end tell"]

    let primary_result = (run-applescript $script_lines)
    mut fallback_used = false
    mut output = ($primary_result.output | default "")

    if not $primary_result.ok {
        if not $use_keystroke_fallback {
            print $"error: AppleScript execution failed for app=($app) operation=($operation)"
            print $primary_result.error
            exit 1
        }

        let fallback_lines = (build-keystroke-fallback $app $operation $count $interval_sec $activate)
        let fallback_result = (run-applescript $fallback_lines)
        if not $fallback_result.ok {
            print $"error: primary and keystroke fallback both failed for app=($app) operation=($operation)"
            print $"primary: ($primary_result.error)"
            print $"fallback: ($fallback_result.error)"
            exit 1
        }

        $fallback_used = true
        $output = ($fallback_result.output | default "")
    }

    print $"Triggered native tabs: app=($app) operation=($operation) count=($count) interval_ms=($interval_ms) fallback_used=($fallback_used)"
    if ($output | str trim | is-not-empty) {
        print "AppleScript output:"
        print $output
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
