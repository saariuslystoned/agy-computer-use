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

## Antigravity Teamwork Runs

- Codex steering enters this repository through literal `/teamwork-preview`; an ordinary follow-up, `/btw`, or `/side` is not an equivalent teamwork run.
- The Antigravity parent owns decomposition, integration, verification, commits, pushes, and terminal reporting. Use at most three concurrent helpers by default, assign disjoint scopes, and close completed helpers before spawning replacements.
- Helper reports, local green tests, commits, pushes, and CI starts are checkpoints, not completion. Keep the parent active with the available task, scheduling, and messaging primitives until the prompt's terminal criteria are satisfied or an irreducible blocker is proved.
- Emit sanitized phase beacons: `CODEX_TEAMWORK_STATUS` for meaningful phase changes, `CODEX_TEAMWORK_ACTION_REQUIRED` only for an irreducible blocker or human gate, and exactly one `CODEX_TEAMWORK_DONE` only at terminal completion. Codex bridges, automations, receipts, and committed proof never read/copy/preserve raw Antigravity transcripts; the parent obtains sanitized helper verdicts through native task/teamwork reporting and never shells out to `tail` transcript files.
- Before `CODEX_TEAMWORK_DONE`, require a clean worktree, verified local/remote/PR identity, completed exact-head CI, and proof claims backed by executed assertions rather than printed case names.
- For a source/proof milestone, push source `S`; wait for exact-`S` push and PR CI; create proof-only child `P` naming full `S` and both CI runs; assert `P^ == S` and that only the designated proof file changed. Bind final acceptance externally to the exact resulting head rather than creating an infinite proof-commit chain.
- **TW-RUN (Fresh, Steering-Bound Beacons)**: Every substantive `/teamwork-preview` turn must emit a `STARTED` beacon after reading its packet and before editing or helper spawn; a late beacon is noncompliant. Every later beacon must include stable run/packet identifier, packet basename or short content hash, immutable base SHA, current phase, helper counts, and next action. A beacon from an older run or head is stale and must never be repeated as current state. Keep beacons sanitized: no prompt body, transcript, command line, raw log, secret, or credential.
- **TW-PUBLISH (Clause Ledger & AGY Skeptic Gate)**: Before editing, the parent must map each acceptance-clause ID to an owner, production artifact, discriminating assertion, and `pending|closed|blocked` state using Antigravity task primitives. Before any push, freeze a clean local candidate SHA `S` and clause-ledger digest `L`, receive and visibly emit `SKEPTIC_PASS(S,L)` from a read-only skeptic helper auditing the integrated diff against that ledger; any repo or ledger mutation invalidates `SKEPTIC_PASS(S,L)`. Missing or narrowed clauses remain open; the parent fixes them or emits ACTION_REQUIRED. A file, case name, helper report, or green command does not close a clause by itself.
- **TW-AUTHORITY (No Weakened or Vacuous Authority)**: Deleting, bypassing, or weakening pre-existing assertions is categorically prohibited. New guards require positive, negative, and error-path discrimination; when practical, prove the assertion fails on the pre-fix implementation or an injected mutant. Reject hard-coded counts, self-comparisons, unreferenced fixtures, printed names, and tests that do not execute the claimed production boundary as sole authority.
- **TW-HISTORY (Immutable Published History & Checkpoint Cadence)**: Run local gates before the first push, group work into 2–3 cohesive commits per source checkpoint, and treat every published head as immutable. Tagged `TW-*` invariants cannot be removed or narrowed without an external contract-change receipt. Use ordinary additive pushes only; never amend, rebase, force, or force-with-lease published history. A later CI repair is a new additive commit and invalidates prior exact-head review.

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
