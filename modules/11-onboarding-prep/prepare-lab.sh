#!/usr/bin/env bash
# Module 11 prepare: no stack needed. Creates .state and restores any missing lab file from the pristine templates
# in .verify/templates (never overwrites a file you have edited). Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
command -v python3 >/dev/null || { echo "prepare-lab: python3 missing"; exit 1; }
mkdir -p "$MODULE_DIR/.state" "$MODULE_DIR/lab"
for f in self-assessment.md team-questions.md first-week-plan.md; do
  [ -f "$MODULE_DIR/lab/$f" ] || { cp "$MODULE_DIR/.verify/templates/$f" "$MODULE_DIR/lab/$f" && echo "prepare-lab: restored lab/$f"; }
done
echo ready > "$MODULE_DIR/.state/prepared"
echo "prepare-lab: ready. Fill in lab/self-assessment.md, lab/team-questions.md, lab/first-week-plan.md, then ./verify.sh"
