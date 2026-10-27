#!/usr/bin/env bash
# Module 07 verify-clean: proves cleanup.sh removed the runtime state and nothing else.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
# containers of other modules' labs (aiinfra-labNN-*, NN != 07) are not this module's state
mine() { docker ps -a --filter label=course=aiinfra --format '{{.Names}}' | grep -Ev '^aiinfra-lab(0[0-6]|0[89]|1[0-9])-' ; }
n=$(mine | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left (stack down, no sandbox containers)" \
  || fail C.1 "$n course container(s) still present: $(mine | tr '\n' ' ')"
s=$(docker ps -aq --filter name=sbx- | wc -l)
[ "$s" = 0 ] && pass C.2 "no sbx-* containers" || fail C.2 "$s sbx-* container(s) left"
left=""
[ -e "$MODULE_DIR/.state" ] && left="$left .state"
[ -e "$MODULE_DIR/lab/env.sh" ] && left="$left lab/env.sh"
pgrep -f "$MODULE_DIR/(\.verify|lab|\.tutor)" >/dev/null 2>&1 && left="$left helper-processes"
[ -z "$left" ] && pass C.3 "runtime state and helper processes gone" || fail C.3 "left behind:$left"
missing=""
for c in cli-proxy-api workout-mongo kali-cli; do docker ps -a --format '{{.Names}}' | grep -qx "$c" || missing="$missing $c"; done
[ -z "$missing" ] && pass C.4 "non-course containers untouched" || fail C.4 "non-course container(s) missing:$missing"
lf=""
for f in agent/loop.py agent/tools.py mcp/server.py mcp/exec_server.py sandbox/run_sandboxed.sh sandbox/legacy_runner.sh rag/ingest.py rag/search.py; do
  [ -f "$MODULE_DIR/lab/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && pass C.5 "lab/ workspace files intact" || fail C.5 "lab files missing:$lf"
summary
