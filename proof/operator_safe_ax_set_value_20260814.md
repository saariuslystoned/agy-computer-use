# Operator-Safe AX `set_value` Verification

- Date: 2026-08-14
- Branch: `codex/operator-safe-ax-set-value-20260814`
- Required base: `d29b20b6abcbac1964047db48932e927b7b24a31`
- Verified source: `3792d982f97ab58353b2b25f97e683f849f00700`
- Scope: deterministic native, MCP, schema, fixture, skill, and readiness
  verification without TCC enrollment or live GUI control

## Verdict

The source commit adds one bounded `set_value` action to the existing
`computer_use_ax_action` route while retaining semantic `press`. Native and MCP
authority tests prove the one-shot retained-element path, exact pre-dispatch
revalidation, live secure/disabled/text/settable checks, one setter call, typed
stale/replay/unsupported/intervention/uncertainty outcomes, mandatory
reinspection metadata, and zero global-HID calls. The action payload is
call-scoped and absent from receipts, errors, retained leases, and test output.

Native status, per-node action metadata, MCP schemas/tool metadata, protocol
fixtures, the press live-proof readiness gate, and both skill mirrors use the
same canonical `press` plus `set_value` contract. This revision deliberately
rejects a mismatched press-only host rather than negotiating a partial wire
surface.

## Exact-source gates

| Gate | Exact-source result |
| --- | --- |
| `./bin/agy-computer-use test-native` | PASS — 42/42 native cases; the live Screen Recording assertion was skipped because TCC was intentionally not granted |
| `pnpm check && pnpm build` in `mcp/computer-use-mcp` | PASS — TypeScript typecheck and build |
| `node --check ../../bin/operator-safe-ax-live-proof.mjs` | PASS |
| `node --test --test-skip-pattern='Deterministic Configured Launcher' dist/test/*.test.js` | PASS — 56/56 runnable Node/MCP cases |
| `pnpm test` | ENVIRONMENT BLOCKED — 56/57 pass; only the configured-launcher case stops because ambient Node is `v26.4.0`, while the repo pins `v22.23.1` and no `mise` or pinned Node binary is installed |
| `./bin/agy-computer-use production-ready` | ENVIRONMENT BLOCKED at the same pinned-toolchain launcher gate after MCP config validation |
| `diff -ru skills/computer-use .agents/skills/computer-use` | PASS — recursive mirrors equal |
| `jq empty docs/protocol_schema.json docs/fixtures/*.json` | PASS |
| `git diff --check d29b20b6abcbac1964047db48932e927b7b24a31..3792d982f97ab58353b2b25f97e683f849f00700` | PASS |
| Native AX source static guards | PASS — exactly one `AXUIElementSetAttributeValue` call site and no `CGEvent.post` or pasteboard reference |
| Gemini compatibility search | PASS — no remaining Gemini 3.6 wording outside ignored generated/dependency trees |

The runnable MCP suite includes recursive skill equality and every protocol
fixture. Focused assertions exercise positive empty/boundary UTF-8 input,
multibyte overflow and ill-formed input, secure and disabled fields,
non-text/non-settable targets, stale and replayed leases, operator
intervention, post-dispatch uncertainty, no automatic retry, strict redacted
receipts, canonical action ordering, and `global_hid_posts: 0`.

## Base discriminator

The required base exposes a press-literal MCP action schema and contains no
`set_value` symbol in that schema. The new positive action/schema/fixture tests
therefore fail against the base, while the native tests additionally reference
new production capability, tombstone, API-seam, error, and setter boundaries
that do not exist there. Prior press success and safety assertions remain; the
replay assertion is strengthened from generic stale to typed replay.

## Gates honored

No host was installed, staged, launched, or controlled. No TCC prompt or
permission state was touched. No UI/device action, credential inspection,
network publication, push, PR mutation, merge, or host/toolchain install
was performed. A live macOS behavior proof and the configured Node 22 launcher
gate remain separate environment-qualified follow-ups.
