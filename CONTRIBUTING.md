# Contributing to Antigravity Computer Use

Thank you for contributing! Please review these guidelines before submitting pull requests or issues.

## Development Setup

### Toolchain Requirements
- **macOS**: macOS 14.0+ (Sonoma)
- **Swift**: Swift 5.9+ / Xcode Command Line Tools
- **Node.js**: `v22.23.1`
- **pnpm**: `10.33.0`
- **Mise**: Used for runtime management (`.mise.toml`)

### Building and Testing

1. **Swift Host Package (`apps/computer-use-host`)**:
   ```bash
   cd apps/computer-use-host
   swift build
   swift test
   ```

2. **TypeScript MCP Server Package (`mcp/computer-use-mcp`)**:
   ```bash
   cd mcp/computer-use-mcp
   pnpm install
   pnpm check
   pnpm test
   ```

3. **Repo Hygiene Rules**:
   - Never commit build output (`.build`, `node_modules`, `dist`).
   - Standard output (`stdout`) of the MCP server is reserved exclusively for MCP JSON-RPC protocol messages. All logging must go to `stderr`.
   - Never commit credentials, `.env` files, or private keys.
