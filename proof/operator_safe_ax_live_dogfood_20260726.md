# Operator-Safe AX Live Dogfood Addendum

- **Date**: 2026-07-26
- **Repository**: `saariuslystoned/agy-computer-use`
- **Branch**: `codex/operator-safe-ax-phase1`
- **Base**: `aa4d1a309b6dacd4a949326ddfed0fb4e6d8e4cd`
- **Prior PR head**: `598573189e395cd4f52451836ee4d924c6bb14d8`
- **Live-dogfood source candidate**:
  `95aa0132da2301fbcee72a64b15a37453a6141be`
- **Draft PR**:
  [#9](https://github.com/saariuslystoned/agy-computer-use/pull/9)
- **Scope issue**:
  [#7](https://github.com/saariuslystoned/agy-computer-use/issues/7)

## Verdict

The source candidate closes the prior Phase 1 real-host proof gap for one-shot
operator-safe AX `press`.

On a three-display operator Mac while the operator continued using the
computer, the isolated staged host:

- acquired Accessibility only after an explicit one-shot enrollment launch and
  human macOS approval;
- inspected Calculator by explicit bundle id;
- selected exact AX controls by perception-only identifier;
- dispatched exactly one retained-element `AXPress`;
- posted zero global HID events;
- did not move the physical pointer or take focus;
- performed a fresh same-app reinspection; and
- had its visible result independently checked through the bundled Codex
  Computer Use observation path.

This is a bounded Phase 1 result, not closure of issue #7. Only semantic
`press` is qualified. The existing coordinate, keyboard, scroll, and drag tools
remain exclusive global-HID operations.

## Exact isolated host identity

The live lane used:

| Field | Exact value |
| --- | --- |
| Worktree | `/Users/bobbybones/Developer/worktrees/agy-computer-use-operator-safe-ax-phase1-20260726` |
| Runtime root | `/tmp/agy-ax-live-p9.3KiIaD` |
| Host socket | `/private/tmp/agy-ax-live-p9.3KiIaD/host.sock` |
| tmux session | `agy-ax-live-p9` |
| Native PID / process group | `63159` / `63159` |
| Native launch time | `Sun Jul 26 14:28:48 2026 EDT` |
| App bundle | `apps/computer-use-host/.build/staged/ComputerUseHostAXP9R2.app` |
| Bundle identifier | `com.saariuslystoned.agy-computer-use.host.axp9r2` |
| Launch opt-in | `--request-accessibility` |
| CDHash | `11b12e0cc7efffb80a2d7bf35bfb944677b34016` |
| Executable SHA-256 | `8c5a783be43e65bde371fe8459471466d57aff9f71c6debc59dbede00f4c7712` |
| Executable inode / mtime | `59622093` / `1785090528` |

After the operator toggled the exact staged app in macOS Accessibility, the
host reported:

```text
connected=true
accessibility_trusted=true
ax_tree_inspection_available=true
operator_safe_ax_available=true
operator_safe_ax_actions=["press"]
```

The principal was ad-hoc signed. This proves the explicit enrollment path, not
durable TCC persistence across replacement identities.

## Final exact-source live receipt

The final live run used the source tree committed as
`95aa0132da2301fbcee72a64b15a37453a6141be`:

```text
target app: com.apple.calculator
selector: identifier == "Clear"
status attempts: 1
inspection attempts: 1
action attempts: 1
reinspection attempts: 1
tree nodes: 242
tree max depth: 8
tree truncated: false
action status: dispatched
strategy: ax_semantic
settlement: native_response
global_hid_posts: 0
duration_ms: 6.292
same target process fields: true
process birth continuity in fresh tree: not exposed
post selector: absent (Clear became AllClear)
controller effect verdict: not_asserted
```

The controller did not infer success from the disappearance of `Clear`.
Independent bundled Computer Use observation verified Calculator changed from
visible value `1` to visible value `0`, and that the control became
`identifier=AllClear`.

An earlier final-controller run selected `identifier=One`, tolerated three
read-only `USER_INTERVENED` retries, dispatched one semantic press with zero
global HID posts, preserved the role/path/subrole/identifier perception
invariant, and was independently observed changing Calculator from `0` to `1`.
This establishes bounded side-by-side availability without claiming that
continuous operator input can never starve an inspection window.

## Live negative evidence and repairs

Dogfood found the following defects before the source candidate was committed:

1. **Unsafe controller retry after an action-side error**
   An early controller retried `computer_use_ax_action` after
   `USER_INTERVENED`, producing an unintended `0 -> 11` Calculator result.
   The repair permits bounded retries only for read-only AX inspection.
   Once an action call is made, the controller never automatically calls the
   action a second time.

2. **Vacuous replay probe**
   An early proof option issued a second action to test replay. It was removed.
   Replay authority now belongs only to deterministic native and MCP tests.

3. **Stateful selector drift**
   `Clear` becomes `AllClear` after dispatch. Post-action observation now
   permits an absent selector when no semantic value predicate was asserted,
   and reports `effect_verdict=not_asserted` instead of inventing success.

4. **Per-inspection app-instance references**
   Fresh AX trees mint fresh opaque `app_instance_ref` values. The controller
   now compares exact exposed target process fields and reports that
   post-action process-birth continuity is not exposed by `ax_tree`.

5. **Selector-switch false verification**
   Pre-action selection now requires exactly one match across the complete,
   non-truncated tree, not merely one actionable match. A value postcondition
   additionally requires the same role, structural path, subrole, and stable
   identifier when present. This blocks the observed selector-switch case;
   continuity remains perception-based rather than native node identity.

6. **Timeout and broken-transport ordering**
   The controller now uses the MCP SDK's settled timeout/cancellation path.
   On every action-side error it attempts to close the old MCP child, connect a
   fresh MCP process, and then reinspect. When that recovery connection
   succeeds, the native host's single-connection ordering prevents the fresh
   reinspection from overtaking an already-received action. Any failure to
   close, reconnect, or reinspect remains an explicit unknown outcome.
   Cancellation settles the MCP request; it cannot undo an AX press already
   written, and the recovery snapshot is state evidence rather than proof of
   the native action's causal outcome.

7. **Hidden inspection retry exhaustion**
   Exhausted read-only intervention retries now return
   `USER_INTERVENED_RETRY_EXHAUSTED`, the exact attempt count, exit code `5`,
   and zero action calls.

8. **Missing AX perception labels**
   Native AX nodes now expose bounded `identifier` and `description` fields.
   They are perception only, never action authority, and are redacted on secure
   text fields.

9. **Unbounded Accessibility enrollment surface**
   Ordinary starts are prompt-silent. Only exact
   `host-start --request-accessibility` on a fully stopped owner may forward
   one prompt flag. Caller `binaryArgs` injection, duplicates, already-running
   starts, and launch-race losers fail closed.

## Exact-source gates

All local gates below passed on the source tree committed as
`95aa0132da2301fbcee72a64b15a37453a6141be`.

| Gate | Result |
| --- | --- |
| `./bin/agy-computer-use test-native` | PASS — 42/42 native cases |
| `pnpm check && pnpm test` | PASS — TypeScript plus 56/56 Node/MCP cases |
| `node --test bin/host-accessibility-enrollment.test.mjs` | PASS — 5/5 hermetic enrollment cases |
| Focused `M9-LAUNCHSERVICES` lifecycle test | PASS — 1/1 mocked LaunchServices case |
| `TEST_FORCE_MISSING_MISE=1 ./bin/agy-computer-use production-ready` | PASS — exact Node `v22.23.1`, ten-tool inventory, and negative launch discriminators |
| `TEST_FORCE_MISSING_MISE=1 ./bin/agy-computer-use canary-ready` | PASS |
| `quick_validate.py skills/computer-use` | PASS |
| `quick_validate.py .agents/skills/computer-use` | PASS |
| `diff -qr skills/computer-use .agents/skills/computer-use` | PASS — no mirror drift |
| `git diff --check` | PASS |

GitHub Actions
[`macos-build-and-test`](https://github.com/saariuslystoned/agy-computer-use/actions/runs/30216100405)
passed on the exact source candidate in attempt 2, job `89830676928`.
Attempt 1 hit the repository's pre-existing `RL-3` SIGINT socket-cleanup smoke
race in `host-app.test.mjs`; the new enrollment test had not yet run because
the step exited first. The unchanged exact source passed every step on rerun.
No lifecycle assertion was weakened.

The new hermetic enrollment suite is explicitly wired into CI. The broad
`bin/host-lifecycle.test.mjs` file is not.

## Independent review

Independent read-only review found and forced repairs for:

- reserved prompt-argument injection and duplicate suppression;
- already-running and ownership-race enrollment behavior;
- selector switching to a different non-action sibling;
- action timeout settlement and recovery ordering;
- replacement MCP transport after action-side failure; and
- production initialization accidentally dropping the recovery hook.

After repair and discriminating regressions, both the enrollment and controller
reviews returned **no blocker** for the bounded Phase 1 scope.

## Non-hermetic canonical-host incident

During local verification, the broad lifecycle test file was mistakenly run
without a name filter. Its early public lifecycle cases called the canonical
`host-stop` surface and moved the pre-existing canonical generation
`8679120f-1e76-40e4-8fa6-2220503b2689` to `stopping`.

The exact canonical processes remained alive:

```text
daemon PID: 70423
LaunchServices PID: 70497
native PID: 70500
status: stopping
native status: connected and Accessibility-trusted
```

No further signal, restart, or cleanup was sent to those processes because the
operator had not approved that exact recovery. The incident is the reason the
new enrollment authority lives in a separate hermetic test file and only the
single mocked LaunchServices case was selected from the broad file.

## Cleanup

After proof capture and hosted CI:

- exact isolated native PID `63159` stopped cleanly after `SIGTERM`;
- exact tmux session `agy-ax-live-p9` was removed;
- the isolated host socket was absent; and
- the separate canonical generation above was left untouched.

No global TCC setting, operator-global config, auth store, non-task tmux
session, or unrelated process was modified during cleanup.

## Residual scope

- Operator-safe semantic control supports only `press`.
- Combined-session input counters are deliberately conservative. Unrelated
  operator input can cause bounded read-only retries or temporarily starve the
  semantic action window, even though the path does not take the pointer or
  focus.
- Fresh `ax_tree` responses do not expose process launch time. The native action
  validates process birth before dispatch, while post-action proof can compare
  only the exact exposed PID, bundle id, and name.
- Controls that change identity after a press require an independent semantic
  observer; selector disappearance alone is never effect proof.
- Post-action continuity is perception-based. A replacement node with the same
  role, structural path, subrole, and identifier—or with no identifier—can
  remain indistinguishable from the original node.
- A native-host outage after uncertain dispatch can prevent recovery
  reinspection. Close, reconnect, and reinspection are best-effort; the
  controller fails closed with an unknown outcome and never repeats the action
  automatically.
- The current ad-hoc app identity is not a durable signed/notarized TCC
  principal.
- Legacy global-HID tools still require an exclusive operator session.
- Exact-window redacted thumbnails and the optional operator HUD remain
  separately deferred in
  [issue #8](https://github.com/saariuslystoned/agy-computer-use/issues/8).
