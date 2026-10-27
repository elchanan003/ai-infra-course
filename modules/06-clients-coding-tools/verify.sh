#!/usr/bin/env bash
# Module 06 verify: Open WebUI, Aider (headless), Continue (replayed) and the captured agent request, against the live gateway. Restarts Open WebUI once. ~4-6 min.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP="$(mktemp -d)"; trap 'reset_mocks; rm -rf "$TMP"' EXIT
ALL_IDS=(6.1.1 6.1.2 6.1.3 6.1.4 6.2.1 6.2.2 6.2.3 6.2.4 6.3.1 6.3.2 6.3.3 6.3.4 6.4.1 6.4.2 6.4.3 6.4.4 6.5.1 6.5.2 6.5.3 6.5.4)
block_all() { for id in "${ALL_IDS[@]}"; do blocked "$id" "$1"; done; summary; }
precond "gateway live" wait_http "$GW/health/liveliness" 30 || block_all "gateway not running - run ./prepare-lab.sh"
precond "Open WebUI healthy" wait_http "$OWUI/health" 60 || block_all "Open WebUI not running - run ./prepare-lab.sh"
precond "mock A/B live" bash -c "curl -fs $MOCK_A_URL/health && curl -fs $MOCK_B_URL/health" || block_all "mock-vllm not running"
[ -f "$STATE/captured.id" ] || block_all "no captured request - run ./prepare-lab.sh"
precond "host load low" wait_idle 70 60 || { warn - "host busy - not scoring"; block_all "host busy"; }
reset_mocks
N="n$(date +%s)$RANDOM"

run_provision() { ( cd "$LAB" && timeout 120 bash ./provision.sh ) >"$TMP/prov.log" 2>&1; }
run_connect() { ( cd "$LAB/openwebui" && timeout 150 bash ./connect.sh ) >"$TMP/conn.log" 2>&1; }
run_provision; run_provision; run_connect; rc1=$?; run_connect; rc2=$?

# ---------------------------------------------------------------- 6.1 Open WebUI
tok=$(owui_token)
if [ -z "$tok" ]; then for i in 6.1.1 6.1.2 6.1.3; do blocked $i "cannot sign in to Open WebUI as admin"; done; else
  t0=$(date +%s); models=$(curl -sS --max-time 90 "$OWUI/api/models" -H "Authorization: Bearer $tok" | jq -r '[.data[]?.id]|sort|join(",")'); T1=$(( $(date +%s)-t0 ))
  echo "$models" | grep -qw chat && ! echo "$models" | grep -qwE 'agent|coder' && pass 6.1.1 "Open WebUI lists [$models] (only what key lab-owui may use)" \
    || fail 6.1.1 "Open WebUI lists [$models] - it should list chat (and embed) from the gateway, using a key that may not call agent/coder"
  before=$(spend_rows "$LAB_KEY_OWUI" chat)
  c=$(curl -sS -o "$TMP/chat.json" -w '%{http_code}' --max-time 120 "$OWUI/api/chat/completions" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg p "nonce $N through the UI" '{model:"chat",stream:false,max_tokens:16,messages:[{role:"user",content:$p}]}')")
  within 40 bash -c "[ \"\$(docker exec $PGC psql -U llm -d litellm -tAc \"select count(*) from \\\"LiteLLM_SpendLogs\\\" where api_key='$(keyhash "$LAB_KEY_OWUI")' and messages::text like '%$N%'\" | tr -d ' \r')\" -ge 1 ]"; arrived=$?
  [ "$c" = 200 ] && [ "$arrived" = 0 ] && pass 6.1.2 "nonce chat through Open WebUI returned 200 and arrived at the gateway under key lab-owui" \
    || fail 6.1.2 "chat via Open WebUI: HTTP $c, nonce seen under lab-owui: $([ $arrived = 0 ] && echo yes || echo no) - the UI must call the gateway with its own key"
  cfg=$(curl -sS --max-time 20 "$OWUI/openai/config" -H "Authorization: Bearer $tok")
  urls=$(echo "$cfg" | jq -c '.OPENAI_API_BASE_URLS'); keys=$(echo "$cfg" | jq -c '.OPENAI_API_KEYS')
  [ "$urls" = '["http://litellm:4000/v1"]' ] && [ "$keys" = "[\"$LAB_KEY_OWUI\"]" ] && pass 6.1.3 "Open WebUI's only upstream is the gateway with key lab-owui" \
    || fail 6.1.3 "stored upstreams: urls=$urls keys=$(echo "$keys" | sed 's/sk-[A-Za-z0-9-]*/sk-.../g') - exactly the gateway (as the Open WebUI container sees it) with the dedicated key"
fi
if [ -z "$tok" ] || ! passed 6.1.3; then blocked 6.1.4 "needs 6.1.3 (a connect.sh that configures the connection) - an empty script is trivially idempotent"
elif [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then pass 6.1.4 "connect.sh idempotent (exit 0 twice, same end state)"
else fail 6.1.4 "connect.sh exit codes $rc1/$rc2: $(tail -2 "$TMP/conn.log" | tr '\n' ' ')"; fi

# ---------------------------------------------------------------- 6.2 Aider
R="$LAB/aider/repo"; git -C "$R" checkout -q -- . 2>/dev/null; git -C "$R" clean -fdq 2>/dev/null
before=$(spend_rows "$LAB_KEY_AIDER" agent)
t0=$(date +%s); ( cd "$LAB/aider" && timeout 150 bash ./run.sh "set the banner to V${N}" ) >"$TMP/aider.log" 2>&1; arc=$?; AT=$(( $(date +%s)-t0 ))
grep -q "BANNER = \"V${N}\"" "$R/app.py" && pass 6.2.1 "Aider edited app.py through the gateway" || fail 6.2.1 "app.py not changed (run.sh exit $arc): $(tail -3 "$TMP/aider.log" | tr '\n' ' ' | head -c 300) - check model name/prefix, edit format and non-interactive flags"
litellm_flush_wait "$LAB_KEY_AIDER" $((before+1)) 40
after=$(spend_rows "$LAB_KEY_AIDER" agent)
[ "${after:-0}" -gt "${before:-0}" ] && pass 6.2.2 "gateway logged Aider's request under key lab-aider, model group agent" || fail 6.2.2 "no spend row for lab-aider on group agent - Aider must use the gateway, the dedicated key and the alias 'agent'"
[ "$arc" = 0 ] && [ "$AT" -le 120 ] && { pass 6.2.3 "run.sh exits 0 within 120 s without interaction"; echo "~ aider took ${AT}s"; } || fail 6.2.3 "run.sh exit $arc after ${AT}s - it must run non-interactively and finish (no prompts, update checks or analytics)"
git -C "$R" checkout -q -- . 2>/dev/null
( cd "$LAB/aider" && LAB_KEY_OVERRIDE="sk-bogus-$N" timeout 120 bash ./run.sh "set the banner to W${N}" ) >"$TMP/aider2.log" 2>&1; brc=$?
if ! passed 6.2.1; then blocked 6.2.4 "needs 6.2.1 (a run.sh that works) - a script that never runs also 'fails cleanly'"
elif [ "$brc" != 0 ] && ! grep -q "W${N}" "$R/app.py"; then pass 6.2.4 "bogus key: non-zero exit and file unchanged"; else fail 6.2.4 "bogus key run exit $brc, file changed: $(grep -c "W$N" "$R/app.py") - keep the LAB_KEY_OVERRIDE line and let Aider fail on auth errors"; fi
git -C "$R" checkout -q -- . 2>/dev/null

# ---------------------------------------------------------------- 6.3 Continue
CF="$LAB/continue/config.yaml"
shape=$("$PY" - "$CF" <<'PY' 2>/dev/null
import sys,yaml
c=yaml.safe_load(open(sys.argv[1])) or {}
ms=c.get("models") or []
def roles(m): return m.get("roles") or ["chat","edit","apply"]
ch=[m for m in ms if "chat" in roles(m)]; ac=[m for m in ms if "autocomplete" in roles(m)]
ok=bool(ch) and bool(ac) and all(str(m.get("apiBase","")).rstrip("/").endswith(":18040/v1") for m in ch+ac)
print("ok" if ok else "bad")
PY
)
[ "$shape" = ok ] && pass 6.3.1 "config has a chat model and an autocomplete model, both on the gateway" || fail 6.3.1 "config.yaml needs one model with role chat and one with role autocomplete, each with apiBase http://127.0.0.1:18040/v1 (+ own apiKey)"
b_chat=$(spend_rows "$LAB_KEY_CONTINUE_CHAT" chat); b_fim=$(spend_rows "$LAB_KEY_CONTINUE_FIM" coder)
rep=$(bash "$LAB/continue/replay.sh" 2>/dev/null)
cs=$(echo "$rep" | jq -r '.chat.status // 0'); as=$(echo "$rep" | jq -r '.autocomplete.status // 0')
litellm_flush_wait "$LAB_KEY_CONTINUE_CHAT" $((b_chat+1)) 40; litellm_flush_wait "$LAB_KEY_CONTINUE_FIM" $((b_fim+1)) 40
a_chat=$(spend_rows "$LAB_KEY_CONTINUE_CHAT" chat); a_fim=$(spend_rows "$LAB_KEY_CONTINUE_FIM" coder)
[ "$cs" = 200 ] && [ "${a_chat:-0}" -gt "${b_chat:-0}" ] && pass 6.3.2 "chat request: 200, logged under lab-continue-chat on group chat" || fail 6.3.2 "chat replay status=$cs, rows under lab-continue-chat/chat: $((a_chat-b_chat)) - model alias and key of the chat role"
fim=$(mock_stats B | jq -c '[.last_requests[]?|select(.endpoint=="completions")]|last // {}')
fimok=$(echo "$fim" | jq -r '(.fim==true) and ((.suffix_chars//0)>0) and ((.prompt_chars//0)>0)')
[ "$as" = 200 ] && [ "${a_fim:-0}" -gt "${b_fim:-0}" ] && [ "$fimok" = true ] && pass 6.3.3 "autocomplete: 200, routed to coder, backend saw a FIM-shaped request (prefix and suffix)" \
  || fail 6.3.3 "autocomplete status=$as, coder rows $((a_fim-b_fim)), backend saw FIM=$fimok - autocomplete must use /completions with prefix+suffix, alias coder and the FIM key"
cc=$(curl -s -o /dev/null -w '%{http_code}' "$GW/v1/chat/completions" -H "Authorization: Bearer $LAB_KEY_CONTINUE_FIM" -H 'Content-Type: application/json' -d '{"model":"chat","messages":[{"role":"user","content":"x"}],"max_tokens":4}')
cd2=$(curl -s -o /dev/null -w '%{http_code}' "$GW/v1/chat/completions" -H "Authorization: Bearer $LAB_KEY_CONTINUE_CHAT" -H 'Content-Type: application/json' -d '{"model":"coder","messages":[{"role":"user","content":"x"}],"max_tokens":4}')
[ "$cc" = 403 ] && [ "$cd2" = 403 ] && pass 6.3.4 "FIM key denied on chat, chat key denied on coder" || fail 6.3.4 "FIM key on chat=$cc, chat key on coder=$cd2 (expected 403/403) - each role's key may use only its own alias"

# ---------------------------------------------------------------- 6.4 dissect
D="$LAB/answers/dissect.env"; J="$LAB/captured/agent-request.json"
read -r SC TC TCH MS TR AS_ TOT <<<"$("$PY" - "$J" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); m=r["messages"]; t=r.get("tools",[])
sc=len(m[0]["content"]); tch=len(json.dumps(t,separators=(",",":")))
rest=sum(len(x.get("content") or "") for x in m[1:])
print(sc,len(t),tch,len(m),sum(1 for x in m if x["role"]=="tool"),sum(1 for x in m if x["role"]=="assistant"),sc+tch+rest)
PY
)"
rid=$(cat "$STATE/captured.id"); LOGGED=$(pg "select prompt_tokens from \"LiteLLM_SpendLogs\" where request_id='$rid'")
g() { env_kv "$D" "$1"; }
if [ "$(g SYSTEM_CHARS)" = "$SC" ] && [ "$(g TOOLS_COUNT)" = "$TC" ] && [ "$(g TOOLS_CHARS)" = "$TCH" ] && [ "$(g MESSAGES)" = "$MS" ] && [ "$(g TOOL_RESULTS)" = "$TR" ]; then pass 6.4.1 "structure of the captured request measured correctly"
else fail 6.4.1 "SYSTEM_CHARS/TOOLS_COUNT/TOOLS_CHARS/MESSAGES/TOOL_RESULTS do not match the captured file - measure it with jq (TOOLS_CHARS = length of the compact JSON of the tools array)"; fi
if [ -n "$LOGGED" ] && python3 -c "import sys;a=float('$(g LOGGED_PROMPT_TOKENS)');b=float('$LOGGED');sys.exit(0 if abs(a-b)<=0.05*b else 1)" 2>/dev/null; then pass 6.4.2 "LOGGED_PROMPT_TOKENS within 5% of the gateway's logged value"
else fail 6.4.2 "LOGGED_PROMPT_TOKENS=$(g LOGGED_PROMPT_TOKENS) vs the spend log - read the row for the request id in captured/README.txt"; fi
if [ -n "$LOGGED" ]; then exp25=$(python3 -c "
L=$LOGGED; tot=$TOT; P=L*($SC+$TCH)/tot; a=$AS_; d=(L-P)/a
print(round(25*P+d*25*26/2))"); else exp25=0; fi
if [ "$exp25" -gt 0 ] && python3 -c "import sys;a=float('$(g SESSION_25_PROMPT_TOKENS)');b=float('$exp25');sys.exit(0 if abs(a-b)<=0.05*b else 1)" 2>/dev/null; then pass 6.4.3 "SESSION_25_PROMPT_TOKENS within 5% of the reference computation"
else fail 6.4.3 "SESSION_25_PROMPT_TOKENS=$(g SESSION_25_PROMPT_TOKENS) - apply the definitions in lab.md (P from char shares, d per assistant turn, 25 P + d x 25 x 26 / 2)"; fi
bad=0; for k in SYSTEM_CHARS TOOLS_COUNT TOOLS_CHARS MESSAGES TOOL_RESULTS LOGGED_PROMPT_TOKENS SESSION_25_PROMPT_TOKENS; do v=$(g $k); { [ -z "$v" ] || [ "$v" = 0 ] || [ "$v" = TODO ]; } && bad=1; done
[ "$bad" = 0 ] && pass 6.4.4 "no template placeholder values left" || fail 6.4.4 "dissect.env still contains the shipped placeholder values (0/TODO)"

# ---------------------------------------------------------------- 6.5 restart + timing
"$PLATFORM_DIR/stack.sh" compose restart open-webui >/dev/null 2>&1
wait_http "$OWUI/health" 180; tok=$(owui_token)
if [ -z "$tok" ]; then for i in 6.5.1 6.5.2 6.5.3 6.5.4; do blocked $i "Open WebUI did not come back"; done; else
  t0=$(date +%s.%N); models=$(curl -sS --max-time 60 "$OWUI/api/models" -H "Authorization: Bearer $tok" | jq -r '[.data[]?.id]|join(",")'); T2=$(python3 -c "print(round($(date +%s.%N)-$t0,2))")
  echo "$models" | grep -qw chat && python3 -c "import sys;sys.exit(0 if $T2<5 else 1)" && { pass 6.5.1 "model list with chat is fast after restart (persisted fix)"; echo "~ listing took ${T2}s"; } || fail 6.5.1 "model list [$models] took ${T2}s after restart - something in the stored configuration still makes the listing wait"
  # first listing before restart was ${T1:-?}s
  oll=$(curl -sS --max-time 20 "$OWUI/ollama/config" -H "Authorization: Bearer $tok" | jq -r '.ENABLE_OLLAMA_API')
  [ "$oll" = false ] && pass 6.5.3 "Ollama API disabled in the stored configuration" || fail 6.5.3 "ENABLE_OLLAMA_API=$oll in the stored config - the stale connection is still active"
  cfg=$(curl -sS --max-time 20 "$OWUI/openai/config" -H "Authorization: Bearer $tok")
  [ "$(echo "$cfg" | jq -c '.OPENAI_API_BASE_URLS')" = '["http://litellm:4000/v1"]' ] && [ "$(echo "$cfg" | jq -c '.OPENAI_API_KEYS')" = "[\"$LAB_KEY_OWUI\"]" ] && pass 6.5.4 "gateway connection with lab-owui still the only upstream" || fail 6.5.4 "OpenAI connection changed or lost after the restart"
  passed 6.5.1 && pass 6.5.2 "fix survived a restart of Open WebUI" || fail 6.5.2 "after the restart the listing is not fast and correct - the fix must live in the application's stored configuration"
fi
summary
