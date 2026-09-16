# Milestone D2 Source Verification & Proof Packet

> [!NOTE]
> This packet remains bound to exact historical source
> `57b0550b1d41588c99783ca7992d49e9e1a486b7`. D2 is now the completed
> observation/source-hardening foundation; current M9 runtime behavior and
> media are recorded in `proof/m9_physical_dogfood.md`.

## 1. Source & Branch Identity
- **Exact Source Commit ($S$)**: `57b0550b1d41588c99783ca7992d49e9e1a486b7`
- **Parent Base ($S^\wedge$)**: `53b1433c8c6095e54232ceb770cea36f8e84b356`
- **Branch**: `codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`
- **Draft Pull Request**: [https://github.com/saariuslystoned/agy-computer-use/pull/1](https://github.com/saariuslystoned/agy-computer-use/pull/1)
- **Pre-Proof Alignment**: Local `HEAD`, remote `origin/codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`, and Draft PR head OID matched exact source SHA $S$ (`57b0550b1d41588c99783ca7992d49e9e1a486b7`) prior to proof child creation.

## 2. Continuous Integration Runs for Exact Source ($S$)
- **Push CI Run**:
  - Run ID: `29919361167`
  - Event: `push`
  - URL: [https://github.com/saariuslystoned/agy-computer-use/actions/runs/29919361167](https://github.com/saariuslystoned/agy-computer-use/actions/runs/29919361167)
  - Head SHA: `57b0550b1d41588c99783ca7992d49e9e1a486b7`
  - Status / Conclusion: `completed` / `success`
- **Pull Request CI Run**:
  - Run ID: `29919364099`
  - Event: `pull_request`
  - URL: [https://github.com/saariuslystoned/agy-computer-use/actions/runs/29919364099](https://github.com/saariuslystoned/agy-computer-use/actions/runs/29919364099)
  - Head SHA: `57b0550b1d41588c99783ca7992d49e9e1a486b7`
  - Status / Conclusion: `completed` / `success`

## 3. Audits & Steering Acceptance
- **Codex Steering Review**: Two independent exact-head Codex reviews accepted source SHA $S$; one static finding was explicitly revised to ACCEPT after proving that the production UDS JSON path encodes whole-valued doubles as JSON integers and `AnyCodable` decodes `Int` before `Double`.
- **Native Test Authority Gate**: Clean `38/38` native test pass executed by Codex at exact source $S$.

## 4. Local Execution Verification
- `./bin/agy-computer-use test-native`: 38/38 native test cases passing cleanly (`38/38 [PASS]`).
- **Rebuilt-Binary Stress Test**: Executed `ComputerUseHostTestRunner` in 50 fresh processes (50 x 38 = 1,900 case executions), 100% exit zero with exact 38-case marker `Executed 38 native test cases successfully. ALL PASSED.` and zero signal termination.
- `pnpm check` & `pnpm test` (in `mcp/computer-use-mcp`): Both TypeScript commands passed in the single macOS job of both exact-source GitHub Actions CI runs on exact source $S$ (45/45 tests passing).
- `./bin/agy-computer-use canary-ready`: Offline D2 readiness checks passed.
- `git diff --check`: 0 whitespace errors or warnings.

## 5. Covered Source Boundaries (Milestone D2)
- **Deterministic EINTR & EIO Authority (`run10_EINTRRetryPath`)**: Injected initial 1 x -1/EINTR for `accept`, 4-byte header `read`, request body `read`, and response `write` with atomic counter assertions (`acceptInjections == 1`, `headerReadInjections == 1`, `bodyReadInjections == 1`, `responseWriteInjections == 1`, `acceptCallCount == 2`, `readCallCount == 4`, `writeCallCount == 2`). Full decoded `status` wire payload authority (`connected`, `tcc_permission_state`, `accessibility_available`, `accessibility_trusted`, `input_mutation_state`, `topology_version`, `primary_display_id`, `display_count`, `topology`). Same-listener recovery verification (`acceptCallCount == 3`, `readCallCount == 6`, `writeCallCount == 3`). Separate 1 x -1/EIO response-write discriminator proving write is NOT retried (`writeCallCount == 1`) and peer experiences read failure / EOF. Throw-safe checked cleanup with descriptor accounting (`areAllDescriptorsClosed == true`). Complete elimination of process-wide `SIGUSR1` and `kill(getpid(), ...)` from host test runner.
- **Cohesive Source Checkpoint Lineage**: `30893a883645f8169b1d6794a209ae357d13bac2` (AGENTS teamwork-authority contract), `dc6d21f03a1ad762416f79b290aaa70acaf73f00` (R3 socket authority), `53b1433c8c6095e54232ceb770cea36f8e84b356` (image capture authority C3/C4), `57b0550b1d41588c99783ca7992d49e9e1a486b7` (deterministic test10 EINTR/EIO authority).
- **Four Test Surfaces Registration**: `run10_EINTRRetryPath` registered across `apps/computer-use-host/Tests/ComputerUseHostTestRunner/main.swift`, XCTest method in `apps/computer-use-host/Tests/ComputerUseHostTests/ComputerUseHostTests.swift`, Linux `__allTests` entry in `ComputerUseHostTests.swift`, and `docs/native_test_manifest.txt`.

## 6. Safety & Operational Invariants
- Zero TCC permission changes, menu-bar UI, stable TCC identity, or real input synthesis invoked.
- Source $S$ and proof child $P$ were published only by ordinary additive pushes; an earlier recorded force-with-lease incident predates $S$ and is preserved rather than erased.
- Draft PR 1 retained without premature merge, ready transition, deployment, release, tag, or global installation.
- No secret or credential access occurred in this checkpoint.

## 7. Lineage Assertions
- Source commit $S$ (`57b0550b1d41588c99783ca7992d49e9e1a486b7`) has parent $S^\wedge = 53b1433c8c6095e54232ceb770cea36f8e84b356$.
- Proof child commit $P$ (`15be6fbaf989ed9d4e887c6672c3d87ab92c59c1`) has exact parent $P^\wedge = S = 57b0550b1d41588c99783ca7992d49e9e1a486b7$.
- `git diff-tree --no-commit-id --name-only -r P` touches strictly `proof/d2_verification.md`.


## Issue 12 compound AX observation candidate — 2026-09-16

Local first-slice candidate: 43 native cases, 66 MCP tests, TypeScript check, configured production readiness, and strict native host build pass. See [candidate proof and live gate](issue_12_action_observation_20260916.md). Live Gemini/AX qualification is pending; Issue 12 remains open.

## September 16, 2026 — Issue 12 follow-up

The original D2 evidence above remains historical. Current source `eb7968b90d3065b2961756f086c88c1457a6d5f7` passes 44 native cases, 66 MCP tests, TypeScript, strict native build, and production readiness. See [background coexistence proof](issue_12_background_20260916.md) for the frozen-build AGY calculator result, intervention checks, and the remaining compound-form qualification limit.

## September 16, 2026 — Issue 12 completion candidate

Production source `979f973f7a54cd14810bf2808493ded234615037` passes 45 native cases, 70 MCP tests, TypeScript, strict native build and twelve-tool production readiness. Its [push workflow](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35104580052) and [PR workflow](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35104583736) both passed.

The [complete source/build-bound report](issue_12_completion_20260916.md) records matched calculator/form AGY runs (16 vs 9 exchanges), physical keyboard and mouse coexistence, human target takeover rejection, final 26-case three-display/window/session proof, and honest unchanged/timeout/failure/stale-recovery outcomes. Earlier incomplete attempts and build differences are retained explicitly. Task-owned test processes and MCP registration were removed; the canonical host remains unchanged.

[PR #14](https://github.com/saariuslystoned/agy-computer-use/pull/14) contains the completed implementation/qualification candidate. Exact proof-child CI and issue disposition are bound in its final external receipt. Merge/release, native exclusive-global-input enforcement (#7), live HUD (#8), and TCC onboarding (#2) remain separate. Historical D2 and PR #13 evidence above is preserved.

## September 16, 2026 — Issue 7 native exclusive admission candidate

Frozen source `526fc8a8ec8188a769b740c68b3c6c13bd9d1da1` passes 48 native cases, 75 MCP tests, TypeScript, strict release build and thirteen-tool production readiness. Both exact-source [push](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35109894780) and [PR](https://github.com/saariuslystoned/agy-computer-use/actions/runs/35109923523) CI passed.

The [source/build-bound report](issue_7_exclusive_20260916.md) records all-six native shared denials, 20 calculator/form actions, a separate 20-write trial overlapping real operator input, zero observed host HID, honest focus/count limits, rejected attempts and cleanup. Ordinary AGY status passed; its full bounded action trial returned an error without action calls. Isolated positive global-input qualification and full AGY action qualification remain open. [Draft PR #16](https://github.com/saariuslystoned/agy-computer-use/pull/16) is reviewable; it is not merged or installed, and Issue #7 stays open. Final proof-head CI is recorded externally on the PR.
