#!/usr/bin/env bash
# Incident 2 - serving: KV exhaustion after a release.  Sourced by prepare-lab.sh / verify.sh.
# SIMULATED: the engine (mock-vllm A: Qwen2.5-7B geometry on a 24 GiB A10G with another process holding memory) - formulas in mock/README.md.
# Real: Prometheus scraping it, LiteLLM, the release-notes-and-flags workflow. Production differs: real vLLM on a real GPU, real CUDA OOM, minutes to restart.

I2_OUT_TOK=96            # output tokens per peak request
I2_PROMPT_CHARS=6000     # ~1,500 prompt tokens by the mock convention (4 chars/token); 4,800 of them are a shared system prefix
I2_PREFIX_CHARS=4800
I2_SEQ_TOK=1603          # prompt (1500 + framing) + output, tokens per sequence at the end of its life

page_2() {
  cat <<MSG
PAGE 2 - $(date -u +%H:%M) UTC  "Latency spikes at peak since yesterday's release"
  TTFT p95 is a multiple of the SLO during the daily peak since yesterday's release. Off-peak is fine. GPU utilisation looks fine.
  Your files: lab/incident-2/mock-vllm-a/args (the flags mock-vllm A starts with; gpu.yaml next to it is the GPU and is given).
  Context: lab/incident-2/RELEASE-NOTES.md, lab/incident-2/PEAK.md. Direct engine: http://127.0.0.1:18021 (metrics, /admin/stats); gateway model "mock-a".
  Restart the engine after editing args with the given lab/incident-2/restart.sh (the engine reads its flags only at start).
  $(win_text 2)
MSG
}

i2_args() {  # SEQS UTIL CACHE(on|off) -> args file content
  local seqs="$1" util="$2" cache="$3"
  cat <<ARGS
# vLLM flags of serving replica A (SIMULATED engine; flag semantics as vLLM 0.31).
--model /models/qwen2.5-7b
--served-model-name chat
--max-model-len 4096
--gpu-memory-utilization $util
--max-num-seqs $seqs
$([ "$cache" = off ] && echo "--no-enable-prefix-caching" || echo "# prefix caching: default (on)")
--uvicorn-log-level $([ "$cache" = off ] && echo warning || echo info)
$([ "$cache" = off ] && echo "--disable-log-stats")
--seed $([ "$cache" = off ] && echo 1234 || echo 0)
ARGS
}

i2_peak() {  # ENGINE_URL WORKERS ROUNDS TAG -> loadgen summary json
  "$PY" "$LIB/loadgen.py" --urls "$1" --key none --model chat --workers "$2" --count $(( $2 * $3 )) --prompt-chars $I2_PROMPT_CHARS \
        --prefix-chars $I2_PREFIX_CHARS --max-tokens $I2_OUT_TOK --timeout 240 --tag "$4"
}

plant_2() {
  local d="$LAB/incident-2" OTHER SEQS UTIL
  OTHER=$(pick 4.0 5.0 6.0); SEQS=$(pick 80 96 128)
  UTIL=$("$PY" -c "print(int(((24-$OTHER)/24-0.02)*100)/100)")
  mkdir -p "$d/mock-vllm-a" "$STATE/2"
  cat > "$d/mock-vllm-a/gpu.yaml" <<YAML
# GIVEN - the simulated GPU of replica A (do not edit; verify restores it). Another process on the node holds ${OTHER} GiB.
name: A10G
memory_gib: 24
count: 1
other_process_gib: $OTHER
YAML
  cp "$d/mock-vllm-a/gpu.yaml" "$STATE/2/gpu.yaml.golden"
  write_restart 2 "$d/restart.sh" "Recreates mock-vllm A so it re-reads lab/incident-2/mock-vllm-a/args."
  # baseline (sane) args -> capacity numbers
  i2_args 24 "$UTIL" on > "$STATE/2/args.base"
  i2_args "$SEQS" "$UTIL" off > "$STATE/2/args.planted"
  local cj kvtok fit peak
  cj=$("$PY" "$LIB/cap.py" "$STATE/2/args.planted" "$d/mock-vllm-a/gpu.yaml" "$CAP/../../mock/models/qwen2.5-7b")
  kvtok=$(echo "$cj" | jq -r '.kv_tokens // empty'); [ -n "$kvtok" ] || die "capacity model refused the planted flags: $cj"
  fit=$((kvtok / I2_SEQ_TOK)); peak=$(( (fit * 135 + 99) / 100 ))
  [ "$peak" -gt "$fit" ] && [ "$peak" -le "$SEQS" ] || die "variant numbers inconsistent (fit=$fit peak=$peak seqs=$SEQS)"
  state_write "$STATE/2/variant.env" OTHER="$OTHER" SEQS="$SEQS" UTIL="$UTIL" KVTOK="$kvtok" FIT="$fit" PEAK_C="$peak"
  cat > "$d/PEAK.md" <<MD
# Daily peak (given)
- ~${peak} concurrent chat requests at the top of the peak (14:30-15:10), each: ~1,500-token prompt, ${I2_OUT_TOK} output tokens.
- Prompts start with the same ~1,200-token system prefix (the assistant's instructions), then a user-specific part.
- SLO: TTFT p95 at or under ${SLO_TTFT_S} s (virtual seconds of the simulated engine, read from the histogram buckets; mock/README.md 3.6).
- Model: Qwen2.5-7B geometry (28 layers, 4 KV heads, head_dim 128, bf16 KV) on one 24 GiB GPU shared with another process.
- Operating rule: the KV cache must stay under 95 % at peak (alert KVCacheNearFull fires at 90 %).
MD
  cat > "$d/RELEASE-NOTES.md" <<MD
# Release 2026.10.26 - serving replica A (given)
Changes in the flags of replica A (all other flags unchanged):
| change | before | after | reason given in the PR |
|---|---|---|---|
| \`--max-num-seqs\` | 24 | $SEQS | "let the batch tenants run more requests in parallel" |
| prefix caching | default (on) | \`--no-enable-prefix-caching\` | "while we check a cache-correctness report" |
| \`--seed\` | 0 | 1234 | "reproducible evals" |
| \`--uvicorn-log-level\` | info | warning | "less log noise" |
| \`--disable-log-stats\` | - | added | "less log noise" |
Not changed: model, \`--max-model-len\`, \`--gpu-memory-utilization\` ($UTIL), the GPU, the traffic mix.
MD
  echo "prepare-lab: converging profiles gw mock obs (mock-vllm A starts from lab/incident-2/mock-vllm-a)"
  cp "$STATE/2/args.base" "$d/mock-vllm-a/args"; chmod_pub "$d" "$STATE/2"
  inc_env 2
  "$P/stack.sh" up gw mock obs >/dev/null 2>&1 || die "stack did not come up healthy with the baseline flags (platform/stack.sh status)"
  recreate mock-vllm-a; svc_health mock-vllm-a 60 || die "mock-vllm A not healthy with the baseline flags: $(svc_log_error mock-vllm-a)"
  prom_ready 60 || die "Prometheus not ready"
  echo "prepare-lab: off-peak traffic with the previous flags (your 'before', ~40 s)"
  local o; o=$(i2_peak "$MOCK_A_URL" 8 4 offpeak)
  [ "$(echo "$o" | jq -r '.codes["200"] // 0')" = 32 ] || die "baseline traffic failed: $o"
  sleep 10
  echo "prepare-lab: release 2026.10.26 is deployed, then the daily peak arrives"
  cp "$STATE/2/args.planted" "$d/mock-vllm-a/args"; chmod_pub "$d"
  recreate mock-vllm-a; svc_health mock-vllm-a 60 || die "mock-vllm A not healthy with the planted flags: $(svc_log_error mock-vllm-a)"
  sleep 12
  local W0 W1 pk; W0=$(date +%s); pk=$(i2_peak "$MOCK_A_URL" "$peak" 3 peak1)
  sleep 8; W1=$(date +%s)
  local st kv pre; st=$(mock_stats A)
  kv=$(echo "$st" | jq -r '(.engine.kv_peak_usage * 100) | round'); pre=$(echo "$st" | jq -r '.engine.preemptions')
  [ "$pre" -ge 1 ] || die "the planted incident did not preempt (preemptions=$pre kv_peak=$kv%): $pk"
  state_write "$STATE/2/truth.env" KV_PEAK_PCT="$kv" PREEMPTIONS="$pre" PLANTED_MAX_NUM_SEQS="$SEQS" KV_TOKENS="$kvtok"
  win_set 2 "$W0" "$W1"
  page_2
}

verify_2() {
  local d="$LAB/incident-2" peak seqs fit
  peak=$(vget 2 PEAK_C); fit=$(vget 2 FIT)
  cp "$STATE/2/gpu.yaml.golden" "$d/mock-vllm-a/gpu.yaml"; chmod_pub "$d"
  inc_env 2
  STACK_ALLOW_EXITED=1 "$P/stack.sh" up gw mock obs >/dev/null 2>&1
  recreate mock-vllm-a
  if ! svc_health mock-vllm-a 60; then
    fail 2.1 "mock-vllm A does not start from lab/incident-2/mock-vllm-a: $(svc_log_error mock-vllm-a) (platform/stack.sh logs mock-vllm-a)"
    blocked 2.2 "needs 2.1"; return
  fi
  local mm; mm=$(curl -fsS "$MOCK_A_URL/v1/models" 2>/dev/null | jq -r '[.data[] | select(.id=="chat") | .max_model_len] | first // 0')
  if [ "${mm:-0}" -lt 4096 ] 2>/dev/null; then
    fail 2.1 "the engine starts but serves chat with max_model_len ${mm:-?} (< 4096): clients' contract is 4,096 tokens - shrinking the window is not a fix"
    blocked 2.2 "needs 2.1"; return
  fi
  local cfgseq kvtok
  cfgseq=$(curl -fsS "$MOCK_A_URL/admin/stats" 2>/dev/null | jq -r '.capacity.max_num_seqs // empty')
  kvtok=$(curl -fsS "$MOCK_A_URL/admin/stats" 2>/dev/null | jq -r '.capacity.kv_cache_size_tokens // empty')
  if ! isint "$kvtok" || ! isint "$cfgseq"; then fail 2.1 "could not read the engine's KV capacity or your --max-num-seqs (kv=${kvtok:-?} seqs=${cfgseq:-?})"; blocked 2.2 "needs 2.1"; return; fi
  if [ $((cfgseq * I2_SEQ_TOK)) -gt "$kvtok" ]; then
    fail 2.1 "the engine admits up to $cfgseq sequences, each ending at ~${I2_SEQ_TOK} tokens (PEAK.md), but its KV cache holds only ${kvtok} tokens: admission is not sized to memory - what happens when all admitted sequences grow (module 01 maths)?"
    blocked 2.2 "needs 2.1"; return
  fi
  pass 2.1 "mock-vllm A restarts healthy from your args file, keeps the 4,096-token window, and admits only as many sequences as its KV cache holds at the peak length"
  local m0=/tmp/cap2-m0.$$ m1=/tmp/cap2-m1.$$ out
  snap_metrics A "$m0"
  out=$(i2_peak "$MOCK_A_URL" "$peak" 3 "v$(rhex 2)")
  sleep 6; snap_metrics A "$m1"
  local st kvp pre tt hits qs n200 ratio msg=""
  st=$(mock_stats A)
  kvp=$(echo "$st" | jq -r '(.engine.kv_peak_usage * 100) | round'); pre=$(echo "$st" | jq -r '.engine.preemptions')
  tt=$("$PY" "$LIB/mq.py" p95 vllm:time_to_first_token_seconds "$m0" "$m1")
  hits=$("$PY" "$LIB/mq.py" delta vllm:prefix_cache_hits_total "$m0" "$m1"); qs=$("$PY" "$LIB/mq.py" delta vllm:prefix_cache_queries_total "$m0" "$m1")
  rm -f "$m0" "$m1"
  n200=$(echo "$out" | jq -r '.codes["200"] // 0'); ratio=$(awk -v h="$hits" -v q="$qs" 'BEGIN{printf "%.2f", (q>0)?h/q:0}')
  [ "$n200" = $((peak*3)) ] || msg+="only $n200/$((peak*3)) peak requests answered 200; "
  [ "$pre" = 0 ] || msg+="$pre preemptions during the peak replay (the scheduler recomputed running sequences: KV memory ran out); "
  [ "$kvp" -lt 95 ] || msg+="KV cache peaked at ${kvp}% (rule: stay under 95%); "
  awk -v t="$tt" -v s="$SLO_TTFT_S" 'BEGIN{exit !(t<=s)}' || msg+="TTFT p95 ${tt}s (virtual) is above the ${SLO_TTFT_S}s SLO - look at where the time goes: queue or prefill; "
  local gc=0 i; for i in 1 2 3 4 5 6; do [ "$(req_code "$GW1" "$LITELLM_KEY" mock-a "gw $i")" = 200 ] && gc=$((gc+1)); done
  [ "$gc" = 6 ] || msg+="through the gateway only $gc/6 requests to model mock-a answered 200; "
  if [ -z "$msg" ]; then pass 2.2 "peak replay: all requests answered, 0 preemptions, KV cache under 95%, TTFT p95 within the SLO, gateway path healthy"
    echo "~ peak ${peak} concurrent: KV peak ${kvp}%, TTFT p95 ${tt}s (virtual), prefix hit ratio ${ratio}"
    awk -v r="$ratio" 'BEGIN{exit !(r>=0.5)}' || echo "[WARN] 2.2 prefix cache hit ratio ${ratio} on a workload that shares 80% of every prompt: prefix caching is a cheap TTFT win here"
  else fail 2.2 "${msg%; }"; fi
}
