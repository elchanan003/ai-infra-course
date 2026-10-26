#!/usr/bin/env bash
# Module 03 verifier. Every check launches the LEARNER's config in a throwaway mock-vllm container (simulated engine,
# real flag semantics) and measures behaviour. No scoring from file contents.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
source "$MOD/harness/mockrun.sh"
LAB="$MOD/lab"; H="$MOD/harness"; VJ="$MOD/.state/variant.json"
trap 'for n in v1 v2 v3 v4 v5 v6 v7 v8; do mockrun_stop $n; done' EXIT

pj() { python3 - "$@" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d)
PY
}
isnum() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
within_pct() { python3 -c "import sys; a,b,p=float(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]); sys.exit(0 if abs(a-b)<=abs(b)*p/100.0 else 1)" "$1" "$2" "$3"; }
chat_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$1/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"chat","max_tokens":8,"messages":[{"role":"user","content":"hello verify"}]}'; }
cap() { curl -s "http://127.0.0.1:$1/admin/stats" | python3 -c "import json,sys; print(json.load(sys.stdin)['capacity']['$2'])"; }
maxlen() { curl -s "http://127.0.0.1:$1/v1/models" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0].get('max_model_len',''))"; }
q95() { python3 - "$@" <<'PY'   # stdin: bucket json {le: cum}; args: quantile -> value lower upper
import json,sys
b=json.load(sys.stdin); qq=float(sys.argv[1])
items=sorted(((float(k) if k!='+Inf' else float('inf'),v) for k,v in b.items()))
tot=items[-1][1]; rank=qq*tot; pl,pc=0.0,0.0
for le,c in items:
    if c>=rank:
        v=pl+(le-pl)*(rank-pc)/(c-pc) if c>pc and le!=float('inf') else pl
        print(v,pl,le); break
    pl,pc=le,c
PY
}

precond "docker image aiinfra-mock:1.0 present" docker image inspect aiinfra-mock:1.0 >/dev/null
precond "variant seeded (prepare-lab.sh ran)" test -f "$VJ" || { echo "run ./prepare-lab.sh first"; summary; exit 1; }
precond "ports 18160-18169 free" bash -c '! ss -ltn 2>/dev/null | grep -qE ":1816[0-9]\b"'

# ------------------------------------------------------------------ 3.1 predictions vs live outcomes
P="$LAB/predict/PREDICT.env"; ok_a=1; ok_b=1; ph=0
for i in 1 2 3; do for k in OUTCOME KV_TOKENS MAX_LEN_FIT; do v=$(env_kv "$P" "${k}_$i"); [ -z "$v" ] || [ "$v" = REPLACE_ME ] && ph=1; done; done
if [ $ph = 1 ]; then
  fail 3.1a "PREDICT.env still has REPLACE_ME/empty values: predict all three configs before launching them"
  blocked 3.1b "needs 3.1a"
else
  for i in 1 2 3; do
    mockrun_start v1 "$LAB/predict/cfg-$i.args" "$LAB/predict/gpu.yaml" 0 18161
    out=$(mockrun_outcome v1 18161)
    want=$(env_kv "$P" "OUTCOME_$i")
    if [ "$out" != "$want" ]; then ok_a=0; echo "  (cfg-$i: you predicted '$want'; the engine disagrees. Checks run in order: free memory vs requested, weights, then KV pool vs ONE max_model_len sequence.)"; fi
    if [ "$out" = start ]; then
      live=$(cap 18161 kv_cache_size_tokens); pv=$(env_kv "$P" "KV_TOKENS_$i")
      isnum "$pv" && within_pct "$pv" "$live" 5 || { ok_b=0; echo "  (cfg-$i: KV_TOKENS off by more than 5%: did you include activations and non-torch memory?)"; }
    elif [ "$out" = fail-kv ]; then
      live=$(mockrun_fit v1); pv=$(env_kv "$P" "MAX_LEN_FIT_$i")
      isnum "$pv" && within_pct "$pv" "${live:-1}" 5 || { ok_b=0; echo "  (cfg-$i: MAX_LEN_FIT off by more than 5%: it is the KV pool divided by KV bytes per token)"; }
    fi
    mockrun_stop v1
  done
  [ $ok_a = 1 ] && pass 3.1a "all three outcomes predicted correctly" || fail 3.1a "at least one predicted outcome differs from the live startup: re-derive the startup checks from theory section 2-3"
  if [ $ok_a = 1 ]; then [ $ok_b = 1 ] && pass 3.1b "KV tokens / max length fit within 5% of the live values" || fail 3.1b "a KV number is off by >5%: recompute weights + activations + overhead (theory 2, cheatsheet vram-kv-math)"
  else blocked 3.1b "needs 3.1a"; fi
fi

# ------------------------------------------------------------------ 3.2 fix the KV startup error
floor=$(pj "$VJ" floor_a)
if mockrun_start v2 "$LAB/vllm-a/args" "$LAB/vllm-a/gpu.yaml" 20 18162 && [ "$(chat_code 18162)" = 200 ]; then
  pass 3.2a "vllm-a starts and serves a completion"
  ml=$(maxlen 18162); ut=$(curl -s http://127.0.0.1:18162/metrics | grep -o 'gpu_memory_utilization="[0-9.]*"' | head -1 | grep -o '[0-9.]*')
  if isnum "$ml" && [ "$ml" -ge "$floor" ] && python3 -c "import sys; sys.exit(0 if float('${ut:-9}')<=0.95 else 1)"; then
    pass 3.2b "max_model_len $ml >= floor and utilization $ut <= 0.95"
  else fail 3.2b "running instance has max_model_len=${ml:-?} (floor from slo/SLO.md) / utilization=${ut:-?} (limit 0.95): meet the product floor without exceeding the headroom limit; weights vs KV vs dtype are the levers"; fi
else
  fail 3.2a "vllm-a does not start (or does not answer a completion): $(mockrun_first_error v2 | cut -c1-160) (read the FIRST error in the log; see theory section 3)"
  blocked 3.2b "needs 3.2a"
fi
mockrun_stop v2

# ------------------------------------------------------------------ 3.3 eight concurrent, no preemption
if mockrun_start v3 "$LAB/vllm-b/args" "$LAB/vllm-b/gpu.yaml" 5 18163; then
  r=$(python3 "$H/load.py" --url http://127.0.0.1:18163 --preset task3 --params "$LAB/slo/load.json" --json)
  s200=$(echo "$r" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'].get('200',0))")
  pk=$(echo "$r" | python3 -c "import json,sys; print(int(json.load(sys.stdin)['peak_running']))")
  pre=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['preemptions'])")
  [ "$s200" = 8 ] && pass 3.3a "all 8 requests completed with 200" || fail 3.3a "only $s200/8 requests returned 200 (engine up but requests rejected/failed: max length vs prompt+max_tokens?)"
  [ "$pk" -ge 8 ] && pass 3.3b "peak running batch $pk >= 8" || fail 3.3b "peak num_requests_running was $pk (<8): something limits the batch: sequence cap or KV room for the prompts (theory section 4, 7)"
  [ "$pre" = 0 ] && pass 3.3c "no preemption" || fail 3.3c "$pre preemptions: running sequences outgrew the KV pool (theory section 6)"
else
  fail 3.3a "vllm-b does not start: $(mockrun_first_error v3 | cut -c1-160)"; blocked 3.3b "needs 3.3a"; blocked 3.3c "needs 3.3a"
fi
mockrun_stop v3

# ------------------------------------------------------------------ 3.4 p95 TTFT by hand
T="$LAB/answers/ttft.env"
pv=$(env_kv "$T" P95_TTFT_SECONDS); lo=$(env_kv "$T" BUCKET_LOWER); up=$(env_kv "$T" BUCKET_UPPER)
if ! isnum "$pv" || ! isnum "$lo" || ! isnum "$up"; then
  fail 3.4a "ttft.env has non-numeric/REPLACE_ME values"; blocked 3.4b "needs 3.4a"
elif mockrun_start v4 "$H/snapshot.args" "$H/snapshot.gpu.yaml" 0 18164 \
     && python3 "$H/load.py" --url http://127.0.0.1:18164 --preset snapshot --params "$LAB/slo/load.json" --seed 1 >/dev/null; then
  mkdir -p "$MOD/.state/run"; SN="$MOD/.state/run/verify-snap.prom"; curl -s http://127.0.0.1:18164/metrics > "$SN"
  buckets=$(python3 - "$SN" <<'PY'
import re,json,sys
b={}
for l in open(sys.argv[1]):
    if l.startswith('vllm:time_to_first_token_seconds_bucket{'):
        le=re.search(r'le="([^"]*)"',l).group(1); b[le]=b.get(le,0)+float(l.split()[-1])
print(json.dumps(b))
PY
)
  read -r tv tl tu <<<"$(echo "$buckets" | q95 0.95)"
  within_pct "$pv" "$tv" 10 && pass 3.4a "P95_TTFT_SECONDS within 10% of histogram_quantile on the snapshot" \
    || fail 3.4a "your p95 differs by >10% from histogram_quantile on the same buckets: find the bucket holding rank 0.95*count, then interpolate linearly inside it (theory 11)"
  if [ "$(python3 -c "print(int(abs(float('$lo')-float('$tl'))<1e-9 and abs(float('$up')-float('$tu'))<1e-9))")" = 1 ]; then
    pass 3.4b "BUCKET_LOWER/UPPER are the adjacent le values bracketing the p95"
  else fail 3.4b "BUCKET_LOWER/UPPER are not the neighbouring bucket boundaries around the quantile rank (use cumulative counts, not per-bucket counts)"; fi
else
  fail 3.4a "verify could not generate the snapshot scenario (mock error)"; blocked 3.4b "needs 3.4a"
fi
mockrun_stop v4

# ------------------------------------------------------------------ 3.5 KV pressure replay
PR="$LAB/answers/pressure.env"
kp=$(env_kv "$PR" KV_PEAK); pp=$(env_kv "$PR" PREEMPTIONS); lim=$(env_kv "$PR" LIMITER)
if mockrun_start v5 "$LAB/pressure/args" "$LAB/pressure/gpu.yaml" 20 18165; then
  r=$(python3 "$H/load.py" --url http://127.0.0.1:18165 --preset pressure --params "$LAB/slo/load.json" --json)
  tk=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['kv_peak_usage'])")
  tp=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['preemptions'])")
  tl=$([ "$tp" = 0 ] && echo seq-cap || echo kv)
  if isnum "$kp" && python3 -c "import sys; sys.exit(0 if abs(float('$kp')-float('$tk'))<=0.05 else 1)"; then pass 3.5a "KV_PEAK within 0.05 of the replay"; else fail 3.5a "KV_PEAK is not within 0.05 of what the scripted burst produces (peak of vllm:kv_cache_usage_perc, a 0..1 fraction)"; fi
  if isnum "$pp" && { [ "$tp" = 0 ] && [ "$pp" = 0 ] || { [ "$tp" != 0 ] && within_pct "$pp" "$tp" 30; }; }; then pass 3.5b "PREEMPTIONS matches the replay"; else fail 3.5b "PREEMPTIONS differs from the counter delta of the burst (vllm:num_preemptions_total before/after)"; fi
  [ "$lim" = "$tl" ] && pass 3.5c "LIMITER matches what bounded the burst" || fail 3.5c "LIMITER is wrong for this config/variant: compare running vs max_num_seqs, KV usage and preemptions at the peak (theory sections 6-8)"
else
  fail 3.5a "pressure scenario could not start (course infra problem)"; blocked 3.5b "needs 3.5a"; blocked 3.5c "needs 3.5a"
fi
mockrun_stop v5

# ------------------------------------------------------------------ 3.6 SLO tuning (median of 3 on virtual-time metrics)
if mockrun_start v6 "$LAB/slo/args" "$LAB/slo/gpu.yaml" 20 18166; then
  tps=(); itl=(); pre=0
  for i in 1 2 3; do
    r=$(python3 "$H/load.py" --url http://127.0.0.1:18166 --preset sweep --params "$LAB/slo/load.json" --seed 7 --json)
    read -r a b c <<<"$(echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin); t=d['itl_buckets']
print(round(d['generation_tokens_delta']/max(d['virtual_time_s'],1e-9),1), round(t['0.1']/t['+Inf'],4), d['preemptions'])")"
    tps+=("$a"); itl+=("$b"); pre=$(( pre > c ? pre : c ))
  done
  mt=$(printf '%s\n' "${tps[@]}" | sort -n | sed -n 2p); mi=$(printf '%s\n' "${itl[@]}" | sort -n | sed -n 2p)
  python3 -c "import sys; sys.exit(0 if float('$mi')>=0.95 else 1)" && pass 3.6a "p95 ITL within 0.1 s (attainment $mi)" || fail 3.6a "only $mi of inter-token gaps are <= 0.1 s: big prefill chunks / big batches stretch decode steps (theory section 4)"
  python3 -c "import sys; sys.exit(0 if float('$mt')>=1450 else 1)" && pass 3.6b "throughput $mt tok/s >= 1450" || fail 3.6b "throughput $mt tok/s is below the floor of 1450: the batch is too small to keep the GPU busy (theory section 9)"
  [ "$pre" = 0 ] && pass 3.6c "no preemption under the load" || fail 3.6c "preemptions occurred ($pre): the sequence cap exceeds what the fixed KV pool can hold for this load (theory sections 6, 9)"
  ut=$(cap 18166 gpu_memory_utilization); ml=$(cap 18166 max_model_len)
  [ "$ut" = 0.3 ] && [ "$ml" = 4096 ] && pass 3.6d "fixed platform settings untouched (utilization 0.30, max length 4096)" || fail 3.6d "utilization/max length were changed (got $ut / $ml): they are fixed for this shared GPU; tune the batch knobs only"
else
  fail 3.6a "slo/args does not start: $(mockrun_first_error v6 | cut -c1-160)"; blocked 3.6b "needs 3.6a"; blocked 3.6c "needs 3.6a"; blocked 3.6d "needs 3.6a"
fi
mockrun_stop v6

# ------------------------------------------------------------------ 3.8 troubleshooting: node-2
n2=$(pj "$VJ" node2_other); free=$(python3 -c "print(round((24-$n2)/24,4))")
if mockrun_start v7 "$LAB/vllm-t/args" "$LAB/vllm-t/gpu.node2.yaml" 20 18167 && [ "$(chat_code 18167)" = 200 ]; then
  pass 3.8a "vllm-t starts and serves on node-2"
  ut=$(cap 18167 gpu_memory_utilization)
  python3 -c "import sys; sys.exit(0 if float('$ut')<=float('$free')-0.02+1e-9 else 1)" && pass 3.8b "utilization $ut <= free fraction $free minus 0.02" || fail 3.8b "utilization $ut leaves less than 0.02 headroom below the free fraction $free of the node-2 GPU"
else
  fail 3.8a "vllm-t does not start on node-2: $(mockrun_first_error v7 | cut -c1-200)"; blocked 3.8b "needs 3.8a"
fi
mockrun_stop v7
if mockrun_start v8 "$LAB/vllm-t/args" "$LAB/vllm-t/gpu.node1.yaml" 20 18168 && [ "$(maxlen 18168)" = 8192 ]; then
  pass 3.8c "same args still start on node-1 with max_model_len 8192 unchanged"
else fail 3.8c "args do not start on node-1, or --max-model-len changed from 8192 (the fix must work on both nodes without touching the context length)"; fi
mockrun_stop v8

summary
