# Operator-Safe AX Press Phase 1 Proof

- **Date**: 2026-07-26
- **Repository**: `saariuslystoned/agy-computer-use`
- **Branch**: `codex/operator-safe-ax-phase1`
- **Base**: `aa4d1a309b6dacd4a949326ddfed0fb4e6d8e4cd`
- **Source candidate**: `bdaee43ffb6c51cb3600e9df2ef01fb9058cc265`
- **Scope issue**: [#7](https://github.com/saariuslystoned/agy-computer-use/issues/7)
- **Deferred HUD research**: [#8](https://github.com/saariuslystoned/agy-computer-use/issues/8)

## Verdict

The source candidate passes the bounded Phase 1 contract for one-shot semantic
AX `press`. It adds a tenth MCP tool, `computer_use_ax_action`, without routing
that tool through the existing global-HID input engine. The candidate is ready
for draft review as a partial implementation of issue #7. It does not close
that issue.

The term *operator-safe* is deliberately narrow here: this path performs an
exact retained-element `AXPress`, posts zero global HID events, never falls
back to coordinate or keyboard synthesis, and fails closed when its retained
authority or observed macOS session input counters change. It is not a claim
that every app/action is supported or that all legacy tools are
noninterfering.

## Production behavior proved

1. `computer_use_ax_tree` requires one explicit, nonblank `app_id`; native IPC
   no longer guesses the frontmost app.
2. A successful inspection issues a 30-second, one-shot lease containing:
   - opaque AX snapshot, app-instance, and actionable element references;
   - exact PID, bundle identity, and process launch time;
   - display topology version;
   - exact retained AX element/window objects and ancestry;
   - bounded semantic fingerprints for element and window; and
   - a snapshot of combined-session mouse, keyboard, flags, and scroll event
     counters.
3. Only enabled, non-secure retained controls advertising `AXPress` receive an
   `element_ref`.
4. `computer_use_ax_action` currently accepts only advertised `press`. It
   consumes the matching lease before validation/dispatch and rejects replay.
5. Before dispatch, the host revalidates process birth, element/window PID,
   enabled state, action support, exact window identity, exact retained
   ancestry, element/window fingerprints, topology, and observed input
   counters.
6. Inspection and action use one serialized production operation gate, so a
   newer inspection cannot replace retained authority while an action is
   validating it.
7. Input-counter drift detected during AX dispatch wins over every returned AX
   error, including `cannotComplete`, and returns `USER_INTERVENED`.
8. Absent detected input drift, AX `cannotComplete` and invalid/unsafe semantic
   receipts return `OUTCOME_UNKNOWN` and explicitly require a fresh
   `computer_use_ax_tree`; the old reference must not be retried.
9. A valid receipt is `status: "dispatched"`,
   `strategy: "ax_semantic"`, `requires_reinspection: true`, and
   `global_hid_posts: 0`. Dispatch is not reported as verified behavior.
10. The MCP socket client applies the same AX-specific recovery instruction to
    post-dispatch timeout, cancellation, close, write/read, parse, and response
    validation uncertainty.

## Exact-source local gates

All commands below ran from source candidate
`bdaee43ffb6c51cb3600e9df2ef01fb9058cc265`.

| Command | Result |
| --- | --- |
| `./bin/agy-computer-use test-native` | PASS — strict-concurrency, warnings-as-errors native authority; 42/42 cases |
| `pnpm check` | PASS — TypeScript `tsc --noEmit` |
| `pnpm test` | PASS — 55/55 Node/MCP cases |
| `TEST_FORCE_MISSING_MISE=1 ./bin/agy-computer-use production-ready` | PASS — exact Node `v22.23.1`, exact ten-tool inventory, minimal-PATH positive path, missing-toolchain and mismatched-version negatives |
| `quick_validate.py skills/computer-use` | PASS |
| `quick_validate.py .agents/skills/computer-use` | PASS |
| `diff -qr skills/computer-use .agents/skills/computer-use` | PASS — no mirror drift |
| `git diff --check` | PASS |
| GitHub Actions `macos-build-and-test` | PASS on exact source candidate — [run 30211472441, attempt 2](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30211472441) |

The native authority includes discriminating cases for:

- required explicit app selection;
- window, ancestry, element fingerprint, and window fingerprint drift;
- observed input-counter drift before dispatch;
- observed input-counter drift after an injected `cannotComplete`;
- full-operation lock serialization;
- one-shot lease replay;
- stale topology/snapshot/app/element references;
- unsafe semantic receipts;
- method-specific `computer_use_ax_tree` recovery; and
- zero calls into a trapping global input engine on every semantic success and
  error path.

The MCP authority includes discriminating post-dispatch timeout, cancellation,
and peer-close tests for AX-specific `OUTCOME_UNKNOWN` recovery, strict schema
and golden-fixture validation, exact tool inventory, and mirrored skill
package identity.

The first hosted attempt hit the pre-existing `RL-3` SIGINT socket-cleanup
smoke race. The unchanged `main` base is red on the same assertion in
[run 30088967765](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30088967765),
the focused `RL-3` test passed locally, and the exact-source rerun passed every
job step. No lifecycle assertion or production cleanup behavior was weakened
or changed in this candidate.

## Independent review

After earlier review rounds and repairs, a read-only independent reviewer
identified three remaining blocking gaps:

1. during-dispatch input drift was checked only after AX success;
2. native AX uncertainty said “fresh observation” instead of naming
   `computer_use_ax_tree`; and
3. production serialization and retained-authority guards lacked
   discriminating tests.

After repair, the same reviewer returned **commit-ready for the bounded Phase 1
scope with no remaining P0/P1 blockers**. The repair moved the input check
ahead of the AX result switch, introduced AX-specific unknown-outcome recovery,
and connected directly tested validation/dispatch/gate seams to the production
inspector.

## Reference evidence and clean-room boundary

The behavioral benchmark is preserved in
[`reference_computer_use_blackbox_20260726.md`](reference_computer_use_blackbox_20260726.md).
It records externally observable pointer/focus isolation, exact-window
observation, independent software-pointer, and live-HUD behaviors on the local
reference product. It also records stale-index retargeting and implicit-window
limitations that this design intentionally improves.

No reference code, private protocol, decompiled control flow, binary offset,
internal type name, credential, or proprietary transport is used by this
implementation. The AGY path is built from public macOS Accessibility APIs,
the repository's existing native host/MCP boundary, and independently designed
lease and validation contracts.

## Explicit residual scope

The following remain open and prevent closing issue #7:

- real background-app fixture proof against the staged native host;
- concurrent human mouse/keyboard dogfood proof;
- semantic `set_value` and additional independently qualified action classes;
- a code-enforced exclusive-session gate for the legacy global-HID tools;
- full application/framework coverage;
- stable signed/notarized TCC principal qualification; and
- the exact-window redacted operator HUD, tracked separately in issue #8.

The live HUD is intentionally not part of this source candidate. Issue #8
contains the pre-researched clean-room continuous exact-window HUD design,
identity/privacy contracts, bounded latest-frame handling, and required
black-box/native proof matrix.
