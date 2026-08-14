# Operator-Safe AX `set_value` Verification

- Date: 2026-08-14
- Branch: `codex/operator-safe-ax-set-value-20260814`
- Pull request: `#10`
- Required base: `d29b20b6abcbac1964047db48932e927b7b24a31`
- Repair base: `d62f5dcfa74660af7364d00372add7a1094f59e8`
- Verified source: `ca346b7252f8387a0b610919092dedffad1dec2a`
- Dual-worker proof parent: `9e904eecb1e12900c31d396c698f1a02e36d6ecc`
- Herdr-Puppet controller: `1b8dfd9439daa0ed3cb014b92e41f10d9012c21e`
  (SaariusSkills PR #18 merged head)
- Scope: deterministic native, MCP, schema, fixture, skill, and readiness
  verification plus bounded AGY/Herdr execution on two dedicated workers,
  without TCC enrollment or live GUI control

## Verdict

The source commit adds one bounded `set_value` action to the existing
`computer_use_ax_action` route while retaining semantic `press`. Native and MCP
authority tests prove the one-shot retained-element path, exact pre-dispatch
revalidation, live secure/disabled/text/settable checks, one setter call, typed
stale/replay/unsupported/intervention/uncertainty outcomes, mandatory
reinspection metadata, and zero global-HID calls. The action payload is
call-scoped and absent from receipts, errors, retained leases, and test output.

Every non-success result returned after the value setter is invoked now becomes
`OUTCOME_UNKNOWN` at the production native seam. The injected test covers all
declared non-success `AXError` cases plus an unrecognized/default raw code,
proves exactly one setter call, and pairs that with the one-shot replay and
fresh-inspection assertions. Typed secure, disabled, non-settable, and
unsupported `set_value` outcomes remain preflight-only; semantic press keeps
its prior mapping.

Native status, per-node action metadata, MCP schemas/tool metadata, protocol
fixtures, the press live-proof readiness gate, and both skill mirrors use the
same compatible capability contract: `[]`, `["press"]`, or canonical
`["press", "set_value"]`, with availability true exactly for a nonempty set.
Native and MCP end-to-end tests prove a press-only status and press receipt,
reject `set_value` before dispatch on that host, and reject set-only, reordered,
duplicate, or unknown global metadata. The full engine still advertises both
actions.

## Exact-source gates

| Gate | Exact-source result |
| --- | --- |
| `./bin/agy-computer-use test-native` | PASS — 42/42 native cases; the live Screen Recording assertion was skipped because TCC was intentionally not granted |
| `pnpm check && pnpm build` in `mcp/computer-use-mcp` | PASS — TypeScript typecheck and build |
| `node --check ../../bin/operator-safe-ax-live-proof.mjs` | PASS |
| `node --test --test-skip-pattern='Deterministic Configured Launcher' dist/test/*.test.js` | PASS — 57/57 runnable Node/MCP cases |
| `pnpm test` | ENVIRONMENT BLOCKED — 57/58 pass; only the configured-launcher case stops because ambient Node is `v26.4.0`, while the repo pins `v22.23.1` and no `mise` or pinned Node binary is installed |
| `./bin/agy-computer-use production-ready` | ENVIRONMENT BLOCKED at the same pinned-toolchain launcher gate after MCP config validation |
| `diff -ru skills/computer-use .agents/skills/computer-use` | PASS — recursive mirrors equal |
| `jq empty docs/protocol_schema.json docs/fixtures/*.json` | PASS |
| `git diff --check d29b20b6abcbac1964047db48932e927b7b24a31..ca346b7252f8387a0b610919092dedffad1dec2a` and repair-base equivalent | PASS |
| Native AX source static guards | PASS — exactly one `AXUIElementSetAttributeValue` call site and no `CGEvent.post` or pasteboard reference |
| Gemini compatibility search | PASS — no legacy Flash product-version wording remains in tracked source |

The runnable MCP suite includes recursive skill equality and every protocol
fixture. Focused assertions exercise positive empty/boundary UTF-8 input,
multibyte overflow and ill-formed input, secure and disabled fields,
non-text/non-settable targets, stale and replayed leases, operator
intervention, post-dispatch uncertainty, no automatic retry, strict redacted
receipts, press-only backward compatibility, canonical action ordering, and
`global_hid_posts: 0`.

## Dual-worker AGY / Herdr proof

The merged checkpoint-driven Herdr-Puppet controller was used to launch and
steer one freshly created, explicitly selected AGY tab on each worker. Both
rows bound the same clean product commit and selected
`gemini-3.7-flash-high` with high effort. Neither row adopted an existing tab
or relied on ordinal-only destination inference.

| Row | Machine selector | Workspace | Product result |
| --- | --- | --- | --- |
| 1 | `aiworker-01` | `w2` | behavior audit `pass` |
| 2 | `aiworker-02` | `w3` | usability audit `usable` |

Each append-only row journal records the same bounded sequence:

1. shell preflight followed by a matched `STATUS` beacon;
2. create-only in-row census, a second `STATUS`, and binding revalidation;
3. one dedicated AGY 1.1.13 launch with the explicit model selector;
4. one wrapped initial task send followed by `STATUS`;
5. one steering send followed by terminal `DONE`;
6. milestone preservation and transcript-blind maintenance closeout.

Each row contains 25 events, two acknowledged sends, four matched beacons,
zero recorded failures or repairs, and a terminal preserved lease. Both
product and controller worktrees were clean at their exact commits after the
run. No raw prompt, pane transcript, model response, credential, or account
data was copied into this proof.

The retained sanitized aiworker-01 artifact has SHA-256
`55d1824ad684cfad5cc8c78e3e93a65060aba148351b73e541a34884419cda2b`.
It binds the product head and selected model and records 42 passing native
cases, protocol and fixture validation, recursive skill-mirror equality,
4096-byte UTF-8 enforcement, receipt redaction, exact pre-dispatch authority
revalidation, one setter dispatch, post-dispatch uncertainty, and press-only
compatibility. Its declared environment gaps are the intentionally ungranted
Screen Recording permission and absence of the pinned Node/pnpm toolchain on
that worker.

The retained sanitized aiworker-02 artifact has SHA-256
`05811d7fd073c281e04f734da2c4a2089db555049572fe8ab2a59d6ab1f325cf`.
It records the product as usable and highlights one-shot AX leases, dynamic
capability reporting, mandatory reinspection, value redaction, and separation
from global HID. Its prioritized follow-up is automatic stale-socket detection
and recovery, followed by clearer toolchain/TCC readiness and safe app/window
discovery.

At the exact merged SaariusSkills controller head, 221 Herdr-Puppet tests, 10
packaging tests, and all 254 repository tests passed. Controller and census
help checks also passed.

This proves the core dual-machine AGY transport/task path, named machine and
fresh-tab selection, and explicit Gemini 3.7 selection. It does not claim the
optional native Herdr-client detach/reattach qualification: Computer Use could
not access Terminal, and the approved visual fallback applies only to Screen
Sharing/VNC. No synthetic view receipt was created. The owned tabs remain
preserved; cleanup and process reaping were not performed.

## Base discriminator

The required base exposes a press-literal MCP action schema and contains no
`set_value` symbol in that schema. The new positive action/schema/fixture tests
therefore fail against the base, while the native tests additionally reference
new production capability, tombstone, API-seam, error, and setter boundaries
that do not exist there. Prior press success and safety assertions remain; the
replay assertion is strengthened from generic stale to typed replay.

Against the repair base, the injected post-setter cases fail because
unsupported, invalid-element, and other AX results are reclassified as typed
safe/preflight errors. The press-only native status, MCP status, protocol
fixture, and action tests also fail because that revision requires the full
two-action global capability.

## Gates honored

At the exact-source gate checkpoint, no host was installed, staged, launched,
or controlled. No TCC prompt or permission state was touched. The later
dual-worker proof likewise performed no UI/device action, credential
inspection, merge, cleanup, process reaping, or host/toolchain install. The
configured Node 22 launcher and native Herdr-view qualification remain
separate environment-qualified follow-ups.
