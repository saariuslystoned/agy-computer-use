# ADR 0003: Local IPC over Versioned Length-Prefixed Unix Domain Socket

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Communication between the TypeScript MCP server and the native Swift host requires low latency, local privilege isolation, and framed message boundaries for binary payload (screenshot) transport.

## Decision
1. **Transport & Darwin Paths**:
   - Unix domain socket located at canonical Darwin per-user directory `/private/tmp/agy-computer-use-$UID/host.sock`.
   - Socket directory created with `0700` owner-only permissions.
   - Host lifecycle guarded by owner-only file lock `host.lock` using `flock(LOCK_EX | LOCK_NB)`.
   - Pre-unlink `lstat` checks, nonblocking `connect`/`poll`/`SO_ERROR` stale socket probes, and post-bind inode revalidation ensure safe lifecycle management.
2. **Darwin Race & Topology ABA Boundaries**:
   - **Kernel Constraint**: macOS lacks inode-conditional `unlinkat` or `bindat`. Stat checks and cooperative `flock` reduce but cannot eliminate a hostile same-UID final-check race window.
   - **Topology Observation Stability**: Topology resolution uses a 3-pass list enumeration and 2-set descriptor fingerprint check (`bitPattern` comparison). This proves bounded observational stability across fetches rather than an atomic kernel snapshot, bounding residual ABA risk.
3. **macOS Peer Credentials**:
   - Peer UID is verified on macOS via `getpeereid(fd, &uid, &gid)` (never Linux `SO_PEERCRED`).
4. **Protocol Framing & Status Semantics**:
   - Connection status and display topology validation (`method: "status"`) reports active connection state, TCC screen recording permission status (`granted`), display topology (`top-sha256-...`), and mutation lockout state.
   - 4-byte big-endian `uint32` payload length header preceding JSON-encoded UTF-8 message payloads (max payload size 16MB).
   - Incremental buffer decoding handles fragmented streams and partial writes cleanly.
5. **Residual Threat Boundary & Future Auth Binding**:
   - Peer UID check is an admission filter, not authorization against malicious same-UID processes.
   - Future releases will incorporate signed client token bindings (`AUTH_SECRET` handshake) to prevent untrusted same-UID processes from sending IPC commands.
