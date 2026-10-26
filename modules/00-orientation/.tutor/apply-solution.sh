#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it, reload the gateway, write the
# variant-bound answer files with the reference method. No manual steps.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
chmod -R a+rX "$MODULE_DIR/lab/litellm"
bash "$MODULE_DIR/lab/bin/reload-gateway.sh" || exit 1
bash "$TUTOR/solve-answers.sh" || exit 1
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), gateway reloaded, answers written"
