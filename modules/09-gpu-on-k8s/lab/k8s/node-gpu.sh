#!/usr/bin/env bash
# Task 9.4 - simulate what the NVIDIA device plugin + GPU Feature Discovery do, for every node in the inventory.
# Inventory: $INVENTORY (default: inventory.txt next to this script). Context: kind-aiinfra.
# Must be idempotent and must work for ANY inventory content (counts, product strings), not only the shipped one.
set -euo pipefail
INV="${INVENTORY:-$(dirname "$0")/inventory.txt}"
k() { kubectl --context kind-aiinfra "$@"; }

# TODO: for each non-comment line "<node> <count> <product> <memory>":
#   - advertise nvidia.com/gpu in the node's status (capacity AND allocatable)
#   - label nvidia.com/gpu.product, nvidia.com/gpu.count, nvidia.com/gpu.memory
#   - taint nvidia.com/gpu=present:NoSchedule
echo "node-gpu.sh: not implemented" >&2
exit 1
