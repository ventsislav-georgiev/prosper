#!/bin/bash
# Full inline-autocomplete regression gate: runs the REAL model headlessly over
# the corpus, then asserts speed + quality + coherence + no-drift (bench/headless_tests.py).
# Use after ANY sampling/prompt/ladder change to prove no regression.
#
# Usage: bench/regress.sh [corpus.json]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CORPUS="${1:-bench/corpus.json}"
bench/headless.sh "$CORPUS"
echo "==> assertions"
python3 bench/headless_tests.py
