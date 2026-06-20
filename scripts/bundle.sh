#!/usr/bin/env bash
# Assemble a Prosper.app bundle from the built Swift binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-release}"

BIN="$ROOT/app/.build/$PROFILE/ProsperApp"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Run scripts/build.sh $PROFILE first." >&2
  exit 1
fi

APP="$ROOT/dist/Prosper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/ProsperApp"

# Stamp the version into the bundled Info.plist. The source scripts/Info.plist
# carries a placeholder; the real version comes from PROSPER_VERSION (set by CI
# from the pushed git tag, or by scripts/release.sh). Never edited by hand.
#   CFBundleShortVersionString — the marketing version, e.g. "2.1.0" or
#                                "2.1.0-beta.3" for a pre-release.
#   CFBundleVersion           — must be a monotonically increasing integer for
#                               Sparkle. Derived so that pre-releases sort BELOW
#                               their final and increase among themselves:
#                                 build = (MAJOR*1e6 + MINOR*1e3 + PATCH)*1000 + PRE
#                               where PRE = 999 for a final release and the beta
#                               number (1..998) for "-beta.N". Thus
#                                 2.55.0-beta.1 → 2055000001
#                                 2.55.0-beta.2 → 2055000002
#                                 2.55.0        → 2055000999  (> any of its betas)
#                                 2.54.0        → 2054000999  (< 2.55.0-beta.1)
#                               The ×1000 jump keeps the new scheme far above any
#                               build stamped by the old MAJOR*1e6+… formula, so
#                               already-installed clients still see newer builds.
VERSION="${PROSPER_VERSION:-}"
if [[ -n "$VERSION" ]]; then
  IFS=. read -r _maj _min _pat <<< "${VERSION%%-*}"
  # Pre-release component: 999 for a final build, else the trailing beta number.
  if [[ "$VERSION" == *-* ]]; then
    _pre="${VERSION##*.}"           # "2.55.0-beta.3" → "3"
    [[ "$_pre" =~ ^[0-9]+$ ]] || _pre=1   # tolerate "-beta" with no number
  else
    _pre=999
  fi
  _base=$(( (10#${_maj:-0}) * 1000000 + (10#${_min:-0}) * 1000 + (10#${_pat:-0}) ))
  BUILD=$(( _base * 1000 + (10#${_pre}) ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
  echo "Version: $VERSION (build $BUILD)"
fi
if [[ -f "$ROOT/scripts/AppIcon.icns" ]]; then
  cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Menu-bar status icon (neon hand, transparent bg). Loaded via Bundle.main by
# MenuBarController.
if [[ -f "$ROOT/scripts/MenuBarIcon.png" ]]; then
  cp "$ROOT/scripts/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
fi

# Bundled system extensions (calc, …). These live in the package source tree;
# ExtensionRegistry loads them from Contents/Resources/extensions via
# Bundle.main. We copy the source dir directly (NOT the SwiftPM-generated
# Prosper_ProsperApp.bundle): a resource bundle at the .app root would break the
# code-signature seal, and one under Contents/Resources can't be found by
# SwiftPM's Bundle.module accessor (which looks at the .app root). See
# Package.swift / ExtensionRegistry.bundledSystemDir.
if [[ -d "$ROOT/app/Sources/ProsperApp/Resources/extensions" ]]; then
  /usr/bin/ditto "$ROOT/app/Sources/ProsperApp/Resources/extensions" \
    "$APP/Contents/Resources/extensions"
  # Dev-only extension tests (*.test.lua) aren't runtime code — keep them out of
  # the shipped app. The loader only runs each manifest's main entry anyway.
  /usr/bin/find "$APP/Contents/Resources/extensions" -name '*.test.lua' -delete
else
  echo "warn: Resources/extensions not found — system extensions won't ship." >&2
fi

# Bundled lexicon (word-frequency + bigram dictionaries) backing the non-LLM
# completion-candidate provider (Lexicon/SymSpell). Same seal-safe rationale as
# extensions above: copy the source dir straight into Contents/Resources and
# load via Bundle.main. See Autocomplete/Lexicon.swift.
if [[ -d "$ROOT/app/Sources/ProsperApp/Resources/lexicon" ]]; then
  /usr/bin/ditto "$ROOT/app/Sources/ProsperApp/Resources/lexicon" \
    "$APP/Contents/Resources/lexicon"
else
  echo "warn: Resources/lexicon not found — completion candidates degrade to OS lexicon only." >&2
fi

# Dependency resource bundles (GRDB/Crypto privacy manifests, swift-transformers
# Hub tokenizer fallbacks). Place them under Contents/Resources so they are
# part of the signed bundle. Their Bundle.module accessors look at the .app root
# and so won't resolve them, but none are reached on the Gemma code path
# (swift-transformers only consults Hub.bundle for models whose tokenizer_config
# lacks a tokenizer_class; Gemma's has one).
shopt -s nullglob
for b in "$ROOT/app/.build/$PROFILE"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Apple MLX loads its GPU kernels from default.metallib inside
# mlx-swift_Cmlx.bundle (staged by scripts/build.sh via xcodebuild — plain
# `swift build` can't compile Metal shaders). Without it the app aborts on the
# first model load: "MLX error: Failed to load the default metallib." Fail the
# bundle rather than ship a signed app that crashes on startup.
METALLIB="$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -f "$METALLIB" ]]; then
  echo "error: $METALLIB missing — MLX will crash on model load. Run scripts/build.sh $PROFILE first." >&2
  exit 1
fi

# Code-signing identity. A STABLE identity (self-signed cert or Developer ID)
# makes macOS keep TCC grants (Accessibility / Input Monitoring) across rebuilds:
# the grant is keyed to the signing identity, not the per-build cdhash that
# ad-hoc signing ("-") produces — which is why ad-hoc builds lose the grant on
# every rebuild (the toggle stays ON in System Settings but no longer matches the
# new binary). Resolution order:
#   1. $PROSPER_SIGN_IDENTITY (explicit; CI sets this from an imported cert)
#   2. a "Developer ID Application: … (TEAMID)" cert (notarizable, prompt-free)
#   3. a keychain identity named "Prosper Self-Signed" (scripts/make-signing-cert.sh)
#   4. ad-hoc "-" (works, but the TCC grant resets each rebuild)
IDENTITY="${PROSPER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Prefer a real Developer ID Application cert when one is installed — that is
  # the only identity that can be notarized (clean, prompt-free first launch).
  DEVID_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n1 || true)
  if [[ -n "$DEVID_LINE" ]]; then
    # Sign by the full common name so a single Team's cert is unambiguous.
    IDENTITY=$(sed -E 's/.*"([^"]+)".*/\1/' <<< "$DEVID_LINE")
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Prosper Self-Signed"; then
    IDENTITY="Prosper Self-Signed"
  fi
fi
IDENTITY="${IDENTITY:--}"

# Notarization is only possible with a Developer ID Application cert. When that is
# the identity, we sign with the Hardened Runtime (--options runtime) + a secure
# timestamp + entitlements — all mandatory for the notary service to accept the
# app. Other identities keep the legacy ad-hoc/self-signed path (no hardened
# runtime: a restricted entitlement would make AMFI kill the launch without a
# provisioning profile).
NOTARIZE=0
TEAM_ID=""
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  NOTARIZE=1
  # Extract the 10-char Team ID from the trailing "(TEAMID)" in the cert name.
  TEAM_ID=$(sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/' <<< "$IDENTITY")
  echo "Signing: $IDENTITY — Developer ID, Hardened Runtime (notarizable)."
elif [[ "$IDENTITY" == "-" ]]; then
  echo "Signing: ad-hoc (TCC grants reset on each rebuild; run scripts/make-signing-cert.sh for a stable identity, or import a Developer ID cert to notarize)."
else
  echo "Signing: $IDENTITY (stable, self-signed — TCC grants persist, but NOT notarizable; import a Developer ID cert for prompt-free launches)."
fi

# codesign flag set shared by every signature in this bundle. Hardened Runtime +
# secure timestamp are required by the notary service and harmless elsewhere
# (but a timestamp needs network, so only request it when notarizing).
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$NOTARIZE" == 1 ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Bundle the Sparkle framework. The binary links @rpath/Sparkle.framework, but
# SwiftPM only stages it under .build (inside the xcframework) — it is never
# copied into the app. Copy it into Contents/Frameworks and add the matching
# rpath so dyld resolves it at runtime (without this the app aborts on launch:
# "Library not loaded: @rpath/Sparkle.framework").
SPARKLE=$(/usr/bin/find "$ROOT/app/.build/artifacts" \
  -path '*/Sparkle.xcframework/*/Sparkle.framework' -type d 2>/dev/null | /usr/bin/head -n1)
if [[ -n "$SPARKLE" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  /usr/bin/ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$APP/Contents/MacOS/ProsperApp" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ProsperApp"
  fi
  # Sign the framework + its nested helpers (Autoupdate/Updater.app, XPC) first.
  codesign "${SIGN_FLAGS[@]}" --deep "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || \
    echo "warn: codesign Sparkle.framework failed." >&2
else
  echo "warn: Sparkle.framework not found under .build/artifacts — auto-update will not load." >&2
fi

# Optional coding-agent helper: the Codex binary at Contents/Helpers/codex (resolved
# first by AgentController.resolveCodexExecutable). On-demand by design — a missing
# helper is expected, not a failure: the app downloads the pinned, SHA-256-verified
# release into Application Support on first agent use (keeps the base app ~86 MB
# slimmer). This only stages a binary already on the build machine.
"$ROOT/scripts/bundle-codex.sh" "$APP" "$IDENTITY" || \
  echo "warn: bundle-codex.sh failed; codex will be downloaded on first agent use." >&2

# Bun plugin host: always stage plugin-host.js; stage the bun runtime only if one is
# available at build time (on-demand download otherwise — keeps the base app slim).
"$ROOT/scripts/bundle-bun.sh" "$APP" "$IDENTITY" || \
  echo "warn: bundle-bun.sh failed; JS plugins fall back to a runtime bun download." >&2

# Privileged lid-sleep helper daemon (ProsperLidHelper) behind openlid's "keep
# awake with the lid closed". It runs `pmset -a disablesleep` as root via launchd,
# so the feature needs NO sudoers entry. The app installs it lazily through
# SMAppService.daemon — only the first time the user actually disables lid sleep —
# and it idle-exits when no client is connected, so it costs nothing until used.
#
# Two pieces must ship in the bundle and be sealed by the final signature:
#   1. the executable at Contents/MacOS/ProsperLidHelper
#   2. the launchd plist at Contents/Library/LaunchDaemons/<label>.plist whose
#      BundleProgram points at (1) and whose MachServices advertises the XPC port.
LID_HELPER_BIN="$ROOT/app/.build/$PROFILE/ProsperLidHelper"
LID_HELPER_LABEL="eu.illegible.prosper.lidhelper"
if [[ -x "$LID_HELPER_BIN" ]]; then
  cp "$LID_HELPER_BIN" "$APP/Contents/MacOS/ProsperLidHelper"
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cat > "$APP/Contents/Library/LaunchDaemons/$LID_HELPER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LID_HELPER_LABEL</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/ProsperLidHelper</string>
	<key>MachServices</key>
	<dict>
		<key>$LID_HELPER_LABEL</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>eu.illegible.prosper</string>
	</array>
</dict>
</plist>
PLIST
  # Sign the helper explicitly (hardened runtime + timestamp when notarizing) so
  # it carries the right identity before the final --deep reseal. The daemon
  # accepts XPC only from a client matching this same Team's Developer ID
  # requirement (see ProsperLidHelper/main.swift), so a stable identity matters.
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/ProsperLidHelper" >/dev/null 2>&1 || \
    echo "warn: codesign ProsperLidHelper failed." >&2
else
  echo "warn: $LID_HELPER_BIN not found — lid-stay-awake (openlid) will be inert. Run scripts/build.sh $PROFILE first." >&2
fi

# Sign the app last (seals the whole bundle). A stable identity persists the TCC
# grant; ad-hoc still works but resets permissions on each rebuild.
if [[ "$NOTARIZE" == 1 ]]; then
  # --- Developer ID / notarization path ---------------------------------------
  # Embed a provisioning profile if one is staged. It is REQUIRED to use the
  # restricted keychain-access-groups entitlement (AMFI kills the launch without
  # it). Register App ID eu.illegible.prosper with the Keychain Sharing capability in
  # the Developer portal, download the Developer ID provisioning profile, and
  # save it as scripts/embedded.provisionprofile (gitignored). Without it we
  # still notarize, just with a hardened-runtime-only entitlement set — the
  # iCloud-Keychain sync key (SyncKeyStore) then stays on the LOCAL device key.
  PROFILE_SRC="$ROOT/scripts/embedded.provisionprofile"
  ENT="$(mktemp -t prosper-ent).plist"
  if [[ -f "$PROFILE_SRC" ]]; then
    cp "$PROFILE_SRC" "$APP/Contents/embedded.provisionprofile"
    # Full entitlements incl. keychain-access-groups; stamp the real Team ID.
    sed "s/__TEAM_ID__/$TEAM_ID/g" "$ROOT/scripts/Prosper.entitlements" > "$ENT"
    echo "Entitlements: hardened runtime + keychain-access-groups ($TEAM_ID.eu.illegible.prosper) — iCloud-Keychain sync enabled."
  else
    # Hardened-runtime-only: notarizes cleanly, no restricted entitlement.
    cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
PLIST
    echo "Entitlements: hardened runtime only (no scripts/embedded.provisionprofile — iCloud-Keychain sync stays on the device key)."
  fi
  # Seal the whole app with --deep + entitlements. --deep is REQUIRED here, not
  # optional: it propagates SIGN_FLAGS (incl. --options runtime --timestamp) to
  # every nested item — Sparkle.framework, Helpers/bun, and the plain
  # Helpers/plugin-host.js script (Helpers is a codesign "nested code" dir, so
  # an unsigned file there fails the seal: "code object is not signed at all").
  # Apple discourages --deep for notarization, BUT an earlier attempt to replace
  # it with inside-out signing broke CI's generate_appcast with
  # errSecCSResourcesNotFound -67056 on the release-config (xcodebuild) product —
  # a failure that local `codesign --verify` does NOT catch (v2.88.1). --deep is
  # the known-good path for this bundle; do not "fix" it to inside-out without
  # reproducing against a real release-config build + the Sparkle generate_appcast
  # validator. See memory: prosper-release-flow.
  codesign "${SIGN_FLAGS[@]}" --deep --entitlements "$ENT" "$APP" >/dev/null 2>&1 || \
    echo "warn: codesign failed — bundle is not validly signed." >&2
  rm -f "$ENT"
  echo "Signed for notarization. Next: scripts/notarize.sh   (submits + staples)."
else
  # --- Self-signed / ad-hoc path (unchanged) ----------------------------------
  # No entitlements: the device secret lives in ~/.config/prosper/device.key (see
  # DatabaseKey.swift) — the keychain-access-groups / data-protection-keychain
  # route is unusable for a self-signed app (restricted entitlement: AMFI kills
  # the launch without a provisioning profile), and the legacy keychain re-prompts
  # after every update (per-build cdhash partition list).
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || \
    echo "warn: codesign failed; permissions may not persist across rebuilds." >&2
fi

echo "Bundled: $APP"
echo "Run:     open \"$APP\"   (or: \"$APP/Contents/MacOS/ProsperApp\" for console logs)"
