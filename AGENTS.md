# AGENTS.md

## Zig Development

Use `zigdoc` when checking unfamiliar Zig standard-library or dependency APIs, especially before changing code that depends on version-sensitive APIs. Prefer local code patterns when the surrounding code already demonstrates the API usage.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Common Zig Patterns

These patterns reflect current Zig APIs and may differ from older documentation.

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**HashMap/StringHashMap (managed):**
```zig
var map: std.StringHashMap(u32) = std.StringHashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", 42);
```

**stdout/stderr Writer:**
```zig
var buf: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buf);
defer writer.flush() catch {};
try writer.print("hello {s}\n", .{"world"});
```

**build.zig executable/test:**
```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

## Zig Code Style

**Naming:**
- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:
```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**
1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/main.zig test block

## ObjC Interop

Use zig-objc (`@import("objc")`) for all Objective-C runtime calls from Zig. There is no clang-compiled shim: custom ObjC classes (`BWStatusBarDelegate`, `BWObserver`, `BWLaunchGate`) are defined at runtime in `src/objc_classes.zig` via `allocateClassPair` / `addMethod`. New BW* classes go there.

Message sends, class lookups, and NSApp lifecycle use zig-objc. AX, CoreFoundation, CoreGraphics, dispatch, and WindowServer/SkyLight interop live in Zig through translated C declarations plus hand-written declarations in `src/c/cg_extra.zig` when Aro cannot translate an API cleanly.

**Message sends:**
```zig
const objc = @import("objc");
const NSApplication = objc.getClass("NSApplication").?;
const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
_ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 1)});
```

**Architecture:** The main thread runs `[NSApp run]` via zig-objc and owns Bobrwm state mutation, layout, workspace state, IPC, status bar, and event draining. AX observer callbacks run on a dedicated background observer thread so slow or hung app AX servers cannot stall the main CFRunLoop. Background AX callbacks must only enqueue events or update observer bookkeeping protected by the AX lock; Bobrwm state mutations happen on the main thread during event drain.

## Window Management Invariants

Bobrwm reconciles AX, WindowServer/CG, SkyLight, and internal workspace/layout state. Do not trust one source alone. AX can lag or expose stale native-tab window IDs; CG can retain invisible Electron windows; SkyLight bounds can fail for destroyed windows; internal workspace state can be stale until cleanup runs.

**Visibility and cleanup:**
- Treat CG on-screen presence as necessary but not always sufficient. Electron apps can keep layer-0 windows around after close-to-background; fully transparent CG windows should not be treated as visible.
- Hidden workspace windows are intentionally parked off-screen with a few peek pixels visible. Use workspace-aware visibility helpers for cleanup and tab inference; do not call raw CG on-screen checks when workspace visibility matters.
- Cleanup should skip hidden workspaces unless the code can distinguish Bobrwm-parked windows from real ghosts.

**Workspace transitions:**
- Workspace transitions are two-phase. Mark them complete when target focus is accepted or when the target workspace is empty, but keep the transition active until the short settle deadline so synthetic AX move/resize events from hide/retile are suppressed.
- Empty target workspaces cannot produce a target focus event; handle them explicitly instead of waiting for the watchdog.
- During a transition, AX focus events from non-target workspaces/displays should be deferred or ignored, not allowed to change focused display state.

**Native tabs and window IDs:**
- A tab group leader owns the workspace/layout slot. Suppressed tab members live in the store but not in workspace window lists or BSP layout leaves.
- Only infer background tabs when the candidate is same-PID, frame-matching, and off-screen. A visible unknown same-PID window is usually standalone or a creation race.
- Some apps can replace the active native-tab CG window ID before AX focus reconciliation catches up. If an AX frame write fails for a stored window ID, it may be stale; reconcile against the app's current focused window ID and update workspace/layout/store together.

**Focus reconciliation:** Unknown focused window IDs should go through the tab-aware reconciliation path before falling back to broad discovery. Broad discovery during a workspace switch can assign ownership from the wrong active workspace.

**Diagnostics:** Keep high-signal transition, cleanup, tab, and AX-reconciliation logs as `log.debug`; they are useful for reproducing event-order bugs and compile away when debug logging is disabled. Use `log.warn` only for failed repair paths or invariants that require attention, such as watchdog expiry or failed cleanup/replacement.

## Verification for Window-Management Changes

For changes touching AX, CG/WindowServer, workspace switching, cleanup, or tab groups, run:

```bash
zig fmt <changed zig files>
zig build
zig build test
zig build -Doptimize=ReleaseFast
```

When behavior depends on macOS event ordering, also perform a manual repro with the relevant app class, for example Ghostty native tabs or Discord/Electron close-to-background behavior.

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**
- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Function size:**
- Soft limit of 70 lines per function
- Existing event-loop and interop functions may exceed this when splitting would obscure event ordering. For new logic, prefer small helpers that isolate pure decisions or bounded mutations.
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**
- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details
