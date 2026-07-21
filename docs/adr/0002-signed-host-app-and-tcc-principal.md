# ADR 0002: Signed Native Host App as Sole TCC Principal

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
macOS protects Screen Recording (`ScreenCaptureKit`) and System Accessibility (`AXUIElement`) with Transparency, Consent, and Control (TCC) prompt requirements bound to app bundle identifiers and code signatures. Node.js MCP processes spawned dynamically by CLI tools cannot reliably maintain persistent TCC entitlements across process restarts or runtime version updates.

## Decision
1. **Single TCC Principal**:
   - A dedicated native macOS menu-bar app (`ComputerUseHost.app`) serves as the sole TCC principal holding Screen Recording and Accessibility permissions.
2. **MCP Server Separation**:
   - The TypeScript MCP server (`computer-use-mcp`) runs as a lightweight client without TCC entitlements, delegating all OS perception and input requests to `ComputerUseHost` via IPC.
