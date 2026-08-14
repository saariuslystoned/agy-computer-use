# ADR 0001: Product Scope and Non-Goals

- **Status**: Accepted
- **Date**: 2026-07-21

## Context
`agy-computer-use` enables Google Antigravity models (currently Gemini 3.7 Flash) to perceive and interact with macOS desktop interfaces.

## Decision
1. **Scope**:
   - Provide visual observation (ScreenCaptureKit / screenshot), accessibility graph extraction (`AXUIElement`), coordinate mapping (`0...999` grid), and low-level mouse/keyboard input synthesis (`CGEvent`).
   - Deliver an MCP server bridge communicating with a staged background macOS host app (currently `ad_hoc_ephemeral`) over local Unix domain socket IPC.

2. **Non-Goals**:
   - Web browser DOM scraping (handled via DevTools MCP tools).
   - Remote desktop streaming or cloud-based OS virtualization.
   - Bypassing macOS security permissions (TCC, Gatekeeper, SIP).
   - Automated financial transactions or autonomous high-risk system actions without explicit human approval.
