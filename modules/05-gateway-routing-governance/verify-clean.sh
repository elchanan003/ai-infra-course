#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
n=$(docker ps -aq --filter label=course=aiinfra | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left" || fail C.1 "$n course container(s) still present"
missing=""; for c in cli-proxy-api workout-mongo kali-cli; do docker ps -a --format '{{.Names}}' | grep -qx "$c" || missing="$missing $c"; done
[ -z "$missing" ] && pass C.2 "non-course containers untouched" || fail C.2 "non-course container(s) missing:$missing"
lf=""; for f in litellm/config.yaml provision.sh answers/spend.env answers/agent-limits.env; do [ -f "$LAB/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && pass C.3 "lab/ workspace files intact" || fail C.3 "lab files missing:$lf"
[ -d "$STATE" ] || [ -f "$LAB/PRICES.md" ] && fail C.4 "runtime state or generated files still present" || pass C.4 "runtime state and generated files removed"
summary
