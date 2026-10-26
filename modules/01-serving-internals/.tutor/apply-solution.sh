#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it, write the variant-bound answer files
# with the reference method (uses the llama server on :18120 via lab/bin/run-llama.sh).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
bash "$TUTOR/solve-answers.sh" || exit 1
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), answers written"
