#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it. No runtime apply steps for module 11.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts)"
