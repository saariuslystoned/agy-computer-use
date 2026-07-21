# ADR 0003: Local IPC over Versioned Length-Prefixed Unix Domain Socket

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Communication between the TypeScript MCP server and the native Swift host requires low latency, strict local privilege isolation, and framed message boundaries for binary payload (screenshot) transport.

## Decision
1. **Transport**:
   - Unix domain socket located at `/tmp/agy-computer-use-$UID/agy-computer-use.sock`.
   - Socket directory permissions restricted to `chmod 0700` (owner read/write/execute only).
2. **Peer Security**:
   - Host checks connecting client effective UID (`LOCAL_PEERCRED` / `SO_PEERCRED`).
   - Limits socket server to 1 active client connection at a time.
3. **Framing**:
   - 4-byte big-endian `uint32` payload length header preceding JSON-encoded UTF-8 message payloads.
4. **Residual Risk**:
   - Same-UID unprivileged local processes can connect to the socket if running under the same user account.
