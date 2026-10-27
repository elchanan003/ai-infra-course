#!/usr/bin/env bash
# Module 08 verifier.  ./verify.sh            tasks 8.1-8.6 (profiles gw llm mock obs)
#                      ./verify.sh langfuse   task 8.7 (profile lf alone + gw mock)
# Learner rules/queries are executed (promtool on synthetic series, Prometheus/Grafana APIs on live data), never grepped.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
LAB="$MOD/lab"; H="$MOD/harness"; RUN="$MOD/.state/run"; mkdir -p "$RUN"
MODE="${1:-main}"
cleanup_all() { for u in "$MOCK_A_URL" "$MOCK_B_URL"; do curl -s -m 3 -X DELETE "$u/admin/fault" >/dev/null 2>&1; done; [ -n "${LG_PID:-}" ] && kill "$LG_PID" 2>/dev/null; }
trap cleanup_all EXIT
pq() { python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
r=d.get('data',{}).get('result',[])
print(sum(float(x['value'][1]) for x in r) if r else '')
"; }
pval() { prom_query "$1" | pq; }
pmax() { prom_query "$1" | python3 -c "import json,sys; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(max(float(x['value'][1]) for x in r) if r else '')"; }
mkkey() { litellm_api /key/generate -d "{\"key_alias\":\"$1\",\"models\":[\"mock-a\",\"mock-b\",\"chat\"]}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))"; }

# ====================================================================== Langfuse gate
if [ "$MODE" = langfuse ]; then
  LF=http://127.0.0.1:18060; AUTH="pk-lf-aiinfra:sk-lf-aiinfra"
  precond "langfuse-web healthy" wait_http "$LF/api/public/health" 60
  precond "litellm healthy" wait_http "$LITELLM_URL/health/liveliness" 60
  precond "mock-vllm-a healthy" wait_http "$MOCK_A_URL/health" 30
  n=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'); user="nonce-user-$n"; prompt="langfuse check nonce-$n"
  body=$(python3 -c "import json; print(json.dumps({'model':'mock-a','max_tokens':16,'user':'$user','metadata':{'trace_name':'verify-$n'},'messages':[{'role':'user','content':'$prompt'}]}))")
  resp=$(litellm_api /v1/chat/completions -d "$body")
  usage=$(echo "$resp" | python3 -c "import json,sys; u=json.load(sys.stdin).get('usage',{}); print(u.get('prompt_tokens',''),u.get('completion_tokens',''))" 2>/dev/null)
  tid=""
  for i in $(seq 1 30); do
    t=$(curl -s -m 10 -u "$AUTH" "$LF/api/public/traces?userId=$user" | python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)
    [ -n "$t" ] && { tid="$t"; break; }; sleep 2
  done
  if [ -n "$tid" ]; then
    tr=$(curl -s -m 10 -u "$AUTH" "$LF/api/public/traces/$tid")
    echo "$tr" > "$RUN/lf-trace.json"
    model=$(echo "$tr" | python3 -c "import json,sys; o=json.load(sys.stdin).get('observations',[]); print(next((x.get('model') for x in o if x.get('model')),''))")
    [ -n "$model" ] && pass 8.7a "trace for the nonce user found in Langfuse (model $model)" || fail 8.7a "trace found but it has no model: is the callback sending generations?"
    echo "$tr" | python3 - "$n" "$usage" <<'PY' && pass 8.7b "trace input has the nonce prompt and token usage equals the response usage" || fail 8.7b "trace content/usage does not match the request: input must contain the prompt and usage must equal the response usage"
import json,sys
d=json.load(sys.stdin); n=sys.argv[1]; pt,ct=(sys.argv[2].split()+['',''])[:2]
blob=json.dumps(d.get('input'))+json.dumps([o.get('input') for o in d.get('observations',[])])
ok=n in blob
us=[o.get('usage') or {} for o in d.get('observations',[])]
good=any(str(u.get('input',u.get('promptTokens','')))==pt and str(u.get('output',u.get('completionTokens','')))==ct for u in us)
sys.exit(0 if ok and good else 1)
PY
  else
    fail 8.7a "no trace for user $user within 60 s: is success_callback set, were the LANGFUSE_* variables used, did LiteLLM restart? (ingestion is asynchronous: web -> S3/Redis -> worker -> ClickHouse)"
    blocked 8.7b "needs 8.7a"
  fi
  # failure callback: mock rejects with 500
  n2=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'); user2="nonce-user-$n2"
  mock_fault A POST '{"error_rate":1.0}' >/dev/null
  litellm_api /v1/chat/completions -d "{\"model\":\"mock-a\",\"max_tokens\":8,\"user\":\"$user2\",\"messages\":[{\"role\":\"user\",\"content\":\"fail $n2\"}]}" >/dev/null
  mock_fault A DELETE >/dev/null
  lvl=""
  for i in $(seq 1 30); do
    lvl=$(curl -s -m 10 -u "$AUTH" "$LF/api/public/traces?userId=$user2" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('data',[])
print('found' if d else '')" 2>/dev/null)
    [ -n "$lvl" ] && break; sleep 2
  done
  if [ -n "$lvl" ]; then
    t2=$(curl -s -m 10 -u "$AUTH" "$LF/api/public/traces?userId=$user2" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])")
    curl -s -m 10 -u "$AUTH" "$LF/api/public/traces/$t2" | python3 -c "import json,sys; o=json.load(sys.stdin).get('observations',[]); sys.exit(0 if any(str(x.get('level','')).upper()=='ERROR' or x.get('statusMessage') for x in o) else 1)" \
      && pass 8.7c "a failed request is traced as an error observation" || fail 8.7c "the failed request has a trace but no error-level observation"
  else fail 8.7c "a failed request produced no trace: is failure_callback set?"; fi
  summary; exit $?
fi

# ====================================================================== main gate
precond "prometheus ready" wait_http "$PROM_URL/-/ready" 30
precond "grafana ready" wait_http "$GRAFANA_URL/api/health" 30
precond "litellm healthy" wait_http "$LITELLM_URL/health/liveliness" 30
precond "mock-vllm A and B healthy" bash -c "curl -sf http://127.0.0.1:18021/health >/dev/null && curl -sf http://127.0.0.1:18022/health >/dev/null"
precond "variant seeded" test -f "$MOD/.state/variant.json" || { echo "run ./prepare-lab.sh first"; summary; exit 1; }
precond "no leftover faults" bash -c "curl -s -X DELETE http://127.0.0.1:18021/admin/fault >/dev/null; curl -s -X DELETE http://127.0.0.1:18022/admin/fault >/dev/null"
curl -s -m 10 -X POST "$PROM_URL/-/reload" >/dev/null; sleep 3   # verify reloads Prometheus for you

# ---- own warm traffic: two keys through the gateway, direct engine traffic, one llama.cpp request
K1=$(mkkey "vk-a-$$"); K2=$(mkkey "vk-b-$$")
python3 "$H/loadgen.py" --url "$LITELLM_URL" --model mock-a --key "$K1" --n 12 --concurrency 2 --max-tokens 32 --prompt-tokens 150 --tag va >/dev/null
python3 "$H/loadgen.py" --url "$LITELLM_URL" --model mock-b --key "$K2" --n 12 --concurrency 2 --max-tokens 32 --prompt-tokens 150 --tag vb >/dev/null
python3 "$H/loadgen.py" --url "$MOCK_A_URL" --model chat --n 30 --concurrency 3 --max-tokens 48 --prompt-tokens 400 --tag da >/dev/null
python3 "$H/loadgen.py" --url "$MOCK_B_URL" --model chat --n 30 --concurrency 3 --max-tokens 48 --prompt-tokens 1500 --tag db >/dev/null
litellm_code "$K1" chat "hello llama" >/dev/null
sleep 20   # >= 4 scrapes after the traffic so rate()/histograms have data

# ---- 8.1 scrape
tj=$(curl -s -m 10 "$PROM_URL/api/v1/targets?state=active")
up_of() { echo "$tj" | python3 -c "import json,sys; t=json.load(sys.stdin)['data']['activeTargets']; print(sum(1 for x in t if x['labels'].get('job')=='$1' and x['health']=='up'))"; }
uv=$(up_of vllm); ul=$(up_of litellm); uc=$(up_of llamacpp)
if [ "$uv" = 2 ] && [ "$ul" = 1 ] && [ "$uc" = 1 ]; then pass 8.1a "targets up: vllm=2 litellm=1 llamacpp=1"
else fail 8.1a "targets up: vllm=$uv (want 2) litellm=$ul (want 1) llamacpp=$uc (want 1); check job names, the LiteLLM metrics path (307 redirect), and Status > Targets"; fi
rep=$(prom_query 'count by (replica) (vllm:kv_cache_usage_perc)' | python3 -c "import json,sys; print(','.join(sorted(x['metric'].get('replica','') for x in json.load(sys.stdin)['data']['result'])))")
lc=$(pval 'count(litellm_proxy_total_requests_metric_total)'); cc=$(pval 'count(llamacpp:tokens_predicted_total)')
if [ "$rep" = "a,b" ] && [ -n "$lc" ] && [ -n "$cc" ]; then pass 8.1b "replica labels a,b present; LiteLLM and llama.cpp series exist"
else fail 8.1b "series check: replica labels='$rep' (want a,b), litellm requests series='${lc:-none}', llamacpp tokens series='${cc:-none}'"; fi

# ---- promtool test files for 8.2/8.4 (learner rule files, verify's synthetic series)
python3 "$H/gentests.py" "$RUN" ../.. || { echo "gentests failed"; exit 1; }
runtest() { local f="$1"; PROMTOOL_MOUNT="$MOD" promtool_test "$RUN/$f" > "$RUN/$f.out" 2>&1; }
if runtest rec.test.yml; then pass 8.2a "recording rules produce the expected p95 TTFT/ITL and token rate on synthetic series"
else fail 8.2a "recording-rule test failed ($(grep -m1 -iE 'error|fail|no such file|expected' "$RUN/rec.test.yml.out" | cut -c1-150)): combine replicas first (sum by (le,...) of rate), quantile last; names must match the lab spec"; fi
# recorded sample and direct query are evaluated at different instants: compare both from the same stable window, up to 4 tries
okb=0
for _ in 1 2 3 4; do
  r1=$(pmax 'model:vllm_ttft_seconds:p95_5m'); r2=$(pmax 'histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))')
  if [ -n "$r1" ] && [ -n "$r2" ] && python3 -c "import sys; a,b=float('$r1'),float('$r2'); sys.exit(0 if abs(a-b)<=0.2*max(b,1e-9) else 1)"; then okb=1; break; fi
  sleep 6
done
if [ $okb = 1 ]; then pass 8.2b "live recorded p95 TTFT matches the direct quantile (same window)"
else fail 8.2b "live recorded series ${r1:-missing} vs direct quantile ${r2:-missing}: is the rule loaded (Prometheus /rules) and evaluating without errors?"; fi

# ---- 8.3 dashboard
dc=$(python3 "$H/dashcheck.py" "$GRAFANA_URL" "$GRAFANA_AUTH" ai-serving)
echo "$dc" > "$RUN/dash.json"
want=("TTFT p95" "ITL p95" "Tokens per second" "Queue (waiting/running)" "KV cache usage" "Preemptions" "Spend per key")
miss=$(echo "$dc" | python3 -c "
import json,sys
d=json.load(sys.stdin)
w=['TTFT p95','ITL p95','Tokens per second','Queue (waiting/running)','KV cache usage','Preemptions','Spend per key']
if 'error' in d: print('ERR:'+d['error'])
else: print(','.join(x for x in w if x not in d['panels']))")
if [ -z "$miss" ]; then pass 8.3a "dashboard 'ai-serving' provisioned with all seven panels"; else fail 8.3a "dashboard problem: ${miss#ERR:} (uid must stay 'ai-serving'; panel titles exact; Grafana reloads provisioned files every ~10 s)"; fi
if [ -z "$miss" ]; then
  bad=$(echo "$dc" | python3 -c "
import json,sys
d=json.load(sys.stdin)['panels']
bad=[f\"{t} ({p['error'] or 'no data'})\" for t,p in d.items() if p['queries']==0 or p['error'] or p['frames']==0]
print('; '.join(bad))")
  [ -z "$bad" ] && pass 8.3b "every panel query returns data" || fail 8.3b "panels without data: $bad"
  echo "$dc" | python3 -c "
import json,sys
d=json.load(sys.stdin)['panels']
ok=d['Spend per key']['frames']>=2 and d['KV cache usage']['max'] is not None and d['KV cache usage']['max']<=1.0
sys.exit(0 if ok else 1)" && pass 8.3c "Spend per key has one series per key; KV values are within 0..1" \
    || fail 8.3c "Spend per key must split by key alias (two keys were used) and KV cache usage must be the 0..1 fraction, not scaled"
else blocked 8.3b "needs 8.3a"; blocked 8.3c "needs 8.3a"; fi

# ---- 8.4 alert rules (promtool) + live fire
runtest kv.test.yml && pass 8.4a "KVCacheNearFull fires with queue/preemption, quiet for KV 0.95 alone" || fail 8.4a "KVCacheNearFull test failed ($(grep -m1 -iE 'error|fail|no such file|expected' "$RUN/kv.test.yml.out" | cut -c1-150)): it must need BOTH high KV and (queue or preemptions); labels severity=warning team=llm-platform; for: 2m"
runtest ttft.test.yml && pass 8.4b "TTFTHigh fires only after its for-duration, quiet below the SLO" || fail 8.4b "TTFTHigh test failed ($(grep -m1 -iE 'error|fail|no such file|expected' "$RUN/ttft.test.yml.out" | cut -c1-150)): SLO 1 s, for 2m, severity=critical team=llm-platform"
runtest queue.test.yml && pass 8.4c "QueueGrowing fires at waiting=8 for 3m, quiet at 3 and for a 1-minute spike" || fail 8.4c "QueueGrowing test failed ($(grep -m1 -iE 'error|fail|no such file|expected' "$RUN/queue.test.yml.out" | cut -c1-150)): threshold 5, for 3m, severity=warning"
# live: pin KV on A and keep a heavy load running
curl -s -X POST "$MOCK_A_URL/admin/fault" -H 'Content-Type: application/json' -d '{"kv_pressure":0.97}' >/dev/null
python3 "$H/loadgen.py" --url "$MOCK_A_URL" --model chat --concurrency 40 --duration 330 --prompt-tokens 1500 --max-tokens 400 --tag live >/dev/null 2>&1 &
LG_PID=$!
fired=0; t0=$(date +%s); ann=""
while [ $(( $(date +%s) - t0 )) -lt 240 ]; do
  a=$(curl -s -m 5 "$PROM_URL/api/v1/alerts" | python3 -c "
import json,sys
al=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels'].get('alertname')=='KVCacheNearFull' and x['state']=='firing']
print(json.dumps(al[0]['annotations']) if al else '')" 2>/dev/null)
  [ -n "$a" ] && { fired=1; ann="$a"; break; }
  sleep 4
done
if [ $fired = 1 ]; then pass 8.4d "KVCacheNearFull fired live under kv_pressure + load"
else fail 8.4d "KVCacheNearFull did not fire within 240 s of kv_pressure + queueing load: check the rule is loaded, the expression sees vllm:kv_cache_usage_perc > 0.9 and waiting/preemptions, and for: is 2m"; fi
if [ $fired = 1 ]; then
  echo "$ann" | python3 -c "
import json,sys,re
a=json.load(sys.stdin); s=a.get('summary',''); r=a.get('runbook_url','')
sys.exit(0 if re.search(r'\d',s) and r.startswith('http') else 1)" && pass 8.4e "rendered annotations: summary contains the value, runbook_url is http(s)" || fail 8.4e "annotations: summary must render the value (template \$value) and runbook_url must be an http(s) URL"
else blocked 8.4e "needs 8.4d"; fi
kill "$LG_PID" 2>/dev/null; wait "$LG_PID" 2>/dev/null; LG_PID=""
curl -s -X DELETE "$MOCK_A_URL/admin/fault" >/dev/null
resolved=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 150 ]; do
  n=$(curl -s -m 5 "$PROM_URL/api/v1/alerts" | python3 -c "import json,sys; print(sum(1 for x in json.load(sys.stdin)['data']['alerts'] if x['labels'].get('alertname')=='KVCacheNearFull' and x['state']=='firing'))")
  [ "$n" = 0 ] && { resolved=1; break; }; sleep 5
done
[ $fired = 1 ] && { [ $resolved = 1 ] && pass 8.4f "alert resolved after the fault and load were removed" || fail 8.4f "alert still firing 150 s after the fault was removed: the expression should clear when KV drops or queue/preemptions stop"; } || blocked 8.4f "needs 8.4d"

# ---- 8.5 token reconciliation (verify runs fresh traffic, then executes YOUR reconcile.sh)
# the 8.4 live load was killed client-side; wait until engine A has drained before opening the measurement window
for _ in $(seq 1 60); do
  busy=$(pval 'sum(vllm:num_requests_running{replica="a"}) + sum(vllm:num_requests_waiting{replica="a"})')
  [ "${busy:-1}" = 0 ] && break; sleep 3
done
sleep 12
python3 "$H/traffic.py" > "$RUN/traffic.out" 2>&1; read -r _ < "$RUN/traffic.out"
S=$(sed -n 's/.*START=\([0-9]*\).*/\1/p' "$RUN/traffic.out" | tail -1); E=$(sed -n 's/.*END=\([0-9]*\).*/\1/p' "$RUN/traffic.out" | tail -1); AL=$(sed -n 's/.*KEY_ALIAS=\([^ ]*\).*/\1/p' "$RUN/traffic.out" | tail -1)
if [ -z "$S" ]; then fail 8.5a "verify traffic run failed: $(tail -1 "$RUN/traffic.out" | cut -c1-120)"; blocked 8.5b "needs 8.5a"; blocked 8.5c "needs 8.5a"
else
  rec=$(grep "\"alias\": \"$AL\"" "$MOD/.state/traffic-runs.jsonl" | tail -1)
  rv() { echo "$rec" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
  now=$(date +%s); [ $now -lt $((E + 14)) ] && sleep $((E + 14 - now))   # scrapes after the run
  precond "spend logs flushed" litellm_flush_wait "$(rv key)" "$(rv n)" 40
  out=$(cd "$MOD" && timeout 120 bash lab/reconcile.sh "$S" "$E" "$AL" 2>"$RUN/reconcile.err"); echo "$out" > "$RUN/reconcile.out"
  g() { echo "$out" | sed -n "s/^$1=//p" | tail -1; }
  gw=$(g GATEWAY_TOKENS); pg=$(g PROM_GATEWAY_TOKENS); en=$(g ENGINE_TOKENS); cause=$(g GAP_CAUSE); byp=$(g BYPASS_REQUESTS)
  tg=$(rv gateway_tokens); te=$(rv engine_tokens); tb=$(rv bypass)
  ok() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && python3 -c "import sys; a,b,p=float('$1'),float('$2'),float('$3'); sys.exit(0 if abs(a-b)<=p/100*b else 1)"; }
  if ok "$gw" "$tg" 2 && ok "$pg" "$tg" 3; then pass 8.5a "gateway tokens (spend logs and Prometheus counters) match the run"
  else fail 8.5a "gateway tokens: spend logs='${gw:-?}' prometheus='${pg:-?}' (reconcile.sh must print numbers for THIS window; the key alias is unique to the run; spend logs are batch-written)"; fi
  if ok "$en" "$te" 3; then pass 8.5b "engine tokens match the run"; else fail 8.5b "engine tokens '${en:-?}' do not match the run: use the difference of the counter between the window edges (increase() extrapolates), engine A only"; fi
  if [ "$cause" = bypass ] && [ "$byp" = "$tb" ]; then pass 8.5c "gap explained: bypass traffic, exact request count"
  else fail 8.5c "GAP_CAUSE='${cause:-?}' BYPASS_REQUESTS='${byp:-?}': engine tokens exceed gateway tokens; work out what produces engine traffic the gateway never saw, and how many requests it takes (tokens per gateway request is in the spend logs)"; fi
fi

# ---- 8.6 flat TTFT panel (promtool on synthetic series, learner's panel query)
pe=$(python3 "$H/dashcheck.py" "$GRAFANA_URL" "$GRAFANA_AUTH" ai-serving --panel-expr "TTFT p95" 2>/dev/null)
if [ -z "$pe" ]; then fail 8.6a "panel 'TTFT p95' not found or has no query"; blocked 8.6b "needs 8.6a"
else
  PANEL_EXPR="$pe" python3 "$H/gentests.py" "$RUN" ../.. >/dev/null
  runtest panel.a.test.yml && pass 8.6a "TTFT panel query returns the true p95 on steady synthetic data" || fail 8.6a "TTFT panel query does not match the p95 of the synthetic histogram (within 10%): a mean or an average of sums is not a quantile; aggregate buckets with sum by (le) and use histogram_quantile (theory section 3)"
  runtest panel.b.test.yml && pass 8.6b "panel stays low when healthy and rises >2 s when 20% of requests turn slow" || fail 8.6b "panel does not react to a tail slowdown: lifetime counters and averages hide it; use a rate window over buckets"
fi
summary
