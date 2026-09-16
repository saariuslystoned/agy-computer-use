# Issue 12 — compound AX action observation candidate (2026-09-16)

## Status and identity

Local implementation of the first slice is ready for review. **Issue #12 is not complete and this build is not live-qualified.** Window targeting, independent session leases and target-qualified intervention remain later slices.

- Repository: `saariuslystoned/agy-computer-use`
- Worktree: `/Users/bobbybones/Developer/worktrees/agy-computer-use-issue-12-action-observation`
- Branch: `codex/issue-12-action-observation`
- Fresh remote base: `67f7d329737c067425b751a7aaaa65bad27789d7`
- Source commit: `359aadf70354a93107f7de9398490774d2e9508e`. The candidate is also bound by the per-file [SHA-256 manifest](../runs/issue-12-runs/20260916-action-observation/source-sha256.json).
- Manifest SHA-256: `46f60d99a45e7b144241c1775f65f7348fe512d8d8cdbee002b36641ca014573`.
- Native binary: [build identity](../runs/issue-12-runs/20260916-action-observation/build-sha256.json).

## Behavior delivered

The existing MCP action accepts an optional bounded `observe` object. The native host dispatches exactly one `press` or `set_value`, then performs read-only reinspection while retaining the operation gate. It binds observations to the original PID, bundle and process birth; topology is checked again before returning observed state. Legacy tools and their mutation checks remain in place.

Dispatch and observation outcomes are separate. Observations distinguish changed, unchanged, timed out and failed. Successful observations carry fresh authority and a bounded difference summary. Observation failure preserves the known dispatch outcome and exposes no stale state. Action-side errors and transport uncertainty never repeat the mutation. A changed tree is not proof that the intended effect occurred.

Both distributed skills now include the operational path, compound semantics, browser/native routing and an accurate pending Gemini 3.8 qualification statement. Lifecycle details are in matching on-demand references.

Published `.txt` captures omit only terminal blank lines; original raw `.log` captures remain local.

## Executed checks

| Check | Result | Output |
| --- | --- | --- |
| `./bin/agy-computer-use test-native` | PASS; 43 executed native cases, strict-concurrency authority. XCTest discovery unavailable; repository-selected executable fallback ran. | [native-final.txt](../runs/issue-12-runs/20260916-action-observation/native-final.txt) |
| `pnpm check` in MCP package | PASS | [check.txt](../runs/issue-12-runs/20260916-action-observation/check.txt) |
| `pnpm test` in MCP package | PASS; 66 tests, zero failures/skips | [mcp-final.txt](../runs/issue-12-runs/20260916-action-observation/mcp-final.txt) |
| `./bin/agy-computer-use production-ready` | PASS; ten configured tools; minimal PATH and negative toolchain checks | [readiness.txt](../runs/issue-12-runs/20260916-action-observation/readiness.txt) |
| Native host build with strict concurrency and warnings as errors | PASS | [build.txt](../runs/issue-12-runs/20260916-action-observation/build.txt) |
| `git diff --check`; distributed skill equality | PASS | Executed locally; no whitespace errors or skill differences |

New native assertions execute the production observation runner for changed/unchanged state, delayed changes, monotonic timeout, late-result rejection, same-state fresh refs, bounded summaries, wrong process/freshness, observation errors, and action-error propagation with exactly one dispatch and no automatic read/retry after an action error. HostServer assertions exercise strict option validation, missing compound capability, legacy-option rejection, missing observation receipts, and post-dispatch topology change/failure.

MCP SDK tests assert one native compound request returns dispatch plus fresh state, preserves the old route, rejects invalid arguments before dispatch, and rejects contradictory, stale or mismatched replies. Real local Unix socket tests cover compound timeout, cancellation and EOF with exactly one request and `OUTCOME_UNKNOWN` recovery.

## Review findings and limits

Accepted and fixed during local review: an older host could silently ignore an added option (separate native method prevents dispatch); a late polling tree could expose stale authority (discard/invalidate); malformed compound replies could look successful (strict schema and request correlation); topology failure after dispatch could erase known dispatch status (separate failed observation now preserves it). The native runner's old printed case count was replaced with an executed-completion counter.

Rejected as a completion claim: deterministic injected observations do not prove live AX compatibility, physical pointer/focus isolation, or a Gemini speedup. No live comparison, screenshots, timings, observation-byte benchmark, operator-correction count, or before/after device claim is made. The observation deadline is cooperative; synchronous AX calls can overrun it, and late results are rejected.

Initial verification attempts exposed test integration errors (`main.swift` executable layout when adding a second Swift source) and a mismatched condition in a test fixture after response correlation was strengthened. These were corrected; earlier logs remain in the local run directory; only the final verification logs are published. No pre-existing assertions were removed or weakened.

## Live handoff gate

`host-status` reports `RUNNING_UNMANAGED`: the native socket is active without a supervisor control process. A read-only `lsof` inventory identifies `ComputerU` PID **58198**, bound to `/private/tmp/agy-computer-use-501/host.sock`. It was left untouched. The main checkout's existing screenshot changes and untracked files were also left unchanged. No merge or host restart was performed.

**WAITING_FOR_HUMAN:** approve stopping this exact unmanaged host and switching to the candidate for a bounded live Calculator and native text/form qualification, or assign an isolated GUI host. The user-provided AGENTS process-safety rule requires exact-scope approval before touching a process outside this task's child process group. Revalidate PID/socket identity before any approved stop. Any required macOS permission prompt still requires the operator's own approval.

After the handoff: stage the exact reviewed candidate, record source/build identity, compare low-level and compound routes under the same Gemini 3.8 model/configuration, capture visible before/after evidence and the issue's requested metrics, and report only measured effects. The two-window/display/movement and independent-session/intervention qualifications belong to their later implementation slices.
