#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
n=$(docker ps -aq --filter label=course=aiinfra | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left" || fail C.1 "$n course container(s) still present"
docker volume ls -q --filter label=course=aiinfra | grep -q openwebui-data && fail C.2 "Open WebUI data volume still present" || pass C.2 "Open WebUI volume removed"
missing=""; for c in cli-proxy-api workout-mongo kali-cli; do docker ps -a --format '{{.Names}}' | grep -qx "$c" || missing="$missing $c"; done
[ -z "$missing" ] && pass C.3 "non-course containers untouched" || fail C.3 "non-course container(s) missing:$missing"
lf=""; for f in provision.sh openwebui/connect.sh aider/run.sh aider/aider.env continue/config.yaml continue/replay.py answers/dissect.env env.sample; do [ -f "$LAB/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && pass C.4 "lab/ workspace files intact" || fail C.4 "lab files missing:$lf"
{ [ -d "$STATE" ] || [ -d "$LAB/aider/repo" ] || [ -f "$LAB/captured/agent-request.json" ]; } && fail C.5 "generated state still present" || pass C.5 "generated state removed"
summary
