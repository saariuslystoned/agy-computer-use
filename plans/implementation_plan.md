# Implementation Plan: Antigravity Computer Use

## Roadmap & Milestones

### Milestone 1: Folder & Spec Scaffolding (Current)
- [x] Create `AGENTS.md` and `README.md` front-door contracts.
- [x] Establish `docs/`, `plans/`, and `proof/` hierarchy.

### Milestone 2: Native Swift Computer Use Host (`apps/computer-use-host`)
- [ ] Initialize Swift package / Xcode project for macOS app host.
- [ ] Implement AXUIElement tree serialization to JSON.
- [ ] Implement ScreenCaptureKit desktop image capture.
- [ ] Implement CGEvent input synthesis (click, type, drag, scroll, shortcut).
- [ ] Implement visual action overlay indicator.

### Milestone 3: MCP Server Bridge (`mcp/computer-use-mcp`)
- [ ] Implement Node.js / TypeScript MCP server.
- [ ] Connect MCP tool definitions to Swift Host IPC.
- [ ] Add coordinate scaling and display normalization.

### Milestone 4: Antigravity Skill (`skills/computer-use`)
- [ ] Package SKILL.md and documentation for Antigravity integration.
- [ ] Test end-to-end execution with Gemini 3.6 Flash.

### Milestone 5: Verification & Benchmarks
- [ ] Create automated integration tests.
- [ ] Generate proof logs in `proof/`.
