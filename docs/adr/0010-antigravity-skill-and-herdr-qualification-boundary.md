# ADR 0010: Antigravity Skill and Herdr-Puppet Qualification Boundary

- **Status**: Accepted design; implementation and live qualification pending
- **Date**: 2026-08-19

## Context

`agy-computer-use` is a computer-use product for Google Antigravity agents on
macOS. Its useful boundary is the Antigravity skill, MCP surface, and local
native host that perceive and act on the Mac where the agent is running.

The same skill must also work when Antigravity is launched on a remote worker
through Herdr-Puppet. Herdr-Puppet already owns machine, workspace, fresh-tab,
model, transport, journal, detach/reattach, preservation, and cleanup
authority. Moving those concerns into `agy-computer-use` would couple the
reusable computer-use product to one fleet controller and make local use
depend on remote-session concepts.

Conversely, source and fixture tests do not prove that a Gemini agent launched
through Herdr can discover the skill, start or reach the native host, inspect
an application, perform a semantic action, verify the effect, and survive a
native Herdr client detach/reattach. That integration requires its own live,
dual-worker qualification.

## Decision

### 1. `agy-computer-use` owns the product

The standalone product boundary contains:

- the Antigravity computer-use skill and its mirrored package;
- the MCP tools and their model-facing schemas;
- the worker-local native host, TCC readiness, observation, AX inspection,
  semantic action, input, and reinspection contracts;
- target discovery and validation within the local Mac session; and
- browser-task routing to a purpose-built DOM/browser MCP backend when AX or
  visual desktop input is not the correct semantic surface.

The skill should feel task-first to the Antigravity agent. It may discover an
application from the task and use the validated active app, window, or browser
page when that target matches. It must pause on genuine ambiguity, mismatch,
or target drift. Mutation authority remains an exact, fresh, one-shot target;
the implementation never silently retargets another window, tab, element, or
input backend.

Browser DOM work remains outside the native host, consistent with ADR 0001.
The skill may route browser work through a separately qualified adapter
(currently expected to be the worker's Peekaboo browser/DevTools surface), but
the public AGY contract must not expose vendor CLI syntax or silently fall back
to clipboard or global HID input.

### 2. Herdr-Puppet owns remote qualification, not product behavior

Herdr-Puppet remains external to `agy-computer-use`. It owns:

- named worker, workspace, fresh-tab, and exact model selection;
- remote harness census, launch, readiness checkpoints, and journals;
- native Herdr client detach/reattach qualification; and
- exact row preservation, resume, and explicitly authorized cleanup.

No AGY tool or skill request accepts an SSH target, Herdr session/workspace/tab
identity, remote worktree, harness model selector, or Herdr lease. Those values
are qualification infrastructure and must not become the local computer-use
API.

A Herdr acknowledgement proves transport only. Qualification succeeds only
when the launched Gemini row actually uses the skill and produces bounded,
sanitized receipts for the computer-use behavior described below.

### 3. The next qualification has two required behavior rungs

The milestone is not complete until both registered AI workers independently
pass both rungs from fresh, controller-owned Gemini 3.7 rows:

1. **Native canary**: status and TCC readiness, explicit-app observation and AX
   inspection, one qualified semantic press and one qualified non-secure
   `set_value`, followed by fresh semantic reinspection that verifies the
   intended state without relying on dispatch success alone.
2. **Browser-form fixture**: a local, non-account browser fixture is filled
   through the qualified DOM/browser backend and read back semantically. The
   fixture must cover ordinary input plus at least one event-sensitive or
   controlled field so a raw value assignment cannot masquerade as form-entry
   proof.

Each worker run also brackets a real task-owned Herdr client detach/reattach
and proves the same session, workspace, tab, pane, terminal, SSH, harness,
source, and computer-use target identities afterward. The exact qualification
row is preserved on success, failure, or uncertainty and returns bounded
resume/close handles. Cleanup remains explicit.

## Out of scope for this decision slice

- Implementing or claiming the native/browser qualification.
- Putting machine, workspace, tab, model, SSH, or Herdr lease selection into
  `agy-computer-use`.
- Signed-in production-site automation or external form submission.
- Automatic cleanup of Herdr rows.
- Live HUD, durable signing/notarization, complete multi-display automation,
  or broad noninterfering-action parity.
- Admission or source-head attestation services.

## Consequences

- Local Antigravity use remains possible without Herdr-Puppet.
- Remote use earns confidence through the same public skill and MCP contracts,
  with Herdr providing transport and lifecycle evidence rather than a second
  computer-use API.
- Native and browser backends can evolve independently behind one skill-level
  policy while retaining exact target and post-action verification rules.
- A green native unit suite, a Herdr launch receipt, or a TextEdit-only demo is
  insufficient to close the milestone.
- The GrillTrack ledger under `.grilltrack/` preserves the earlier
  remote-front-door proposal and its explicit supersession by this boundary.
