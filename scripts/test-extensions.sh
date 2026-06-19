#!/usr/bin/env bash
# Run every extension's Lua tests (*.test.lua) against the shared host stub.
# No app build needed — just a stock `lua` (override with LUA=luajit).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$ROOT/app/Sources/ProsperApp/Resources/extensions"
HARNESS_DIR="$ROOT/scripts/ext-test"
LUA="${LUA:-lua}"

command -v "$LUA" >/dev/null || { echo "error: '$LUA' not found (brew install lua)"; exit 127; }

export LUA_PATH="$HARNESS_DIR/?.lua;${LUA_PATH:-;}"

fail=0 count=0
while IFS= read -r t; do
  count=$((count + 1))
  printf '▶ %s\n' "${t#"$ROOT"/}"
  "$LUA" "$t" || fail=1
done < <(find "$EXT_DIR" "$HARNESS_DIR" -name '*.test.lua' | sort)

if [ "$count" -eq 0 ]; then echo "no extension tests found"; exit 0; fi
[ "$fail" -eq 0 ] && echo "✅ all $count extension test file(s) passed" \
  || { echo "❌ extension tests failed"; exit 1; }
