#!/usr/bin/env bash
# 10-capstone cleanup: remove the runtime state of all incidents (rollout containers, lab key/team and registry artifact, kind cluster,
# compose stack, .state). Never touches lab/ (your files, answers, postmortems). Idempotent.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
docker ps -aq --filter label=course=aiinfra --filter label=module=10 | xargs -r docker rm -f >/dev/null 2>&1
docker rm -f aiinfra-lab10-rollout aiinfra-lab10-rollout-neg >/dev/null 2>&1
if curl -fsS --max-time 3 "$LITELLM_URL/health/liveliness" >/dev/null 2>&1; then      # lab keys and teams live in the gateway database (volume survives 'down')
  for v in $(env_kv "$STATE/1/variant.env" V) $(env_kv "$STATE/1/variant.env" OLD_V); do
    gw_key POST /key/delete "{\"keys\":[\"sk-cap1-chat-$v\",\"sk-cap1-agent-$v\"]}" >/dev/null 2>&1
    gw_key POST /team/delete "{\"team_ids\":[\"cap1-team-$v\"]}" >/dev/null 2>&1
  done
fi
if curl -fsS --max-time 3 "$REGISTRY_URL/v2/" >/dev/null 2>&1; then                  # the incident-4 release artifact
  d=$(curl -sI --max-time 5 -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$REGISTRY_URL/v2/cap4/rollout/manifests/release-2026-10" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [ -n "$d" ] && curl -fsS --max-time 10 -o /dev/null -X DELETE "$REGISTRY_URL/v2/cap4/rollout/manifests/$d" 2>/dev/null
fi
kind_up && "$P/k8s.sh" down >/dev/null 2>&1
"$P/stack.sh" down >/dev/null 2>&1
rm -rf "$STATE" "$CAP/.last-verify"
echo "cleanup: rollout containers, lab key/team, registry artifact, kind cluster and compose stack removed; scenario state cleared"
