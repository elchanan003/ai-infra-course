#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it. Module 07 has no runtime apply steps
# (verify starts the learner's servers and runs the learner's scripts itself).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
chmod -R a+rX "$MODULE_DIR/lab"
chmod +x "$MODULE_DIR"/lab/agent/loop.py "$MODULE_DIR"/lab/mcp/*.py "$MODULE_DIR"/lab/sandbox/*.sh "$MODULE_DIR"/lab/rag/*.py
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts)"
