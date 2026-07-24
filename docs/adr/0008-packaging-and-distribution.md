# ADR 0008: Packaging and Release Distribution Model

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
Distribution of native Swift binaries alongside Node-based MCP server packages requires clear packaging boundaries and reproducible build pipelines.

## Decision
1. **Swift Host Packaging**:
   - Packaged as a standard macOS Swift Package (`apps/computer-use-host`) buildable via `swift build`.
   - Production releases wrap the executable into a staged `.app` bundle (currently ad-hoc signed `ad_hoc_ephemeral`) with `Info.plist` key declarations (`NSScreenCaptureUsageDescription`). Future production releases will use team-signed certificates.
2. **TypeScript MCP Packaging**:
   - Packaged in `mcp/computer-use-mcp` with `package.json` declaring `packageManager: "pnpm@10.33.0"`.
3. **Monorepo Structure**:
   - Single repository with clean subdirectories for Swift host, TypeScript MCP server, Antigravity skills, and documentation.
