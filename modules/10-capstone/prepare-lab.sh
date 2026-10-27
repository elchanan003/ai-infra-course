#!/usr/bin/env bash
# 10-capstone: plant incident N.   usage: ./prepare-lab.sh N     (N = 1..5; incidents are independent, re-running gives a fresh variant)
#   1-3: compose profiles gw (+gw2) mock obs     4: profile store     5: kind cluster (compose profiles are stopped)
# Writes lab/incident-N/ (your files + GIVEN helpers), plants the fault after a short healthy baseline, prints the page.
# Run through platform/lab-session.sh when other course work may run on this host. Never prints the hidden variant.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
for i in 1 2 3 4 5; do source "$LIB/inc$i.sh"; done
N="${1:-}"
case "$N" in 1|2|3|4|5) ;; *) echo "usage: $0 N   (N = 1..5)" >&2; exit 2;; esac
mkdir -p "$STATE"
avail=$(awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)
[ "${avail:-99}" -ge 6 ] || echo "prepare-lab: WARN only ${avail} GB RAM available (doctor warns below 6 GB)"
if [ -d "$LAB/incident-$N" ] && [ -n "$(ls -A "$LAB/incident-$N" 2>/dev/null)" ]; then   # keep the previous attempt
  b="$CAP/lab.bak-prepare-$(date +%Y%m%d%H%M%S)-$N"; mkdir -p "$b"; cp -a "$LAB/incident-$N" "$b/" 2>/dev/null
  echo "prepare-lab: previous lab/incident-$N saved to ${b#$CAP/}"
fi
rm -f "$STATE/current"
mkdir -p "$STATE/$N"
"plant_$N" || die "incident $N could not be planted"
echo "$N" > "$STATE/current"
echo
echo "prepare-lab: incident $N is live. Work in lab/incident-$N/ and lab/answers/$N-*.env, lab/postmortem-$N.md; then ./verify.sh $N"
