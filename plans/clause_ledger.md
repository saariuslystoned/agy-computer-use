# Host Lifecycle HL1B Acceptance Clause Ledger

| Clause ID | Owner | Production Artifact | Discriminating Assertion | State |
| --- | --- | --- | --- | --- |
| HL1B-P1 | Gemini / Parent | `bin/agy-computer-use`, `bin/host-lifecycle.mjs`, `bin/host-lifecycle-core.mjs` | Public front-door resolves `/tmp/agy-computer-use-$UID`; ignores `COMPUTER_USE_RUNTIME_DIR` in production CLI; status/stop never create or chmod absent/existing root; lstat validates symlink/non-directory/foreign UID failure. | closed |
| HL1B-P2 | Gemini / Parent | `bin/host-lifecycle-core.mjs`, `bin/host-lifecycle.mjs` | Daemon alone performs stale recovery and atomically reserves/binds control socket before build, stage, or native spawn; starting state is live owner; live owner waiting without spawning contender; attach daemon close/error observation before first poll; default build/stage seam. | closed |
| HL1B-P3 | Gemini / Parent | `bin/host-lifecycle-core.mjs`, `bin/host-lifecycle.mjs` | `host-status` is one correlated owner probe (no split probes); strictly requires generation, daemon PID, native PID, owner state, schema-valid native status; stable classifications (`running`, `RUNNING_UNMANAGED`, `STALE_OR_AMBIGUOUS`, `stopped`). | closed |
| HL1B-P4 | Gemini / Parent | `bin/host-lifecycle-core.mjs`, `bin/host-lifecycle.mjs` | Public stop mutates only through correlated live owner; single cleanup promise; retains child until actual close; TERM once, grace timer, KILL once, final close wait; captured native socket identity; stop RPC receipt flushed before close & daemon exit; public stop receipt validation & daemon exit wait. | closed |
| HL1B-P5 | Gemini / Parent | `bin/host-lifecycle-core.mjs` | Request/response IDs equal without type coercion; bounded frame per connection, payload bounds, input deadline, no trailing/repeated frames, settle once; mandatory captured rootIdentity + socket identity in `safeUnlinkSocket`; lstat artifact presence; regular 0600 `host.lock`. | closed |
| HL1B-T1 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Public cases routed through `bin/agy-computer-use` entrypoint. | closed |
| HL1B-T2 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Cold-start 2 concurrent commands: identical generation/daemon/native, single winner (`idempotent: false`/`true`), stable control inode, single native process. | closed |
| HL1B-T3 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Correlated public status returns identical 3 identities & native status. | closed |
| HL1B-T4 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Public stop receipt validation, PIDs terminal immediately without post-return polling, regular 0600 `host.lock`. | closed |
| HL1B-T5 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Retained daemon `ChildProcess` TERM ordering: native child closes before sockets disappear. | closed |
| HL1B-T6 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Cooperative vs stubborn child teardown with grace timer and KILL escalation proof. | closed |
| HL1B-T7 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Real starting phase barrier contender exclusion proof. | closed |
| HL1B-T8 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Unmanaged state stability & zero signals to sentinel proof. | closed |
| HL1B-T9 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Stale/dangling/ambiguous status & stop nonzero classification & artifact preservation proof. | closed |
| HL1B-T10 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Socket replacement, mandatory rootIdentity, symlink, device/inode mismatch rejection proof. | closed |
| HL1B-T11 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Strict IPC ID equality, 16MB payload bounds, single frame handling proof. | closed |
| HL1B-T12 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Stubborn and cooperative child teardown proof. | closed |
| HL1B-T13 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Socket-existence readiness mutant rejection proof. | closed |
| HL1B-T14 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | `COMPUTER_USE_RUNTIME_DIR` environmental override isolation & sentinel preservation proof. | closed |
| HL1B-T15 | Gemini / Parent | `bin/host-lifecycle.test.mjs` | Clean-export stage-host-app verification proof. | closed |
| HL1-NATIVE-CLOSEOUT | Parent / Swift | `apps/computer-use-host/Sources/ComputerUseHostLib/Lifecycle/HostLifecycle.swift` | Native `HostLifecycle.start()` failure when listener throws properly cancels signal sources, closes listener, and sets state to `.stopped` (preserved from 9501). | closed |
| HL1B-DOCS | Gemini / Parent | `README.md`, `.agents/skills/computer-use/SKILL.md`, `skills/computer-use/SKILL.md` | Operator docs reflect terminally correlated lifecycle ownership and non-override runtime directory policy. | closed |
