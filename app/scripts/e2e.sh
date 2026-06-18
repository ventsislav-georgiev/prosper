#!/usr/bin/env bash
# Prosper end-to-end test runner.
#
# Per project policy, e2e ALWAYS starts by building Prosper FROM SOURCE and runs
# against that build — never the installed/official app — with auto-update
# disabled (the suites pass `-automaticUpdateChecks NO`) so the dev build can't
# Sparkle-replace itself with the official build mid-run.
#
# The suites launch the freshly built ProsperApp (real keystroke tap) and the
# E2EHost dummy field app as real external processes, synthesize keystrokes, and
# read fields back via Accessibility. Requirements:
#   - a logged-in GUI session (not headless / not over plain SSH)
#   - Accessibility trust for BOTH the test runner and the dev ProsperApp binary
#     (System Settings › Privacy & Security › Accessibility)
#
# Usage:
#   scripts/e2e.sh                 # all e2e suites
#   scripts/e2e.sh Snippet         # filter (passed to swift test --filter)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building Prosper + E2EHost from source (debug)…"
swift build --build-tests

# Belt-and-braces: kill any leftover host/app from a previous aborted run.
pkill -x E2EHost 2>/dev/null || true

FILTER="${1:-}"
SUITES=(SnippetExpansionExternalAppTests InlineAutocompleteE2ETests)

echo "==> Running e2e suites (real app, auto-update off)…"
export PROSPER_E2E=1
# E2EHost is launched via NSWorkspace.openApplication (detaches its stderr from
# our pipe), so route its transcript to a file we can inspect.
export PROSPER_E2E_HOST_LOG="${PROSPER_E2E_HOST_LOG:-/tmp/prosper-e2e-host.log}"
: > "$PROSPER_E2E_HOST_LOG"
LOG="${PROSPER_E2E_LOG:-/tmp/prosper-e2e.log}"
echo "    (full output tee'd to $LOG)"
if [[ -n "$FILTER" ]]; then
    swift test --filter "$FILTER" 2>&1 | tee "$LOG"
else
    # One --filter per suite.
    args=()
    for s in "${SUITES[@]}"; do args+=(--filter "$s"); done
    swift test "${args[@]}" 2>&1 | tee "$LOG"
fi
