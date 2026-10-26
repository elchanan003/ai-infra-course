#!/usr/bin/env bash
# Task 3.4: freeze a deterministic /metrics snapshot (sequential scenario on a scratch mock, no time pacing) into lab/answers/ttft.snapshot.prom
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/mockrun.sh"
H="$MOD_DIR/harness"
mockrun_start snap "$H/snapshot.args" "$H/snapshot.gpu.yaml" 0 18169 || { echo "snapshot: scratch mock failed to start"; mockrun_logs snap | tail -5; exit 1; }
python3 "$H/load.py" --url http://127.0.0.1:18169 --preset snapshot --params "$MOD_DIR/lab/slo/load.json" --seed 1 || exit 1
mkdir -p "$MOD_DIR/lab/answers"
curl -s http://127.0.0.1:18169/metrics > "${1:-$MOD_DIR/lab/answers/ttft.snapshot.prom}"
mockrun_stop snap
echo "wrote ${1:-lab/answers/ttft.snapshot.prom}"
