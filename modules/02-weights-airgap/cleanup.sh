#!/usr/bin/env bash
# Module 02 cleanup: remove lab containers, the synthetic repo from the mirror cache, the local registry tags
# and the store volumes (S3 data, registry data) this module filled; stop the stack. Never touches lab/ or
# .state/variant.json. Idempotent. Label-scoped.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
docker ps -aq --filter name=aiinfra-lab02- --filter label=course=aiinfra | xargs -r docker rm -f >/dev/null 2>&1
docker ps -aq --filter label=course=aiinfra | while read -r c; do   # containers started from the internal registry
  case "$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)" in localhost:18050/aiinfra/*) docker rm -f "$c" >/dev/null 2>&1;; esac
done
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
for ref in $(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost:18050/aiinfra/' | grep -v ':<none>'); do docker rmi "$ref" >/dev/null 2>&1; done
for v in aiinfra_seaweedfs-data aiinfra_registry-data; do
  docker volume ls -q --filter label=course=aiinfra --filter "name=^${v}\$" | xargs -r docker volume rm >/dev/null 2>&1
done
HUB="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/hf/hub"
for d in "$HUB"/models--aiinfra-lab--tiny-*; do [ -e "$d" ] && rm -rf "$d"; done
rm -f /tmp/aiinfra-canary-*
rm -rf "$MODULE_DIR/.state/runtime"
echo "cleanup: lab containers, registry tags, store volumes and the synthetic mirror repo removed; stack down (lab/ untouched)"
