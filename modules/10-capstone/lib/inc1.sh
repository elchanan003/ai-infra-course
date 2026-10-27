#!/usr/bin/env bash
# Incident 1 - gateway: noisy agent key, shared team quota, per-replica counters.  Sourced by prepare-lab.sh / verify.sh.
# Real: LiteLLM x2 (:18040/:18041), Postgres, Valkey, Prometheus. Simulated: the serving engines behind it (mock-vllm A/B).

I1_CHAT_RESERVE=12     # policy printed on the page: chat keeps >= 12 req/min out of the team quota

page_1() {
  cat <<MSG
PAGE 1 - $(date -u +%H:%M) UTC  "Chat users get 429s and slow answers while one team is working"
  Chat users of the internal assistant report HTTP 429 and slow answers since the agents team started its nightly batch.
  Both gateway replicas are up (http://127.0.0.1:18040 and :18041), the engines behind them are healthy.
  Policy from the platform owner: the chat key must keep at least ${I1_CHAT_RESERVE} requests per minute of the team's quota.
  Your files: lab/incident-1/litellm/config.yaml (both replicas mount this directory) and lab/incident-1/keys.yaml
  (applied with the given lab/incident-1/apply-keys.sh). Tokens: lab/incident-1/keys.env. The team quota is platform policy (not yours).
  Restart both replicas after a config edit with the given lab/incident-1/restart.sh.
  $(win_text 1)
MSG
}

i1_write_files() {  # V TL
  local V="$1" TL="$2" d="$LAB/incident-1"
  mkdir -p "$d/litellm"
  cat > "$d/litellm/config.yaml" <<YAML
# Gateway config (yours) - mounted by BOTH replicas (litellm :18040, litellm-2 :18041).
# Restart both replicas after edits:  lab/incident-1/restart.sh   (never "stack.sh up" without the lab environment: it would switch the config dir back)
model_list:
  - model_name: chat
    litellm_params: {model: openai/chat, api_base: "http://mock-vllm-a:8000/v1", api_key: none}   # SIMULATED engine A
    model_info: {id: chat-a}
  - model_name: chat
    litellm_params: {model: openai/chat, api_base: "http://mock-vllm-b:8000/v1", api_key: none}   # SIMULATED engine B
    model_info: {id: chat-b}

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  proxy_batch_write_at: 5                      # lab-only (production: 60)

litellm_settings:
  callbacks: ["prometheus"]
  require_auth_for_metrics_endpoint: false     # lab-only

router_settings:
  routing_strategy: simple-shuffle
YAML
  cat > "$d/keys.yaml" <<YAML
# Key policy (yours): alias -> limits. Applied by ./apply-keys.sh (POST /key/update). null / absent = leave unlimited.
# Fields: rpm_limit, tpm_limit, max_parallel_requests.
keys:
  chat-$V:
    rpm_limit: null
    max_parallel_requests: null
  agent-$V:
    rpm_limit: null
    max_parallel_requests: null
YAML
  cat > "$d/keys.env" <<ENV
# GIVEN: tokens of the two keys of team ai-apps-$V (created by prepare-lab.sh; do not edit)
CHAT_ALIAS=chat-$V
CHAT_KEY=sk-cap1-chat-$V
AGENT_ALIAS=agent-$V
AGENT_KEY=sk-cap1-agent-$V
TEAM_ID=cap1-team-$V
ENV
  cat > "$d/apply-keys.sh" <<'SH'
#!/usr/bin/env bash
# GIVEN (do not edit). Applies keys.yaml to the gateway: POST /key/update for every alias listed. Idempotent.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
PY="$D/../../../../platform/.venv/bin/python"; [ -x "$PY" ] || PY=python3
exec "$PY" - "$D" <<'PYEOF'
import json, os, sys, urllib.request, yaml
d = sys.argv[1]
env = dict(l.strip().split("=", 1) for l in open(os.path.join(d, "keys.env")) if "=" in l and not l.startswith("#"))
tok = {env["CHAT_ALIAS"]: env["CHAT_KEY"], env["AGENT_ALIAS"]: env["AGENT_KEY"]}
gw = os.environ.get("LITELLM_URL", "http://127.0.0.1:18040"); master = os.environ.get("LITELLM_KEY", "sk-aiinfra-master")
spec = (yaml.safe_load(open(os.path.join(d, "keys.yaml"))) or {}).get("keys") or {}
rc = 0
for alias, lim in spec.items():
    if alias not in tok:
        print(f"apply-keys: unknown alias {alias}"); rc = 1; continue
    body = {"key": tok[alias]}
    for f in ("rpm_limit", "tpm_limit", "max_parallel_requests"):
        if isinstance(lim, dict) and lim.get(f) is not None:
            body[f] = int(lim[f])
    req = urllib.request.Request(gw + "/key/update", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + master, "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).read(); print(f"apply-keys: {alias} -> " + ", ".join(f"{k}={v}" for k, v in body.items() if k != "key"))
    except Exception as e:
        print(f"apply-keys: {alias} FAILED: {e}"); rc = 1
sys.exit(rc)
PYEOF
SH
  cat > "$d/restart.sh" <<'SH'
#!/usr/bin/env bash
# GIVEN (do not edit). Recreates both gateway replicas so they re-read lab/incident-1/litellm/config.yaml.
exec "$(cd "$(dirname "$0")/../.." && pwd)/lib/restart.sh" 1
SH
  chmod +x "$d/apply-keys.sh" "$d/restart.sh"
  chmod_pub "$d"
}

i1_plant_keys() {  # (re)create team + both keys in the planted state (no per-key limits). Uses variant.env of incident 1.
  local V TL team ck ak
  V=$(vget 1 V); TL=$(vget 1 TEAM_RPM); team="cap1-team-$V"; ck="sk-cap1-chat-$V"; ak="sk-cap1-agent-$V"
  gw_key POST /key/delete "{\"keys\":[\"$ck\",\"$ak\"]}" >/dev/null
  gw_key POST /team/delete "{\"team_ids\":[\"$team\"]}" >/dev/null
  gw_key POST /team/new "{\"team_id\":\"$team\",\"team_alias\":\"ai-apps-$V\",\"rpm_limit\":$TL,\"models\":[\"chat\"]}" >/dev/null
  gw_key POST /key/generate "{\"key\":\"$ck\",\"key_alias\":\"chat-$V\",\"team_id\":\"$team\",\"models\":[\"chat\"]}" >/dev/null
  gw_key POST /key/generate "{\"key\":\"$ak\",\"key_alias\":\"agent-$V\",\"team_id\":\"$team\",\"models\":[\"chat\"]}" >/dev/null
  [ "$(gw_key GET "/key/info?key=$ak" | jq -r '.info.team_id // empty')" = "$team" ]
}

plant_1() {
  local V TL old
  [ -s "$STATE/1/variant.env" ] && old=$(vget 1 V)
  V=$(rhex 3); TL=$(pick 30 36 42)
  state_write "$STATE/1/variant.env" V="$V" TEAM_RPM="$TL" OLD_V="${old:-}"
  i1_write_files "$V" "$TL"
  echo "prepare-lab: converging profiles gw gw2 mock obs (two gateway replicas, mock engines, Prometheus)"
  stack_up_inc 1 || die "stack did not come up healthy (platform/stack.sh status)"
  gw_wait "$GW1" 120 && gw_wait "$GW2" 120 || die "gateway replicas not healthy (platform/stack.sh logs litellm-2)"
  prom_ready 60 || die "Prometheus not ready"
  if [ -n "${old:-}" ]; then   # remove the previous variant's objects
    gw_key POST /key/delete "{\"keys\":[\"sk-cap1-chat-$old\",\"sk-cap1-agent-$old\"]}" >/dev/null
    gw_key POST /team/delete "{\"team_ids\":[\"cap1-team-$old\"]}" >/dev/null
  fi
  i1_plant_keys || die "could not create the team/keys"
  local CK="sk-cap1-chat-$V" AK="sk-cap1-agent-$V" U="$GW1,$GW2" T0 b1 f1 f2
  echo "prepare-lab: 30 s of normal chat traffic (your 'before')"
  T0=$(date +%s)
  b1=$("$PY" "$LIB/loadgen.py" --urls "$U" --key "$CK" --model chat --workers 1 --duration 30 --think-ms 1000 --tag base)
  [ "$(echo "$b1" | jq -r '.codes["429"] // 0')" = 0 ] || die "baseline already shows 429s: $b1"
  echo "prepare-lab: the agents team starts its batch (60 s)"
  local W0; W0=$(date +%s)
  "$PY" "$LIB/loadgen.py" --urls "$U" --key "$AK" --model chat --workers 3 --duration 60 --tag batch > "$STATE/1/agent.json" &
  f1=$!
  "$PY" "$LIB/loadgen.py" --urls "$U" --key "$CK" --model chat --workers 1 --duration 60 --think-ms 1500 --tag chat > "$STATE/1/chat.json" &
  f2=$!
  wait $f1 $f2
  local c429; c429=$(jq -r '.codes["429"] // 0' "$STATE/1/chat.json")
  [ "$c429" -ge 3 ] || die "the planted incident did not produce chat 429s (got $c429); is the team quota enforced on this gateway version? $(cat "$STATE/1/chat.json")"
  state_write "$STATE/1/truth.env" HEAVY_KEY_ALIAS="agent-$V" TEAM_RPM_LIMIT="$TL" CHAT_429_COUNT="$c429" LIMIT_SCOPE=per-replica
  win_set 1 "$W0" "$(date +%s)"
  page_1
}

verify_1() {  # sets results for 1.1 / 1.2
  local V TL CK AK team nonce="$(rhex 3)"
  V=$(vget 1 V); TL=$(vget 1 TEAM_RPM); CK="sk-cap1-chat-$V"; AK="sk-cap1-agent-$V"
  # --- reset keys to the planted state, restart BOTH replicas with the learner's files, re-apply keys.yaml
  inc_env 1
  "$P/stack.sh" up gw gw2 mock obs >/dev/null 2>&1
  local sane=1
  gw_wait "$GW1" 60 || sane=0
  [ "$sane" = 1 ] && i1_plant_keys
  recreate litellm litellm-2
  if ! { gw_wait "$GW1" 150 && gw_wait "$GW2" 150; }; then
    fail 1.1 "a gateway replica did not come back healthy with your config: $(svc_log_error litellm-2) (platform/stack.sh logs litellm-2)"
    blocked 1.2 "needs 1.1"; return
  fi
  local ap; ap=$("$LAB/incident-1/apply-keys.sh" 2>&1); local aprc=$?
  # --- 1.1 shared limit state: a fresh key with rpm_limit 3, 2 requests on replica 1 then 3 on replica 2
  local tk n200=0 n429=0 c i
  tk=$(gw_key POST /key/generate "$(jq -nc --arg a "verify-$nonce" '{key_alias:$a,models:["chat"],rpm_limit:3}')" | jq -r '.key // empty')
  if [ -z "$tk" ]; then fail 1.1 "could not create the probe key (gateway/DB problem)"; blocked 1.2 "needs 1.1"; return; fi
  for i in 1 2; do c=$(req_code "$GW1" "$tk" chat "scope $nonce $i"); [ "$c" = 200 ] && n200=$((n200+1)); [ "$c" = 429 ] && n429=$((n429+1)); done
  for i in 1 2 3; do c=$(req_code "$GW2" "$tk" chat "scope $nonce b$i"); [ "$c" = 200 ] && n200=$((n200+1)); [ "$c" = 429 ] && n429=$((n429+1)); done
  gw_key POST /key/delete "$(jq -nc --arg k "$tk" '{keys:[$k]}')" >/dev/null
  if [ "$aprc" != 0 ]; then
    fail 1.1 "keys.yaml could not be applied by apply-keys.sh: $(echo "$ap" | tail -2 | tr '\n' ' ')"
  elif [ "$n200" -gt 3 ]; then
    fail 1.1 "a key with rpm_limit 3 got $n200 x 200 across the two replicas: the counters are per replica - where does a limiter keep its state, and what must both replicas share? (theory 3.2)"
  elif [ "$n200" -lt 3 ]; then
    fail 1.1 "a key with rpm_limit 3 got only $n200 x 200 ($n429 x 429): the limiter is over-counting"
  else pass 1.1 "a key limit of 3 holds across both replicas after a restart with your config and keys.yaml"; fi
  if ! passed 1.1; then blocked 1.2 "needs 1.1"; return; fi
  # --- 1.2 live: agent flood vs chat in the same team window
  probe_chat_both() { [ "$(req_code "$GW1" "$CK" chat clear)" = 200 ] && [ "$(req_code "$GW2" "$CK" chat clear)" = 200 ] && [ "$(req_code "$GW1" "$AK" chat clear)" = 200 ]; }
  if ! within 75 probe_chat_both; then fail 1.2 "the chat key and the agent key could not both get a 200 within 75 s (quota window did not clear): something else keeps using the shared quota"; return; fi
  local a0=/tmp/cap1-a0.$$ a1=/tmp/cap1-a1.$$ b0=/tmp/cap1-b0.$$ b1=/tmp/cap1-b1.$$ ag ch
  snap_metrics A "$a0"; snap_metrics B "$b0"
  ag=$("$PY" "$LIB/loadgen.py" --urls "$GW1,$GW2" --key "$AK" --model chat --workers 1 --count $((TL+2)) --tag "ag$nonce")
  ch=$("$PY" "$LIB/loadgen.py" --urls "$GW1,$GW2" --key "$CK" --model chat --workers 1 --count 8 --tag "ch$nonce")
  snap_metrics A "$a1"; snap_metrics B "$b1"
  local pa pb tt ag200 ag429 ch200 e5
  pa=$("$PY" "$LIB/mq.py" p95 vllm:time_to_first_token_seconds "$a0" "$a1"); pb=$("$PY" "$LIB/mq.py" p95 vllm:time_to_first_token_seconds "$b0" "$b1")
  tt=$(awk -v a="$pa" -v b="$pb" 'BEGIN{print (a>b)?a:b}'); rm -f "$a0" "$a1" "$b0" "$b1"
  ag200=$(echo "$ag" | jq -r '.codes["200"] // 0'); ag429=$(echo "$ag" | jq -r '.codes["429"] // 0'); ch200=$(echo "$ch" | jq -r '.codes["200"] // 0')
  e5=$(echo "$ag $ch" | jq -rs '[.[].codes | to_entries[] | select(.key|test("^5|ERR")) | .value] | add // 0')
  local cap=$((TL - I1_CHAT_RESERVE)) msg=""
  [ "$e5" = 0 ] || msg+="$e5 request(s) failed with 5xx/transport errors; "
  [ "$ch200" = 8 ] || msg+="chat key got only $ch200/8 x 200 right after the agent flood - the noisy key still eats the shared quota; "
  [ "$ag429" -ge 1 ] || msg+="the agent flood was never rejected (0 x 429); "
  [ "$ag200" -le "$cap" ] || msg+="the agent key got $ag200 requests through in one window; policy leaves it at most $cap (team quota $TL minus the chat reserve $I1_CHAT_RESERVE); "
  [ "$ag200" -ge 3 ] || msg+="the agent key got only $ag200 x 200 - capped so low it is useless; "
  awk -v t="$tt" -v s="$SLO_TTFT_GW_S" 'BEGIN{exit !(t<=s)}' || msg+="engine TTFT p95 ${tt}s (virtual) is above the ${SLO_TTFT_GW_S}s SLO; "
  if [ -z "$msg" ]; then pass 1.2 "agent flood is capped inside the team quota, chat keeps its share (8/8 x 200), no 5xx, engine TTFT within the SLO"
    echo "~ agent $ag200 x 200 / $ag429 x 429 (cap $cap), TTFT p95 ${tt}s (virtual)"
  else fail 1.2 "${msg%; }"; echo "~ raw agent=$ag chat=$ch body429=$(curl -s --max-time 20 "$GW1/v1/chat/completions" -H "Authorization: Bearer $AK" -H 'Content-Type: application/json' -d '{"model":"chat","messages":[{"role":"user","content":"x"}]}' | cut -c1-300)"; fi
}
