# ADR 0006: Safety, Privacy, Sensitive Text Redaction & Human Gates

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Automated desktop interaction poses security and privacy risks if credentials, personal information, or destructive commands are executed without safeguards.

## Decision
1. **Official AX Subrole Redaction**:
   - Accessibility graph extraction automatically redacts secure text fields matching `kAXSubroleAttribute == kAXSecureTextFieldSubrole` (`subrole == "AXSecureTextField"`) to `[REDACTED]`. Title-based matching is not used as a classifier per Apple AX guidelines.
2. **Visual Screenshot Pixel Limitation**:
   - AX text DTO redaction does NOT obscure visual desktop screenshot pixels. Passwords rendered inside visible UI entry fields remain present in visual JPEG payloads unless secure element bounding boxes are post-processed and masked.
3. **App Entitlements & TCC Checks**:
   - Accessibility trust is checked asynchronously via `AXIsProcessTrustedWithOptions`. `NSAccessibilityUsageDescription` is not a valid macOS Info.plist key. Screen recording entitlement requires `NSScreenCaptureUsageDescription`.
4. **Human Approval Gate (`WAITING_FOR_HUMAN`)**:
   - Destructive file operations, external communications (email/SMS/chat to non-test contacts), or payment/financial actions require explicit concise human confirmation.
