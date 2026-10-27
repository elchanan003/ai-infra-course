#!/usr/bin/env bash
# 10-capstone verify-clean: proves cleanup.sh removed the runtime state and nothing else.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
# containers of other modules' labs (aiinfra-labNN-*, NN != 10) are not this module's state
mine() { docker ps -a --filter label=course=aiinfra --format '{{.Names}}' | grep -Ev '^aiinfra-lab(0[0-9]|1[1-9])-'; }
n=$(mine | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left (stack down, no rollout containers)" || fail C.1 "$n course container(s) still present: $(mine | tr '\n' ' ')"
if kind_up; then fail C.2 "kind cluster 'aiinfra' still exists"; else pass C.2 "no kind cluster"; fi
k=$(docker ps -a --filter label=io.x-k8s.kind.cluster=aiinfra -q | wc -l)
[ "$k" = 0 ] && pass C.3 "no kind node containers" || fail C.3 "$k kind node container(s) remain"
[ ! -e "$STATE" ] && pass C.4 "scenario state removed" || fail C.4 "$STATE still exists"
miss=""
for i in 1 2 3 4 5; do for f in "answers/$i-rootcause.env" "answers/$i-evidence.env" "postmortem-$i.md"; do [ -f "$LAB/$f" ] || miss="$miss $f"; done; done
[ -z "$miss" ] && pass C.5 "learner workspace lab/ intact" || fail C.5 "missing in lab/:$miss"
missing=""
for c in cli-proxy-api workout-mongo kali-cli; do docker ps -a --format '{{.Names}}' | grep -qx "$c" || missing="$missing $c"; done
[ -z "$missing" ] && pass C.6 "non-course containers untouched" || fail C.6 "non-course container(s) missing:$missing"
summary
