# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

## Reporting a Vulnerability

Security issues should be reported confidentially. Do NOT open public GitHub issues for security vulnerabilities.

### Security Principles & Boundaries

1. **Owner-Only IPC & Peer Admission**:
   - The IPC socket for `agy-computer-use` resides in a Darwin per-user directory (`/tmp/agy-computer-use-$UID/host.sock`) created with `umask 077` (`chmod 0700`).
   - On macOS, peer UID is checked via `getpeereid` or `SOL_LOCAL / LOCAL_PEERCRED` (never Linux `SO_PEERCRED`).
   - **Residual Threat Boundary**: Peer UID is an admission filter, not full privilege authorization. Malicious same-UID unprivileged local processes can connect to the socket. Future revisions will enforce authenticated client token bindings (`AUTH_SECRET` handshake).
   - Socket directory checks enforce fail-closed `lstat` verification of owner (`uid`), permission mode (`0700`), and non-symlink status before binding, and never unlink live sockets.

2. **TCC Permission Scope & App Entitlements**:
   - Screen Recording (`ScreenCaptureKit`) requires `NSScreenCaptureUsageDescription` in `ComputerUseHost.app`.
   - Accessibility trust is checked asynchronously via `AXIsProcessTrustedWithOptions`. (`NSAccessibilityUsageDescription` is not a documented macOS key).
   - The MCP server process must never request or claim TCC permissions independently.

3. **AX Metadata Redaction & Pixel Limitation**:
   - Accessibility graph extraction automatically redacts secure text fields matching `kAXSubroleAttribute == kAXSecureTextFieldSubrole` (`[REDACTED]`). Title matching is not used as a classifier.
   - **Visual Pixel Limitation**: AX text metadata redaction does NOT mask visual desktop screenshot pixels. Passwords typed into visible UI elements may be visible in visual JPEG frame captures unless visual rect masking is applied.

4. **Human Gate Boundary**:
   - Destructive file operations, external communications, financial transactions, or system configuration mutations must be gated by explicit human approval (`CODEX_TEAMWORK_ACTION_REQUIRED`).
