#!/usr/bin/env bash
# Validation helper: back up lab/, install the reference solution for the seeded variant (no manual steps), restart the stack mocks.
set -uo pipefail
MOD="$(cd "$(dirname "$0")/.." && pwd)"
source "$MOD/harness/mockrun.sh"
H="$MOD/harness"; LAB="$MOD/lab"
ts=$(date +%Y%m%d-%H%M%S); cp -a "$LAB" "$MOD/lab.bak-$ts"
SOL="$MOD/.tutor/solution/lab"; rm -rf "$SOL"; mkdir -p "$SOL"
python3 "$H/gen.py" solution "$SOL" || exit 1
# live-derived answers (what a learner measures): replay the scenarios exactly like verify does
mkdir -p "$SOL/answers"
mockrun_start s1 "$H/snapshot.args" "$H/snapshot.gpu.yaml" 0 18164 >/dev/null
python3 "$H/load.py" --url http://127.0.0.1:18164 --preset snapshot --params "$LAB/slo/load.json" --seed 1 >/dev/null
curl -s http://127.0.0.1:18164/metrics > "$MOD/.state/run/sol-snap.prom"; mockrun_stop s1
python3 - "$MOD/.state/run/sol-snap.prom" "$SOL/answers/ttft.env" <<'PY'
import re,sys
b={}
for l in open(sys.argv[1]):
    if l.startswith('vllm:time_to_first_token_seconds_bucket{'):
        le=re.search(r'le="([^"]*)"',l).group(1); b[le]=b.get(le,0)+float(l.split()[-1])
items=sorted(((float(k) if k!='+Inf' else float('inf'),v) for k,v in b.items()))
tot=items[-1][1]; rank=.95*tot; pl,pc=0.0,0.0
for le,c in items:
    if c>=rank:
        v=pl+(le-pl)*(rank-pc)/(c-pc); break
    pl,pc=le,c
open(sys.argv[2],'w').write(f"P95_TTFT_SECONDS={v:.4f}\nBUCKET_LOWER={pl}\nBUCKET_UPPER={le}\n")
PY
mockrun_start s2 "$LAB/pressure/args" "$LAB/pressure/gpu.yaml" 20 18165 >/dev/null
r=$(python3 "$H/load.py" --url http://127.0.0.1:18165 --preset pressure --params "$LAB/slo/load.json" --json); mockrun_stop s2
echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
lim='seq-cap' if d['preemptions']==0 else 'kv'
open('$SOL/answers/pressure.env','w').write(f\"KV_PEAK={d['kv_peak_usage']:.2f}\nPREEMPTIONS={d['preemptions']}\nLIMITER={lim}\n\")"
cp -a "$SOL"/. "$LAB"/
chmod -R a+rX "$LAB"
# solution-side apply: restart the stack mocks so they run the solved configs
for t in a b; do docker restart "aiinfra-mock-vllm-$t-1" >/dev/null 2>&1; done
echo "solution applied (backup: lab.bak-$ts)"
