# Reference Computer Use Black-Box Behavior Map

- **Run date**: 2026-07-26
- **Purpose**: Behavioral benchmark for an original Antigravity/Gemini design
- **Reference surface**: Local macOS Computer Use skill `1.0.1000502`
- **Test apps**: Calculator and TextEdit
- **Mutation scope**: Generated calculator values and one unsaved TextEdit
  document containing only synthetic test strings
- **Excluded**: Browser state, accounts, messages, credentials, system
  settings, secure fields, and permanent deletion

This report records externally observable behavior and public API feasibility.
It is not implementation provenance. No reference code, private protocol,
decompiled control flow, binary offset, internal type name, or proprietary
transport is admitted into the AGY implementation.

## Method

All reference UI actions used the installed Computer Use skill through its
documented Node wrapper. A read-only native helper sampled:

- physical pointer coordinates;
- frontmost process identity; and
- target app/window geometry.

The sampler collected 300 observations at 5 ms intervals during representative
scroll, coordinate-click, drag, and concurrent-action tests. Every action was
followed by a fresh app-state observation before its behavior was classified.

Three active displays were present:

| Display | Bounds in points |
| --- | --- |
| Main | `1728 x 1117 @ (0, 0)` |
| External | `1920 x 1080 @ (0, -1080)` |
| External portrait | `1440 x 2560 @ (-1440, -1443)` |

Calculator and TextEdit windows were on the portrait display. Codex remained
frontmost throughout the non-raising tests.

## Accepted behavior

| Surface | Result |
| --- | --- |
| Background observation | Launched/read Calculator and TextEdit without changing the frontmost process or pointer |
| Fresh semantic click | Activated exact Calculator buttons and TextEdit controls |
| Window-local coordinate click | Activated Calculator `8` while Codex remained frontmost |
| Click count | A semantic double click on `7` produced `77` |
| Targeted text and key input | Entered `123`, then targeted Backspace to produce `12`; Codex received no input |
| Settable AX value | Set TextEdit content without moving the pointer or raising TextEdit |
| Text selection | Selected and replaced a unique substring |
| Disambiguated selection | Prefix/suffix selection replaced only the second repeated `alpha` |
| Element scroll | Changed TextEdit vertical scroll state down and back up |
| Coordinate drag | Selected a multi-line TextEdit range; replacement verified the selected region |
| Right click and transient UI | Opened a TextEdit context menu in the background |
| Secondary action | Cancelled the exact context menu through its advertised secondary action |
| State diff | Reported changed checkbox/style/value elements after a fresh semantic action |
| Cross-app concurrency | Calculator click and TextEdit scroll both completed |
| Same-app concurrency | Concurrent Calculator `1` then `2` requests produced ordered `12` in this run |
| Unknown app | Rejected before mutation |
| Invalid element | Rejected before mutation |
| Unsupported secondary action | Rejected before mutation |
| Out-of-window coordinate | Rejected before mutation |

## Pointer and focus evidence

During each 300-sample action window:

- `pointer_span_x = 0`;
- `pointer_span_y = 0`; and
- the only frontmost PID was the Codex app.

This passed for:

- a two-page background TextEdit scroll;
- a background Calculator coordinate click;
- a background TextEdit coordinate drag;
- simultaneous Calculator and TextEdit actions; and
- two simultaneous Calculator actions.

Before/after checks on semantic clicks, set-value, text selection, text input,
keypress, right-click, secondary action, scroll, and cleanup also reported zero
pointer displacement and preserved Codex focus.

These observations prove the tested paths on this exact local build. They do
not justify a universal claim for every app, action fallback, macOS version, or
permission state.

## Operator presentation behavior

Two different visual surfaces were observed.

### Explicit point-in-time image

- App observation produced window-scoped images rather than full-desktop
  captures:
  - Calculator: `230 x 408`;
  - TextEdit: `586 x 488`.
- Explicitly emitting an image through the Node tool result made the Codex app
  render that one captured state in the conversation.
- The emitted TextEdit image showed a glowing software pointer inside the
  target window while native sampling showed the physical pointer stationary
  elsewhere.

### Orchestrator live HUD

- Separately, the operator observed a live Codex-app HUD containing multiple
  small thumbnails of the controlled apps and the agent pointer while Computer
  Use was active.
- This HUD was not the explicit point-in-time image result and must not be
  described as though `emitImage` created it.
- Computer Use refused a request to inspect the Codex app itself with:
  `Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.`
  That establishes a target exclusion and supports, but does not by itself
  prove, a separate orchestrator-owned presentation boundary.
- Static inspection of the installed signed runtime supports a narrower
  architectural statement: continuous exact-window ScreenCaptureKit output is
  presented through native sample-buffer/Core Animation layers across a local
  host boundary, with the software cursor composed separately. Lifecycle state
  is bound to task/thread, turn, window, visibility/suppression, revisions,
  fences, and generations.
- Exact visual FPS, buffering/drop policy, stale-frame cutoff, failure
  placeholder behavior, redaction, persistence, and telemetry remain unproved.
  The original AGY design and required black-box matrix are preserved in
  [issue #8](https://github.com/saariuslystoned/agy-computer-use/issues/8).

The screenshot and AX text are separate channels; visible pixels can contain
content that AX redaction does not remove. The transferable behavior is an
AGY-native separation between model observation, explicit one-frame artifacts,
and an operator-only live HUD with exact app/window identity and an independent
agent pointer. The reference transport and Codex rendering implementation are
not implementation inputs.

## Rejected or limited behavior

### Stale element indexes silently retarget

After Calculator state changed, the old index for `7` became the index for `9`.
The stale click returned success and produced `9`; it was not rejected. A
second stale TextEdit index likewise returned success without the intended
checkbox change.

AGY must improve this by issuing opaque, capture-bound, one-shot element
references and refusing traversal-index mutation authority.

### Multiple windows are implicit

After targeted `Command-N`, TextEdit had two windows but app observation
returned only the app's internally active `Untitled 2` window. The API exposed
no explicit window selector. Targeted `Command-W` closed that empty active
window and the original window became observable again.

AGY must expose an exact `window_ref` and reject ambiguity.

### Dispatch success is not behavior proof

A coordinate drag returned success before the intended scrollbar-state check
showed no change. Visual inspection later showed the drag had selected document
text at those coordinates. Only a fresh observation established what happened.

AGY receipts must distinguish dispatch from verified effect and
outcome-unknown.

### Diff output can become large

The accessibility diff correctly identified changed controls, but also repeated
the entire focused 120-line synthetic TextEdit value. AGY should preserve
bounded, redacted summaries and avoid treating focused content as required
operator telemetry.

## Unproved paths

This run intentionally did not claim:

- concurrent real human movement or typing during an action;
- lock-screen or permission-revocation recovery;
- secure-field behavior;
- process restart between observation and action;
- canvas/WebGL coordinate targeting;
- every drag/drop or hover implementation;
- cross-Space behavior; or
- browser, account, messaging, financial, or destructive workflows.

These remain required independent qualification before broad capability
claims.

## Cleanup

- Calculator was reset to `0`.
- Synthetic TextEdit content was cleared.
- The irreversible `Delete` choice in TextEdit's close sheet was not used; the
  close was cancelled, leaving one blank unsaved test window.
- No external send, file upload, account action, permission change, or
  permanent deletion occurred.
