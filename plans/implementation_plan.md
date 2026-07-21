# Implementation Plan & Status Ledger: Antigravity Computer Use (`agy-computer-use`)

## Architecture Overview & Scope Boundary
This implementation plan establishes the architectural foundation (v0.1) and deterministic test suite for `agy-computer-use`.
Work is partitioned into 10 dependency-ordered milestones (M0–M9), strictly distinguishing **Implemented & Tested**, **Designed / Bounded Foundation**, and **Gated / Future Work (M9)**.

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
| **M8** | Continuous Integration & End-to-End Verification Suite | `IMPLEMENTED & TESTED` | `swift run ComputerUseHostTestsRunner`, `pnpm test`, `.github/workflows/ci.yml` |
| **M9** | Real OS Drivers (ScreenCaptureKit, CGEvent, Signed App Bundle) | `GATED / FUTURE` | Requires signed `ComputerUseHost.app` bundle and active TCC authorization |

---

## Milestone Breakdown

### M0: Repository Hygiene, Toolchain & ADRs
- **Status**: Implemented & Tested
- **Tasks**:
  - Pin Node (`22.23.1`), pnpm (`10.33.0`), `@modelcontextprotocol/sdk` (`1.29.0`), and `zod` (`3.25.76`).
  - Establish `.gitignore`, `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`.
  - Document Architectural Decision Records (ADR 0001–0008) in `docs/adr/`.

### M1: Shared IPC Protocol Schema & Golden Fixtures
- **Status**: Implemented & Tested
- **Tasks**:
  - Define length-prefixed JSON-RPC framing protocol over Unix domain socket.
  - Create JSON schemas for requests, responses, frame capture, AX element tree, and input actions.
  - Provide golden JSON test fixtures in `docs/fixtures/`.

### M2: Swift Host Core Architecture & Typed Error Taxonomy
- **Status**: Implemented & Tested
- **Tasks**:
  - Create macOS 14+ Swift Package in `apps/computer-use-host`.
  - Define `ComputerUseError` taxonomy (stale topology, stale capture, out of bounds, velocity limit exceeded, permission denied, cancellation, timeout, IPC error).
  - Define DTOs for `CaptureFrame`, `AXNode`, `InputAction`, `DisplayTopology`.

### M3: Unix Domain Socket Listener & Framing Transport
- **Status**: Implemented & Tested
- **Tasks**:
  - Implement Unix domain socket listener and path resolver `/tmp/agy-computer-use-$UID/agy-computer-use.sock` with `0700` directory permissions.
  - Fail-closed `lstat` owner (`getuid()`), mode (`0700`), and non-symlink verification.
  - Implement length-prefixed message framing (4-byte big-endian uint32 payload header, max 16MB cap).

### M4: Bounded Accessibility (AX) Inspection Engine
- **Status**: Implemented & Tested
- **Tasks**:
  - Implement `AXInspectionEngine` protocol and fake backend for test environment.
  - Enforce depth limit (max 10), node count cap (max 500), text length truncation (max 256 chars), and cycle detection.
  - Detect `kAXSubroleAttribute == kAXSecureTextFieldSubrole` to redact passwords (`[REDACTED]`).

### M5: Display Topology & Coordinate Authority Engine
- **Status**: Implemented & Tested
- **Tasks**:
  - Implement `CoordinateMapper` for logical points <-> physical pixels <-> 0...999 normalized agent grid using `floor(gridX / 1000.0 * widthPoints)`.
  - Support multi-monitor coordinate spaces with negative screen origins.
  - Enforce topology versioning and stale-coordinate rejection.

### M6: Node / TypeScript MCP Server (`computer-use-mcp`)
- **Status**: Implemented & Tested
- **Tasks**:
  - Implement Node/TypeScript MCP server using production `@modelcontextprotocol/sdk` (`1.29.0`).
  - Strict Zod schema validation with `.strict()` and required `intent` parameter.
  - Ensure `stdout` is kept 100% clean for JSON-RPC stdio transport; logs strictly routed to `stderr`.
  - Return dual-content (JSON text metadata + MCP `ImageContent` object in camelCase).

### M7: Antigravity Skill & Safety Guardrails
- **Status**: Implemented & Tested
- **Tasks**:
  - Provide `.agents/skills/computer-use/SKILL.md` skill definition for Google Antigravity and Gemini 3.6 Flash.
  - Sync `.agents/skills/computer-use/SKILL.md` with `skills/computer-use/SKILL.md` with zero drift.

### M8: CI Workflow & Integration Proof
- **Status**: Implemented & Tested
- **Tasks**:
  - Provide GitHub Actions workflow `.github/workflows/ci.yml`.
  - Provide empirical verification record in `proof/v0.1_verification.md`.

### M9: Real OS Driver Integration & Signed Production App (Future / Gated)
- **Status**: Gated & Future Work
- **Dependencies**: Requires Xcode app bundle signing, notarization, and user TCC authorization.
- **Future Tasks**:
  - Implement real ScreenCaptureKit `SCScreenshotManager.captureImage` capture engine.
  - Implement real `CGEvent` mouse/keyboard synthesis engine.
  - Implement real `AXUIElement` system inspector.
