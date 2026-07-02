#!/bin/bash
# FAST inline-completion iteration — no GUI, no ghost, no focus stealing.
# Drives the real completion pipeline headlessly (see HeadlessBenchCLI.swift).
# Use for CONTENT/QUALITY work (language, echo, drift). For UI/UX feel (live
# ghost, rendering) use the GUI ghost bench (bench/iterate.sh) instead.
#
# Usage: bench/headless.sh [corpus.json] [ids]
#   bench/headless.sh                          # full corpus
#   bench/headless.sh bench/corpus.json lat02,lat29   # just those ids
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SCR=/private/tmp/claude-502/-Users-ventsislav-georgiev-personal-prosper/10ad5361-4ca2-47e0-a254-512d84aa21d0/scratchpad
CORPUS="${1:-bench/corpus.json}"; IDS="${2:-}"; OUT="$SCR/headless_out.json"

echo "==> build"; (cd app && swift build 2>&1 | tail -1) || { echo BUILD FAIL; exit 1; }
echo "==> bundle"; rm -rf dist/Prosper.app
scripts/bundle.sh debug >/tmp/bundle.log 2>&1 || { echo BUNDLE FAIL; tail -5 /tmp/bundle.log; exit 1; }
# Free the GPU: a running GUI Prosper + this process = two model loads → OOM.
osascript -e 'tell application "Prosper" to quit' 2>/dev/null; sleep 1; pkill -x ProsperApp 2>/dev/null; sleep 1
echo "==> headless run"
PROSPER_HEADLESS_BENCH="$CORPUS" PROSPER_HEADLESS_OUT="$OUT" ${IDS:+PROSPER_HEADLESS_IDS="$IDS"} \
  dist/Prosper.app/Contents/MacOS/ProsperApp 2>&1 | grep -vE "mlx:|CoreData|NSXPC:"
echo "==> out: $OUT"
