#!/usr/bin/env bash
# Install the `prosper` CLI: a symlink to the app binary, which handles the
# `agent` subcommand (see app/Sources/ProsperApp/AgentCLI.swift):
#   prosper agent [--cwd <dir>] "fix the failing tests"
# Usage: scripts/install-cli.sh [/path/to/Prosper.app] [link-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-$ROOT/dist/Prosper.app}"
BIN="$APP/Contents/MacOS/ProsperApp"
[[ -x "$BIN" ]] || { echo "error: $BIN not found (build + bundle first)" >&2; exit 1; }

LINK_DIR="${2:-}"
if [[ -z "$LINK_DIR" ]]; then
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then LINK_DIR=/usr/local/bin
  else LINK_DIR="$HOME/bin"; mkdir -p "$LINK_DIR"; fi
fi

ln -sf "$BIN" "$LINK_DIR/prosper"
echo "installed: $LINK_DIR/prosper -> $BIN"
case ":$PATH:" in
  *":$LINK_DIR:"*) ;;
  *) echo "note: $LINK_DIR is not on PATH" ;;
esac
