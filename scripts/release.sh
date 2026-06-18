#!/usr/bin/env bash
# Cut a new release by auto-incrementing the MINOR version from the latest
# v* git tag, then pushing it. The push triggers .github/workflows/release.yml,
# which checks out the tagged commit, builds, stamps the version into Info.plist
# (via PROSPER_VERSION → bundle.sh), signs, notarizes, and publishes the Release.
#
# No file is edited by hand: the tag is the single source of truth for the
# version. Default bump is MINOR (vX.Y.Z → vX.(Y+1).0); override the segment:
#   scripts/release.sh            # minor bump (default)
#   scripts/release.sh patch      # patch bump (vX.Y.Z → vX.Y.(Z+1))
#   scripts/release.sh major      # major bump (vX.Y.Z → v(X+1).0.0)
#   scripts/release.sh beta       # next minor as a beta: vX.(Y+1).0-beta.N
#   scripts/release.sh v3.0.0     # explicit version (incl. -beta.N pre-releases)
#
# A "-beta.N" tag publishes a GitHub *pre-release*; release.yml tags its appcast
# item with the `beta` channel and exposes it via the stable feed, so only users
# who opted into beta updates (Settings → About) receive it. Promote a beta to
# everyone by cutting a normal version (e.g. `scripts/release.sh` for the matching
# minor) — it becomes "latest" and propagates to the stable channel.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git fetch --tags --quiet

ARG="${1:-minor}"
if [[ "$ARG" == v* ]]; then
  NEXT="$ARG"
elif [[ "$ARG" == beta ]]; then
  # Base the beta on the next MINOR above the latest *stable* (non-beta) tag, then
  # take the next free -beta.N for that base.
  STABLE=$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
  STABLE="${STABLE:-v0.0.0}"
  IFS=. read -r MAJ MIN _PAT <<< "${STABLE#v}"
  BASE="v${MAJ}.$((MIN + 1)).0"
  LASTB=$(git tag -l "${BASE}-beta.*" | sort -V | tail -n1)
  if [[ -n "$LASTB" ]]; then N=$(( ${LASTB##*.} + 1 )); else N=1; fi
  NEXT="${BASE}-beta.${N}"
  LATEST="$STABLE"
else
  LATEST=$(git tag -l 'v*' | sort -V | tail -n1)
  LATEST="${LATEST:-v0.0.0}"
  IFS=. read -r MAJ MIN PAT <<< "${LATEST#v}"
  case "$ARG" in
    major) NEXT="v$((MAJ + 1)).0.0" ;;
    minor) NEXT="v${MAJ}.$((MIN + 1)).0" ;;
    patch) NEXT="v${MAJ}.${MIN}.$((PAT + 1))" ;;
    *) echo "error: unknown bump '$ARG' (use major|minor|patch|beta|vX.Y.Z)" >&2; exit 1 ;;
  esac
fi

if git rev-parse "$NEXT" >/dev/null 2>&1; then
  echo "error: tag $NEXT already exists" >&2
  exit 1
fi

echo "Releasing $NEXT (from ${LATEST:-explicit})"

# Push main first so the branch ref advances with the tag, then push the tag.
# release.yml triggers on the v* tag and builds the exact tagged commit.
git push origin HEAD
git tag -a "$NEXT" -m "Prosper $NEXT"
git push origin "$NEXT"
echo "Pushed $NEXT — release.yml will build, sign, notarize, and publish the Release."
