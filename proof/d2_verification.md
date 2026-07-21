# Milestone D2 Verification Summary: Production-Bounded Native Observation Slice

## Overview
This document records empirical test verification for Milestone D2 in `agy-computer-use`.
Milestone D2 establishes the native macOS observation slice without real input synthesis (`MUTATION_DISABLED`) or live prompt generation during implementation.

---

## Architectural Boundaries Implemented

1. **Non-Prompting Permission Preflight**:
   - `ScreenRecordingAuthorizing` protocol and `CGScreenRecordingAuthorizer`.
   - Calls ONLY `CGPreflightScreenCaptureAccess()`.
   - Zero calls to `CGRequestScreenCaptureAccess()`.

2. **Deterministic Display Topology**:
   - `DisplayTopologyProviding` protocol and `SystemDisplayTopologyProvider`.
   - Queries `CGGetActiveDisplayList`, `CGMainDisplayID`, `CGDisplayBounds`, `CGDisplayCopyDisplayMode`, `CGDisplayRotation`.
   - Derives Retina scale factor (`pixelWidth / bounds.width`).
   - Computes deterministic, order-independent SHA-256 topology version string (`top-sha256-...`).

3. **Native ScreenCaptureKit Engine (`SCScreenshotCaptureEngine`)**:
   - Async/Sendable implementation utilizing macOS 14 `SCShareableContent` and `SCScreenshotManager.captureImage`.
   - Excludes host app (`excludingApplications: [currentApp]`).
   - In-process ImageIO JPEG encoding (`UTType.jpeg`).
   - Bounded image size guard (rejects payloads >10 MiB before base64).

4. **HostServer Sequence Gate & Reentrancy Lock**:
   - Monotonic sequence counter gating capture lease installation.
   - Prevents stale/out-of-order completions from overwriting newer observations.
   - Cancelled/timed out tasks never install a lease.

5. **Mutation Lockout & AX Seam**:
   - `DisabledInputInjector`: all 6 action methods (`click`, `move`, `drag`, `type`, `shortcut`, `scroll`) return stable `MUTATION_DISABLED` error before lease consumption.
   - `DisabledAXInspector`: returns `TARGET_UNREACHABLE` for `ax_tree`.

---

## Verification Test Run Outputs

### 1. Swift Host Unit & Integration Test Suite
```text
[TEST] Running Swift Host Unit & Integration Tests (Milestone D2)...
[ALL TESTS PASSED] Swift Host unit & integration tests (D2) executed cleanly.
Command: swift build && swift test
Status: SUCCESS (Exit Code 0)
```

### 2. TypeScript MCP Server & HostClient Test Suite
```text
TAP version 13
# Subtest: Computer Use Canary MCP Server Protocol & Hardening Test Suite
ok 1 - Computer Use Canary MCP Server Protocol & Hardening Test Suite
# Subtest: Computer Use MCP Server & HostClient Test Suite (Milestone D2)
ok 2 - Computer Use MCP Server & HostClient Test Suite (Milestone D2)

# tests 23
# pass 23
# fail 0
Command: pnpm check && pnpm test
Status: SUCCESS (Exit Code 0)
```

### 3. Canary Readiness Verification Script
```text
[bin/agy-computer-use] Validating canary readiness for Dogfood D1...
[bin/agy-computer-use] Node.js version: v22.23.1
[bin/agy-computer-use] Verified .agents/mcp_config.json command, args, cwd, and target existence.
[bin/agy-computer-use] Verified public MCP tool inventory: Exactly 1 tool ('computer_use_canary_screenshot')
[bin/agy-computer-use] ALL CANARY READINESS CHECKS PASSED!
Command: ./bin/agy-computer-use canary-ready
Status: SUCCESS (Exit Code 0)
```

### 4. Source Safety Checks
```text
Verified 0 occurrences of CGRequestScreenCaptureAccess across Swift sources.
Verified 0 occurrences of CGEvent across Swift sources.
```
