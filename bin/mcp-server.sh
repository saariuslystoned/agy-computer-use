#!/bin/sh
set -eu

export PATH="${PATH:-}:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MISE_BIN=""

if [ "${TEST_FORCE_MISSING_MISE:-0}" = "1" ]; then
  MISE_BIN=""
elif command -v mise >/dev/null 2>&1; then
  MISE_BIN="$(command -v mise)"
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/mise" ]; then
  MISE_BIN="$HOME/.local/bin/mise"
elif [ -x "/opt/homebrew/bin/mise" ]; then
  MISE_BIN="/opt/homebrew/bin/mise"
elif [ -x "/usr/local/bin/mise" ]; then
  MISE_BIN="/usr/local/bin/mise"
elif [ -x "/home/linuxbrew/.linuxbrew/bin/mise" ]; then
  MISE_BIN="/home/linuxbrew/.linuxbrew/bin/mise"
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.cargo/bin/mise" ]; then
  MISE_BIN="$HOME/.cargo/bin/mise"
fi

if [ -n "$MISE_BIN" ]; then
  cd "$REPO_ROOT"
  exec "$MISE_BIN" exec -- node "$SCRIPT_DIR/mcp-server.mjs" "$@"
fi

NODE_VER=""
PNPM_VER=""

if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node -v 2>/dev/null || echo "")"
fi

if command -v pnpm >/dev/null 2>&1; then
  PNPM_VER="$(pnpm -v 2>/dev/null || echo "")"
fi

NODE_NUM="$(echo "$NODE_VER" | sed 's/^v//')"

if [ "$NODE_NUM" = "22.23.1" ] && [ "$PNPM_VER" = "10.33.0" ]; then
  cd "$REPO_ROOT"
  exec node "$SCRIPT_DIR/mcp-server.mjs" "$@"
fi

echo "[mcp-server-launcher] ERROR: Unpinned or missing toolchain. Ambient Node.js (${NODE_VER:-missing}) or pnpm (${PNPM_VER:-missing}) does not match pinned versions (Node v22.23.1, pnpm 10.33.0). Please install mise (https://mise.jdx.dev) and run 'mise install'." >&2
exit 1
