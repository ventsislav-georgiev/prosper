#!/usr/bin/env bash
# Verify the JSON-RPC method names pinned in CodexHarness.swift's `Wire` enum
# still exist in the Codex app-server schema. Run on a Codex version bump
# (alongside scripts/bundle-codex.sh's CODEX_VERSION).
#
# CodexHarness pins method strings (thread/start, item/agentMessage/delta, …) to a
# specific Codex version. Unknown notifications degrade to "missing events" rather
# than crash, but a renamed REQUEST method silently breaks turns — this script
# catches that before shipping.
#
# Usage: verify-codex-wire.sh   (uses $PROSPER_CODEX_BIN or codex on PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX="${PROSPER_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
HARNESS="$ROOT/app/Sources/ProsperApp/Harness/CodexHarness.swift"

[[ -n "$CODEX" && -x "$CODEX" ]] || { echo "error: no codex binary (set PROSPER_CODEX_BIN or install codex)" >&2; exit 1; }
[[ -f "$HARNESS" ]] || { echo "error: $HARNESS not found" >&2; exit 1; }

# `generate-json-schema` writes a DIRECTORY of per-type schema files (one .json per
# protocol type, plus combined codex_app_server_protocol*.schemas.json), NOT stdout.
schemadir="$(mktemp -d)"
trap 'rm -rf "$schemadir"' EXIT
if ! "$CODEX" app-server generate-json-schema --out "$schemadir" >/dev/null 2>&1; then
  echo "warn: '$CODEX app-server generate-json-schema --out <dir>' failed — the schema command may have moved." >&2
  echo "      Check 'codex app-server --help' and update this script + CodexHarness.Wire." >&2
  exit 2
fi
# Search the combined v1 schema (carries the full ServerNotification/ClientRequest
# method registry); fall back to every emitted .json if its name ever changes.
schema="$schemadir/codex_app_server_protocol.schemas.json"
[[ -f "$schema" ]] || schema="$schemadir"

# Pinned methods are the slash-namespaced string literals in the Wire enum
# (thread/*, turn/*, item/*). This excludes decision/provider literals like
# "approved" / "chat" that are not protocol method names.
methods="$(grep -oE '"[a-z]+/[a-zA-Z/]+"' "$HARNESS" | tr -d '"' | sort -u)"

missing=0
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if ! grep -rq "$m" "$schema"; then
    echo "MISSING from schema: $m"
    missing=$((missing + 1))
  fi
done <<< "$methods"

# The handshake methods are not slash-namespaced; check them explicitly.
for m in initialize initialized; do
  grep -rq "\"$m\"" "$schema" || echo "note: handshake method '$m' not found in schema (often implicit)."
done

if [[ "$missing" -eq 0 ]]; then
  echo "OK: all pinned Wire method names present in the codex schema."
else
  echo "$missing pinned method(s) not found — review CodexHarness.Wire against the new schema." >&2
  exit 1
fi
