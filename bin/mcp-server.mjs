#!/usr/bin/env node
import { spawn, execSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const MCP_DIR = path.join(REPO_ROOT, 'mcp/computer-use-mcp');
const DIST_INDEX = path.join(MCP_DIR, 'dist/src/index.js');

// Redirect build stdout to stderr so stdio stdout remains strictly JSON-RPC protocol
try {
  execSync('pnpm build', {
    cwd: MCP_DIR,
    stdio: ['ignore', 'ignore', 'inherit']
  });
} catch (err) {
  process.stderr.write(`[mcp-server-launcher] Build failed: ${err.message}\n`);
  process.exit(1);
}

if (!fs.existsSync(DIST_INDEX)) {
  process.stderr.write(`[mcp-server-launcher] Compiled server dist file not found at ${DIST_INDEX}\n`);
  process.exit(1);
}

const child = spawn(process.execPath, [DIST_INDEX, ...process.argv.slice(2)], {
  cwd: REPO_ROOT,
  stdio: 'inherit'
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
