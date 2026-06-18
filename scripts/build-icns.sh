#!/usr/bin/env bash
# Build scripts/AppIcon.icns from a 1024×1024 master PNG.
#
# Master source (first that exists):
#   scripts/AppIcon-master.png   (e.g. an AI-generated icon)
#   scripts/AppIcon-1024.png     (the code-generated fallback from make-icon.swift)
#
# Produces every size macOS expects via `sips` + `iconutil`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/scripts"

SRC=""
for cand in AppIcon-master.png AppIcon-1024.png; do
  [[ -f "$cand" ]] && { SRC="$cand"; break; }
done
[[ -n "$SRC" ]] || { echo "error: no master PNG (AppIcon-master.png / AppIcon-1024.png)" >&2; exit 1; }
echo "master: $SRC"

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"

# size:filename pairs (1x + 2x retina variants)
for spec in \
  16:icon_16x16 32:icon_16x16@2x \
  32:icon_32x32 64:icon_32x32@2x \
  128:icon_128x128 256:icon_128x128@2x \
  256:icon_256x256 512:icon_256x256@2x \
  512:icon_512x512 1024:icon_512x512@2x ; do
  px="${spec%%:*}"; name="${spec##*:}"
  sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"
echo "wrote: $ROOT/scripts/AppIcon.icns"
