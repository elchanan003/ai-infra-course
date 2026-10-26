#!/usr/bin/env bash
# Tutor/validation only: back up lab/ to lab.bak-<ts>/, copy the reference solution over it, fill the variant-bound answers
# from .state/variant.env and reload Prometheus. No manual steps. Needs prepare-lab.sh A to have run (variant + stack).
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOL="$MODULE_DIR/.tutor/solution"; LAB="$MODULE_DIR/lab"
[ -s "$MODULE_DIR/.state/variant.env" ] || { echo "apply-solution: run ./prepare-lab.sh A first (variant missing)" >&2; exit 1; }
set -a; . "$MODULE_DIR/.state/variant.env"; set +a
ts=$(date +%Y%m%d-%H%M%S%N | cut -c1-24)
cp -a "$LAB" "$MODULE_DIR/lab.bak-$ts"
cp -a "$SOL/." "$LAB/"
if [ "$XID_ACTION" = wait ]; then
  XID_REASON="XID $XID_CODE is application-class: restart or investigate the workload and watch for recurrence, no hardware action yet"
else
  XID_REASON="XID $XID_CODE is hardware-class (ECC, bus or link): cordon and drain the node, check replicas and PDB first, then open a hardware ticket"
fi
for f in "$LAB/answers/smi.env" "$LAB/answers/xid.env"; do
  sed -i -e "s|@HOT_IDX@|$HOT_IDX|; s|@HOT_UUID@|$HOT_UUID|; s|@HOT_MEM@|$HOT_MEM|; s|@HOT_POWER@|$HOT_POWER|" \
         -e "s|@XID_CODE@|$XID_CODE|; s|@XID_NODE@|$XID_NODE|; s|@XID_UUID@|$XID_UUID|; s|@XID_ACTION@|$XID_ACTION|; s|@XID_REASON@|$XID_REASON|" "$f"
done
chmod +x "$LAB/k8s/node-gpu.sh"; chmod -R a+rX "$LAB/prometheus"
"$MODULE_DIR/../../platform/stack.sh" reload-prometheus >/dev/null 2>&1 || true
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts)"
