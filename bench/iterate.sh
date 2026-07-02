#!/bin/bash
# One inline-autocomplete improvement iteration on the DEV Prosper:
#   build (debug) → bundle → relaunch with ground-truth logging → run bench.
# Usage: bench/iterate.sh [lang] [limit]   e.g. bench/iterate.sh en 10
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
LANG_SEL="${1:-en}"; LIMIT="${2:-10}"
SCR=/private/tmp/claude-502/-Users-ventsislav-georgiev-personal-prosper/10ad5361-4ca2-47e0-a254-512d84aa21d0/scratchpad
GLOG="$SCR/prosper-bench.log"; OUT="$SCR/pg_iter.json"

echo "==> build (debug)"; (cd app && swift build 2>&1 | tail -2) || { echo BUILD FAILED; exit 1; }
echo "==> bundle"; rm -rf dist/Prosper.app   # cp over an existing signed .app silently no-ops; nuke first
scripts/bundle.sh debug >"$SCR/bundle.log" 2>&1 || { echo BUNDLE FAILED; tail -5 "$SCR/bundle.log"; exit 1; }
echo "==> relaunch"; osascript -e 'tell application "Prosper" to quit' 2>/dev/null; sleep 1; pkill -x ProsperApp 2>/dev/null; sleep 1
# Launch the bundled binary DIRECTLY, never via `open`: `open dist/Prosper.app`
# resolves by bundle id (eu.illegible.prosper) and LaunchServices happily launches
# the STALE /Applications/Prosper.app instead — which silently tested an old binary.
# A direct exec runs exactly this build, sets PROSPER_BENCH_LOG, and still resolves
# Bundle.main to the .app (correct UserDefaults domain + adjacent metallib).
: > "$GLOG"
if ! strings dist/Prosper.app/Contents/MacOS/ProsperApp | grep -q "phone keyboard's next-word"; then
  echo "WARN: dist binary looks stale (rebundle failed?)"; fi
PROSPER_BENCH_LOG="$GLOG" dist/Prosper.app/Contents/MacOS/ProsperApp >/tmp/prosper-dev.stdout.log 2>&1 &
sleep 20
echo "==> bench ($LANG_SEL, $LIMIT)"
app/.build/debug/bench --corpus bench/corpus.json --out "$OUT" \
  --tool prosper --engineapp Prosper --capture ghost --kind nstextview \
  --type full --prewait 2.5 --ghostwait 8 --lang "$LANG_SEL" --limit "$LIMIT" 2>&1 | tail -n "$((LIMIT+3))"
