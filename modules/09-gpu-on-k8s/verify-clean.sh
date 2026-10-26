#!/usr/bin/env bash
# Module 09: proves cleanup.sh worked (no course containers, no kind cluster, no variant state, lab/ still yours).
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
n=$(docker ps -aq --filter label=course=aiinfra 2>/dev/null | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left" || fail C.1 "$n course containers still exist (docker ps -a --filter label=course=aiinfra)"
if kind get clusters 2>/dev/null | grep -qx aiinfra; then fail C.2 "kind cluster aiinfra still exists"; else pass C.2 "no kind cluster aiinfra"; fi
[ ! -e "$MODULE_DIR/.state" ] && pass C.3 "variant state removed" || fail C.3 ".state/ still exists"
[ -f "$MODULE_DIR/lab/answers/smi.env" ] && [ -f "$MODULE_DIR/lab/k8s/node-gpu.sh" ] && pass C.4 "lab/ is intact" || fail C.4 "lab/ files are missing - cleanup must never delete them"
summary
