# Host Lifecycle A123 Acceptance Clause Ledger

| Clause ID | Owner | Production Artifact | Discriminating Assertion | State |
| --- | --- | --- | --- | --- |
| HL1-PUBLIC | Parent / Helper 2 | `bin/agy-computer-use`, `bin/host-lifecycle.mjs` | `bin/agy-computer-use` exposes `host-start`, `host-status`, `host-stop`; rejects extra tokens & inherited props before side-effects; returns factual JSON; non-zero exit on failure. | closed |
| HL1-OWNER | Helper 1 / Parent | `bin/host-lifecycle-core.mjs`, `bin/host-lifecycle.mjs` | Supervisor state machine owns child handle; fixed per-UID 0700 runtime dir; control socket IPC; no PID file trusting. Concurrent start converges to 1 supervisor/child. | closed |
| HL1-READY | Helper 1 / Parent | `bin/host-lifecycle-core.mjs` | `host-start` builds/stages if needed; connects over native UNIX socket to test production `status` schema; tears down child on spawn error, early exit, bad schema, or timeout. | closed |
| HL1-STATUS | Helper 2 / Parent | `bin/host-lifecycle.mjs` | `host-status` is strictly read-only, non-mutating; returns factual status `running`, `stopped`, `stale/unhealthy` without modifying socket files or launching processes. | closed |
| HL1-STOP | Helper 1 / Parent | `bin/host-lifecycle-core.mjs` | `host-stop` is idempotent; sends SIGTERM -> wait -> SIGKILL escalation on exact child handle; awaits `close` event; removes control/host sockets safely. | closed |
| HL1-ARTIFACT | Helper 3 / Parent | `bin/host-lifecycle-core.mjs` | Socket cleanup revalidates `isSocket()` and inode identity immediately before `unlinkSync`; regular files/symlinks/changed inodes fail closed & preserved. | closed |
| HL1-AUTHORITY | Helper 3 / Parent | `bin/host-lifecycle.test.mjs` | 14 discriminating tests including mutants for PID-file signaling, socket-only readiness, sentinels, SIGKILL escalation, and residue checks. | closed |
| HL1-NATIVE-CLOSEOUT | Parent / Swift | `apps/computer-use-host/Sources/ComputerUseHostLib/Lifecycle/HostLifecycle.swift` | In `HostLifecycle.swift`, `start()` failure when listener throws properly cancels signal sources, closes listener, and sets state to `.stopped`. | closed |
| HL1-DOCS | Helper 2 / Parent | `README.md`, `.agents/skills/computer-use/SKILL.md`, `skills/computer-use/SKILL.md` | Operator docs updated with `host-start`, `host-status`, `host-stop` commands; highlights observation-only state & TCC permissions. | closed |
