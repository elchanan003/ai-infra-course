#!/usr/bin/env bash
# Module 04 verify: checks LIVE gateway behaviour against lab.md. Restarts the gateway, bursts requests, runs your provision.sh,
# temporarily swaps in a control config (4.5.3) and restores yours. ~6-8 min with a complete solution.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ALL_IDS=(4.1.1 4.1.2 4.1.3 4.1.4 4.2.1 4.2.2 4.2.3 4.2.4 4.3.1 4.3.2 4.3.3 4.3.4 4.4.1 4.4.2 4.4.3 4.4.4 4.5.1 4.5.2 4.5.3 4.5.4 4.6.1 4.6.2 4.7.1 4.7.2 4.7.3 4.8.1 4.8.2 4.8.3 4.8.4)
block_all() { for id in "${ALL_IDS[@]}"; do blocked "$id" "$1"; done; summary; }

# ---------------------------------------------------------------- preconditions (not scored)
precond "gateway live" wait_http "$GW/health/liveliness" 30 || block_all "gateway not running - run ./prepare-lab.sh"
[ "$(mounted_cfg)" = "$LAB/litellm" ] || block_all "gateway is not using $LAB/litellm - run ./prepare-lab.sh"
[ -f "$STATE/seed.env" ] || block_all "no seed state - run ./prepare-lab.sh"
precond "postgres reachable" pg "select 1" || block_all "postgres not reachable"
KEY_DS=$(env_kv "$STATE/seed.env" KEY_DS); LAB_TOKEN=$(env_kv "$STATE/variant.env" LAB_TOKEN)
precond "host load low" wait_idle 70 60 || { warn - "host CPU busy - not scoring (timing checks would be unreliable)"; block_all "host busy"; }
for p in A B; do mock_fault "$p" DELETE >/dev/null 2>&1; done
NONCE="n$(date +%s)$RANDOM"

# ---------------------------------------------------------------- 4.1 aliases, db
models=$(curl -sS --max-time 20 "$GW/v1/models" -H "Authorization: Bearer $MASTER" | jq -r '[.data[]?.id]|sort|join(",")' 2>/dev/null)
[ "$models" = "chat,coder,embed" ] || { echo "$models" | grep -q 'chat' && echo "$models" | grep -q 'coder' && echo "$models" | grep -q 'embed'; } \
  && pass 4.1.1 "/v1/models lists chat, coder, embed" || fail 4.1.1 "/v1/models returned [$models]: aliases (model_name) missing - the client-facing names come from model_list"
c=$(req "$GW" "$MASTER" chat "Say hello. $NONCE")
content=$(jq -r '.choices[0].message.content // empty' "$TMP/body" 2>/dev/null)
[ "$c" = 200 ] && [ -n "$content" ] && pass 4.1.2 "chat completion via alias 'chat' returns 200 with content" \
  || fail 4.1.2 "chat via alias returned HTTP $c ($(jq -r '.error.message // empty' "$TMP/body" 2>/dev/null | head -c 150)) - check the provider prefix, api_base (with /v1) and backend name"
c=$(embed_req "$GW" "$MASTER"); dim=$(jq -r '.data[0].embedding|length' "$TMP/body" 2>/dev/null)
bdim=$(curl -sS --max-time 20 "$LLAMA_EMBED_URL/v1/embeddings" -H 'Content-Type: application/json' -d '{"model":"embed","input":"hello"}' | jq -r '.data[0].embedding|length' 2>/dev/null)
[ "$c" = 200 ] && [ -n "$dim" ] && [ "$dim" = "$bdim" ] && pass 4.1.3 "embedding via alias 'embed' has the backend's dimension ($dim)" \
  || fail 4.1.3 "embedding via alias returned HTTP $c dim=${dim:-none} (backend $bdim) - alias or api_base of the embedding model"
c=$(admin POST /key/generate "$(jq -nc --arg a "verify-probe-$NONCE" '{key_alias:$a}')" | jq -r '.key // empty')
if [ -n "$c" ]; then pass 4.1.4 "/key/generate works (database connected)"; admin POST /key/delete "$(jq -nc --arg a "verify-probe-$NONCE" '{key_aliases:[$a]}')" >/dev/null
else fail 4.1.4 "/key/generate failed - keys need a database; see the gateway log for the DB error"; fi
if ! passed 4.1.4; then
  for id in 4.2.1 4.2.2 4.2.3 4.2.4 4.3.1 4.3.2 4.3.3 4.3.4 4.4.1 4.4.2 4.4.3 4.4.4 4.6.1 4.6.2 4.7.1 4.7.2 4.7.3; do blocked "$id" "needs 4.1.4 (database)"; done
  KEYS_OK=0
else KEYS_OK=1; fi

run_provision() { ( cd "$LAB" && MASTER="$MASTER" GATEWAY="$GW" timeout 180 bash ./provision.sh ) >"$TMP/prov.log" 2>&1; }
if [ "$KEYS_OK" = 1 ]; then
  run_provision; rc1=$?; run_provision; rc2=$?
  [ $rc1 = 0 ] && [ $rc2 = 0 ] && pass 4.2.4 "provision.sh ran twice with exit 0" || fail 4.2.4 "provision.sh exit codes $rc1/$rc2 (idempotence: a second run must not fail on existing aliases): $(tail -2 "$TMP/prov.log" | tr '\n' ' ')"
  K_CHAT=$(kv KEY_CHAT_ONLY); K_LIM=$(kv KEY_LIMITED); K_TPM=$(kv KEY_TPM); K_TEAM=$(kv KEY_TEAM)

  # ------------------------------------------------------------ 4.2
  if [ -z "$K_CHAT" ]; then blocked 4.2.1 "KEY_CHAT_ONLY missing in lab/out/keys.env"; blocked 4.2.2 "needs KEY_CHAT_ONLY"; else
    c=$(req "$GW" "$K_CHAT" chat "hi $NONCE"); [ "$c" = 200 ] && pass 4.2.1 "lab-chat-only gets 200 on chat" || fail 4.2.1 "lab-chat-only got $c on chat (key valid? allowed models?)"
    c=$(embed_req "$GW" "$K_CHAT"); [ "$c" = 403 ] && pass 4.2.2 "lab-chat-only denied on embed with 403" || fail 4.2.2 "lab-chat-only got $c on embed - expected 403 (authorization, not authentication): the key's model list"
  fi
  c=$(req "$GW" "sk-does-not-exist-$NONCE" chat); [ "$c" = 401 ] && pass 4.2.3 "unknown key gets 401" || fail 4.2.3 "unknown key got $c, expected 401"

  # ------------------------------------------------------------ 4.4.1 restart durability (uses keys before further provisioning)
  gw_restart
  if [ -n "$K_CHAT" ]; then
    c=$(req "$GW" "$K_CHAT" chat "after restart $NONCE")
    [ "$c" = 200 ] && pass 4.4.1 "key still works after a gateway restart (state is in Postgres)" || fail 4.4.1 "key got HTTP $c after restart - key records must live in the database, not in memory"
  else blocked 4.4.1 "needs KEY_CHAT_ONLY"; fi
fi

# ---------------------------------------------------------------- 4.4 answers
if [ "$KEYS_OK" = 1 ]; then
  D="$LAB/answers/durability.env"
  tbl=$(env_kv "$D" KEYS_TABLE); pk=$(env_kv "$D" SPENDLOG_PK); lost=$(env_kv "$D" LEGACY_KEY_ROWS); rows=$lost; lst=$(env_kv "$D" LOST_ON_RESTART)
  live=$(pg "select count(*) from \"LiteLLM_VerificationToken\" where key_alias like 'legacy-%'")
  realpk=$(pg "select a.attname from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=any(i.indkey) where i.indrelid='\"LiteLLM_SpendLogs\"'::regclass and i.indisprimary")
  [ "$tbl" = LiteLLM_VerificationToken ] && [ "$pk" = "$realpk" ] && pass 4.4.2a "table and spend-log primary key named correctly" || fail 4.4.2a "KEYS_TABLE/SPENDLOG_PK wrong - look at the tables in the litellm database (\\dt) and the primary key of the spend log"
  [ -n "$rows" ] && [ "$rows" = "$live" ] && [ "$live" -gt 0 ] 2>/dev/null && pass 4.4.2b "LEGACY_KEY_ROWS equals the live count" || fail 4.4.2b "LEGACY_KEY_ROWS=$rows does not match what Postgres holds - query the key table yourself"
  if passed 4.4.2a && passed 4.4.2b; then pass 4.4.2 "durability facts read from the live database"; else fail 4.4.2 "see 4.4.2a/4.4.2b above"; fi
  norm=$(echo "$lst" | tr ',' '\n' | tr -d ' ' | sort | paste -sd,)
  [ "$norm" = rpm_counters ] && pass 4.4.3 "LOST_ON_RESTART is right" || fail 4.4.3 "LOST_ON_RESTART='$lst' - think about which state lives only in process memory when no shared store is configured"
  if [ -n "$K_CHAT" ]; then
    c=$(req "$GW" "$K_CHAT" chat "spend probe" "$(jq -nc --arg u "$NONCE" '{user:$u}')")
    if [ "$c" = 200 ] && within 30 bash -c "[ \"\$(docker exec $PGC psql -U llm -d litellm -tAc \"select count(*) from \\\"LiteLLM_SpendLogs\\\" where end_user='$NONCE' or \\\"user\\\"='$NONCE'\" | tr -d ' \r')\" -ge 1 ]"; then
      pass 4.4.4 "request with nonce user is in LiteLLM_SpendLogs within the bounded poll"
    else fail 4.4.4 "no spend-log row for the nonce request within 30 s (HTTP $c) - spend is batch-written (proxy_batch_write_at) and needs a database"; fi
  else blocked 4.4.4 "needs KEY_CHAT_ONLY"; fi
else for id in 4.4.2 4.4.3; do blocked $id "needs 4.1.4"; done; fi

# ---------------------------------------------------------------- 4.3 limits (fresh keys)
if [ "$KEYS_OK" = 1 ]; then
  run_provision; K_LIM=$(kv KEY_LIMITED); K_TPM=$(kv KEY_TPM); K_CHAT=$(kv KEY_CHAT_ONLY)
  if [ -z "$K_LIM" ]; then for i in 4.3.1 4.3.2 4.3.3; do blocked $i "KEY_LIMITED missing"; done; else
    ok=0; l429=0; body429=""
    for i in 1 2 3 4 5; do c=$(req "$GW" "$K_LIM" chat "burst $i $NONCE"); [ "$c" = 200 ] && ok=$((ok+1)); if [ "$c" = 429 ]; then l429=$((l429+1)); body429=$(cat "$TMP/body"); fi; done
    start429=$(date +%s)
    if [ "$ok" -le 2 ] && [ "$l429" -ge 1 ] && [ "$ok" -ge 1 ]; then pass 4.3.1 "burst of 5: $ok x 200, $l429 x 429"; else fail 4.3.1 "burst of 5 gave $ok x 200 / $l429 x 429 - expected at most 2 x 200 and at least one 429 (rpm_limit on the key)"; fi
    echo "$body429" | grep -qi 'Limit type: requests' && pass 4.3.2 "429 names the request limit" || { passed 4.3.1 && fail 4.3.2 "429 body does not report 'Limit type: requests': $(echo "$body429" | head -c 160)" || blocked 4.3.2 "needs 4.3.1"; }
  fi
  if [ -z "$K_TPM" ]; then blocked 4.3.4 "KEY_TPM missing"; else
    got_tok=0; n200=0
    for i in 1 2 3 4 5 6 7 8; do c=$(req "$GW" "$K_TPM" chat "tpm $i $NONCE"); [ "$c" = 200 ] && n200=$((n200+1)); if [ "$c" = 429 ]; then grep -qi 'Limit type: tokens' "$TMP/body" && got_tok=1; break; fi; done
    c2=$(req "$GW" "$K_CHAT" chat "control $NONCE")
    [ "$got_tok" = 1 ] && [ "$n200" -ge 1 ] && [ "$c2" = 200 ] && pass 4.3.4 "tpm key refused with 'Limit type: tokens' after $n200 request(s); control key unaffected" \
      || fail 4.3.4 "tpm key: 200s=$n200, tokens-429=$got_tok, control=$c2 - tpm_limit must be low enough to trip within 8 small requests and is counted after the response"
  fi
  if [ -n "$K_LIM" ] && passed 4.3.1; then
    if within 75 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $K_LIM' -H 'Content-Type: application/json' -d '{\"model\":\"chat\",\"messages\":[{\"role\":\"user\",\"content\":\"recover\"}],\"max_tokens\":8}' $GW/v1/chat/completions)\" = 200 ]"; then
      pass 4.3.3 "request limit recovered within 70 s ($(( $(date +%s) - start429 )) s after the burst)"
    else fail 4.3.3 "no 200 within the recovery window - the limit window should reset at most 60 s after it started"; fi
  else blocked 4.3.3 "needs 4.3.1"; fi
fi

# ---------------------------------------------------------------- 4.6 / 4.7 teams
if [ "$KEYS_OK" = 1 ]; then
  K_TEAM=$(kv KEY_TEAM)
  if [ -z "$K_TEAM" ]; then blocked 4.6.1 "KEY_TEAM missing"; blocked 4.6.2 "KEY_TEAM missing"; else
    c1=$(req "$GW" "$K_TEAM" chat "team $NONCE"); c2=$(embed_req "$GW" "$K_TEAM")
    [ "$c1" = 200 ] && [ "$c2" = 403 ] && pass 4.6.1 "team key: 200 on chat, 403 on embed" || fail 4.6.1 "team key got chat=$c1 embed=$c2 (expected 200/403) - the team's model list governs a key that has none of its own"
    tid=$(admin GET "/key/info?key=$K_TEAM" | jq -r '.info.team_id // empty'); talias=$(admin GET "/team/info?team_id=$tid" | jq -r '.team_info.team_alias // empty')
    if [ "$talias" = lab-team ] && within 30 bash -c "t=\$(curl -s -H 'Authorization: Bearer $MASTER' '$GW/team/info?team_id=$tid' | jq -r '.team_info.spend // 0'); awk -v t=\$t 'BEGIN{exit !(t>0)}'"; then
      pass 4.6.2 "key belongs to team lab-team and spend is attributed to the team"
    else fail 4.6.2 "key team_alias='$talias' / team spend not attributed within 30 s - the key must be created with the team's id"; fi
  fi
  c1=$(req "$GW" "$KEY_DS" chat "ds $NONCE"); c2=$(embed_req "$GW" "$KEY_DS"); c3=$(req "$GW" "$KEY_DS" coder "ds coder $NONCE")
  [ "$c1" = 200 ] && [ "$c2" = 200 ] && pass 4.7.1 "lab-ds-key: 200 on chat and embed" || fail 4.7.1 "lab-ds-key got chat=$c1 embed=$c2 - find which level (key or team) denies embed and fix that object"
  [ "$c3" = 403 ] && pass 4.7.2 "lab-ds-key still denied on coder" || fail 4.7.2 "lab-ds-key got $c3 on coder (expected 403) - the fix widened access beyond what was asked"
  c4=$(embed_req "$GW" "${K_TEAM:-none}"); [ "$c4" = 403 ] && pass 4.7.3 "other team's key unchanged (403 on embed)" || fail 4.7.3 "lab-team-key got $c4 on embed (expected 403) - another team was affected"
fi

# ---------------------------------------------------------------- 4.5 replicas + Valkey
"$PLATFORM_DIR/stack.sh" up gw gw2 llm mock >/dev/null 2>&1 || true
export LITELLM_CONFIG_DIR="$LAB/litellm"
LITELLM_CONFIG_DIR="$LAB/litellm" "$PLATFORM_DIR/stack.sh" up gw gw2 llm mock >/dev/null 2>&1
if gw_wait "$GW2" 120 && gw_wait "$GW" 60 && [ "$KEYS_OK" = 1 ]; then
  run_provision; K_LIM=$(kv KEY_LIMITED)
  L=$(admin GET "/key/info?key=$K_LIM" | jq -r '.info.rpm_limit // empty')
  if [ -z "$K_LIM" ] || [ -z "$L" ] || [ "$L" -gt 5 ] 2>/dev/null; then
    blocked 4.5.1 "needs KEY_LIMITED with a small rpm_limit (task 4.3)"; blocked 4.5.2 "needs 4.5.1"
  else
    a_ok=0; for i in $(seq 1 "$L"); do c=$(req "$GW" "$K_LIM" chat "rep A $i $NONCE"); [ "$c" = 200 ] && a_ok=$((a_ok+1)); done
    b429=0; b200=0; for i in 1 2 3; do c=$(req "$GW2" "$K_LIM" chat "rep B $i $NONCE"); [ "$c" = 429 ] && b429=$((b429+1)); [ "$c" = 200 ] && b200=$((b200+1)); done
    if [ "$a_ok" = "$L" ] && [ "$b429" = 3 ]; then pass 4.5.1 "limit $L holds across replicas ($a_ok x 200 on A, then 429 x3 on B)"
    else fail 4.5.1 "A: $a_ok/$L x 200, B: $b200 x 200 / $b429 x 429 - the limit is per replica; rate-limit counters must live in a shared store"; fi
    h=$(keyhash "$K_LIM")
    nkeys=$(docker exec "$VALKEYC" valkey-cli --scan --pattern "*${h}*" 2>/dev/null | wc -l)
    [ "$nkeys" -ge 1 ] && pass 4.5.2 "counter keys for the limited key exist in Valkey ($nkeys)" || fail 4.5.2 "no keys for the limited key in Valkey - the rate limiter is not using the shared store (check where Redis is configured, not just that it is)"
  fi
  # 4.5.4 no response caching: identical request twice -> two spend rows, none a cache hit
  if [ -n "$K_CHAT" ]; then
    K_C2=$(kv KEY_CHAT_ONLY); P="identical request $NONCE"
    req "$GW" "$K_C2" chat "$P" '{"temperature":0}' >/dev/null; req "$GW2" "$K_C2" chat "$P" '{"temperature":0}' >/dev/null
    litellm_flush_wait "$K_C2" 3 40
    hits=$(pg "select count(*) from \"LiteLLM_SpendLogs\" where api_key='$(keyhash "$K_C2")' and cache_hit='True'")
    [ "${hits:-1}" = 0 ] && pass 4.5.4 "identical requests were both executed (no response caching)" || fail 4.5.4 "a cache hit was recorded - the shared store must hold rate-limit counters only, not cached responses"
  else blocked 4.5.4 "needs KEY_CHAT_ONLY"; fi
  # 4.5.3 control: same models, no shared store
  LITELLM_CONFIG_DIR="$MODULE_DIR/env/control" "$PLATFORM_DIR/stack.sh" up gw gw2 llm mock >/dev/null 2>&1
  if gw_wait "$GW2" 120 && gw_wait "$GW" 60; then
    ck=$(admin POST /key/generate "$(jq -nc --arg a "verify-ctl-$NONCE" '{key_alias:$a,models:["chat"],rpm_limit:2}')" | jq -r '.key // empty')
    t200=0; for i in 1 2; do c=$(req "$GW" "$ck" chat "ctl A $i"); [ "$c" = 200 ] && t200=$((t200+1)); done
    for i in 1 2; do c=$(req "$GW2" "$ck" chat "ctl B $i"); [ "$c" = 200 ] && t200=$((t200+1)); done
    if passed 4.5.1; then
      [ "$t200" -gt 2 ] && pass 4.5.3 "control without shared store let $t200 requests pass a limit of 2 (your 4.5.1 is caused by your config)" || fail 4.5.3 "control behaved like a global limit ($t200 x 200) - verify environment problem"
    else blocked 4.5.3 "needs 4.5.1"; fi
    admin POST /key/delete "$(jq -nc --arg a "verify-ctl-$NONCE" '{key_aliases:[$a]}')" >/dev/null
  else fail 4.5.3 "control stack did not come up"; fi
  LITELLM_CONFIG_DIR="$LAB/litellm" "$PLATFORM_DIR/stack.sh" up gw llm mock >/dev/null 2>&1; gw_wait "$GW" 120
else
  for i in 4.5.1 4.5.2 4.5.3 4.5.4; do blocked $i "second replica / keys not available (is your config valid? ../../platform/stack.sh logs litellm-2)"; done
  LITELLM_CONFIG_DIR="$LAB/litellm" "$PLATFORM_DIR/stack.sh" up gw llm mock >/dev/null 2>&1; gw_wait "$GW" 120
fi

# ---------------------------------------------------------------- 4.8 network
( cd "$LAB/net" && timeout 120 bash ./apply.sh ) >"$TMP/net.log" 2>&1; nrc1=$?
( cd "$LAB/net" && timeout 120 bash ./apply.sh ) >>"$TMP/net.log" 2>&1; nrc2=$?
probe() {  # probe URL [KEY] -> prints "200" | status | unresolvable | refused | timeout | error
  docker exec "$CLIENT_C" python3 - "$1" "${2:-}" <<'PY' 2>/dev/null
import sys,urllib.request,urllib.error,socket,json
url,key=sys.argv[1],sys.argv[2]
req=urllib.request.Request(url, data=(json.dumps({"model":"chat","messages":[{"role":"user","content":"net"}],"max_tokens":8}).encode() if key else None),
    headers=({"Authorization":"Bearer "+key,"Content-Type":"application/json"} if key else {}))
try:
    r=urllib.request.urlopen(req,timeout=6); print(r.status)
except urllib.error.HTTPError as e: print(e.code)
except Exception as e:
    s=str(getattr(e,'reason',e)).lower()
    if 'name or service' in s or 'resolution' in s or 'nodename' in s: print('unresolvable')
    elif 'refused' in s: print('refused')
    elif 'timed out' in s or isinstance(getattr(e,'reason',None),socket.timeout): print('timeout')
    else: print('error')
PY
}
direct=$(probe "http://llama-chat:8080/v1/models"); direct2=$(probe "http://mock-vllm-a:8000/v1/models")
K_C3=$(kv KEY_CHAT_ONLY); [ -z "$K_C3" ] && K_C3="$MASTER"
viagw=$(probe "http://$GW1C:4000/v1/chat/completions" "$K_C3")
hostgw=$(req "$GW" "$K_C3" chat "host $NONCE")
case "$direct$direct2" in 200*|*200) dok=0 ;; *) dok=1 ;; esac
[ "$dok" = 1 ] && [ "$viagw" = 200 ] && pass 4.8.1 "client: backends unreachable ($direct/$direct2), gateway answers 200" || fail 4.8.1 "client container: direct=$direct/$direct2, via gateway=$viagw - the client must reach the gateway only (networks it shares with each)"
N="$LAB/answers/network.env"
tok=$(env_kv "$N" CLIENT_TOKEN); dr=$(env_kv "$N" DIRECT_RESULT); gr=$(env_kv "$N" GATEWAY_RESULT); kc=$(env_kv "$N" K8S_CONTROL); bl=$(env_kv "$N" BYPASS_LOSES)
if [ "$tok" = "$LAB_TOKEN" ] && [ "$dr" = "$direct" ] && [ "$gr" = "$viagw" ] && [ "$kc" = NetworkPolicy ]; then pass 4.8.2 "network.env matches the live probe and the token"
else fail 4.8.2 "network.env: token ok=$([ "$tok" = "$LAB_TOKEN" ] && echo y || echo n), DIRECT_RESULT='$dr' (observed '$direct'), GATEWAY_RESULT='$gr' (observed '$viagw'), K8S_CONTROL='$kc' - report what you observe from the client container"; fi
bn=$(echo "$bl" | tr ',' '\n' | tr -d ' ' | sort | paste -sd,)
[ "$bn" = "aliases,audit,auth,rate_limits,spend" ] && pass 4.8.3 "BYPASS_LOSES is right" || fail 4.8.3 "BYPASS_LOSES='$bl' - list everything the gateway provides that a direct engine call skips"
[ "$nrc1" = 0 ] && [ "$nrc2" = 0 ] && [ "$hostgw" = 200 ] && pass 4.8.4 "apply.sh idempotent; gateway still works for host clients" || fail 4.8.4 "apply.sh exit $nrc1/$nrc2, host gateway call=$hostgw: $(tail -2 "$TMP/net.log" | tr '\n' ' ')"
summary
