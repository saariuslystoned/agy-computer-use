# AGENTS.md

## Overview & Mission
This repository defines the production architecture, protocol specifications, Swift host foundation, and MCP server bridge for Computer Use with Google Antigravity and Gemini 3.6 Flash on macOS. It combines low-latency screen perception, bounded accessibility element tree querying (`AXUIElement`), coordinate normalization, input synthesis contracts, and local Unix-domain-socket IPC.

## Depth & Quality Standards
- **Production Architecture & Bounded Contracts**: Screen capture, AX DOM extraction, coordinate normalization, and input synthesis are bound by strict schemas, error handling, depth limits, and security redaction rules.
- **Native OS Integration & Security Principal**: A signed menu-bar macOS app (`ComputerUseHost.app`) serves as the single TCC principal for Screen Recording and Accessibility permissions. The MCP server connects to the host over a local Unix domain socket in an owner-only runtime directory (`chmod 0700`).
- **Antigravity Tooling**: Exposes clean MCP server tools (`computer_use_status`, `computer_use_observe`) alongside skill definitions compatible with Google Antigravity / Gemini 3.6 Flash in Milestone D2.

## Execution Rules & Safety Policy
- **Proof Policy**: Every feature milestone requires verifiable empirical proof (unit/integration test run outputs, deterministic test host validation, schema validation, and tracked verification reports in `proof/`).
- **Human Gate Boundary (`WAITING_FOR_HUMAN`)**: Any operation involving automated financial transactions, sending external emails/RCS/SMS to non-test contacts, deleting system files outside project scope, or installing system-wide launch daemons without approval requires user confirmation (`CODEX_TEAMWORK_ACTION_REQUIRED`).
- **Sanitisation**: Secrets (`.env`, auth tokens, keychain values) must never be logged, committed, or included in screenshot payloads. Standard output (`stdout`) of the MCP server is reserved exclusively for MCP JSON-RPC protocol transport; all logging goes to `stderr`.

## System Components & Directory Layout
```text
.
├── AGENTS.md               # Agent operational guidelines & safety contracts
├── README.md               # Architecture documentation, usage, and setup guide
├── LICENSE                 # Apache 2.0 License
├── SECURITY.md             # Security policy and IPC boundary definitions
├── CONTRIBUTING.md         # Developer setup and contribution guide
├── .mise.toml              # Toolchain pins (Node 22.23.1, pnpm 10.33.0)
├── apps/                   # Native macOS Swift Package (`computer-use-host`)
├── mcp/                    # TypeScript MCP server (`computer-use-mcp`)
├── .agents/skills/         # Antigravity Skill package definition (`computer-use`)
├── docs/                   # ADRs, protocol schemas, and golden JSON test fixtures
├── plans/                  # Milestones, task breakdowns, status ledger
└── proof/                  # Execution verification logs and proof packets
```

## Agent Build & Verification Workflow
1. Run authoritative native Swift test authority (`./bin/agy-computer-use test-native`).
2. Run TypeScript MCP server checks and unit/integration tests (`pnpm check` and `pnpm test` in `mcp/computer-use-mcp`).
3. Run offline readiness validation (`./bin/agy-computer-use canary-ready`).
4. Document test output and verification summary in `proof/d2_verification.md`.
