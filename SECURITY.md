# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

## Reporting a Vulnerability

Security issues should be reported confidentially. Do NOT open public GitHub issues for security vulnerabilities.

### Security Principles & Boundaries

1. **Owner-Only IPC**:
   - The IPC socket for `agy-computer-use` communicates over a Unix domain socket residing in an owner-only directory (`chmod 0700`).
   - Peer UID and credentials are validated at connect time. Same-UID unprivileged local processes are acknowledged as a residual risk boundary on macOS.

2. **TCC Permission Scope**:
   - Accessibility (`AXUIElement`) and Screen Recording (`ScreenCaptureKit`) permissions belong exclusively to the signed `ComputerUseHost.app` bundle.
   - The MCP server process must never request or claim TCC permissions independently.

3. **Data Redaction & Sanitization**:
   - Secure text fields (`AXIsPassword`, `AXIsSecureText`) are automatically redacted at the native host extraction boundary (`[REDACTED]`).
   - Secrets, tokens, environment variables, keychain values, and authorization credentials must never be included in visual screenshot payloads or standard log output.

4. **Human Gate Boundary**:
   - Destructive operations, external communications, financial transactions, or system configuration mutations must be gated by explicit human approval.
