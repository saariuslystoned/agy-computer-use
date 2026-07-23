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
| **D2** | Production-Bounded Native Observation Slice (Source Hardening) | `IMPLEMENTED & TESTED` | `ComputerUseHostTestRunner` (authoritative native tests), `SCScreenshotCaptureEngine`, `SystemDisplayTopologyProvider`, `HostServer` generation gate, `proof/d2_verification.md` |
| **M9** | Production Bounded Input Synthesis & Physical Dogfooding | `IMPLEMENTED & PHYSICALLY DOGFOODED` | Five-tool surface (`status`, `observe`, `click`, `type`, `shortcut`), local ad-hoc staged app TCC proof, `proof/m9_physical_dogfood.md`. |
| **M10** | Expanded AX Inspection & Continuous Pointer Actions (M10/D3) | `IMPLEMENTED & PHYSICALLY DOGFOODED` | Nine-tool surface (`status`, `observe`, `ax_tree`, `click`, `move`, `type`, `shortcut`, `scroll`, `drag`), `proof/m10_d3_physical_dogfood.md`. |

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
- **Key Deliverables**:
  - Authoritative native test runner (`./bin/agy-computer-use test-native`) executing required named native test cases.
  - Strict-concurrency compilation with warnings as errors (`swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`).
  - Pure test target isolation under `Tests/ComputerUseHostTestRunner`. Demangled release executable contains zero test-double family symbols (`Fake`, `Spy`, `Scripted`, `Mock`, `TestDouble`, `TestRunner`, `TestHelper`).
  - Nonisolated static observation deadline helper (`executeObservationWithDeadline`) preventing actor isolation leaks under Swift 5.10.
  - Generation allocation counter (`latestIssuedGeneration`) with immediate lease invalidation before await.
  - ContinuousClock UDS monotonic deadlines and separate phase budgets.
  - `SCScreenshotCaptureEngine` actor with strict `CGImage` dimension verification and 10 MiB raw JPEG bounds guard.
  - Lossless IEEE-754 bitPattern UInt64 hex formatting (`top-sha256-...`) with golden vector assertion and single-field float/integer mutation checks.
  - Raw JPEG SOF marker byte parser (`parseJPEGDimensions`) matching embedded JPEG dimensions with declared DTO dimensions.
  - 100% skill package recursive sync between `.agents/skills` and `skills/`.

### M9: Bounded Input Synthesis & Physical Dogfooding Slice
- **Status**: Implemented & Physically Dogfooded
- **Key Deliverables & Behavior**:
  - Five-tool active MCP surface (`computer_use_status`, `computer_use_observe`, `computer_use_click`, `computer_use_type`, `computer_use_shortcut`) driven live through Google Antigravity.
  - Proven local ad-hoc staged-app/TCC operation (`ComputerUseHost.app`).
  - Authoritative visual proof packet (`proof/m9_physical_dogfood.md`) and media artifacts (`m9_proof2_before.jpg`, `m9_proof2_after.jpg`, `m9_proof2_recording.mp4`).
  - Stable team signing, distribution, and notarization remain human-gated future work.
  - AX-tree inspection (`ax_tree`) and continuous input actions (`move`, `drag`, `scroll`) were deferred in M9 and activated in M10.

### M10: Expanded AX Inspection & Continuous Pointer Actions (M10/D3)
- **Status**: Implemented & Physically Dogfooded
- **Key Deliverables & Behavior**:
  - Nine-tool active MCP surface (`computer_use_status`, `computer_use_observe`, `computer_use_ax_tree`, `computer_use_click`, `computer_use_move`, `computer_use_type`, `computer_use_shortcut`, `computer_use_scroll`, `computer_use_drag`) driven live through Google Antigravity.
  - Active AX inspection with automatic secure text field subrole redaction (`[REDACTED]`).
  - Active continuous pointer movement (`move`), anchored relative scrolling (`scroll`), and button drag synthesis (`drag`).
  - Authoritative visual proof packet (`proof/m10_d3_physical_dogfood.md`) and media artifacts (`m10_proof_before.jpg`, `m10_proof_after.jpg`, `m10_hover_active.jpg`, `m10_ax_tree_redacted.json`, `m10_d3_end_to_end.mp4`).
