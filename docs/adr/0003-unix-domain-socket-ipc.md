# ADR 0003: Local IPC over Versioned Length-Prefixed Unix Domain Socket

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Communication between the TypeScript MCP server and the native Swift host requires low latency, local privilege isolation, and framed message boundaries for binary payload (screenshot) transport.

## Decision
1. **Transport & Darwin Paths**:
   - Unix domain socket located at Darwin per-user directory `/tmp/agy-computer-use-$UID/agy-computer-use.sock`.
   - Socket directory created with `umask 077` (`chmod 0700` owner-only).
   - Socket creation performs fail-closed `lstat` checks verifying owner UID, mode `0700`, and non-symlink status before binding. Never unlinks unverified or live sockets.
2. **macOS Peer Credentials**:
   - Peer UID is verified on macOS via `getpeereid(fd, &uid, &gid)` or `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...)` (never Linux `SO_PEERCRED`).
3. **Protocol Framing & Status Semantics**:
   - Connection status and display topology validation (`method: "status"`) reports active connection state, TCC screen recording permission status (`granted`), display topology (`top-sha256-...`), and mutation lockout state. Protocol version `1.0` contract is declared in `status` payload.
   - 4-byte big-endian `uint32` payload length header preceding JSON-encoded UTF-8 message payloads (max payload size 16MB).
   - Incremental buffer decoding handles fragmented streams and partial writes cleanly.
4. **Residual Threat Boundary & Future Auth Binding**:
   - Peer UID check is an admission filter, not authorization against malicious same-UID processes.
   - Future releases will incorporate signed client token bindings (`AUTH_SECRET` handshake) to prevent untrusted same-UID processes from sending IPC commands.
