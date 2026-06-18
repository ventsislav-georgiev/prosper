#!/usr/bin/env bash
# Notarize + staple the already-signed dist/Prosper.app, then verify Gatekeeper
# accepts it. Run AFTER scripts/build.sh + scripts/bundle.sh have produced a
# Developer ID-signed, hardened-runtime bundle (bundle.sh prints "Signed for
# notarization." when it did). Notarization is a network round-trip to Apple
# (tens of seconds to minutes); it is deliberately NOT part of bundle.sh so dev
# rebuilds stay fast.
#
# CREDENTIALS — stored keychain profile (no secrets in env or repo). Create once:
#   xcrun notarytool store-credentials prosper-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-pwd>
# (or --key/--key-id/--issuer for an App Store Connect API key). Override the
# profile name with PROSPER_NOTARY_PROFILE.
#
#   scripts/notarize.sh                # notarize dist/Prosper.app
#   scripts/notarize.sh path/to.app    # notarize a specific bundle
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Prosper.app}"
PROFILE="${PROSPER_NOTARY_PROFILE:-prosper-notary}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run scripts/build.sh && scripts/bundle.sh first." >&2
  exit 1
fi

# Refuse to waste a notary round-trip on a bundle that isn't Developer ID-signed
# with the hardened runtime — the service would reject it anyway.
SIGNINFO=$(codesign -dvvv "$APP" 2>&1 || true)
if ! grep -q "Authority=Developer ID Application" <<< "$SIGNINFO"; then
  echo "error: $APP is not Developer ID-signed. Import a Developer ID cert and re-run scripts/bundle.sh." >&2
  exit 1
fi
if ! grep -q "flags=.*runtime" <<< "$SIGNINFO"; then
  echo "error: $APP lacks the Hardened Runtime. Re-run scripts/bundle.sh with a Developer ID cert." >&2
  exit 1
fi

# Notarization takes a ZIP (a .app can't be uploaded directly). --keepParent
# preserves the .app wrapper inside the archive.
ZIP="$(mktemp -d)/Prosper.zip"
trap 'rm -rf "$(dirname "$ZIP")"' EXIT
echo "Zipping $APP …"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary (profile: $PROFILE) — this can take a few minutes …"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Staple the ticket INTO the .app so Gatekeeper validates offline (no network
# needed on the user's first launch). Then assert Gatekeeper actually accepts it.
echo "Stapling ticket …"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"

echo "Notarized + stapled: $APP"
echo "Now re-zip for release (the stapled .app):"
echo "  ditto -c -k --keepParent \"$APP\" Prosper.zip"
