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
   - The IPC socket for `agy-computer-use` resides in a canonical Darwin per-user directory (`/private/tmp/agy-computer-use-$UID/host.sock`) created with `0700` owner-only permissions.
   - On macOS, peer UID is checked via `getpeereid`.
   - Host lifecycle is protected by a cooperative single-instance file lock (`host.lock` with `flock(LOCK_EX | LOCK_NB)`).
   - **Darwin Race Boundary**: macOS kernel lacks inode-conditional `unlink` (`unlinkat` with inode verification) or `bindat`. Pre-unlink `lstat` checks, nonblocking `connect`/`poll`/`SO_ERROR` stale socket probes, and post-bind inode revalidation minimize race windows but cannot eliminate a hostile same-UID final-check race window.
   - **Process Isolation & Hung Captures**: Physical capture execution is bounded by an in-process `CaptureBudget` (default max 2 concurrent captures). If a framework call hangs indefinitely inside ScreenCaptureKit, the in-process budget returns `CAPTURE_BUSY` to new requests. Terminating a permanently hung framework capture requires a separate host process boundary or external `SIGKILL`.

2. **TCC Permission Scope & App Entitlements**:
   - Screen Recording (`ScreenCaptureKit`) requires `NSScreenCaptureUsageDescription` in `ComputerUseHost.app`.
   - Accessibility trust is checked asynchronously via `AXIsProcessTrustedWithOptions`.
   - The MCP server process must never request or claim TCC permissions independently.

3. **AX Metadata Redaction & Pixel Limitation**:
   - Accessibility graph extraction automatically redacts secure text fields matching `kAXSubroleAttribute == kAXSecureTextFieldSubrole` (`[REDACTED]`).
   - **Visual Pixel Limitation**: AX text metadata redaction does NOT mask visual desktop screenshot pixels. Passwords typed into visible UI elements may be visible in visual JPEG frame captures unless visual rect masking is applied.

4. **Human Gate Boundary**:
   - Destructive file operations, external communications, financial transactions, or system configuration mutations must be gated by explicit human approval (`CODEX_TEAMWORK_ACTION_REQUIRED`).
