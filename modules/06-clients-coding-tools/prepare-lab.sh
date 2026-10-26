#!/usr/bin/env bash
# Module 06 prepare: profiles gw ui mock llm; gateway on env/litellm (aliases chat embed agent coder); mock A scripted for Aider;
# FRESH Open WebUI volume with the 6.5 fault planted in its stored config; scratch git repo for Aider; captured agent request (6.4).
# Idempotent; never touches your lab/ sources.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
chmod -R a+rX "$LAB"
if [ ! -f "$STATE/variant.env" ]; then
  { echo "SYS_CHARS=$(( RANDOM % 8000 + 5000 ))"; echo "N_TOOLS=$(( RANDOM % 5 + 5 ))"; echo "N_TURNS=$(( RANDOM % 4 + 3 ))"; echo "SEED=$RANDOM"; } > "$STATE/variant.env"
fi
"$PLATFORM_DIR/stack.sh" reset-openwebui >/dev/null 2>&1
stack_up >/dev/null || { echo "prepare-lab: stack did not come up (see ../../platform/stack.sh status)"; exit 1; }
gw_wait 120 || { echo "prepare-lab: gateway not live"; exit 1; }
reset_mocks
# clean runtime keys
for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%'"); do admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null; done
# 6.4: captured agent request, really sent through the gateway
CAP_KEY=sk-lab06-captured
admin POST /key/generate "$(jq -nc --arg k "$CAP_KEY" '{key:$k,key_alias:"lab-captured",models:["agent"]}')" >/dev/null
SYS=$(env_kv "$STATE/variant.env" SYS_CHARS); NT=$(env_kv "$STATE/variant.env" N_TOOLS); TURNS=$(env_kv "$STATE/variant.env" N_TURNS); SEED=$(env_kv "$STATE/variant.env" SEED)
mkdir -p "$LAB/captured"
"$PY" - "$LAB/captured/agent-request.json" "$SYS" "$NT" "$TURNS" "$SEED" <<'PY'
import json, random, sys
out, sys_chars, nt, turns, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
r = random.Random(seed)
words = "read the file list directory search replace run command test output error line function class import return value".split()
def text(n): 
    s = ""
    while len(s) < n: s += r.choice(words) + " "
    return s[:n]
names = ["read_file", "write_file", "list_files", "search_files", "run_command", "apply_diff", "ask_followup", "attempt_completion", "browser_action"]
tools = [{"type": "function", "function": {"name": names[i], "description": text(r.randint(120, 400)),
          "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": text(60)}}, "required": ["path"]}}} for i in range(nt)]
msgs = [{"role": "system", "content": text(sys_chars)}, {"role": "user", "content": "Fix the failing test in utils/. " + text(80)}]
for t in range(turns):
    msgs.append({"role": "assistant", "content": text(r.randint(40, 160)), "tool_calls": [{"id": f"call_{t}", "type": "function", "function": {"name": names[t % nt], "arguments": json.dumps({"path": f"src/f{t}.py"})}}]})
    msgs.append({"role": "tool", "tool_call_id": f"call_{t}", "content": text(r.randint(300, 3000))})
json.dump({"model": "agent", "stream": False, "max_tokens": 256, "tool_choice": "auto", "tools": tools, "messages": msgs}, open(out, "w"))
PY
rid=$(curl -sS --max-time 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $CAP_KEY" -H 'Content-Type: application/json' -d @"$LAB/captured/agent-request.json" | jq -r '.id // empty')
[ -n "$rid" ] || { echo "prepare-lab: captured request failed"; exit 1; }
echo "$rid" > "$STATE/captured.id"
cat > "$LAB/captured/README.txt" <<MSG
agent-request.json is the body of ONE request a coding agent sent through the gateway during prepare-lab.
Key alias: lab-captured   model alias: agent   response/request id: $rid
Find its row in LiteLLM_SpendLogs (column request_id) for the logged prompt_tokens, e.g.
  docker exec aiinfra-postgres-1 psql -U llm -d litellm -c "select request_id, prompt_tokens, completion_tokens from \"LiteLLM_SpendLogs\" where request_id='$rid'"
(rows appear 2-5 s after the request; prepare-lab sent it a while ago)
MSG
# Aider scratch repo
R="$LAB/aider/repo"; rm -rf "$R"; mkdir -p "$R"
printf 'BANNER = "hello"\n\ndef show():\n    print(BANNER)\n' > "$R/app.py"
( cd "$R" && git init -q && git config user.email lab@example.com && git config user.name lab && git add -A && git commit -qm init )
# Open WebUI: wait for admin bootstrap, then plant the stale configuration (6.5): no gateway connection, Ollama enabled on a dead address
wait_http "$OWUI/health" 180 || { echo "prepare-lab: Open WebUI not healthy"; exit 1; }
tok=$(owui_token); [ -n "$tok" ] || { echo "prepare-lab: cannot sign in to Open WebUI"; exit 1; }
curl -sS -o /dev/null -X POST "$OWUI/openai/config/update" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
  -d '{"ENABLE_OPENAI_API":true,"OPENAI_API_BASE_URLS":[],"OPENAI_API_KEYS":[],"OPENAI_API_CONFIGS":{}}'
curl -sS -o /dev/null -X POST "$OWUI/ollama/config/update" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
  -d '{"ENABLE_OLLAMA_API":true,"OLLAMA_BASE_URLS":["http://10.255.255.1:11434"],"OLLAMA_API_CONFIGS":{}}'
echo "prepare-lab: ready. Open WebUI $OWUI (admin credentials in lab/env.sample), gateway $GW. Captured request: lab/captured/."
