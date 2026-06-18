#!/usr/bin/env bash
# Stage the Bun plugin host into a Prosper.app bundle:
#   - Contents/Helpers/plugin-host.js  (always — the opencode-plugin bridge)
#   - Contents/Helpers/bun             (only if a bun runtime is available at build time)
#
# Bun delivery is on-demand by design (keeps the base app slim, like the codex helper):
# BunHarness.resolveBun() looks at Contents/Helpers/bun first, then PATH, then downloads
# the pinned release into Application Support on first use. So a missing bun here is a
# warning, not a failure — the app fetches it the first time a JS plugin is installed.
#
# Binary resolution order for the optional bundled bun:
#   1. $PROSPER_BUN_BIN  — explicit path to a bun binary
#   2. bun on PATH       — dev convenience
#   (no build-time download; that's the runtime's job)
#
# Usage: bundle-bun.sh <APP_PATH> [SIGN_IDENTITY]
set -euo pipefail

APP="${1:?usage: bundle-bun.sh <APP_PATH> [SIGN_IDENTITY]}"
IDENTITY="${2:--}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"

# 1. Always stage the host script.
SRC_JS="$ROOT/app/plugin-host/plugin-host.js"
if [[ -f "$SRC_JS" ]]; then
  cp "$SRC_JS" "$HELPERS/plugin-host.js"
  chmod 0644 "$HELPERS/plugin-host.js"
  echo "bun: staged plugin-host.js"
else
  echo "warn: $SRC_JS missing; JS plugins cannot run." >&2
fi

# 2. Optionally stage the bun runtime.
src=""
if [[ -n "${PROSPER_BUN_BIN:-}" && -x "${PROSPER_BUN_BIN}" ]]; then
  src="$PROSPER_BUN_BIN"
elif command -v bun >/dev/null 2>&1; then
  src="$(command -v bun)"
fi

if [[ -z "$src" ]]; then
  echo "bun: no build-time runtime (set PROSPER_BUN_BIN or install bun); app downloads on first use."
  exit 0
fi

# Warn on a runtime mismatch — the plugin host is tested against the pinned release,
# and a stale dev bun bundled here would diverge from the on-demand download path.
# Keep PINNED_BUN in lockstep with BunHarness.bunVersion ("bun-v1.3.14").
PINNED_BUN="1.3.14"
got="$("$src" --version 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -n "$got" && "$got" != "$PINNED_BUN" ]]; then
  echo "warn: bundling bun $got but app pins $PINNED_BUN (BunHarness.bunVersion)." >&2
fi

DEST="$HELPERS/bun"
cp "$src" "$DEST"
chmod 0755 "$DEST"
/usr/bin/xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

# Nested executable needs its own signature + hardened runtime to notarize.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$DEST" >/dev/null 2>&1 || \
    echo "warn: ad-hoc codesign of bun helper failed." >&2
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST" || \
    echo "warn: codesign of bun helper failed (notarization will reject an unsigned helper)." >&2
fi

echo "bun: staged runtime at $DEST (from $src)"
