# Implementation Plan & Status Ledger: Antigravity Computer Use (`agy-computer-use`)

## Architecture Overview & Scope Boundary
This implementation plan establishes the architectural foundation (v0.1) and deterministic test suite for `agy-computer-use`.
Work is partitioned into dependency-ordered milestones (M0–M9 & Dogfood D1–D2), strictly distinguishing **Implemented & Tested**, **Designed / Bounded Foundation**, and **Gated / Future Work (M9)**.

---

## Status Ledger

| Milestone | Description | Status | Verification / Artifact |
|---|---|---|---|
| **M0** | Repository Hygiene, Toolchain Pins, Security Policy & ADRs | `IMPLEMENTED & TESTED` | `.gitignore`, `.mise.toml`, `LICENSE`, `SECURITY.md`, `docs/adr/` |
| **M1** | Shared IPC Protocol Schema & Golden JSON Fixtures | `IMPLEMENTED & TESTED` | `docs/protocol_schema.json`, `docs/fixtures/` |
| **M2** | Swift Host Core Architecture, DTOs & Error Taxonomy | `IMPLEMENTED & TESTED` | `apps/computer-use-host/Sources/ComputerUseHostLib/Core/` |
| **M3** | Unix Domain Socket Listener & Length-Prefixed Transport | `IMPLEMENTED & TESTED` | `apps/computer-use-host/Sources/ComputerUseHostLib/IPC/` |
| **M4** | Bounded AX Inspection Engine & Subrole Redaction Seam | `IMPLEMENTED & TESTED` | `apps/computer-use-host/Sources/ComputerUseHostLib/AX/` |
| **M5** | Display Topology & Half-Open Coordinate Authority | `IMPLEMENTED & TESTED` | `apps/computer-use-host/Sources/ComputerUseHostLib/Topology/` |
| **M6** | TypeScript MCP Server Bridge & Official Client Tests | `IMPLEMENTED & TESTED` | `mcp/computer-use-mcp/` |
| **M7** | Antigravity Skill Definition & Safety Guardrails | `IMPLEMENTED & TESTED` | `.agents/skills/computer-use/SKILL.md` |
| **M8** | Continuous Integration & End-to-End Verification Suite | `IMPLEMENTED & TESTED` | `./bin/agy-computer-use test-native`, `pnpm test`, `.github/workflows/ci.yml` |
| **D1** | Dogfood Harness Canary & Read-Only Vision Verification | `IMPLEMENTED & TESTED` | `computer_use_canary_screenshot`, `proof/v0.1_verification.md` |
| **D2** | Production-Bounded Native Observation Slice (Closure Slice) | `IMPLEMENTED & TESTED` | `ComputerUseHostTestRunner` (13 native tests), `SCScreenshotCaptureEngine`, `SystemDisplayTopologyProvider`, `HostServer` generation gate, `DisabledInputInjector`, `DisabledAXInspector`, `proof/d2_verification.md` |
| **M9** | Production Input Synthesis (CGEvent) & Signed App Bundle | `GATED / FUTURE` | Requires signed `ComputerUseHost.app` bundle and active TCC authorization |

---

## Milestone Breakdown

### M0: Repository Hygiene, Toolchain & ADRs
- **Status**: Implemented & Tested

### M1: Shared IPC Protocol Schema & Golden Fixtures
- **Status**: Implemented & Tested

### M2: Swift Host Core Architecture & Typed Error Taxonomy
- **Status**: Implemented & Tested

### M3: Unix Domain Socket Listener & Framing Transport
- **Status**: Implemented & Tested

### M4: Bounded Accessibility (AX) Inspection Engine
- **Status**: Implemented & Tested

### M5: Display Topology & Coordinate Authority Engine
- **Status**: Implemented & Tested

### M6: Node / TypeScript MCP Server (`computer-use-mcp`)
- **Status**: Implemented & Tested

### M7: Antigravity Skill & Safety Guardrails
- **Status**: Implemented & Tested

### M8: CI Workflow & Integration Proof
- **Status**: Implemented & Tested

### D1: Dogfood Harness Canary
- **Status**: Implemented & Tested
- Read-only Calculator capture proof via Peekaboo bridge and `computer_use_canary_screenshot`.

### D2: Production-Bounded Native Observation Slice (Test Authority Closure)
- **Status**: Implemented & Tested
- **Key Deliverables & Repairs**:
  - Authoritative native test runner (`./bin/agy-computer-use test-native`) executing 13 named native test cases.
  - Strict-concurrency compilation with warnings as errors (`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`).
  - Pure test target isolation under `Tests/ComputerUseHostTestRunner`. Demangled release executable contains zero `fake`, `test`, `spy`, `scripted`, or `continuation` symbols.
  - Nonisolated static observation deadline helper (`executeObservationWithDeadline`) preventing actor isolation leaks under Swift 5.10.
  - Generation allocation counter (`latestIssuedGeneration`) with immediate lease invalidation before await.
  - ContinuousClock UDS monotonic deadlines and separate phase budgets.
  - `SCScreenshotCaptureEngine` actor with strict `CGImage` dimension verification and 10 MiB raw JPEG bounds guard.
  - Lossless IEEE-754 bitPattern UInt64 hex formatting (`top-sha256-...`) with golden vector assertion and single-field float/integer mutation checks.
  - Raw JPEG SOF marker byte parser (`parseJPEGDimensions`) matching embedded JPEG dimensions with declared DTO dimensions.
  - D2 observation-only MCP tool inventory (`computer_use_status` and `computer_use_observe`).
  - 100% skill package recursive sync between `.agents/skills` and `skills/`.

### M9: Real OS Driver Integration & Signed Production App (Future / Gated)
- **Status**: Gated & Future Work
- **Dependencies**: Requires Xcode app bundle signing, notarization, and user TCC authorization for input synthesis.
