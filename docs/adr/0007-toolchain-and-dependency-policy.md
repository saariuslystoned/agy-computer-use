# ADR 0007: Toolchain, Dependency Pinning & Stdio Cleanliness

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
MCP servers communicate with language models via JSON-RPC messages sent over standard input/output (`stdio`). Unwanted console output (`console.log`, third-party library logging) corrupts the JSON stream and breaks agent communication.

## Decision
1. **Toolchain Pins**:
   - Node.js pinned to `22.23.1`.
   - pnpm pinned to `10.33.0`.
   - Use official production `@modelcontextprotocol/sdk` (`1.29.0`).
2. **Strict Stdio Hygiene**:
   - Standard output (`stdout`) is strictly reserved for MCP JSON-RPC protocol frames.
   - All server logging, diagnostic messages, and debug output must route strictly to `stderr`.
