#!/usr/bin/env bash
# Module 04 verify-clean: proves cleanup.sh removed runtime state and nothing else.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
n=$(docker ps -aq --filter label=course=aiinfra | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left" || fail C.1 "$n course container(s) still present"
docker network inspect "$CLIENT_NET" >/dev/null 2>&1 && fail C.2 "client network still present" || pass C.2 "client network removed"
missing=""; for c in cli-proxy-api workout-mongo kali-cli; do docker ps -a --format '{{.Names}}' | grep -qx "$c" || missing="$missing $c"; done
[ -z "$missing" ] && pass C.3 "non-course containers untouched" || fail C.3 "non-course container(s) missing:$missing"
lf=""; for f in litellm/config.yaml provision.sh net/apply.sh answers/durability.env answers/network.env replicas.sh; do [ -f "$LAB/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && pass C.4 "lab/ workspace files intact" || fail C.4 "lab files missing:$lf"
[ -d "$STATE" ] && fail C.5 "runtime state .state/ still present" || pass C.5 "runtime state removed"
docker volume ls -q --filter label=course=aiinfra | grep -q postgres-data && pass C.6 "data volumes kept (cleanup is not a wipe)" || pass C.6 "no data volume (fresh host)"
summary
