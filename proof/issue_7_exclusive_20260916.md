# Issue 7 — native exclusive admission candidate

Date: September 16, 2026. Owner: this Codex task; no helper agents or teamwork run.
Repository/worktree: `/Users/bobbybones/.codex/worktrees/1d35/agy-computer-use`.
Branch: `codex/issue-7-exclusive-input`. Draft [PR #16](https://github.com/saariuslystoned/agy-computer-use/pull/16).

**Shared-mode native enforcement and background coexistence are proved for this candidate. Issue #7 remains open: admitted global input still needs live qualification on an administrator-owned isolated GUI VM or dedicated worker.** No such resource was assigned, and no admission record was provisioned on the shared desktop. This candidate does not replace the canonical host.

## Source and build binding

- Merged baseline: `2baef89f8937e64922dc9c4f58ef862040095d11` (PR #14).
- Frozen source S: `526fc8a8ec8188a769b740c68b3c6c13bd9d1da1`.
- Live executable SHA-256: `4b906df0d30182e97ad22fbd7e6f0ae5f963e0e7163a1c94a714435dc70181ab`.
- Task host PID 8627 used an isolated socket and task-local ad-hoc app bundle. Target PID 8189 and Sentinel PID 8191 were disposable fixtures.
- [Build manifest](issue_7_exclusive_20260916/build-manifest.json) binds every production Swift/C/MCP source file. [Source equivalence](issue_7_exclusive_20260916/source-equivalence.json) verifies those hashes and the running executable; all six AX implementation files match the merged baseline byte-for-byte. The later proof checkpoint changes only evidence, fixtures and run records.

Both exact-S workflows passed: [push](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35109894780), [pull request](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35109923523). [CI receipt](issue_7_exclusive_20260916/source-ci.json) records exact heads and completed steps. Final proof-head identity and CI are bound externally in the PR receipt to avoid a self-referential proof-commit chain.

## Production boundary and executed assertions

`ExclusiveInputAuthority` is mandatory in the production engine. Native IPC rejects every global method without the owning lease; direct engine calls independently need a one-use permit minted by that exact authority for the action and capture. AX trust, a caller boolean, an invented lease and a display ID cannot substitute.

A root-controlled, short-lived record binds environment, host instance, controller, login UID and GUI session. Acquisition binds an explicit already-focused app, process birth, window identity/set/bounds, topology and focused element. Wall and monotonic expiry, record revocation, target focus/geometry, secure input and full event-tap health are checked before each post, including after potentially blocking focus checks. External input poisons exclusive authority. Cleanup may only release downs already posted by this engine, and counts those releases in uncertain receipts. This remains global input with a non-atomic final-check/post interval; isolation is still required. See [admission contract](../docs/exclusive-input.md).

[Local gate receipts](issue_7_exclusive_20260916/local-checks.json): 48 native cases, 75 MCP tests, TypeScript check, thirteen-tool configured production readiness, and a strict-concurrency release build passed. Exact-S CI additionally passed Swift 5.10 discovery/manifest checks, app staging/enrollment tests and binary-symbol guards.

New native cases execute the real authority, server and CGEvent plan with a recording sink, never a system event post:

- All six methods reject missing/foreign/invented permits with zero sink events. Native shared status separates AX trust from admission. Native routes exercise successful admitted dispatch, capture replay and 31-second age rejection, and connection-close revocation even without an AX engine.
- Admitted click/move/type/shortcut/scroll/drag assert event types, counts and coordinates, including a negative display origin, wheel anchoring, shortcut modifiers, Unicode and drag release. Expiry, record changes, focus/takeover and guard errors block all six; keyboard checks use the explicit target guard.
- Mid-sequence revocation yields `OUTCOME_UNKNOWN`; only matching held-input releases follow. Replay posts nothing. Ownership, TTL bounds, wrong action/capture, admission identity and expiry errors are discriminated.
- MCP tests reject spoofed controller arguments, inject its private connection identity, preserve typed zero-post failures, reject contradictory status and malformed receipts, and prove no retry.

These tests do **not** qualify real global event delivery, system AX focus binding or the positive root-policy path. [Integrated review](issue_7_exclusive_20260916/review.json) records accepted/rejected findings and limits; it is primary-agent review, not an independent helper verdict.

## Live shared-desktop proof

The frozen host reported AX trusted, `operator_safe_ax`, mutation disabled, and only `ax_semantic`. The target was observed by its explicit window; only disposable target images were saved.

[Native assertions](issue_7_exclusive_20260916/native-live-02/assertions.json) cover 12 rejected global requests (all six normally and with a forged boolean/lease), rejected unprovisioned admission, five calculator presses and 15 verified background value writes. The global requests carry an observed window-image token; rejection occurs before global display-capture validation. Valid display-capture routing is covered by native tests. Calculator result was 5 and form value `issue7-background-14`; [final image](issue_7_exclusive_20260916/native-live-02/after.jpg) was visually inspected.

During the enclosing 25-second observation window, the read-only full-mask event tap recorded zero host events. All 460 samples kept Sentinel frontmost with unchanged focused element; 115 hardware key-downs matched 115 Sentinel key events, with 126 mouse moves and 22 sampled pointer-position changes. The action sequence occupied 2.53 seconds of that window; these aggregate counts alone do not establish per-action overlap. [Summary](issue_7_exclusive_20260916/shared-summary.json).

A second, paced [coexistence trial](issue_7_exclusive_20260916/coexistence-summary.json) addressed overlap directly: the user explicitly agreed to type and move the mouse while 20 background writes ran over 24.283 seconds. Every one-second iteration recorded Sentinel key activity and verified its background value. The 25-second observer saw 247 hardware key-downs, 2,163 mouse moves, zero host events and Sentinel frontmost in all 474 samples. Sentinel's independently sampled counter advanced 249 times; the sampling windows differ, so exact keystream equivalence is not claimed. There were 18 samples with a different focused-element identity and zero focus-read errors; their cause was not established. This trial therefore proves overlap/zero-HID/no target foreground activation, not invariant focused-element identity. Every iteration ended with the Sentinel field focused. Typed contents were never recorded.

An initial read-only image capture returned `STALE_OPERATION` before any action. Its empty [partial assertion record](issue_7_exclusive_20260916/native-live/partial-assertions.json) and failure receipt are retained; it is excluded. The accepted trials began from new observations, and no failed mutation was automatically retried.

## AGY qualification

The unique task-only MCP registration reached the frozen host through ordinary AGY CLI with requested model `gemini-3.8-flash-high`, effort high, permission bypass and no teamwork/helpers. The [read-only startup result](issue_7_exclusive_20260916/agy-startup-result.json) verified shared status in 69.04 seconds, backed by one status call in [tool metadata](issue_7_exclusive_20260916/agy-metrics.jsonl).

The full action qualification did **not** pass. The initial bounded attempt yielded no tool metrics and no usable parsed result; its wrapper looked for `result` while this CLI uses `structured_output`. After correcting that parser and proving status connectivity, the full action attempt returned an error envelope without a structured result after 182.16 seconds and made zero new tool calls. CLI exit zero is not accepted as success. [Final attempt receipt](issue_7_exclusive_20260916/agy-qualified-result.json) preserves that limitation. The wrapper's initial substring-based `lock` classification was discarded because `blocker_code` itself matches that substring; no specific store-lock cause was established. The unrelated existing AGY process was preserved, and no further retry was launched.

Ordinary AGY status connectivity is qualified; this candidate's full AGY action workflow remains an explicit qualification gap. Native live actions and MCP unit/readiness results above are separate evidence, not substitutes for that missing model-driven run. Only structured counters/envelope field names and tool metadata were retained, never raw AGY transcripts, tool arguments, model response text or typed Sentinel content.

## Exclusions, reference limits and remaining gate

An optional local lifecycle/app test invocation was discovered to target the canonical runtime; a duplicate invocation also overlapped its output. Canonical stop attempts were refused, and canonical PID 58198 remained running at its original executable path. Only this task's test process subtree was terminated. That output is excluded from validation; exact-S CI ran its required app/enrollment tests successfully in isolation. No successful canonical stop/replacement or TCC change is claimed.

The installed Codex `cua` interface was refreshed on September 16: explicit app/tab targets, index-first advertised actions, fresh AX differences, and combined image/AX observations. No upstream source SHA or release identity was exposed. This is an interface reference, not audited upstream-main equivalence. Public Apple event-tap/source-PID and OpenAI custom-tool references are linked in the admission contract. No proprietary implementation was copied or OpenAI model dependency added.

Remaining acceptance is a live positive/negative/error-path run on an explicitly owned isolated GUI environment: provision exact host/controller admission out of band, deliberately focus a disposable target, and prove coordinate geometry, keyboard recipient, stale state, focus change, expiry, release and takeover against actual system delivery. The current shared desktop must not be admitted merely to make those tests green. Issue #7 stays open; no merge, install or release is performed by this task.

[Cleanup receipt](issue_7_exclusive_20260916/cleanup.json): task host, target, Sentinel and AGY subprocesses exited; the task socket and unique MCP registration are gone. Canonical PID 58198 and unrelated AGY PID 80401 were preserved.
