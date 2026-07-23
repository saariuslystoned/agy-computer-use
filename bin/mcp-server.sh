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

if [ -z "$MISE_BIN" ]; then
  echo "[mcp-server-launcher] ERROR: 'mise' CLI not found on PATH or standard install paths (~/.local/bin, /opt/homebrew/bin, /usr/local/bin). Please install mise (https://mise.jdx.dev) and run 'mise install'." >&2
  exit 1
fi

cd "$REPO_ROOT"
exec "$MISE_BIN" exec -- node "$SCRIPT_DIR/mcp-server.mjs" "$@"
