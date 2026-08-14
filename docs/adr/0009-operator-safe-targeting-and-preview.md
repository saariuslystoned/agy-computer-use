# ADR 0009: Operator-Safe Targeting and Preview Planes

- **Status**: Accepted for Phase 1 press and Phase 2 set-value; preview plane deferred
- **Date**: 2026-07-26

## Context

The current input engine converts display-relative coordinates into global
Quartz events and posts them at the HID event tap. This provides broad
coordinate fidelity, but it shares the operator's physical pointer and current
system focus. App-aware AX inspection is read-only and its traversal IDs are
not mutation identities.

Black-box testing of another macOS computer-use product establishes useful
behavioral benchmarks: background app actions can preserve the operator's
frontmost app and physical pointer, an independent visual pointer can explain
agent intent, and the orchestrator can show a live multi-thumbnail HUD for the
apps being controlled. Explicitly emitting a captured image into a tool result
also produces a point-in-time chat image, but that is a separate surface from
the live HUD. The benchmark is evidence only. This repository will not copy
another product's code, private protocol, type names, transport, policy, or
internal control flow.

Antigravity and Gemini need a compact contract with strong server-side
authority. A model should carry opaque target and observation references, not
reconstruct process/window identity or choose a privileged input backend on
every action.

## Decision

Build an original AGY/Gemini implementation with three separate planes.

### 1. Target and observation plane

- Resolve an explicit application to one exact process instance and window.
- Issue opaque `app_instance_ref`, `window_ref`, `snapshot_ref`, and
  `element_ref` values.
- Bind every reference to process identity, window ancestry, observation
  generation, display topology, operator-activity epoch, and a short expiry.
- Discover supported AX actions and settable attributes during inspection.
- Consume actionable references once. Never re-resolve mutation authority by a
  traversal index, localized label, title, bounds, or frontmost-app guess.
- Reject ambiguous apps/windows, restarted processes, stale snapshots, changed
  ancestry, disabled elements, unsupported actions, and expired references
  before mutation.

### 2. Action plane

Support explicitly classified backends:

1. `ax_semantic`: perform an exact advertised AX action or settable-value
   mutation against the retained element. This is the first operator-safe
   backend.
2. `pid_targeted_experimental`: a future, separately qualified backend for
   process-targeted synthesized events. PID targeting is not sufficient proof
   of window, focus, or physical-pointer isolation, so no capability is
   advertised until native black-box tests pass for each action class.
3. `exclusive_global_hid`: the existing coordinate-complete engine. It is
   explicitly operator-interfering and may run only under an exclusive-session
   policy.

There is no silent fallback between these backends. A safe request that lacks a
safe route returns a typed failure without mutation.

The host snapshots the macOS combined-session mouse, keyboard, flags, and
scroll event counters. Any observed counter change after inspection invalidates
pending references. A change observed during an action makes the result
indeterminate and requires fresh inspection; the host does not automatically
retry.

Phase 1 added exact-element AX `press`. Phase 2 adds one bounded `set_value`
class for enabled, non-secure `AXTextField` and `AXTextArea` elements whose
`kAXValueAttribute` is proven settable at inspection and revalidated immediately
before dispatch. The submitted value is call-scoped, accepts empty text, is
limited to 4096 well-formed UTF-8 bytes, and never enters a lease, fingerprint,
receipt, log, error, or proof. The host calls
`AXUIElementSetAttributeValue` exactly once, never focuses the element, uses the
pasteboard, posts global HID, or retries after dispatch. This still does not
claim safe coordinate clicks, hover, drag/drop, arbitrary scroll, shortcuts,
secure text entry, or full application coverage.

The one-shot lease is consumed before set dispatch. Replay, secure, disabled,
non-settable, stale, and user-intervened outcomes are typed. `cannotComplete`,
input intervention during dispatch, or IPC ambiguity require a fresh explicit-
app AX inspection and prohibit automatic retry.

### 3. Operator presentation planes

Presentation and proof never grant input authority. Three distinct surfaces
must not be conflated:

1. A model observation carries the bounded pixels and accessibility state
   needed for the active Gemini turn.
2. An explicitly emitted image is a point-in-time artifact rendered in the
   orchestrator conversation.
3. An orchestrator-owned live HUD can show one or more controlled-app
   thumbnails, action state, and an independent agent pointer without flooding
   model context.

The reference Codex app visibly provides the third surface. Static inspection
supports a bounded architectural statement: it uses continuous exact-window
ScreenCaptureKit output, native sample-buffer/Core Animation presentation, a
local host boundary, and a separately composed software-cursor layer. Its
lifecycle is scoped by task/thread, turn, window, revisions, fences, and
generations. Exact FPS, queue depth, stale-frame cutoff, failure placeholders,
redaction, and retention are not established. The AGY-native follow-up is
tracked in [issue #8](https://github.com/saariuslystoned/agy-computer-use/issues/8).

An AGY-native HUD should eventually:

- Capture only exact target windows and bind every frame to opaque
  app/window/observation identities.
- Derive ephemeral thumbnails that may add an agent cursor, intended action
  marker, observation revision, and independently verified result.
- Keep the agent cursor as host-owned logical state. It never moves, hides,
  disconnects, or substitutes for the physical system cursor.
- Mark frames `before_action`, `action_pending`, `verified_after`, or
  `indeterminate`; dispatch alone is not shown as verification.
- Redact or suppress secure regions and fail closed when masking cannot be
  established.
- Keep only a bounded latest-frame buffer and avoid automatic persistence in
  logs, prompts, transcripts, proofs, or model context.
- Keep Puppet's structured checkpoints and native read-only AGY TUI viewer
  separate. The TUI viewer shows the harness; the HUD shows the app/window AGY
  is controlling.

Phase 1 does not implement or depend on this HUD. It ships the operator-safe AX
action seam first; live presentation remains a separately qualified follow-up.

## Gemini-facing loop

```text
status
  -> require operator-safe capability
observe(explicit app)
  -> snapshot_ref + app_instance_ref + window_ref + preview
inspect(snapshot_ref)
  -> element_ref + advertised actions
act(snapshot_ref, element_ref, "press")
  or act(snapshot_ref, element_ref, "set_value", transient_value)
  -> route + dispatched/indeterminate result
observe(explicit app)
  -> verified state + verified_after preview
```

Gemini re-observes after stale or intervention errors. It stops on
`SAFE_PATH_UNAVAILABLE` and never requests `exclusive_global_hid` without
explicit human authorization.

## Consequences

- The safe surface grows by independently proved action classes instead of
  inheriting the fidelity and hazards of global HID synthesis.
- Exact target/window/revision identity prevents silent stale-index
  retargeting.
- Operator thumbnails make computer use understandable without making images,
  terminal content, or model claims acceptance authority.
- Full coordinate fidelity remains available only in explicit exclusive mode
  until an original targeted implementation earns promotion through native
  proof.
