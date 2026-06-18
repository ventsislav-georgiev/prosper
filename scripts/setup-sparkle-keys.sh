#!/usr/bin/env bash
# One-shot Sparkle EdDSA key setup for Prosper auto-update.
#
# What it does (all free, no Apple account needed):
#   1. Downloads Sparkle's signing tools (generate_keys) if not cached.
#   2. Generates an EdDSA key pair (private key stored in your login Keychain).
#   3. Patches scripts/Info.plist -> SUPublicEDKey with the public key.
#   4. Exports the private key to stdout so you can paste it into the GitHub
#      repo secret SPARKLE_PRIVATE_KEY (used by .github/workflows/release.yml).
#
# Re-running is safe: if a key already exists in the Keychain, Sparkle reuses it
# (pass --force to generate_keys yourself to rotate). The script only rewrites
# the Info.plist public key and re-prints the private key.
#
# Usage:
#   ./scripts/setup-sparkle-keys.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/scripts/Info.plist"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
TOOLS_DIR="$ROOT/.sparkle-tools"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# --- 1. Fetch Sparkle tools (cached) ----------------------------------------
GEN="$(find "$TOOLS_DIR" -name generate_keys -type f 2>/dev/null | head -n1 || true)"
if [[ -z "${GEN}" ]]; then
  bold "Downloading Sparkle ${SPARKLE_VERSION} signing tools..."
  mkdir -p "$TOOLS_DIR"
  TARBALL="$TOOLS_DIR/sparkle-${SPARKLE_VERSION}.tar.xz"
  curl -fL -o "$TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xf "$TARBALL" -C "$TOOLS_DIR"
  GEN="$(find "$TOOLS_DIR" -name generate_keys -type f | head -n1)"
fi
[[ -n "${GEN}" ]] || { warn "generate_keys not found after download"; exit 1; }

# --- 2. Generate (or reuse) the key pair ------------------------------------
bold "Generating / loading EdDSA key pair (private key lives in your Keychain)..."
# generate_keys prints the public key line and stores the private key in the
# Keychain. If a key already exists it prints the existing public key.
PUBKEY_OUTPUT="$("$GEN" 2>&1 || true)"
echo "$PUBKEY_OUTPUT"

# Extract the base64 public key. generate_keys prints a line like:
#   <string>BASE64KEY==</string>  (inside an Info.plist snippet it suggests)
PUBKEY="$(printf '%s\n' "$PUBKEY_OUTPUT" | grep -Eo '[A-Za-z0-9+/]{40,}={0,2}' | tail -n1 || true)"
if [[ -z "${PUBKEY}" ]]; then
  warn "Could not auto-extract the public key from generate_keys output."
  warn "Copy the SUPublicEDKey value above into $INFO_PLIST manually."
  exit 1
fi

# --- 3. Patch Info.plist SUPublicEDKey --------------------------------------
bold "Writing SUPublicEDKey into $INFO_PLIST ..."
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${PUBKEY}" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${PUBKEY}" "$INFO_PLIST"
echo "  SUPublicEDKey = ${PUBKEY}"

# --- 4. Export private key for the CI secret --------------------------------
SIGN="$(find "$TOOLS_DIR" -name sign_update -type f | head -n1 || true)"
bold ""
bold "=============================================================="
bold "Next: add the PRIVATE key as the GitHub repo secret SPARKLE_PRIVATE_KEY"
bold "=============================================================="
echo "Export it from the Keychain with Sparkle's generate_keys:"
echo
echo "    \"$GEN\" -x sparkle_private_key.pem"
echo "    gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.pem"
echo "    rm -f sparkle_private_key.pem   # do NOT commit this file"
echo
warn "The private key is secret. Never commit it. .gitignore already excludes *.pem and .sparkle-tools/."
[[ -n "${SIGN}" ]] && echo "(sign_update tool available at: $SIGN)"
bold ""
bold "Done. Commit the Info.plist change, set the secret, then push a v* tag to release."
