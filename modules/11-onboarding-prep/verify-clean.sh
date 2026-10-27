#!/usr/bin/env bash
# Module 11 verify-clean: proves cleanup.sh removed runtime state and left the lab files alone.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
trap 'rm -f "$MODULE_DIR/.last-verify"' EXIT   # summary writes it; verify-clean must leave no state
left=""
[ -e "$MODULE_DIR/.state" ] && left="$left .state"
[ -e "$MODULE_DIR/.last-verify" ] && left="$left .last-verify"
[ -z "$left" ] && pass C.1 "runtime state gone" || fail C.1 "left behind:$left"
miss=""
for f in self-assessment.md team-questions.md first-week-plan.md; do [ -f "$MODULE_DIR/lab/$f" ] || miss="$miss $f"; done
[ -z "$miss" ] && pass C.2 "lab files intact" || fail C.2 "lab files missing:$miss"
nx=""
for f in prepare-lab.sh verify.sh cleanup.sh verify-clean.sh .tutor/apply-solution.sh; do [ -x "$MODULE_DIR/$f" ] || nx="$nx $f"; done
[ -z "$nx" ] && pass C.3 "module scripts intact" || fail C.3 "not executable:$nx"
summary
