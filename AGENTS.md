# AGENTS.md

## Overview & Mission
This repository implements enterprise-grade Computer Use for Google Antigravity and Gemini 3.6 Flash on macOS. It provides low-latency screen perception, high-precision accessibility element tree querying (AXUIElement), multimodal vision capture, coordinate normalization, mouse/keyboard automation, and native macOS window management via a native Swift app/sidecar and MCP server.

## Depth & Quality Standards
- **Cut No Corners**: Standard visual screenshotting alone is insufficient. Must combine low-latency screen capture with native macOS Accessibility (AXUIElement) DOM extraction, target element identification, retina scale handling, and sub-millisecond input synthesis.
- **Native OS Integration**: Native macOS app (`ComputerUseHost.app` / Swift binary) handles Screen Recording permissions, Accessibility API hooks, CGEvent injection, AX tree inspection, and displays visual action overlays/breadcrumbs.
- **Antigravity Tooling**: Exposes clean MCP server tools (`computer_use_click`, `computer_use_type`, `computer_use_screenshot`, `computer_use_ax_tree`, `computer_use_shortcut`, `computer_use_drag`, `computer_use_scroll`) alongside skill definitions compatible with Google Antigravity / Gemini 3.6 Flash.

## Execution Rules & Safety Policy
- **Proof Policy**: Every modification or feature milestone requires verifiable proof (unit/integration test run, native binary invocation verification, screenshot artifact, or logged AX tree dump).
- **Human Gate Boundary (`WAITING_FOR_HUMAN`)**: Any operation involving automated financial transactions, sending external emails/RCS/SMS to non-test contacts, deleting system files outside project scope, or installing system-wide launch daemons without approval requires user confirmation. Exemption: Pre-approved local test automation on registered local display targets.
- **Sanitisation**: Secrets (`.env`, auth tokens, keychain values) must never be logged, committed, or included in screenshot payloads.

## System Components & Directory Layout
```text
.
├── AGENTS.md               # Agent operational guidelines & safety contracts
├── README.md               # Architecture documentation, usage, and setup guide
├── apps/                   # Native macOS Swift Desktop App / Sidecar Host
│   └── computer-use-host/  # Swift app for Screen Capture, AXUIElement, CGEvent
├── mcp/                    # MCP server interface for Antigravity
│   └── computer-use-mcp/   # Node.js/TypeScript or Go MCP server
├── skills/                 # Antigravity Skill package definition
│   └── computer-use/       # SKILL.md and reference material
├── docs/                   # Technical specs, architecture decisions, API schemas
├── plans/                  # Milestones, task breakdowns, roadmap
└── proof/                  # Execution verification logs and artifacts
```

## Agent Build & Verification Workflow
1. Build native host Swift app (`swift build` or `xcodebuild`).
2. Run unit tests and headless CGEvent / AXUIElement smoke tests.
3. Validate MCP server schema compatibility with Gemini 3.6 Flash tool calls.
4. Document test output in `proof/`.
