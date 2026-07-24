# ADR 0002: Staged Background Host App as TCC Principal

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
macOS protects Screen Recording (`ScreenCaptureKit`) and System Accessibility (`AXUIElement`) with Transparency, Consent, and Control (TCC) prompt requirements bound to app bundle identifiers and code signatures. Node.js MCP processes spawned dynamically by CLI tools cannot reliably maintain persistent TCC entitlements across process restarts or runtime version updates.

## Decision
1. **Single TCC Principal**:
   - A dedicated native macOS background app (`ComputerUseHost.app`, currently staged as an `ad_hoc_ephemeral` bundle) serves as the TCC principal holding Screen Recording and Accessibility permissions. A future non-ad-hoc team-signed candidate may become the durable TCC principal only after separately gated signing, installation, launch, and TCC proof.
2. **MCP Server Separation**:
   - The TypeScript MCP server (`computer-use-mcp`) runs as a lightweight client without TCC entitlements, delegating all OS perception and input requests to `ComputerUseHost` via IPC.
