# Milestone D2 Execution Verification & Proof Packet

- **Date**: 2026-07-21
- **Branch**: `codex/bobby-computer-use-v0-20260721t174022z-a9ab71173113`
- **Parent Source Commit**: `3c2a20c9ecb001a1cce8a30dbf2ff6ef7ec3c3c7`
- **Reviewed Terminal Repair Head**: `a9d8957c562539883446c28afaf3d3bcbd4f0384` / `701fcf91dcf6b990f308648cd1ad575cc3acd45a`
- **Scope**: Milestone D2 Terminal Repair & Production-Bounded Native Observation (Exact-Head 9a1 & Terminal Repair A9D Closure)

---

## 1. Native Swift Test Authority Execution

Executed via `./bin/agy-computer-use test-native` (Swift 5.10 strict concurrency complete, `-warnings-as-errors`):

```text
[ComputerUseHostTestRunner] Starting Portable Native Execution Test Authority...
[TEST CASE 1] testLengthPrefixedFraming - PASSED
[TEST CASE 2] testOversizedFramingHeaderRejection - PASSED
[TEST CASE 3] testDirectoryPreparation - PASSED
[TEST CASE 4] testUDSClientServerRoundTrip - PASSED
[TEST CASE 5] testPostTimeoutUDSRecovery - PASSED
[TEST CASE 6] testSlowDripHeaderTimeout - PASSED
[TEST CASE 7] testSlowDripBodyTimeout - PASSED
[TEST CASE 8] testBlockedResponseWriteTimeout - PASSED
[TEST CASE 9] testPeerCloseAndPartialIO - PASSED
[TEST CASE 10] testEINTRRetryPath - PASSED
[TEST CASE 11] testTimeoutResponseFollowedByNextClient - PASSED
[TEST CASE 12] testLiveSocketCollisionRefusal - PASSED
[TEST CASE 13] testVerifiedStaleSocketRecovery - PASSED
[TEST CASE 14] testForeignSymlinkNonSocketRefusal - PASSED
[TEST CASE 15] testStopNeverUnlinksReplacementInode - PASSED
[TEST CASE 16] testIEEE754BitPatternTopologyGoldenVectorAndMutations - PASSED
[TEST CASE 17] testHotPlugSafeDisplayEnumerator - PASSED
[TEST CASE 18] testPermissionPreflightDeniedZeroLoaderCalls - PASSED
[TEST CASE 19] testPureJPEGValidatorExactAndNear10MiBBoundaries - PASSED
[TEST CASE 20] testSOF0AndSOF2MarkerValidation - PASSED
[TEST CASE 21] testJPEGInvalidMagicTruncatedSegmentAndMismatchRejection - PASSED
[TEST CASE 22] testNoncooperativeLateCompletionGenerationFence - PASSED
[TEST CASE 23] testTopologyChangeDuringCaptureDiscarded - PASSED
[TEST CASE 24] testDisabledActionsAndAXTreeRejection - PASSED
[TEST CASE 25] testDisplayIdParameterValidation - PASSED
[TEST CASE 26] testNoncooperativeObservationDeadlineElapsedTime - PASSED
[TEST CASE 27] test64MegapixelSafetyPreCheckRejection - PASSED
[TEST CASE 28] testCancellationErrorMappedToCancelledCode - PASSED
[TEST CASE 29] testCaptureBudgetCapacityLimitAndFastFailure - PASSED
[ComputerUseHostTestRunner] Executed 29 native test cases successfully. ALL PASSED.
```

---

## 2. Production Source & Demangled Binary Symbol Safety Guards

1. **Production Host Code Source Guard**:
   - `! git grep -n "CGRequestScreenCaptureAccess" -- 'apps/computer-use-host/Sources/'`: **0 matches** (Passed)
   - `! git grep -n "CGEvent" -- 'apps/computer-use-host/Sources/'`: **0 matches** (Passed)
   - `! git grep -n "Fake" -- 'apps/computer-use-host/Sources/'`: **0 matches** (Passed)
2. **Release Binary Symbol Guard & Fail-Closed Inspection**:
   - `swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
   - `BIN_PATH=$(swift build -c release --show-bin-path)/ComputerUseHost`
   - `test -f "$BIN_PATH"`: Binary exists (Passed)
   - `NM_OUT=$(nm "$BIN_PATH") && test -n "$NM_OUT"` (Passed)
   - `DEMANGLED_OUT=$(echo "$NM_OUT" | swift demangle) && test -n "$DEMANGLED_OUT"` (Passed)
   - `! echo "$DEMANGLED_OUT" | grep -iE "Fake|Spy|Scripted|Mock|TestDouble|TestRunner|TestHelper"`: **0 matches** (Passed)
   - Missing binary & demangler failure probes fail closed (Passed).

---

## 3. Protocol Schema, Golden Fixtures & SOF Image Verification

1. **Protocol Schema Definition**:
   - `docs/protocol_schema.json` defines method-specific strict status, observe, and error request/response subschemas with `additionalProperties: false`.
2. **Golden JSON Fixture Suite**:
   - Explicit fixture-to-schema mapping (`FIXTURE_MAPPINGS`) validates active D2 request, response, and error fixtures against Ajv subschemas and Zod data schemas.
   - `status_request.json` & `status_response.json`: Validated against Ajv `StatusRequest`/`StatusResponse` subschemas and Zod `StatusDataSchema`.
   - `observe_request.json` & `observe_response.json`: Validated against Ajv `ObserveRequest`/`ObserveResponse` subschemas, Zod `ObserveDataSchema`, and `validateAndDecodeBase64JPEG` asserting embedded JPEG SOF0 markers match `100x100` declared pixel dimensions.
   - `permission_denied_response.json`, `stale_topology_response.json`, `timeout_response.json`, `ax_tree_unreachable_response.json`: Validated as `ErrorResponse` fixtures.

---

## 4. MCP Server & TypeScript Test Suite

Executed via `cd mcp/computer-use-mcp && pnpm check && pnpm test`:

```text
# tests 34
# suites 2
# pass 34
# fail 0
# cancelled 0
# skipped 0
# todo 0
```

- **Tool Inventory**: `computer_use_status` and `computer_use_observe` (Exactly 2 tools).
- **Adversarial & Hardening Tests**:
  - Full JPEG state machine validation (`parseJPEGDimensions`) enforcing marker ordering, length checks (`SOF == 8 + 3*Nf`, `SOS == 6 + 2*Ns`), SOF0/SOF2 DCT variants, entropy stuffed/restart markers, and terminal EOI with no trailing non-zero garbage.
  - Allocation-free Base64 precheck validating $N = 10,485,760$ byte exact boundary acceptance and $N+1, N+2, N+3$ rejections before decoder invocation.
  - Single canonical Base64 decoding path (`validateAndDecodeBase64JPEG`).
  - Host client response ID matching (`parsedResp.id === reqId`).
  - Post-dispatch mutation error mapping to `ACTION_OUTCOME_UNKNOWN`.
  - Signal propagation, `display_id` argument normalization, and runtime Zod checks.
  - Strict Zod schemas (`.strict()`) and finite numbers (`.finite()`).
  - Skill package 100% recursive byte-for-byte identity between `.agents/skills/computer-use/` and `skills/computer-use/`.

---

## 5. Offline D2 Canary Readiness Validation

Executed via `./bin/agy-computer-use canary-ready`:

```text
[bin/agy-computer-use] Validating offline readiness for Milestone D2 (building TypeScript sources)...
[bin/agy-computer-use] Node.js version: v22.23.1
[bin/agy-computer-use] Verified .agents/mcp_config.json computer-use & computer-use-canary server registrations.
[bin/agy-computer-use] Verified D2 public MCP tool inventory: Exactly 2 tools (computer_use_observe, computer_use_status)
[bin/agy-computer-use] ALL OFFLINE D2 READINESS CHECKS PASSED!
```

---

## Honesty & Boundary Declarations

- **Darwin Race Boundary**: macOS kernel lacks inode-conditional `unlinkat` or `bindat`. Pre-unlink `lstat` checks, nonblocking `connect`/`poll`/`SO_ERROR` probes, and post-bind inode revalidation reduce but cannot eliminate a hostile same-UID final-check race window.
- **Topology Observation Stability**: Topology resolution uses a 3-pass list enumeration and 2-set descriptor fingerprint check (`bitPattern` comparison). This proves bounded observational stability across fetches rather than an atomic kernel snapshot, bounding residual ABA risk.
- **Process Isolation & Hung Captures**: Physical capture execution is bounded by an in-process `CaptureBudget` (default max 2 concurrent captures). If a framework call hangs indefinitely inside ScreenCaptureKit, the in-process budget returns `CAPTURE_BUSY` to new requests. Terminating a permanently hung framework capture requires a separate host process boundary or external `SIGKILL`.
- **Screen Recording Access**: Tested deterministically using `FakeScreenRecordingAuthorizer` and `SCScreenshotCaptureEngine` test double in `Tests/ComputerUseHostTestRunner`. No prompting `CGRequestScreenCaptureAccess` call or live screen capture was triggered.
- **Input Synthesis & AX Tree Inspection**: All action dispatch methods (`click`, `move`, `drag`, `type`, `shortcut`, `scroll`) return `MUTATION_DISABLED`. Accessibility tree inspection returns `TARGET_UNREACHABLE`. Real `CGEvent` synthesis is deferred to M9.
