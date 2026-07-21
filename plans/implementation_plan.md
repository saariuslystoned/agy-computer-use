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
| **M8** | Continuous Integration & End-to-End Verification Suite | `IMPLEMENTED & TESTED` | `swift test`, `pnpm test`, `.github/workflows/ci.yml` |
| **D1** | Dogfood Harness Canary & Read-Only Vision Verification | `IMPLEMENTED & TESTED` | `computer_use_canary_screenshot`, `proof/v0.1_verification.md` |
| **D2** | Production-Bounded Native Observation Slice | `IMPLEMENTED & TESTED` | `SCScreenshotCaptureEngine`, `SystemDisplayTopologyProvider`, `HostServer` sequence gate, `DisabledInputInjector`, `DisabledAXInspector`, `proof/d2_verification.md` |
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

### D2: Production-Bounded Native Observation Slice
- **Status**: Implemented & Tested
- **Key Deliverables**:
  - Nonprompting `ScreenRecordingAuthorizing` protocol calling only `CGPreflightScreenCaptureAccess()`.
  - `DisplayTopologyProviding` protocol and `SystemDisplayTopologyProvider` using `CGGetActiveDisplayList`, `CGMainDisplayID`, `CGDisplayBounds`, `CGDisplayCopyDisplayMode`, `CGDisplayRotation`, and order-independent SHA-256 topology versioning.
  - Async/Sendable `SCScreenshotCaptureEngine` with macOS 14 `SCScreenshotManager.captureImage`, process filtering (`excludingApplications`), in-process ImageIO JPEG encoding, and 10 MiB frame bounds check.
  - `HostServer` actor reentrancy sequence gate preventing stale/out-of-order capture lease promotion.
  - `DisabledInputInjector` returning stable `MUTATION_DISABLED` error for all input actions without consuming capture lease.
  - `DisabledAXInspector` returning `TARGET_UNREACHABLE` for `ax_tree`.
  - Real drivers wired in production `main.swift`.
  - Zero `CGEvent` code and zero `CGRequestScreenCaptureAccess` calls.

### M9: Real OS Driver Integration & Signed Production App (Future / Gated)
- **Status**: Gated & Future Work
- **Dependencies**: Requires Xcode app bundle signing, notarization, and user TCC authorization for input synthesis.
