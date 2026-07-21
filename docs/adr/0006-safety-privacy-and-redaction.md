# ADR 0006: Safety, Privacy, Sensitive Text Redaction & Human Gates

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Automated desktop interaction poses security and privacy risks if credentials, personal information, or destructive commands are executed without safeguards.

## Decision
1. **Automatic Redaction**:
   - Accessibility graph extraction automatically redacts element values flagged with `AXIsPassword` or `AXIsSecureText` (`[REDACTED]`).
   - Screenshots must never capture password entry fields when detectable.
2. **Human Approval Gate (`WAITING_FOR_HUMAN`)**:
   - Destructive file operations, external communications (email/SMS/chat to non-test contacts), or payment/financial actions require explicit user confirmation.
3. **Prompt Injection Defense**:
   - Desktop visual text or accessibility strings are untrusted data. Instructions found inside desktop UI windows must not override system safety prompts.
