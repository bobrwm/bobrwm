# Architecture

Bobrwm is a deterministic state engine surrounded by macOS adapters.

The operating system is asynchronous, partially observable, and occasionally
inconsistent. Bobrwm must not spread that nondeterminism through its model.
AX, CG, WindowServer, SkyLight, AppKit, timers, and IPC live at the leaves. The
core consumes explicit facts and produces explicit intent.

This document defines the target architecture and the rules for migrating to
it. New window-management work should move the code toward this model.

## Core equation

```text
reduce(model, event) -> { next_model, effects }
```

Given the same initial model and event sequence, the reducer must produce the
same models and effects.

The reducer does not call macOS, read a clock, wait, allocate hidden authority,
or mutate process globals. Time arrives as an event. OS observations arrive as
events. Requested OS work leaves as effects, and its result returns as another
event.

```text
macOS callbacks ──> observations ──> reducer ──> effects ──> macOS adapters
                                      │   ▲
                                      └───┘ effect results and timer events
```

The main thread owns the model and is the only place where reduction occurs.
Background AX callbacks may enqueue observations, never mutate model state.

## State is truth, intent, or memory

Every field must have one of three meanings:

- **Observed truth** — the latest accepted fact from an authoritative source.
- **Requested intent** — an operation Bobrwm wants the OS to perform.
- **Internal memory** — layout, focus history, configuration, and bookkeeping
  owned entirely by Bobrwm.

These categories must not be conflated. In particular, requesting a native
Space switch does not change the observed active Space. Only a later topology
observation can do that.

When sources disagree, the disagreement is represented in the model and
resolved by a transition. It is not hidden by updating several containers in
an arbitrary order.

## Logical workspaces and physical Spaces

A configured `WorkspaceId` names one logical workspace across the application.
It is never scoped to a display. Native Space IDs identify the physical backing
instances supplied by macOS; they do not create additional Bobrwm workspaces.

A logical workspace has exactly one current placement: a native Space ID on
one display. Moving a workspace changes that placement and moves its windows;
it never creates a display-scoped copy.

Conceptually:

```text
SpaceKey = NativeSpaceId

WorkspaceState:
  WorkspaceId
  current SpaceKey placement
  window leaders
  focus history
  tiling state

SpaceState:
  key
  display identity
  occupying WorkspaceId?

DisplayState:
  stable display identity
  runtime CG display ID
  observed SpaceKey
  requested SpaceKey?

WindowState:
  window ID
  process ID
  owning SpaceKey
  frame and mode
```

Native Space ordinals are local to each display. At startup, Bobrwm assigns the
primary display's Spaces the lowest workspace IDs in native ordinal order, then
assigns secondary displays in stable display identity order while reserving at
least one workspace for each. It preserves those bindings by native Space ID
across later topology observations rather than re-deriving them from ordinals.
Startup creates missing physical Spaces on the primary display and removes
trailing extras before this mapping is built.

## Events and effects

Events are complete inputs to a state transition. Examples include:

- a hotkey or IPC command;
- a focused-window observation;
- a window creation, update, or destruction observation;
- a complete display and native Space topology snapshot;
- a configuration replacement;
- an effect result;
- a timer firing for a named transition epoch.

Effects describe work without performing it. Examples include:

- query AX, CG, or SkyLight;
- focus, move, resize, or raise a window;
- switch a native Space;
- move a window to a native Space;
- publish menu bar or dimming state;
- schedule a timer.

Every asynchronous effect carries an identity or epoch. Late results from an
obsolete transition are ignored deterministically.

## Commands resolve one action context

Every command that acts on a window uses the same resolved context:

```text
ActionContext:
  focused visible window
  tab-group layout leader
  owning SpaceKey
  display
  layout
```

Resolution is a pure decision over the model and an explicit focus
observation. Individual commands must not choose independently between live AX
focus, workspace focus history, a global active workspace, or a tab cache.

If the context is incomplete, stale, or belongs to a Space that is not
observed active, the reducer returns a deliberate result: request a fresh
observation, defer behind a transition, or reject with a reason. A silent
fallback to another window is not allowed for mutating actions. A no-op is an
explicit output, not accidental control flow.

## Native Space transitions

A native switch is a state machine:

```text
observed A
  + request B
  -> observed A, requested B, emit switch(B)

topology observes B
  -> observed B, requested none, emit reconcile/layout/focus effects

topology observes C or the deadline fires
  -> observed C, requested none, report failed request B, reconcile from C
```

Bobrwm never claims B is active before WindowServer observes B. Focus events,
window actions, queued switches, and effect completions are reduced against the
same transition epoch.

Native Space topology is authoritative for native Space membership and active
Space identity. AX is authoritative for accessibility focus and actions. CG is
evidence of physical visibility and geometry. Internal state supplies intent
and memory. No source is silently promoted beyond its authority.

## Invariants

The reducer checks invariants at its boundary in debug builds. At minimum:

1. Every managed window leader belongs to exactly one Space.
2. Every layout leaf references a live leader owned by that layout's Space.
3. Suppressed tab members own no workspace-list or layout slot.
4. Window ownership, Space membership, focus history, and layout membership
   cannot contradict one another after a transition.
5. A display's observed active Space comes only from accepted observation.
6. Requested state never changes observed state without a confirming event.
7. A window action targets a window on its observed active Space and display.
8. A `WorkspaceId` has exactly one placement, and active workspace IDs are
   unique across displays.
9. Stale events and effect results cannot mutate a newer transition epoch.
10. Derived views such as menu rows and IPC queries cannot become authorities.

An invariant violation is a model bug. It should fail near the transition that
created it rather than being repaired later by unrelated code.

## Pure layout

Layout is a pure projection:

```text
layout(space, display frame, ordered windows, config) -> frame assignments
```

Applying those assignments is an effect. AX acceptance and later WindowServer
geometry are observations. Apps that clamp or reject frames therefore produce
new facts for the reducer instead of mutating layout ownership implicitly.

## Testing and diagnostics

Pure transitions are tested with tables and event sequences. Important races
become deterministic fixtures:

- native switch lands on the requested, intermediate, or unexpected Space;
- focus changes during a switch;
- a window is destroyed before an effect completes;
- native tabs replace a window ID;
- two displays expose the same local native ordinal and the placement reducer
  assigns them distinct logical workspaces;
- display topology changes while work is pending.

Production diagnostics should be serializable as an initial model plus event
sequence. Replaying that sequence must reproduce the same state and effects.
Adapters receive separate integration tests for translating macOS behavior
into events and effects.

## Migration rules

The migration is incremental, but each step must remove an old authority:

1. Introduce pure model, event, effect, and reducer modules that mirror current
   behavior without calling platform APIs.
2. Centralize action-context resolution and route every window keybind through
   it.
3. Replace workspace-ordinal ownership with `SpaceKey` ownership; make layout
   and focus history per Space instance.
4. Separate observed and requested display/Space state.
5. Move native switching, native window moves, focus, and geometry writes
   behind effects.
6. Translate callbacks, timers, IPC, and config reloads into events.
7. Delete the corresponding globals, side channels, repair paths, and special
   cases as their authority moves into the reducer.

Do not add a new timing flag, pending global, cached ownership path, or focus
fallback unless it is represented as model state with a transition test. Do
not preserve two writable representations of the same fact during migration.

The goal is not abstraction for its own sake. The goal is one deterministic
place where Bobrwm decides what is true and what should happen next.
