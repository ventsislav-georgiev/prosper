#!/usr/bin/env bash
# Install / refresh the author's personal example extensions into the live
# config dir (~/.config/prosper/extensions/<id>) so they're present by default
# on every dev machine. Unlike the bundled SYSTEM extensions (Resources/
# extensions, reseeded by ExtensionRegistry.seedSystemExtensions on launch),
# the ones under app/Examples are user/marketplace extensions and never
# auto-update — this script is their reseed path.
#
#   - Installs a missing extension.
#   - Updates one whose installed extension.toml version != the source version.
#   - SKIPS one already at the same version (no copy, no churn).
#   - Auto-trusts them (they're mine) so they actually run — without trust an
#     installed user extension loads zero rules.
#
# Dev convenience only: it writes into $HOME and the app's prefs, so it
# self-skips in CI. Called from scripts/build.sh (with `|| true`), or run by
# hand. Pass -n / --dry-run to print actions without changing anything.
#
# bash 3.2 compatible (CI runner / stock macOS): no associative arrays.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/Examples/extensions"
DST="$HOME/.config/prosper/extensions"
APP_DOMAIN="eu.illegible.prosper"

DRY=0
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY=1

# Never touch a CI runner's home/prefs — release.yml runs build.sh.
if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]]; then exit 0; fi
[[ -d "$SRC" ]] || { echo "install-example-extensions: no $SRC, nothing to do"; exit 0; }

# Grab a quoted scalar from a toml line:  version = "1.4.0"  ->  1.4.0
read_field() {
  grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null \
    | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}

installed=0; updated=0; skipped=0; trust_ids=""
for dir in "$SRC"/*/; do
  toml="$dir/extension.toml"
  [[ -f "$toml" ]] || continue
  id="$(read_field "$toml" id)"
  ver="$(read_field "$toml" version)"
  if [[ -z "$id" || -z "$ver" ]]; then
    echo "warn: ${dir#$ROOT/} has no id/version — skipped" >&2
    continue
  fi
  trust_ids="$trust_ids $id"
  dest="$DST/$id"

  if [[ -d "$dest" ]]; then
    cur="$(read_field "$dest/extension.toml" version)"
    if [[ "$cur" == "$ver" ]]; then
      skipped=$((skipped + 1)); continue
    fi
    echo "update $id: $cur -> $ver"
    [[ $DRY -eq 1 ]] && continue
    rm -rf "$dest"
    updated=$((updated + 1))
  else
    echo "install $id ($ver)"
    [[ $DRY -eq 1 ]] && continue
    installed=$((installed + 1))
  fi

  mkdir -p "$dest"
  /usr/bin/ditto "$dir" "$dest"
  # Match bundle.sh: tests don't belong in an installed copy.
  /usr/bin/find "$dest" -name '*.test.lua' -delete
done

echo "extensions: $installed installed, $updated updated, $skipped up-to-date"

# Auto-trust. Prosper rewrites its prefs on quit, so editing them while it runs
# would be clobbered — tell the user to quit (or click Trust) instead.
if [[ -n "$trust_ids" && $DRY -eq 0 ]]; then
  if pgrep -x Prosper >/dev/null 2>&1; then
    echo "note: Prosper is running — quit it then re-run to auto-trust, or click Trust in Settings → Extensions."
  else
    existing="$(defaults read "$APP_DOMAIN" trustedExtensionIDs 2>/dev/null \
      | grep -oE '"[^"]*"' | tr -d '"' || true)"
    args=()
    while IFS= read -r x; do [[ -n "$x" ]] && args+=("$x"); done < <(
      printf '%s\n' $existing $trust_ids | sort -u
    )
    [[ ${#args[@]} -gt 0 ]] && defaults write "$APP_DOMAIN" trustedExtensionIDs -array "${args[@]}"
    echo "trusted: ${args[*]}"
  fi
fi
