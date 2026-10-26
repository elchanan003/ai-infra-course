#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it, then run the reference method for the
# variant-bound parts (downloads, answers, registry push, bundle repair). No manual steps.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
chmod +x "$MODULE_DIR/lab/airgap/run.sh" "$MODULE_DIR/lab/pickle_scan.py" "$MODULE_DIR/lab/s3-sync.py"
bash "$TUTOR/solve-answers.sh" || exit 1
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), downloads/answers/registry/bundle repair done"
