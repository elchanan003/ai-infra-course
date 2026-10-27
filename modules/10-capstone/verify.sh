#!/usr/bin/env bash
# 10-capstone verify.   usage: ./verify.sh [N]      (default: the incident prepare-lab.sh planted last)
#                             ./verify.sh --status  (your results so far)
# Five graded checks per incident:  N.1 durable fix / N.2 live behaviour (both restart the affected components from YOUR files first),
# N.3 root cause enum, N.4 evidence vs live data, N.5 postmortem.  Needs 2-8 minutes.  Wrap in platform/lab-session.sh if other course work runs.
# Simulated parts: the serving engines, GPUs and Kubernetes GPU capacity (see lab.md); real: gateway, Prometheus, registry, tripwire, scheduler.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$LIB/checks.sh"
for i in 1 2 3 4 5; do source "$LIB/inc$i.sh"; done

if [ "${1:-}" = "--status" ]; then
  for n in 1 2 3 4 5; do printf 'incident %s: %s\n' "$n" "$(cat "$STATE/result-$n" 2>/dev/null || echo 'not verified yet')"; done
  exit 0
fi
N="${1:-$(current)}"
case "$N" in 1|2|3|4|5) ;; *) echo "verify: no incident planted yet - run ./prepare-lab.sh N" >&2; exit 2;; esac
IDS=("$N.1" "$N.2" "$N.3" "$N.4" "$N.5")
block_all() { local i; for i in "${IDS[@]}"; do blocked "$i" "$1"; done; summary; }

# ---- preconditions (not scored) ---------------------------------------------------------------------
[ "$(current)" = "$N" ] || block_all "incident '$(current)' is the planted one, not $N - run ./prepare-lab.sh $N (or ./verify.sh $(current))"
[ -s "$STATE/$N/variant.env" ] || block_all "no hidden state for incident $N - run ./prepare-lab.sh $N"
case "$N" in
  5) precond "kind cluster aiinfra is up" kind_up || block_all "the kind cluster is not running - run ./prepare-lab.sh 5"
     precond "API server answers" k get nodes || block_all "kubectl cannot reach the cluster";;
  4) precond "tripwire reachable" wait_http "$TRIPWIRE_URL/health" 30 || block_all "profile store is not up - run ./prepare-lab.sh 4"
     precond "registry reachable" wait_http "$REGISTRY_URL/v2/" 30 || block_all "registry is not up - run ./prepare-lab.sh 4";;
  *) precond "Prometheus ready" wait_http "$PROM_URL/-/ready" 30 || block_all "profile obs is not up - run ./prepare-lab.sh $N";;
esac
precond "course Python venv" test -x "$PLATFORM_DIR/.venv/bin/python"
wait_idle 85 45 || block_all "host CPU is busy; timing-sensitive checks refuse to score - retry when it is quiet"

# ---- N.1 / N.2 : incident-specific ------------------------------------------------------------------
"verify_$N"
# ---- N.3 / N.4 / N.5 : never blocked ------------------------------------------------------------------
check_3 "$N"
check_4 "$N"
check_5 "$N"
save_result "$N"
summary
