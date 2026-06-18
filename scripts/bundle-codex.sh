#!/usr/bin/env bash
# Optionally stage + sign the Codex binary into a Prosper.app bundle at
# Contents/Helpers/codex. Called by scripts/bundle.sh right before the final app seal;
# also runnable standalone while iterating on the helper.
#
# Codex delivery is on-demand by design (keeps the base app slim — the binary is ~86 MB):
# AgentController.resolveCodexExecutable() looks at Contents/Helpers/codex first, then
# Homebrew/PATH, then downloads the pinned, SHA-256-verified release into Application
# Support on first use of the coding agent. So a missing codex here is NOT a failure —
# users who never open the agent never pull it. This script only stages a binary that's
# already on the build machine (dev convenience / reproducible bundle).
#
# Binary resolution order for the optional bundled codex:
#   1. $PROSPER_CODEX_BIN  — explicit path to a prebuilt codex binary
#   2. codex on PATH       — dev convenience
#   (no build-time download; that's the runtime's job — keep CODEX_VERSION in lockstep
#    with AgentController.codexVersion + codexSHA256.)
#
# Usage: bundle-codex.sh <APP_PATH> [SIGN_IDENTITY]
set -euo pipefail

APP="${1:?usage: bundle-codex.sh <APP_PATH> [SIGN_IDENTITY]}"
IDENTITY="${2:--}"

HELPERS="$APP/Contents/Helpers"
DEST="$HELPERS/codex"
mkdir -p "$HELPERS"

arch="$(uname -m)"   # arm64 | x86_64
case "$arch" in
  arm64)  machoArch="arm64"  ;;
  x86_64) machoArch="x86_64" ;;
  *) echo "error: unsupported arch $arch" >&2; exit 1 ;;
esac

src=""
if [[ -n "${PROSPER_CODEX_BIN:-}" && -x "${PROSPER_CODEX_BIN}" ]]; then
  src="$PROSPER_CODEX_BIN"
  echo "codex: using PROSPER_CODEX_BIN=$src"
elif command -v codex >/dev/null 2>&1; then
  src="$(command -v codex)"
  echo "codex: using PATH copy $src"
else
  echo "codex: no build-time binary (set PROSPER_CODEX_BIN or install codex); app downloads on first agent use."
  exit 0
fi

# Sanity-check the arch — a mismatched helper would fail to exec at runtime.
if ! /usr/bin/file "$src" | grep -q "$machoArch"; then
  echo "warn: $src does not look like a $machoArch mach-o — bundling anyway." >&2
fi

cp "$src" "$DEST"
chmod 0755 "$DEST"
# A freshly-downloaded binary may carry the quarantine xattr; strip it so the
# signed helper launches without a Gatekeeper prompt.
/usr/bin/xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

# Sign so the helper passes notarization. The app is sealed afterwards by
# bundle.sh; a nested executable must carry its OWN signature + hardened runtime
# (do not rely on the deprecated --deep). Ad-hoc ("-") is fine for dev but won't
# notarize — only a Developer ID identity + --options runtime --timestamp will.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$DEST" >/dev/null 2>&1 || \
    echo "warn: ad-hoc codesign of codex helper failed." >&2
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST" || \
    echo "warn: codesign of codex helper failed (notarization will reject an unsigned helper)." >&2
fi

echo "codex: staged at $DEST (version $CODEX_VERSION, $triple)"
