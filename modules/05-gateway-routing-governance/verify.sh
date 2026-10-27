#!/usr/bin/env bash
# Module 05 verify: live routing/fallback/cooldown/budget/separation behaviour on mock-vllm A/B. Injects faults itself and removes them. ~4-6 min.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP="$(mktemp -d)"; trap 'reset_mocks; rm -rf "$TMP"' EXIT
ALL_IDS=(5.1.1 5.1.2 5.1.3 5.2.1 5.2.2 5.2.3 5.3.1 5.3.2 5.3.3 5.4.1 5.4.2 5.4.3 5.4.4 5.5.1 5.5.2 5.5.3 5.5.4 5.6.1 5.6.2 5.6.3)
block_all() { for id in "${ALL_IDS[@]}"; do blocked "$id" "$1"; done; summary; }
precond "gateway live" wait_http "$GW/health/liveliness" 30 || block_all "gateway not running - run ./prepare-lab.sh"
precond "mock A and B live" bash -c "curl -fs ${MOCK_A_URL}/health && curl -fs ${MOCK_B_URL}/health" || block_all "mock-vllm not running - run ./prepare-lab.sh"
[ -f "$STATE/variant.env" ] || block_all "no variant state - run ./prepare-lab.sh"
[ "$(docker inspect aiinfra-litellm-1 --format '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}')" = "$LAB/litellm" ] || block_all "gateway is not using $LAB/litellm - run ./prepare-lab.sh"
precond "host load low" wait_idle 70 60 || { warn - "host busy - not scoring"; block_all "host busy"; }
reset_mocks
N="n$(date +%s)$RANDOM"; CAN=$(vget CANARY_PCT); P_IN=$(vget P_IN); P_OUT=$(vget P_OUT); K=$(vget K_ALLOWED); R=$(vget R_CHAT); CPM=$(vget NORMAL_CPM)
PT=$(env_kv "$STATE/usage.env" PT); CT=$(env_kv "$STATE/usage.env" CT)
STD='{"max_tokens":20}'

# ---------------------------------------------------------------- 5.1 weighted split (n=200 sequential)
a0=$(mhits A); b0=$(mhits B); ok=0
for i in $(seq 1 200); do c=$(req "$MASTER" chat "price-check"); [ "$c" = 200 ] && ok=$((ok+1)); done
a1=$(mhits A); b1=$(mhits B); da=$((a1-a0)); db=$((b1-b0))
exp=$(( CAN * 2 )); sd=$(python3 -c "import math;print(round(math.sqrt(200*$CAN/100*(1-$CAN/100)),1))"); band=$(python3 -c "print(int(3.2*$sd+0.999))")
if [ $((da+db)) -ge 190 ] && [ "$da" -ge $((exp-band)) ] && [ "$da" -le $((exp+band)) ]; then pass 5.1.2 "deployment A got the canary share of 200 sequential requests (within the binomial band)"; echo "~ A served $da of 200 (target $exp, band +-$band)"
else fail 5.1.2 "deployment A served $da / B $db of 200; the target is ${CAN}% to A (about $exp, band +-$band) - a weighted split needs the right strategy and weights"; fi
if [ "$ok" != 200 ]; then fail 5.1.1 "$ok/200 requests returned 200 - the group must serve every request"
elif passed 5.1.2; then pass 5.1.1 "200 requests on 'chat' all returned 200 on a weighted split"
else blocked 5.1.1 "needs 5.1.2 (a working weighted split) - an unweighted group answering 200 proves nothing"; fi
req "$MASTER" chat "id-check" >/dev/null; hid=$(grep -i '^x-litellm-model-id' "$TMP/hdr" | tr -d '\r' | awk '{print $2}')
ids=$(admin GET /model/info | jq -r '[.data[]|select(.model_name=="chat")|.model_info.id]|sort|join(",")')
[ "$ids" = "chat-a,chat-b" ] && { [ "$hid" = chat-a ] || [ "$hid" = chat-b ]; } && pass 5.1.3 "deployments carry the ids chat-a / chat-b and responses report one of them" || fail 5.1.3 "group chat has deployment ids [$ids], response id '$hid' - set stable model_info.id values chat-a and chat-b"

# ---------------------------------------------------------------- 5.2 fallback group -> group
reset_mocks; b0=$(mhits B); ok=0
mock_fault A POST '{"error_rate":1.0}' >/dev/null
for i in $(seq 1 10); do c=$(req "$MASTER" ha "fb $i $N"); [ "$c" = 200 ] && ok=$((ok+1)); done
b1=$(mhits B); mock_fault A DELETE >/dev/null
[ "$ok" = 10 ] && [ $((b1-b0)) -ge 10 ] && pass 5.2.1 "A failing: 10/10 requests on 'ha' answered 200 and B served them" || fail 5.2.1 "A failing: $ok/10 x 200, B served $((b1-b0)) - group ha must fall back to group ha-backup (fallbacks map group -> group)"
# the 5.2.1 fault may have put A in cooldown: wait (bounded) until A serves group ha again before the control
a0=$(mhits A); for w in $(seq 1 35); do req "$MASTER" ha "wait $w $N" >/dev/null; [ "$(mhits A)" -gt "$a0" ] && break; sleep 2; done
b0=$(mhits B); ok=0; for i in $(seq 1 10); do c=$(req "$MASTER" ha "healthy $i $N"); [ "$c" = 200 ] && ok=$((ok+1)); done; b1=$(mhits B)
if ! passed 5.2.1; then blocked 5.2.2 "needs 5.2.1 (a fallback that works) - a control without the fallback proves nothing"
elif [ "$ok" = 10 ] && [ "$b1" = "$b0" ]; then pass 5.2.2 "healthy A: 10/10 x 200 and B untouched"
else fail 5.2.2 "healthy A: $ok/10 x 200, B served $((b1-b0)) - a fallback must only fire on failure (or A never left its cooldown within 70 s: cooldown_time too long)"; fi
mock_fault A POST '{"error_rate":1.0}' >/dev/null; mock_fault B POST '{"error_rate":1.0}' >/dev/null
t0=$(date +%s); c=$(req "$MASTER" ha "both $N"); dt=$(( $(date +%s)-t0 )); reset_mocks
clean_err=$(jq -e '.error.message // .detail // .error' "$TMP/body" >/dev/null 2>&1 && echo y || echo n)
if ! passed 5.2.1; then blocked 5.2.3 "needs 5.2.1 (fallback configured)"
else case "$c" in 5??|429) [ "$dt" -le 60 ] && [ "$clean_err" = y ] && pass 5.2.3 "both failing: clean error response within the bound (no hang, no 200)" || fail 5.2.3 "both failing: $c but after ${dt}s - bound retries/timeouts (or the error body is not JSON)";; *) fail 5.2.3 "both failing: got HTTP $c (expected a clean 5xx/429 error) after ${dt}s";; esac; fi

# ---------------------------------------------------------------- 5.3 cooldown on group pool
reset_mocks; sleep 1; a0=$(mhits A); ok=0
mock_fault A POST '{"error_rate":1.0}' >/dev/null
for i in $(seq 1 20); do c=$(req "$MASTER" pool "cd $i $N"); [ "$c" = 200 ] && ok=$((ok+1)); done
a1=$(mhits A); hitsA=$((a1-a0))
[ "$ok" = 20 ] && [ "$hitsA" -le 3 ] && { pass 5.3.1 "A failing: 20/20 x 200, at most 3 requests reached A"; echo "~ $hitsA requests reached A"; } || fail 5.3.1 "A failing: $ok/20 x 200, $hitsA requests reached A (limit 3) - a failing deployment should leave the group quickly, and retries should hide it from users"
mock_fault A DELETE >/dev/null; a0=$(mhits A); t0=$(date +%s)
if ! passed 5.3.1; then blocked 5.3.2 "needs 5.3.1 (a cooldown that excluded A) - recovery of a never-excluded deployment proves nothing"
elif within 75 bash -c "for i in 1 2 3 4 5 6; do curl -s -o /dev/null -H 'Authorization: Bearer $MASTER' -H 'Content-Type: application/json' -d '{\"model\":\"pool\",\"messages\":[{\"role\":\"user\",\"content\":\"rec\"}],\"max_tokens\":5}' $GW/v1/chat/completions; done; [ \$(curl -s ${MOCK_A_URL}/admin/stats | jq '[.requests[]?.chat//0]|add') -gt $a0 ]"; then
  { pass 5.3.2 "after the fault was removed A served again within 75 s"; echo "~ recovery took $(( $(date +%s)-t0 )) s"; }
else fail 5.3.2 "A did not receive traffic within 75 s after recovery - cooldown_time too long, or A stays excluded"; fi
c=$(req "$MASTER" ha "ha-ok $N")
if ! passed 5.3.1; then blocked 5.3.3 "needs 5.3.1 (tuning done)"; elif [ "$c" = 200 ] && passed 5.2.1; then pass 5.3.3 "group ha still healthy (config intact)" || fail 5.3.3 "group ha returned $c - the cooldown tuning broke another group"; fi

# ---------------------------------------------------------------- 5.4 prices, exact spend, budget
exp20=$(python3 -c "print(repr(20*($PT*$P_IN+$CT*$P_OUT)))")
vk=$(admin POST /key/generate "$(jq -nc --arg a "verify-spend-$N" '{key_alias:$a}')" | jq -r '.key // empty')
for i in $(seq 1 20); do req "$vk" chat "price-check" >/dev/null; done
litellm_flush_wait "$vk" 20 40
spend=$(litellm_spend "$vk")
if [ -n "$spend" ] && python3 -c "import sys;e=$exp20;s=float('$spend');sys.exit(0 if abs(s-e)<=1e-7*e else 1)"; then { pass 5.4.1 "spend of 20 calls equals the hand-computed value"; echo "~ spend $spend expected $exp20"; }
else fail 5.4.1 "spend of 20 calls = '${spend:-none}', expected $exp20 from lab/PRICES.md - prices must be on every deployment of group chat (model_info) and spend is batch-written"; fi
admin POST /key/delete "$(jq -nc --arg a "verify-spend-$N" '{key_aliases:[$a]}')" >/dev/null
ans=$(env_kv "$LAB/answers/spend.env" SPEND_20)
if [ -n "$ans" ] && python3 -c "import sys;e=$exp20;s=float('$ans');sys.exit(0 if abs(s-e)<=1e-6*e else 1)" 2>/dev/null; then pass 5.4.2 "SPEND_20 matches the hand computation"
else fail 5.4.2 "SPEND_20='$ans' - compute 20 x (prompt tokens x prompt price + completion tokens x completion price) from lab/PRICES.md"; fi
( cd "$LAB" && MASTER="$MASTER" GATEWAY="$GW" timeout 180 bash ./provision.sh ) >"$TMP/prov.log" 2>&1
KB=$(env_kv "$LAB/out/keys.env" KEY_BUDGET)
if [ -z "$KB" ]; then blocked 5.4.3 "KEY_BUDGET missing (provision.sh, task 5.4)"; blocked 5.4.4 "needs KEY_BUDGET"; else
  n200=0; first=""; etype=""
  for i in $(seq 1 $((K+6))); do c=$(req "$KB" chat "price-check"); if [ "$c" = 200 ]; then n200=$((n200+1)); else first=$c; etype=$(jq -r '.error.type // empty' "$TMP/body"); break; fi; done
  if [ "$first" = 422 ] && [ "$etype" = budget_exceeded ] && [ "$n200" -ge "$K" ] && [ "$n200" -le $((K+1)) ]; then { pass 5.4.3 "budget key: allowed calls up to the budget, then 422 budget_exceeded"; echo "~ $n200 x 200"; }
  else fail 5.4.3 "budget key: $n200 x 200 then status '${first:-none}' type '${etype:-none}' (expected about $K calls, then 422 budget_exceeded) - max_budget must come from PRICES.md and prices must be configured"; fi
  admin GET /key/list >/dev/null
  if [ -n "$(kv2=$(env_kv "$LAB/out/keys.env" KEY_CHAT_USER); echo $kv2)" ]; then ck=$(env_kv "$LAB/out/keys.env" KEY_CHAT_USER); else ck=$MASTER; fi
  ok=0; for i in 1 2 3 4 5 6 7 8; do c=$(req "$ck" chat "ctl $i"); [ "$c" = 200 ] && ok=$((ok+1)); done
  [ "$ok" = 8 ] && passed 5.4.3 && pass 5.4.4 "control key without budget keeps returning 200" || { passed 5.4.3 && fail 5.4.4 "control key got $ok/8 x 200" || blocked 5.4.4 "needs 5.4.3"; }
fi

# ---------------------------------------------------------------- 5.5 chat vs agent
KC=$(env_kv "$LAB/out/keys.env" KEY_CHAT_USER); KA=$(env_kv "$LAB/out/keys.env" KEY_AGENT)
if [ -z "$KC" ] || [ -z "$KA" ]; then for i in 5.5.1 5.5.2 5.5.3 5.5.4; do blocked $i "KEY_CHAT_USER / KEY_AGENT missing (provision.sh, task 5.5)"; done; else
  reset_mocks; mock_fault A POST '{"latency_ms":1500}' >/dev/null
  t0=$(date +%s.%N); req "$KC" shared "idle" >/dev/null; base=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")
  agent_loop() { local end=$(( $(date +%s)+16 )); while [ "$(date +%s)" -lt "$end" ]; do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $KA" -H 'Content-Type: application/json' -d '{"model":"shared","messages":[{"role":"user","content":"agent step"}],"max_tokens":20}'); echo "$c" >> "$TMP/agent.codes"; [ "$c" = 429 ] && sleep 0.2; done; }
  : > "$TMP/agent.codes"; for w in 1 2 3 4 5 6 7 8; do agent_loop & done
  peak=0; : > "$TMP/chat.lat"; chat_bad=0; endt=$(( $(date +%s)+14 ))
  ( while [ "$(date +%s)" -lt "$endt" ]; do mock_stats A | jq -r '.engine.running' >> "$TMP/run.samples"; sleep 0.15; done ) &
  sleep 1
  while [ "$(date +%s)" -lt "$endt" ]; do t1=$(date +%s.%N); c=$(req "$KC" shared "chat while agent"); t2=$(date +%s.%N)
    [ "$c" = 200 ] || chat_bad=$((chat_bad+1)); python3 -c "print(round($t2-$t1,3))" >> "$TMP/chat.lat"; done
  wait; mock_fault A DELETE >/dev/null
  peak=$(sort -n "$TMP/run.samples" | tail -1); a429=$(grep -c 429 "$TMP/agent.codes"); a200=$(grep -c 200 "$TMP/agent.codes"); worst=$(sort -n "$TMP/chat.lat" | tail -1)
  nchat=$(wc -l < "$TMP/chat.lat")
  [ "$chat_bad" = 0 ] && [ "$nchat" -ge 3 ] && pass 5.5.1 "all chat requests returned 200 while the agent looped" || fail 5.5.1 "$chat_bad of $nchat chat requests failed while the agent looped - chat must not be starved or limited by the agent"
  ans_mp=$(env_kv "$LAB/answers/agent-limits.env" MAX_PARALLEL); ans_tpm=$(env_kv "$LAB/answers/agent-limits.env" AGENT_TPM)
  lim=$(admin GET "/key/info?key=$KA" | jq -r '.info.max_parallel_requests // empty'); ktpm=$(admin GET "/key/info?key=$KA" | jq -r '.info.tpm_limit // empty')
  want=$((8-R)); lo=$((CPM*(PT+CT))); hi=$((10*lo))
  if [ "${peak:-99}" -le $((want+1)) ] && [ "$a429" -ge 1 ]; then { pass 5.5.2 "agent backend concurrency stayed within the cap and the excess got 429"; echo "~ peak $peak (cap $want+1), 429s $a429"; }
  else fail 5.5.2 "peak running=$peak (allowed $want+1), agent 200/429 = $a200/$a429 - the agent's in-flight requests must be capped, not just its rate"; fi
  if [ "$ans_mp" = "$want" ] && [ "$lim" = "$want" ] && [ -n "$ans_tpm" ] && [ "$ans_tpm" -ge "$lo" ] && [ "$ans_tpm" -le "$hi" ] && [ "$ktpm" = "$ans_tpm" ]; then pass 5.5.3 "answers and key limits match the capacity numbers"
  else fail 5.5.3 "MAX_PARALLEL=$ans_mp (key $lim, expected from CAPACITY.md), AGENT_TPM=$ans_tpm (key $ktpm, must allow the normal rate and stay below 10x) - compute slots minus the chat reserve"; fi
  limit=$(python3 -c "print(round(1.5*$base+0.3,3))")
  python3 -c "import sys;sys.exit(0 if $worst<=$limit else 1)" && { pass 5.5.4 "worst chat latency within 1.5x idle + 0.3 s"; echo "~ worst ${worst}s limit ${limit}s idle ${base}s"; } || fail 5.5.4 "worst chat latency ${worst}s > ${limit}s (idle ${base}s) - chat waited behind the agent for engine slots"
fi

# ---------------------------------------------------------------- 5.6 context-window fallback
reset_mocks
LONG=$(python3 -c "print('lorem ipsum dolor sit amet ' * 1000)")
a0=$(mhits A); b0=$(mhits B); c=$(req "$MASTER" small "$LONG"); a1=$(mhits A)
[ "$c" = 200 ] && [ "$a1" -gt "$a0" ] && pass 5.6.1 "long prompt on 'small' answered 200 by the big deployment" || fail 5.6.1 "long prompt on 'small': HTTP $c ($(jq -r '.error.type // .detail // empty' "$TMP/body" 2>/dev/null | head -c 80)), big served $((a1-a0)) - a context-length error is a 400, not an outage: read the fallbacks= the error message prints - is that list reachable from the group the client asked for?"
a0=$(mhits A); b0=$(mhits B); c=$(req "$MASTER" small "short prompt $N"); a1=$(mhits A); b1=$(mhits B)
if ! passed 5.6.1; then blocked 5.6.2 "needs 5.6.1 (overflow routing)"
elif [ "$c" = 200 ] && [ "$b1" -gt "$b0" ] && [ "$a1" = "$a0" ]; then pass 5.6.2 "short prompt stays on 'small'"
else fail 5.6.2 "short prompt: HTTP $c, small served $((b1-b0)), big served $((a1-a0)) - only overflow may go to big"; fi
mock_fault A POST '{"error_rate":1.0}' >/dev/null; c=$(req "$MASTER" ha "regress $N"); mock_fault A DELETE >/dev/null
[ "$c" = 200 ] && passed 5.2.1 && pass 5.6.3 "generic fallback (ha -> ha-backup) still works" || fail 5.6.3 "ha with A failing returned $c - the 5xx fallback from task 5.2 broke"
summary
