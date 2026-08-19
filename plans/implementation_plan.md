# Implementation Plan & Status Ledger: Antigravity Computer Use (`agy-computer-use`)

## Architecture Overview & Scope Boundary
This implementation plan establishes the architectural foundation (v0.1) and deterministic test suite for `agy-computer-use`.
Work is partitioned into dependency-ordered milestones (M0–M11 and Dogfood D1–D3), strictly distinguishing **Implemented & Tested**, **Designed / Bounded Foundation**, and **Gated / Future Work (post-v0.1)**.

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
| **M11** | Antigravity Skill Usability & Herdr-Puppet Qualification | `DESIGNED / BOUNDED FOUNDATION` | ADR 0010 and `.grilltrack/`; product implementation and live dual-worker proof are pending. |

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

### M11: Antigravity Skill Usability & Herdr-Puppet Qualification
- **Status**: Designed / Bounded Foundation
- **Boundary**: [ADR 0010](../docs/adr/0010-antigravity-skill-and-herdr-qualification-boundary.md)
- **Decision state**: `.grilltrack/ledger.json` and append-only `.grilltrack/events.jsonl`

`agy-computer-use` remains the standalone Computer Use-like skill and local
runtime for Antigravity. Herdr-Puppet is external qualification infrastructure;
it does not become an AGY tool, accept local computer-use actions, or move
machine/workspace/tab/model selectors into this repository's product API.

#### Bounded implementation slice

- Make the skill's normal task loop usable without Herdr concepts: readiness,
  validated app/window/page selection, observation, exact semantic action or
  purpose-built browser routing, and fresh result verification.
- Default to a validated active target when it matches the task. Return a
  typed ambiguity or drift result instead of guessing or silently retargeting.
- Keep browser DOM behavior behind a separately qualified adapter consistent
  with ADR 0001. Do not expose a vendor CLI as the AGY contract and do not
  silently fall back to clipboard or global HID input.
- Preserve submitted text and sensitive state outside receipts, logs, model
  intent strings, and curated proof.
- Treat any newly reported live blocker as source input to diagnose; do not
  weaken target, freshness, TCC, or post-action verification authority merely
  to make the dogfood pass.

#### Required live exit criteria

All criteria must pass independently on `aiworker-01` and `aiworker-02` from
fresh Herdr-Puppet-owned Gemini 3.7 rows:

1. The row's bound Antigravity installation discovers the current mirrored
   `computer-use` skill and reaches the expected MCP/native-host surface.
2. `computer_use_status` proves host connectivity, TCC readiness, mutation
   policy, topology, and the advertised operator-safe action vector before any
   mutation.
3. A deterministic native fixture exercises one semantic `press` and one
   non-secure `set_value`. Each action uses fresh exact references and is
   followed by fresh AX inspection that proves the intended state; dispatched
   status alone is insufficient.
4. A local browser fixture exercises ordinary input and an event-sensitive or
   controlled field through the qualified DOM/browser backend. Fresh semantic
   read-back must prove the value and expected event-driven state.
5. A real native Herdr client detach/reattach occurs during the task-owned row.
   Session, workspace, tab, pane, terminal, SSH, harness, source, and relevant
   computer-use target identities remain exact afterward.
6. The controller preserves the exact row on success, failure, or uncertainty
   and returns sanitized resume/close handles. Cleanup remains explicit.

The M11 status must not advance to implemented or verified from source tests,
a transport acknowledgement, a model assertion, one worker, a native-only
demo, or a browser screenshot without semantic read-back.

#### Deferred beyond M11

- Signed-in production-site automation or external form submission.
- Automatic Herdr row cleanup.
- Live HUD, durable signing/notarization, full multi-display automation, and
  broad noninterfering-action parity.
- Admission and source-head attestation services.
