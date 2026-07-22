# Milestone D2 Source Verification & Proof Packet

## 1. Source & Branch Identity
- **Exact Source Commit ($S$)**: `428338feec2c9752c49a59b07ce52b6841036be7`
- **Branch**: `codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`
- **Draft Pull Request**: [https://github.com/saariuslystoned/agy-computer-use/pull/1](https://github.com/saariuslystoned/agy-computer-use/pull/1)
- **Pre-Proof Alignment**: Local `HEAD`, remote `origin/codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`, and Draft PR head OID matched exact source SHA $S$ (`428338feec2c9752c49a59b07ce52b6841036be7`) prior to proof child creation.

## 2. Continuous Integration Runs for Exact Source ($S$)
- **Push CI Run**:
  - Run ID: `29891770989`
  - Event: `push`
  - URL: [https://github.com/saariuslystoned/agy-computer-use/actions/runs/29891770989](https://github.com/saariuslystoned/agy-computer-use/actions/runs/29891770989)
  - Head SHA: `428338feec2c9752c49a59b07ce52b6841036be7`
  - Status / Conclusion: `completed` / `success`
- **Pull Request CI Run**:
  - Run ID: `29891772570`
  - Event: `pull_request`
  - URL: [https://github.com/saariuslystoned/agy-computer-use/actions/runs/29891772570](https://github.com/saariuslystoned/agy-computer-use/actions/runs/29891772570)
  - Head SHA: `428338feec2c9752c49a59b07ce52b6841036be7`
  - Status / Conclusion: `completed` / `success`

## 3. Audits & Steering Acceptance
- **Antigravity Read-Only Skeptic Verdict**: `SKEPTIC_PASS(428338feec2c9752c49a59b07ce52b6841036be7, af2fdd695316b02c8d6fda257e0a619114a3103b1508fcd6e2cd92809c0faf59)`
- **Codex Steering Review**: Three independent exact-head Codex reviews accepted source SHA $S$.
- **Native Test Authority Gate**: Clean `38/38` native test pass executed by Codex at exact source $S$.

## 4. Local Execution Verification
- `./bin/agy-computer-use test-native`: 3 consecutive passes, 38/38 native test cases passing cleanly on every pass.
- `git diff --check`: 0 whitespace errors or warnings.
- `pnpm check` & `pnpm test` (in `mcp/computer-use-mcp`): Executed cleanly via GitHub Actions CI matrix on exact source $S$.

## 5. Covered Source Boundaries (Milestone D2)
- **R1 Sleeper State-Machine Authority**: Race-free `ManualSleeper` with atomic `waitUntilArmed`, coherent lock state, and orphan-continuation prevention.
- **R2 Deadline & Capture Lifecycle Authority**: `HostServer` deadline and capture arbiter across 6 deterministic scenarios (timeout, requester cancellation, pre-entry generation fence, success, post-wake sleeper error, capture cancellation).
- **Four Test Surfaces Registration**: `run38_HostServerDeadlineCaptureAuthority` registered across `HostServerTests.swift`, `XCTestDiscovery.swift`, `main.swift`, and `native-authority-selection.ts`.
- **TypeScript & Schema Alignment**: Canonical JPEG mutation JSON vector, Node bounds validator export, and ESM authority selection.
- **Release-Symbol & Canary Readiness**: Strict Swift concurrency flags (`-strict-concurrency=complete -warnings-as-errors`) and offline readiness.

## 6. Safety & Operational Invariants
- Zero TCC permission changes or real input synthesis invoked.
- Zero force-pushes or history rewrites.
- Draft PR retained without premature merge or ready transition.
- Zero secret disclosure or unverified external calls.

## 7. Proof Child Lineage Assertion
- Proof child commit $P$ has exact parent $P^\wedge = S = 428338feec2c9752c49a59b07ce52b6841036be7$.
- `git diff --name-only S..P` touches strictly `proof/d2_verification.md`.
