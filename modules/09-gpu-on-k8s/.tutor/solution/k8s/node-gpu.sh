#!/usr/bin/env bash
# Simulated device plugin + GFD for every node in the inventory (SIMULATION: node-status patch).
set -euo pipefail
INV="${INVENTORY:-$(dirname "$0")/inventory.txt}"
k() { kubectl --context kind-aiinfra "$@"; }
while read -r node count product mem _; do
  [[ -z "${node:-}" || "$node" == \#* ]] && continue
  # extended resources live in status; "/" is escaped as "~1" in a JSON pointer. allocatable is what the scheduler reads.
  k patch node "$node" --subresource=status --type=json -p "[
    {\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"$count\"},
    {\"op\":\"add\",\"path\":\"/status/allocatable/nvidia.com~1gpu\",\"value\":\"$count\"}]" >/dev/null
  k label node "$node" --overwrite "nvidia.com/gpu.product=$product" "nvidia.com/gpu.count=$count" "nvidia.com/gpu.memory=$mem" >/dev/null
  k taint node "$node" --overwrite nvidia.com/gpu=present:NoSchedule >/dev/null
  echo "$node: nvidia.com/gpu=$count product=$product"
done < "$INV"
