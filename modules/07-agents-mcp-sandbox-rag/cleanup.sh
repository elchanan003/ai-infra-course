#!/usr/bin/env bash
# Module 07 cleanup: remove sandbox containers, helper processes, runtime state, module Qdrant collections and the lab key; stack down.
# Never touches lab/ (except the generated lab/env.sh). Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
ST="$MODULE_DIR/.state"
docker ps -aq --filter label=course=aiinfra --filter label=module=07 | xargs -r docker rm -f >/dev/null 2>&1
docker ps -aq --filter label=course=aiinfra --filter name=sbx- | xargs -r docker rm -f >/dev/null 2>&1
if [ -d "$ST/pids" ]; then
  for f in "$ST"/pids/*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
fi
pkill -f "$MODULE_DIR/(\.verify|lab|\.tutor)/" 2>/dev/null || true
if curl -fsS --max-time 3 "$QDRANT_URL/collections" >/dev/null 2>&1; then
  for c in $(curl -fsS --max-time 5 "$QDRANT_URL/collections" | jq -r '.result.collections[].name' | grep -E '^v07-'); do
    curl -fsS -o /dev/null --max-time 10 -X DELETE "$QDRANT_URL/collections/$c" || true
  done
fi
curl -fsS -o /dev/null --max-time 5 "$LITELLM_URL/key/delete" -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
  -d '{"keys":["sk-lab07-student"]}' 2>/dev/null || true
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
rm -rf "$ST" "$MODULE_DIR/lab/env.sh" "$MODULE_DIR/.last-verify"
echo "cleanup: sandbox containers, helper processes, runtime state and lab key removed; stack down"
