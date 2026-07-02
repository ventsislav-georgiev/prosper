#!/bin/bash
# Launch the freshly-built DEV Prosper binary directly (so we can pass
# PROSPER_BENCH_LOG in its environment — `open` cannot). The MLX metallib bundle
# sits next to the binary in .build/debug, so a direct launch still finds it.
# Accessibility must be granted to this binary path (user grants once; it
# persists across rebuilds at the same path).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/app/.build/debug/ProsperApp"
LOG="${1:-/private/tmp/claude-502/-Users-ventsislav-georgiev-personal-prosper/10ad5361-4ca2-47e0-a254-512d84aa21d0/scratchpad/prosper-bench.log}"

# kill any running Prosper (installed or dev)
osascript -e 'tell application "Prosper" to quit' 2>/dev/null; sleep 1
pkill -x ProsperApp 2>/dev/null; sleep 1

: > "$LOG"   # truncate the ground-truth log
echo "launching dev Prosper with PROSPER_BENCH_LOG=$LOG"
PROSPER_BENCH_LOG="$LOG" TRACE_PROSPER=0 "$BIN" >/tmp/prosper-dev.stdout.log 2>&1 &
echo "pid $!"
sleep 20   # model warmup
echo "autocompleteEnabled=$(defaults read eu.illegible.prosper autocompleteEnabled 2>/dev/null)"
echo "prosper procs: $(pgrep -x ProsperApp | wc -l | tr -d ' ')"
