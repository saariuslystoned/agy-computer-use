# Architecture & Design Specification

## System Architecture

`agy-computer-use` bridges Google Antigravity / Gemini 3.7 Flash with macOS UI automation capabilities via a dual-process architecture:

1. **Staged Background Host (`apps/computer-use-host`)**:
   - Built with Swift targeting macOS 14.0+.
   - Single TCC permission principal (currently staged as an `ad_hoc_ephemeral` bundle) for Accessibility (`AXUIElement`) and Screen Recording (`ScreenCaptureKit`). A future non-ad-hoc team-signed candidate may become the durable TCC principal only after separately gated signing, installation, launch, and TCC proof.
   - Serves as the single source of truth for display topology, coordinate transformations (converting between physical pixels, logical points, and normalized `0...999` agent grid), and negative screen origins.
   - Retains short-lived, one-shot AX snapshot/app/element references for exact
     semantic `press` and bounded `set_value`. It advertises `set_value` only
     for enabled, non-secure text fields/areas whose `AXValue` is settable, then
     revalidates topology, process birth, exact window/ancestry identity,
     semantic fingerprints, role/subrole, enabled/settable state, advertised
     action, and macOS session input counters immediately before dispatch.
   - Keeps submitted `set_value` text call-scoped and bounded to 4096 UTF-8
     bytes. It never copies that value into retained leases, fingerprints,
     receipts, logs, or errors.
   - Keeps the operator-safe AX engine separate from the global-HID engine.
     The AX route never calls or falls back to global event posting.
   - Listens on a Unix domain socket in an owner-only runtime directory (`chmod 0700`).

2. **TypeScript MCP Server (`mcp/computer-use-mcp`)**:
   - Spawned by Google Antigravity over stdio using JSON-RPC 2.0.
   - Pinned to Node `v22.23.1`, pnpm `10.33.0`, and `@modelcontextprotocol/sdk` (`1.29.0`).
   - Communicates with the native host using a length-prefixed protocol over the Unix domain socket.
   - Enforces strict Zod schema validation for all tool calls.
   - Keeps `stdout` strictly clean for MCP transport, routing all logging to `stderr`.

3. **Antigravity Skill (`.agents/skills/computer-use`)**:
   - Teaches Antigravity models the explicit-app AX inspect/action/reinspect loop
     and the separate display Observe-Action-Observe loop.
   - Prioritizes exact semantic AX `press` and bounded non-secure text
     `set_value` on shared workstations.
   - Restricts global coordinate/keyboard synthesis to explicitly exclusive GUI
     sessions, VMs, or dedicated worker Macs.
   - Enforces prompt-injection skepticism and human safety gates.

## Security & IPC Boundaries

- **Local IPC Security**: Unix domain socket path `/private/tmp/agy-computer-use-$UID/host.sock` (resolving macOS `/tmp` symlink) with directory permissions set to `0700` and owner-only `host.lock` lifecycle lock.
- **Peer Verification**: Host verifies connecting process UID. (Residual risk: unprivileged processes owned by the same UID on macOS can access the socket).
- **Data Redaction**: Sensitive fields (`AXIsPassword`, `AXIsSecureText`) are redacted at the host level before serialization (`[REDACTED]`).
- **Action Authority**: Traversal IDs, identifiers, descriptions, labels, titles, bounds, and indexes never
  authorize mutation. Only matching opaque refs from the current unexpired
  snapshot may dispatch one advertised action.
- **Honest Outcome**: A successful `AXUIElementPerformAction` or
  `AXUIElementSetAttributeValue` receipt is `dispatched`, not verified. Gemini
  must reinspect the same explicit app before accepting the intended effect.
- **Compatible Wire Contract**: Native status, per-node action advertisement,
  MCP schemas, and protocol fixtures accept unavailable, press-only, or
  canonical press-plus-set-value capability states. Set-value-only, reordered,
  duplicate, and unknown global action metadata fails validation.
- **Preview Boundary**: The future live operator HUD is tracked in
  [issue #8](https://github.com/saariuslystoned/agy-computer-use/issues/8) and
  remains separate from model observation, action authority, and Puppet's
  read-only AGY TUI viewer.
