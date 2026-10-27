#!/usr/bin/env bash
# Module 01 verify: executes your sizing.py, team_calc.py, prompt_template.py, bench.py and llama.env live.
# Starts its own llama-server containers (aiinfra-lab01-v-*), measures with counters, timing only as ratios.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; V="$MODULE_DIR/.state/variant.json"; CK="$MODULE_DIR/.lib/checks.py"
MODELS="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/models"
TMP="$(mktemp -d)"; trap 'docker ps -aq --filter name=aiinfra-lab01-v- | xargs -r docker rm -f >/dev/null 2>&1; rm -rf "$TMP"' EXIT
ALL=(1.1.1 1.1.2 1.1.3 1.1.4 1.2.1 1.2.2 1.2.3 1.3.1 1.3.2 1.3.3 1.4.1 1.4.2 1.4.3 1.5.1 1.5.2 1.5.3 1.5.4 1.6.1 1.6.2 1.6.3 1.6.4 1.7.1 1.7.2)
emit() { local st id msg; while read -r st id msg; do case "$st" in PASS) pass "$id" "$msg";; FAIL) fail "$id" "$msg";; esac; done; }
[ -s "$V" ] || { for id in "${ALL[@]}"; do blocked "$id" "run ./prepare-lab.sh first"; done; summary; }

start_llama() {  # NAME PORT MODEL CTX NP THREADS [LOGLV]
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" --label course=aiinfra --label module=01 -p "127.0.0.1:$2:8080" -v "$MODELS:/models:ro" "$LLAMACPP_IMAGE" \
    -m "/models/$3" --host 0.0.0.0 --port 8080 --metrics -c "$4" -np "$5" -t "$6" -lv "${7:-3}" >/dev/null 2>&1 && wait_http "http://127.0.0.1:$2/health" 90
}
stop_llama() { docker rm -f "$1" >/dev/null 2>&1; }
median() { python3 -c 'import sys,statistics;print(statistics.median([float(x) for x in sys.argv[1:]]))' "$@"; }

precond "stack llm answers" curl -fsS "$LLAMA_CHAT_URL/health" || { for id in "${ALL[@]}"; do blocked "$id" "environment not ready - run ./prepare-lab.sh"; done; summary; }
wait_idle 70 90 || { warn env "host CPU is busy; refusing to score (retry when idle)"; exit 2; }

# ---- 1.1 sizing.py / 1.2 / 1.6 / 1.7 (pure python) ---------------------------------------------
emit < <(python3 "$CK" sizing "$LAB/sizing.py" "$V")
emit < <(python3 "$CK" vram "$LAB/answers/vram.env" "$V")
emit < <(python3 "$CK" tp "$LAB/answers/tp.json" "$V")
python3 "$CK" calc "$LAB/team_calc.py" "$V" > "$TMP/calc.txt" 2>&1
emit < <(grep -E '^(PASS|FAIL) 1\.7\.1' "$TMP/calc.txt")
if passed 1.7.1; then emit < <(grep -E '^(PASS|FAIL) 1\.7\.2' "$TMP/calc.txt"); else blocked 1.7.2 "needs 1.7.1 (a CLI that prints wrong numbers is not a working contract)"; fi

# ---- 1.3 slots / batching (your llama.env, your bench.py) --------------------------------------
CTX=$(env_kv "$LAB/llama.env" CTX); NP=$(env_kv "$LAB/llama.env" PARALLEL); TH=$(env_kv "$LAB/llama.env" THREADS); MODEL=$(env_kv "$LAB/llama.env" MODEL)
if [ -z "$CTX" ] || [ -z "$NP" ] || [ ! -f "$MODELS/${MODEL:-x}" ]; then
  fail 1.3.1 "lab/llama.env is incomplete (CTX, PARALLEL, THREADS, MODEL must be set; MODEL must exist in ~/.cache/aiinfra-course/models)"
else
  U1="http://127.0.0.1:18121"
  if start_llama aiinfra-lab01-v-a 18121 "$MODEL" "$CTX" "$NP" "${TH:-4}"; then emit < <(python3 "$CK" slots "$U1" 1800)
  else fail 1.3.1 "llama-server did not start with your llama.env (ctx=$CTX parallel=$NP): docker logs aiinfra-lab01-v-a"; fi
  stop_llama aiinfra-lab01-v-a
fi
BATCH_OK=1
measure_pair() {  # prints "v1 l1 v4 l4" medians (verify's and your bench's) for PARALLEL=1 and 4
  local P res=() vv ll
  for P in 1 4; do
    start_llama aiinfra-lab01-v-b 18122 "$MODEL" "${CTX:-4096}" "$P" "${TH:-4}" || { echo "x x x x"; return; }
    local vs=() ls=() i
    for i in 1 2 3; do
      vv=$(python3 "$CK" measure "http://127.0.0.1:18122" 4 32 | jq -r .tokens_per_s)
      ll=$(python3 "$LAB/bench.py" --url "http://127.0.0.1:18122" --concurrency 4 --max-tokens 32 2>"$TMP/bench.err" | jq -r '.tokens_per_s // empty' 2>/dev/null)
      vs+=("$vv"); [ -n "$ll" ] && [ "$ll" != null ] && ls+=("$ll")
    done
    stop_llama aiinfra-lab01-v-b
    res+=("$(median "${vs[@]}")"); if [ ${#ls[@]} -ge 1 ]; then res+=("$(median "${ls[@]}")"); else res+=(x); fi
  done
  echo "${res[0]} ${res[1]} ${res[2]} ${res[3]}"
}
read -r v1 l1 v4 l4 <<<"$(measure_pair)"
ratio_ok() { python3 -c 'import sys; v1,l1,v4,l4=sys.argv[1:5]; f=float; print(1 if all(map(lambda a:a not in("x",""),[v1,l1,v4,l4])) and v4!="x" and f(l1)<=f(v1)*1.5 and f(l1)>=f(v1)/1.5 and f(l4)<=f(v4)*1.5 and f(l4)>=f(v4)/1.5 else 0)' "$v1" "$l1" "$v4" "$l4" 2>/dev/null; }
rv=$(python3 -c 'import sys;print(float(sys.argv[2])/float(sys.argv[1]))' "$v1" "$v4" 2>/dev/null)
if [ "$(ratio_ok)" != 1 ] || ! python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>1.2 else 1)' "${rv:-0}" 2>/dev/null; then
  read -r v1 l1 v4 l4 <<<"$(measure_pair)"; rv=$(python3 -c 'import sys;print(float(sys.argv[2])/float(sys.argv[1]))' "$v1" "$v4" 2>/dev/null)   # one retry
fi
if [ "$(ratio_ok)" = 1 ]; then pass 1.3.2 "your bench.py agrees with the counter-based throughput of verify's own load (within 1.5x)"
else fail 1.3.2 "bench.py output is missing or differs by more than 1.5x from the counter-based throughput (verify measured ${v1} tok/s at PARALLEL=1, ${v4} at 4; yours ${l1}, ${l4}); stderr: $(head -c 160 "$TMP/bench.err" | tr '\n' ' ')"; fi
if ! python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>1.2 else 1)' "${rv:-0}" 2>/dev/null; then
  blocked 1.3.3 "batching gain not observable right now (measured ratio ${rv:-?}); host noise - rerun when idle"
else
  emit < <(python3 - "$LAB/answers/batching.json" "$rv" <<'PY'
import json, sys
try: a = json.load(open(sys.argv[1]))
except Exception as e: print("FAIL 1.3.3 batching.json unreadable:", e); sys.exit()
rv = float(sys.argv[2]); r = a.get("ratio"); p1 = a.get("parallel1_tps"); p4 = a.get("parallel4_tps")
ok = all(isinstance(x, (int, float)) and x > 0 for x in (r, p1, p4)) and abs(r - p4 / p1) <= 0.05 * r and rv * 0.6 <= r <= rv * 1.6 and r > 1.2 and a.get("why") == "continuous_batching_shares_weight_reads"
print("PASS 1.3.3 ratio consistent with verify's own measurement and the reason is right" if ok else
      "FAIL 1.3.3 batching.json: ratio must equal parallel4_tps/parallel1_tps, lie within 0.6-1.6x of verify's measured ratio and why must name what makes concurrent decoding cheaper")
PY
  )
fi

# ---- 1.4 prompt cache -----------------------------------------------------------------------------
if start_llama aiinfra-lab01-v-c 18123 qwen2.5-0.5b-instruct-q4_k_m.gguf 4096 1 4; then
  emit < <(python3 "$CK" cache "http://127.0.0.1:18123" "$LAB/prompt_template.py" "$V" "$LAB/variant")
  emit < <(python3 "$CK" cacheans "http://127.0.0.1:18123" "$LAB/variant" "$LAB/answers/cache.json")
else fail 1.4.1 "verify's llama-server did not start"; fail 1.4.2 "verify's llama-server did not start"; fail 1.4.3 "verify's llama-server did not start"; fi
stop_llama aiinfra-lab01-v-c

# ---- 1.5 quantisation ------------------------------------------------------------------------------
Q4=$(env_kv "$LAB/variant/models.txt" Q4); Q8=$(env_kv "$LAB/variant/models.txt" Q8)
declare -A SP
for q in Q4 Q8; do
  f=${!q}
  start_llama "aiinfra-lab01-v-$q" 18124 "$f" 2048 1 4 4 && sleep 1
  docker logs "aiinfra-lab01-v-$q" >"$TMP/log-$q.txt" 2>&1
  python3 "$CK" logparse "$TMP/log-$q.txt" > "$TMP/parse-$q.json"
  SP[$q]=$(python3 "$CK" pspeed "http://127.0.0.1:18124" 3 | jq -r .tps)
  stop_llama "aiinfra-lab01-v-$q"
done
ratio=$(python3 -c 'import sys;print(float(sys.argv[2])/float(sys.argv[1]))' "${SP[Q4]}" "${SP[Q8]}" 2>/dev/null)
if ! python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>1.5 else 1)' "${ratio:-0}" 2>/dev/null; then   # retry once
  for q in Q4 Q8; do f=${!q}; start_llama "aiinfra-lab01-v-$q" 18124 "$f" 2048 1 4 4; SP[$q]=$(python3 "$CK" pspeed "http://127.0.0.1:18124" 3 | jq -r .tps); stop_llama "aiinfra-lab01-v-$q"; done
  ratio=$(python3 -c 'import sys;print(float(sys.argv[2])/float(sys.argv[1]))' "${SP[Q4]}" "${SP[Q8]}" 2>/dev/null)
fi
jq -n --argjson q4 "$(cat "$TMP/parse-Q4.json")" --argjson q8 "$(cat "$TMP/parse-Q8.json")" --argjson s4 "$(stat -c%s "$MODELS/$Q4")" --argjson s8 "$(stat -c%s "$MODELS/$Q8")" --arg r "${ratio:-}" \
  '{q4:$q4,q8:$q8,size_q4:$s4,size_q8:$s8,ratio:(if $r=="" then null else ($r|tonumber) end)}' > "$TMP/truth.json"
emit < <(python3 "$CK" quant "$LAB/answers/quant.json" "$TMP/truth.json")
summary
