# Architecture & Design Specification

## System Architecture

`agy-computer-use` bridges Google Antigravity / Gemini 3.6 Flash with macOS UI automation capabilities via a dual-process architecture:

1. **Signed Native Host (`apps/computer-use-host`)**:
   - Built with Swift targeting macOS 14.0+.
   - Single TCC permission principal for Accessibility (`AXUIElement`) and Screen Recording (`ScreenCaptureKit`).
   - Serves as the single source of truth for display topology, coordinate transformations (converting between physical pixels, logical points, and normalized `0...999` agent grid), and negative screen origins.
   - Listens on a Unix domain socket in an owner-only runtime directory (`chmod 0700`).

2. **TypeScript MCP Server (`mcp/computer-use-mcp`)**:
   - Spawned by Google Antigravity over stdio using JSON-RPC 2.0.
   - Pinned to Node `v22.23.1`, pnpm `10.33.0`, and `@modelcontextprotocol/sdk` (`1.29.0`).
   - Communicates with the native host using a length-prefixed protocol over the Unix domain socket.
   - Enforces strict Zod schema validation for all tool calls.
   - Keeps `stdout` strictly clean for MCP transport, routing all logging to `stderr`.

3. **Antigravity Skill (`.agents/skills/computer-use`)**:
   - Teaches Antigravity models the Observe-Action-Observe control loop.
   - Prioritizes AX tree inspection before visual fallback.
   - Enforces prompt-injection skepticism and human safety gates.

## Security & IPC Boundaries

- **Local IPC Security**: Unix domain socket path `/private/tmp/agy-computer-use-$UID/host.sock` (resolving macOS `/tmp` symlink) with directory permissions set to `0700` and owner-only `host.lock` lifecycle lock.
- **Peer Verification**: Host verifies connecting process UID. (Residual risk: unprivileged processes owned by the same UID on macOS can access the socket).
- **Data Redaction**: Sensitive fields (`AXIsPassword`, `AXIsSecureText`) are redacted at the host level before serialization (`[REDACTED]`).
