#!/usr/bin/env bash
# GIVEN helper behind lab/incident-N/restart.sh: recreate the services of incident N so they re-read the learner's files
# (config dirs come from the incident environment, see lib/common.sh inc_env). Exits non-zero if a service is not healthy afterwards.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
N="${1:-}"
case "$N" in
  1) svcs="litellm litellm-2" ;;
  2) svcs="mock-vllm-a" ;;
  3) svcs="litellm" ;;
  *) echo "restart: nothing to restart for incident ${N:-?}" >&2; exit 2 ;;
esac
[ "$(current)" = "$N" ] || { echo "restart: incident $N is not the planted one (run ./prepare-lab.sh $N)" >&2; exit 1; }
inc_env "$N"
recreate $svcs
rc=0
for s in $svcs; do
  if svc_health "$s" 150; then echo "restart: $s healthy"; else echo "restart: $s NOT healthy: $(svc_log_error "$s")"; rc=1; fi
done
exit $rc
