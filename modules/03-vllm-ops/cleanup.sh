#!/usr/bin/env bash
# Remove runtime state of module 03 (containers it created). Never touches lab/.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
for c in $(docker ps -aq --filter label=lab=03-vllm-ops); do docker rm -f "$c" >/dev/null 2>&1; done
for n in aiinfra-mock-vllm-a-1 aiinfra-mock-vllm-b-1 aiinfra-mock-dcgm-a-1 aiinfra-mock-dcgm-b-1; do
  if [ -n "$(docker ps -aq --filter "name=^${n}\$" --filter label=course=aiinfra)" ]; then docker rm -f "$n" >/dev/null 2>&1; fi
done
rm -rf "$MOD/.state/run" "$MOD/.last-verify"
echo "cleanup: module 03 runtime state removed"
