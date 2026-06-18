#!/usr/bin/env bash
# App-level end-to-end smoke for the coding-agent integration. Launches a built
# Prosper.app, inspects the unified log (subsystem com.prosper.app), and asserts
# the agent subsystem is wired: the `agent` system extension seeds, and the LLM
# server / AgentController are reachable.
#
# Stages:
#   boot (default) — launch the app, confirm boot + that the `agent` extension
#                    seeded. Safe: no synthetic input, no model download.
#   --drive        — additionally open the universal runner (⌘Space) and type the
#                    `g ` agent prefix to fire a real goal run. REQUIRES: a
#                    downloaded agent model, a bundled/PATH codex binary, and
#                    Accessibility permission for synthetic keystrokes. WARNING:
#                    synthetic keystrokes go to the frontmost app — close other
#                    windows first.
#
# The deterministic protocol-level e2e lives in the test suite
# (CodexHarnessE2ETests + ProsperLLMServerE2ETests); this script verifies the
# assembled app boots and the pieces are connected.
#
# Usage: e2e-agent.sh [--drive] [--app /path/to/Prosper.app] [--goal "text"]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Prosper.app"
DRIVE=0
GOAL="list the files in this directory"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drive) DRIVE=1; shift ;;
    --app)   APP="$2"; shift 2 ;;
    --goal)  GOAL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

BIN="$APP/Contents/MacOS/ProsperApp"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found. Build + bundle first:" >&2
  echo "       scripts/build.sh debug && scripts/bundle.sh debug" >&2
  exit 1
fi

LOGFILE="$(mktemp -t prosper-e2e-XXXX).log"
PRED='subsystem == "com.prosper.app"'

cleanup() {
  [[ -n "${STREAM_PID:-}" ]] && kill "$STREAM_PID" 2>/dev/null || true
  # Only kill the app if WE launched it; never tear down a pre-existing instance.
  [[ "${LAUNCHED:-0}" -eq 1 && -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ streaming logs ($PRED)"
log stream --predicate "$PRED" --style compact --level debug >"$LOGFILE" 2>/dev/null &
STREAM_PID=$!
sleep 1

# Attach to an already-running instance rather than launching a duplicate: a 2nd
# process would register the same global hotkeys (⌘Space) and fight the live one,
# and cleanup must NOT kill an instance we didn't start.
EXISTING="$(pgrep -f "$BIN" | head -n1 || true)"
LAUNCHED=0
if [[ -n "$EXISTING" ]]; then
  echo "▶ attaching to running instance (pid $EXISTING) — not launching a duplicate"
  APP_PID="$EXISTING"
else
  echo "▶ launching $APP"
  "$BIN" >>"$LOGFILE" 2>&1 &
  APP_PID=$!
  LAUNCHED=1
fi

# Give the app time to boot, seed system extensions, and settle.
sleep 6

pass=0; partial=0
check() {  # check "<label>" "<grep-pattern>"
  if grep -Eiq "$2" "$LOGFILE"; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1 (pattern: $2)"
    partial=1
  fi
}

echo "▶ boot assertions"
# The app process is alive.
if kill -0 "$APP_PID" 2>/dev/null; then echo "  ✓ app process alive"; else echo "  ✗ app exited early"; pass=1; fi
# The `agent` system extension seeded into the editable dir on first launch.
if [[ -f "$HOME/.config/prosper/extensions/agent/extension.toml" ]]; then
  echo "  ✓ agent extension seeded (~/.config/prosper/extensions/agent)"
else
  echo "  ✗ agent extension not seeded"; partial=1
fi

if [[ "$DRIVE" -eq 1 ]]; then
  echo "▶ driving a goal run via the runner (⌘Space → '$GOAL')"
  echo "  (requires a downloaded agent model + codex; synthetic keystrokes need Accessibility)"
  osascript >/dev/null 2>&1 <<OSA || echo "  ! osascript step failed (Accessibility not granted?)"
    tell application "System Events"
      key code 49 using {command down}
      delay 1
      keystroke "g ${GOAL}"
      delay 0.5
      key code 36
    end tell
OSA
  # The agent path should now light up: server start, residency swap, harness spawn.
  sleep 8
  echo "▶ agent-run assertions"
  check "LLM server bound"              "LLMServer.*ready|LLM server ready"
  check "AgentController engaged"       "AgentController|loading coding model|Loading .* model"
  check "harness spawn attempted"       "CodexHarness|codex|coding model"
else
  echo "  (skipping goal run; pass --drive to fire a real run — needs model + codex + Accessibility)"
fi

echo "▶ recent agent-subsystem log tail:"
grep -Ei 'LLMServer|AgentController|CodexHarness|extension .*agent' "$LOGFILE" | tail -n 15 | sed 's/^/    /'

if [[ "$pass" -ne 0 ]]; then
  echo "RESULT: FAIL — app did not stay up. Full log: $LOGFILE"
  exit 1
elif [[ "$partial" -ne 0 ]]; then
  echo "RESULT: PARTIAL — boot ok, some assertions unmet. Full log: $LOGFILE"
  exit 0
else
  echo "RESULT: PASS — agent subsystem wired. Full log: $LOGFILE"
  exit 0
fi
