# bobrwm

A tiling window manager for macOS, written in Zig.

The state-engine design and its invariants are defined in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Installation

```
brew trust bobrwm/tap
brew install --cask bobrwm/tap/bobrwm
```

Homebrew 6 refuses to load casks from third-party taps until you trust them, so
the first command is required rather than advisory.

This installs `Bobrwm.app` and symlinks the `bobrwm` client onto your `PATH`.
The build is signed, notarized and stapled, so Gatekeeper lets it run without
a detour through System Settings.

The cask tracks `main`: every push publishes a fresh build and updates the
cask, so `brew upgrade` picks it up. There are no tagged releases to wait for.

Bobrwm is still in early development. To build it yourself, see
[Development](#development); `zig build` produces `zig-out/Bobrwm.app`.

### Upgrading from the formula

bobrwm used to install as a formula that built from source. It ships as an app
bundle now, so replace it.

If you ran `bobrwm service install`, remove that launchd agent first. It points
at the old binary and `bobrwm service uninstall` is gone, so it has to go by
hand — otherwise launchd keeps trying to start a binary Homebrew is about to
delete:

```
launchctl bootout gui/$(id -u)/com.bobrwm.bobrwm
rm ~/Library/LaunchAgents/com.bobrwm.bobrwm.plist
```

Then swap the package:

```
brew uninstall --formula bobrwm
brew trust bobrwm/tap
brew install --cask bobrwm/tap/bobrwm
```

macOS ties Accessibility grants to a code signature, and the bundle is a
different subject than the old bare binary, so you will have to grant access
once more in System Settings > Privacy & Security > Accessibility.

## Usage

`bobrwm` is a client. It never starts the window manager itself — that is
`Bobrwm.app`, which runs as a menu-bar agent. Every command below is forwarded
to the running app over a unix socket.

```
bobrwm                    # show help
bobrwm query windows      # IPC: list managed windows
bobrwm query windows --json  # IPC: list managed windows as JSON
bobrwm query workspaces   # IPC: list workspaces
bobrwm query workspaces --json # IPC: list workspaces as JSON
bobrwm query displays     # IPC: list connected displays
bobrwm query displays --json # IPC: list connected displays as JSON
bobrwm query apps         # IPC: list observed apps
bobrwm query apps --json  # IPC: list observed apps as JSON
bobrwm focus-workspace next # IPC: switch to next workspace without wrapping
bobrwm focus-workspace prev # IPC: switch to previous workspace without wrapping
bobrwm move-to-display 2  # IPC: move focused window to display slot 2
bobrwm bsp insert-point min_depth     # IPC: focused | first | last | min_depth
bobrwm bsp ratio rel 0.05             # IPC: adjust focused parent split ratio
bobrwm bsp ratio abs 0.6              # IPC: set focused parent split ratio
bobrwm bsp mirror horizontal          # IPC: horizontal | vertical
bobrwm bsp equalize                   # IPC: set all split ratios to config ratio
bobrwm bsp balance                    # IPC: proportional balance by subtree size
bobrwm bsp rotate 90                  # IPC: 90 | 180 | 270
```

### Starting and stopping

Launch `Bobrwm.app` from Finder or Spotlight, or with `open -a Bobrwm`. Quit
from the menu-bar item. To run it at login, set `start-at-login = true` in
your config; there is no launchd agent to install by hand.

### Logging

The window manager sends logs to macOS unified logging and stderr. Both
destinations honor the configured log level, including debug in optimized
builds. Stream all Bobrwm records with:

```bash
log stream --level debug --predicate 'subsystem == "com.bobrwm.bobrwm"'
```

`BOBRWM_LOG` controls destinations with `stderr`, `macos`, `no-stderr`, and
`no-macos`; `true` enables both and `false` disables both.

Log level is compile-time configurable and applies to both binaries. Default
follows build mode (`debug` in Debug, `info` otherwise).

```bash
zig build -Dlog_level=debug
LOG_LEVEL=debug zig build
LOG_LEVEL=trace zig build   # alias of debug (extra trace-style diagnostics)
```

## Configuration

Config is loaded from (in order):

1. `-c` / `--config` CLI argument
2. `$XDG_CONFIG_HOME/bobrwm/config`
3. `~/.config/bobrwm/config`

If no config file is found, built-in defaults are used. The format follows
[ghostty's](https://ghostty.org/docs/config): one `key = value` per line, `#`
comments, and list options repeated once per entry. Set only what you want to
change:

```ini
workspace-name = term
workspace-name = web
workspace-name = code
gaps-inner = 4
gaps-outer-top = 4
keybind = alt+shift+h=swap_left
keybind = alt+1=focus_workspace:1
app-rule = app-id:com.apple.Safari,workspace:2
```

`bobrwm show-config --default --docs` lists every option with its
documentation and default, `bobrwm show-config` prints what your file changes,
and `bobrwm list-actions --docs` lists every keybind action.

Upgrading from a `config.zon`? Run `bobrwm migrate-config` to convert it.

Press `Alt+Shift+R` (the default `reload_config` binding) or run
`bobrwm reload-config` to apply changes without restarting. If the file
contains invalid lines or values outside the documented bounds, bobrwm keeps the
last valid configuration and shows a temporary error in its menu-bar item;
details remain in the error log. `bobrwm reload-config` is silent on success and
exits non-zero with an error message when the new config cannot be loaded.

### Workspaces

Each bobrwm workspace is assigned to exactly one ordinary Mission Control
Space across all displays. At startup, the primary display receives the lowest
workspace numbers in native ordinal order, so Bobrwm workspace 1 maps to its
native Space 1. Secondary displays follow in stable display order, with at
least one workspace reserved for each. Display configuration changes, including
disconnecting or reconnecting a monitor, rebuild this numbering in native Space
order. Renumbering keeps windows, layouts and focus history attached to surviving
Spaces. Ordinary Space observations preserve assignments by native Space ID.
Configure at least as many ordinary Mission Control Spaces in total as Bobrwm
workspaces, with at least one on every managed display. Bobrwm creates missing
Spaces on the primary display and
removes trailing extras so the physical count matches the configured workspace
count. It watches the native topology while running and reapplies this invariant
after external Space creation or deletion.

Full-screen application spaces are ignored when assigning workspace numbers,
but are crossed when switching. Switching uses the
high-velocity synthetic Dock gesture pioneered by InstantSpaceSwitcher;
on macOS 27 and later, Bobrwm also supplies the serialized IOHID payload now
required by Dock. Window moves and topology queries use private, undocumented
APIs. Either path can break on a future macOS release. Bobrwm waits for the
native transition to settle, then reconciles the landed Space against
WindowServer without injecting a second gesture from stale intermediate state.
Rapid switch requests are serialized at native Space-change confirmations;
while one is in flight, the newest requested workspace replaces older queued
requests.

### Trackpad swipes

Enable trackpad workspace switching in the main bobrwm config:

```ini
swipe-enabled = true
swipe-reverse = false
```

Bobrwm intercepts macOS's native horizontal Spaces gesture and immediately
requests the adjacent bobrwm workspace. The finger count comes from **System
Settings → Trackpad → More Gestures → Swipe between full-screen applications**;
it is not duplicated in bobrwm's config. Vertical Mission Control and App
Exposé gestures pass through unchanged.

Bobrwm starts the listener itself and uses its existing Accessibility grant.
Horizontal gestures are consumed for their complete lifetime. At the first or
last bobrwm workspace no switch occurs; that boundary gesture cannot safely be
handed back to the Dock after its opening events were already suppressed.

To diagnose swipe/keyboard switching, run:

```bash
zig build run -Doptimize=ReleaseFast -Dlog_level=debug
```

Debug logs include gesture phases and raw progress/velocity, source PID and
synthetic marker, recognition state before/after, event disposition, and
observed/desired/target workspaces with pending switch epochs. Synthetic posting
logs include phase, direction, and marker to compare with tap delivery; a
pre-post event timestamp may be zero until macOS stamps it. Look for
`orphan=true`, ignored-event reasons, boundary decisions, and tap resets/timeouts.
Routine in-progress motion and gesture companions are omitted to limit callback
logging overhead. Debug logs also appear in stderr for optimized builds;
normal release builds compile these diagnostics out.

## Development

`zig build` assembles `zig-out/Bobrwm.app`. The build system writes the bundle
tree itself, so no Xcode project is involved. `zig build run` execs the
executable inside the bundle rather than `open`ing the app, which keeps logs on
the terminal while still giving the process its bundle identity.

```
Bobrwm.app/Contents/MacOS/
  Bobrwm         # the window manager; links AppKit, AX, SkyLight
  bobrwm-cli     # the client; links libSystem only
```

The two binaries share nothing at runtime but the socket, so the client starts
in roughly a third of the time the combined binary took. `bobrwm-cli` is what
the Homebrew cask symlinks into `PATH` as `bobrwm`. The window manager accepts
only `-c` / `--config`.

macOS ties Accessibility grants to a binary's code signature. Ad-hoc and
unsigned builds get a signature derived from the code hash, so every rebuild
looks like a new application and loses the grant you just approved. Create a
stable self-signed identity once:

```bash
script/dev-identity.sh
```

The script prompts for keychain authorization while marking the certificate as
trusted for code signing. The first build that signs with it also raises a
keychain prompt — choose *Always Allow* so later builds run unattended.

Then point builds at it:

```bash
zig build -Dcodesign-identity="bobrwm Development"
```

The grant survives from then on. Builds without `-Dcodesign-identity` are left
unsigned and need re-approval in System Settings after every rebuild.
