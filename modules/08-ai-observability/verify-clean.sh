#!/usr/bin/env bash
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
f=$(curl -s -m 3 http://127.0.0.1:18021/admin/fault 2>/dev/null)
if [ -z "$f" ] || echo "$f" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not any(d.get(k) for k in ('latency_ms','error_rate','kv_pressure','crash')) else 1)"; then
  pass C.1 "no mock faults left"; else fail C.1 "a mock fault is still set"; fi
[ ! -d "$MOD/.state/run" ] && [ ! -f "$MOD/.state/traffic-runs.jsonl" ] && pass C.2 "scratch state removed" || fail C.2 "scratch state still present"
[ -d "$MOD/lab/prometheus" ] && pass C.3 "lab/ untouched" || fail C.3 "lab/ content missing"
summary
