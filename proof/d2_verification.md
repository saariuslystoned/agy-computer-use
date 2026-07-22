# Milestone D2 Source Verification & Proof Packet

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
- **Antigravity Read-Only Skeptic Verdict**: `SKEPTIC_PASS(57b055050cebf35d64b18dfaae262ecffabfc4be, 7420c51cb96d470c458c99f51d50e465ed98c13bcd6a1c313d1a852367cd0249)`
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
- **Cohesive Source Checkpoint Lineage**: `30893a8` (socket authority), `dc6d21f` (post-cycle scope adjudication), `53b1433` (image capture authority C3/C4), `57b0550` (test10 EINTR & EIO authority).
- **Four Test Surfaces Registration**: `run10_EINTRRetryPath` registered across `apps/computer-use-host/Tests/ComputerUseHostTestRunner/main.swift`, XCTest method in `apps/computer-use-host/Tests/ComputerUseHostTests/ComputerUseHostTests.swift`, Linux `__allTests` entry in `ComputerUseHostTests.swift`, and `docs/native_test_manifest.txt`.

## 6. Safety & Operational Invariants
- Zero TCC permission changes, menu-bar UI, stable TCC identity, or real input synthesis invoked.
- Source $S$ and proof child $P$ were published only by ordinary additive pushes; an earlier recorded force-with-lease incident predates $S$ and is preserved rather than erased.
- Draft PR 1 retained without premature merge, ready transition, deployment, release, tag, or global installation.
- No secret or credential access occurred in this checkpoint.

## 7. Lineage Assertions
- Source commit $S$ (`57b0550b1d41588c99783ca7992d49e9e1a486b7`) has parent $S^\wedge = 53b1433c8c6095e54232ceb770cea36f8e84b356$.
- Proof child commit $P$ has exact parent $P^\wedge = S = 57b0550b1d41588c99783ca7992d49e9e1a486b7$.
- `git diff-tree --no-commit-id --name-only -r P` touches strictly `proof/d2_verification.md`.
