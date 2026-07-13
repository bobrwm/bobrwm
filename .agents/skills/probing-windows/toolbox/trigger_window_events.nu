#!/usr/bin/env nu

# Toolbox tool: generate window lifecycle/focus events via AppleScript (System Events)
#
# Complements trigger_native_tabs: where that tool drives tab lifecycle, this
# one drives app-level events (focus, hide, minimize, close, move, resize) so
# bobrwm's focus reconciliation, cleanup, dimming, and retiling paths can be
# exercised deterministically while a probe is running.

def describe [] {
    {
        name: "trigger_window_events"
        description: "Trigger window events (activate, hide/unhide app, minimize/unminimize, close, move, resize front window) for a macOS app via AppleScript. Use while probe_windows is running to generate deterministic focus/visibility/geometry events for window-manager debugging."
        inputSchema: {
            type: "object"
            required: ["app", "operation"]
            properties: {
                app: { type: "string", description: "App name as seen by System Events (e.g. Ghostty, Discord, Safari)" }
                operation: { type: "string", description: "One of: activate, hide, unhide, minimize, unminimize, close_front, move_front, resize_front, cycle_focus" }
                x: { type: "integer", description: "Target x for move_front (screen coordinates)" }
                y: { type: "integer", description: "Target y for move_front (screen coordinates)" }
                width: { type: "integer", description: "Target width for resize_front" }
                height: { type: "integer", description: "Target height for resize_front" }
                other_app: { type: "string", description: "Second app for cycle_focus (default: Finder)" }
                count: { type: "integer", description: "How many times to repeat the operation (default: 1)" }
                interval_ms: { type: "integer", description: "Delay between repeats in milliseconds (default: 300)" }
            }
        }
    } | to json
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

# System Events acts on "process" objects, so most operations share this shell.
def process-script [app: string, count: int, interval_sec: float, body: list<string>] {
    [
        "tell application \"System Events\""
        $"tell process \"($app)\""
        $"repeat with i from 1 to ($count)"
    ] | append $body | append [
        $"delay ($interval_sec)"
        "end repeat"
        "end tell"
        "end tell"
    ]
}

def execute [] {
    let input = ($in | from json)

    let app = ($input | get -o app)
    let operation = ($input | get -o operation)
    let count = ($input | get -o count | default 1)
    let interval_ms = ($input | get -o interval_ms | default 300)
    let other_app = ($input | get -o other_app | default "Finder")

    if $app == null or $operation == null {
        print "error: app and operation are required"
        exit 1
    }
    if $count <= 0 {
        print "error: count must be > 0"
        exit 1
    }

    let valid = ["activate", "hide", "unhide", "minimize", "unminimize", "close_front", "move_front", "resize_front", "cycle_focus"]
    if not ($operation in $valid) {
        print $"error: invalid operation '($operation)'. expected one of: ($valid | str join ', ')"
        exit 1
    }

    let interval_sec = (($interval_ms | into float) / 1000.0)

    let script_lines = (match $operation {
        "activate" => {
            [
                $"tell application \"($app)\" to activate"
                $"delay ($interval_sec)"
            ]
        }
        "hide" => {
            # AppleScript `hide` on the app object maps to Cmd-H app hiding,
            # the same path bobrwm sees as an app-level visibility change.
            (process-script $app $count $interval_sec [
                "set visible to false"
            ])
        }
        "unhide" => {
            (process-script $app $count $interval_sec [
                "set visible to true"
            ])
        }
        "minimize" => {
            (process-script $app $count $interval_sec [
                "try"
                "set value of attribute \"AXMinimized\" of front window to true"
                "end try"
            ])
        }
        "unminimize" => {
            (process-script $app $count $interval_sec [
                "try"
                "set value of attribute \"AXMinimized\" of window 1 to false"
                "end try"
            ])
        }
        "close_front" => {
            (process-script $app $count $interval_sec [
                "try"
                "click (first button of front window whose subrole is \"AXCloseButton\")"
                "end try"
            ])
        }
        "move_front" => {
            let x = ($input | get -o x)
            let y = ($input | get -o y)
            if $x == null or $y == null {
                print "error: move_front requires x and y"
                exit 1
            }
            (process-script $app $count $interval_sec [
                $"set position of front window to {($x), ($y)}"
            ])
        }
        "resize_front" => {
            let width = ($input | get -o width)
            let height = ($input | get -o height)
            if $width == null or $height == null {
                print "error: resize_front requires width and height"
                exit 1
            }
            (process-script $app $count $interval_sec [
                $"set size of front window to {($width), ($height)}"
            ])
        }
        "cycle_focus" => {
            # Alternate activation between two apps to exercise focus
            # reconciliation and inactive-window dimming.
            [
                $"repeat with i from 1 to ($count)"
                $"tell application \"($app)\" to activate"
                $"delay ($interval_sec)"
                $"tell application \"($other_app)\" to activate"
                $"delay ($interval_sec)"
                "end repeat"
                $"tell application \"($app)\" to activate"
            ]
        }
    })

    let result = (run-applescript $script_lines)
    if not $result.ok {
        print $"error: AppleScript execution failed for app=($app) operation=($operation)"
        print $result.error
        exit 1
    }

    print $"Triggered window events: app=($app) operation=($operation) count=($count) interval_ms=($interval_ms)"
    if ($result.output | str trim | is-not-empty) {
        print "AppleScript output:"
        print $result.output
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
