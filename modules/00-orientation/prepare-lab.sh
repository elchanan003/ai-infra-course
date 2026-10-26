#!/usr/bin/env bash
# Module 00 prepare: converge to profiles gw+llm with LiteLLM reading lab/litellm/, assign the
# per-learner variant (.state/variant.json, stable across cleanups), create the variant-bound lab
# files (only if missing), and seed the helpdesk ticket request. Idempotent. Never reveals answers.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"; mkdir -p "$STATE"
chmod -R a+rX "$LAB/litellm"

# ---- variant (assigned once) ------------------------------------------------------------------
if [ ! -s "$STATE/variant.json" ]; then
python3 - "$STATE/variant.json" <<'PY'
import json, random, sys
r = random.SystemRandom()
reqs = [
  ("Count from 1 to 40, numbers only, separated by spaces.", 14),
  ("Reply with exactly the single word: PONG", 64),
  ("List the seven days of the week, comma separated, nothing else.", 20),
  ("Name three primary colours, one per line, nothing else.", 16),
]
tickets = [("Explain in one sentence what a load balancer does.", 12),
           ("Give one tip for writing a good commit message.", 18),
           ("What is DNS? Answer in one short sentence.", 15)]
pool = ["litellm","postgres","valkey","llama-chat","llama-coder","llama-embed","open-webui","aider","seaweedfs","registry"]
running = pool[:6]; other = pool[6:]
comps = r.sample(running, 5) + r.sample(other, 3)
r.shuffle(comps)
t = r.choice(tickets)
v = {"req": r.choice(reqs), "ticket_id": "%06x" % r.randrange(1 << 24),
     "ticket_prompt": t[0], "ticket_max_tokens": t[1], "components": comps}
json.dump(v, open(sys.argv[1], "w"), indent=1)
PY
fi
V="$STATE/variant.json"

# ---- variant-bound lab files (never overwrite learner edits) ------------------------------------
[ -e "$LAB/request.json" ] || jq '{model:"chat", messages:[{role:"user",content:.req[0]}], max_tokens:.req[1], temperature:0, seed:7, stream:true}' "$V" > "$LAB/request.json"
[ -e "$LAB/TICKET.txt" ] || printf 'Helpdesk ticket: "my request from this morning looked slow and I was told it used a lot of tokens".\nTicket id: ticket-%s\n(The request was sent through the gateway with this value in the OpenAI "user" field.)\n' "$(jq -r .ticket_id "$V")" > "$LAB/TICKET.txt"
if [ ! -e "$LAB/ARCH.env" ]; then
  { echo "# Fill every LAYER_ with 1|2|3|4 (1 clients, 2 gateway/control incl. its state, 3 engines, 4 hardware/platform)"
    echo "# and every PORT_ with the host port published on 127.0.0.1 (docker ps), or none."
    for c in $(jq -r '.components[]' "$V"); do n=${c//-/_}; echo "LAYER_${n}="; echo "PORT_${n}="; done; } > "$LAB/ARCH.env"
fi

# ---- stack -------------------------------------------------------------------------------------
LITELLM_CONFIG_DIR="$LAB/litellm" "$PLATFORM_DIR/stack.sh" up gw llm >/dev/null || { echo "prepare-lab: stack did not come up healthy (platform/stack.sh status; platform/doctor.sh)"; exit 1; }
wait_http "$LITELLM_URL/health/liveliness" 90 || { echo "prepare-lab: gateway not live"; exit 1; }

# ---- seed the ticket request (and decoys) once -------------------------------------------------
TID="ticket-$(jq -r .ticket_id "$V")"
have=$(docker exec aiinfra-postgres-1 psql -U llm -d litellm -tAc "select count(*) from \"LiteLLM_SpendLogs\" where \"user\"='$TID'" 2>/dev/null | tr -d '[:space:]')
if [ "${have:-0}" = 0 ]; then
  send() { curl -sS -o /dev/null --max-time 90 "$LITELLM_URL/v1/chat/completions" -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg u "$1" --arg p "$2" --argjson n "$3" '{model:"chat",messages:[{role:"user",content:$p}],max_tokens:$n,temperature:0,user:$u}')"; }
  send "ticket-$(printf '%06x' $((RANDOM*RANDOM % 16777216)))" "Say hello in French." 9
  send "$TID" "$(jq -r .ticket_prompt "$V")" "$(jq -r .ticket_max_tokens "$V")"
  send "ticket-$(printf '%06x' $((RANDOM*RANDOM % 16777216)))" "What is 2+2?" 11
  litellm_flush_wait "" 1 30 || echo "prepare-lab: WARN spend logs slow to flush"
fi
cat <<MSG
prepare-lab: ready (profiles gw llm).
  Gateway  http://127.0.0.1:18040   (lab/litellm/config.yaml; reload: lab/bin/reload-gateway.sh)
  Engines  chat :18011  coder :18012  embed :18013
  Your files: lab/request.json (given), lab/TICKET.txt (given), lab/ARCH.env, lab/answers/*.json, lab/litellm/config.yaml
MSG
