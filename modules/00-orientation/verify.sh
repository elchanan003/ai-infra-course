#!/usr/bin/env bash
# Module 00 verify: checks LIVE behaviour against lab.md. Makes its own requests; learner config is
# executed (gateway restarted on lab/litellm), answers are compared with values measured now.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"; V="$STATE/variant.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ALL=(0.2.1 0.2.2 0.2.3 0.3.1 0.3.2 0.3.3 0.4.1 0.4.2 0.5.1 0.5.2 0.5.3)
block_all() { local id; for id in "${ALL[@]}"; do blocked "$id" "$1"; done; summary; }

[ -s "$V" ] && [ -r "$LAB/request.json" ] || block_all "run ./prepare-lab.sh first (no variant/lab files)"

# ---- preconditions (unscored) ----------------------------------------------------------------
mounted=$(docker inspect aiinfra-litellm-1 --format '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
precond "LiteLLM reads $LAB/litellm" test "$mounted" = "$LAB/litellm" || block_all "environment not ready - run ./prepare-lab.sh"
precond "llama.cpp engines answer" bash -c "curl -fsS $LLAMA_CHAT_URL/health && curl -fsS $LLAMA_CODER_URL/health" || block_all "engines down - run ./prepare-lab.sh"
wait_idle 70 60 || { warn env "host CPU is busy; not scoring (retry when idle)"; exit 2; }

# Execute the learner's gateway config: restart and wait.
if ! bash "$LAB/bin/reload-gateway.sh" >"$TMP/reload.txt" 2>&1; then
  echo "[PRE] gateway restart with your config: NOT OK ($(tail -1 "$TMP/reload.txt"))"; GW=0
else echo "[PRE] gateway restart with your config: ok"; GW=1; fi

# ---- helpers -----------------------------------------------------------------------------------
metric() { curl -fsS --max-time 5 "$1/metrics" 2>/dev/null | awk -v n="$2" '$1==n{print $2; exit}'; }
stream_probe() {  # prints JSON {content_chunks,prompt_tokens,completion_tokens,finish_reason,usage_chunk_present}
  jq '. + {stream_options:{include_usage:true}}' "$LAB/request.json" > "$TMP/req.json"
  curl -sSN --max-time 120 "$LITELLM_URL/v1/chat/completions" -H "Authorization: Bearer $LITELLM_KEY" \
    -H 'Content-Type: application/json' -d @"$TMP/req.json" 2>/dev/null | python3 -c '
import sys, json
n = 0; fin = None; usage = None; present = False
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data:"): continue
    d = line[5:].strip()
    if d == "[DONE]": continue
    try: o = json.loads(d)
    except Exception: continue
    ch = o.get("choices") or []
    if ch:
        c = ch[0]
        if (c.get("delta") or {}).get("content"): n += 1
        if c.get("finish_reason"): fin = c["finish_reason"]
    if o.get("usage"): usage = o["usage"]; present = True
u = usage or {}
print(json.dumps({"content_chunks": n, "prompt_tokens": u.get("prompt_tokens"), "completion_tokens": u.get("completion_tokens"),
                  "finish_reason": fin, "usage_chunk_present": present}))'
}

# ---- 0.2 stream ----------------------------------------------------------------------------------
if [ "$GW" = 1 ]; then
  stream_probe > "$TMP/s1.json"; stream_probe > "$TMP/s2.json"
  jq -s '.[0]==.[1]' "$TMP/s1.json" "$TMP/s2.json" | grep -q true || warn 0.2 "the engine answered the same request differently twice; any matching run is accepted"
  A="$LAB/answers/stream.json"
  ok_any() { local k="$1" v; v=$(jq -c ".$k" "$A" 2>/dev/null); for f in "$TMP/s1.json" "$TMP/s2.json"; do [ "$(jq -c ".$k" "$f")" = "$v" ] && return 0; done; return 1; }
  if ok_any content_chunks; then pass 0.2.1 "content_chunks matches the stream the gateway delivers"
  else fail 0.2.1 "content_chunks does not match a live replay of lab/request.json (count only chunks with non-empty delta.content; see theory 4.1)"; fi
  if ok_any prompt_tokens && ok_any completion_tokens && [ "$(jq -r '.prompt_tokens // -1' "$TMP/s1.json")" != -1 ]; then pass 0.2.2 "prompt/completion tokens match usage"
  else fail 0.2.2 "prompt_tokens/completion_tokens differ from the live usage (is include_usage requested? usage comes from the engine's tokenizer)"; fi
  if ok_any finish_reason && ok_any usage_chunk_present && [ "$(jq -r .usage_chunk_present "$A" 2>/dev/null)" = true ]; then pass 0.2.3 "finish_reason and usage chunk correct for this request"
  else fail 0.2.3 "finish_reason/usage_chunk_present wrong for this request (what ended generation: EOS or max_tokens? is usage in the stream only on request?)"; fi
else
  for id in 0.2.1 0.2.2 0.2.3; do blocked $id "gateway is down - fix lab/litellm/config.yaml (platform/stack.sh logs litellm)"; done
fi

# ---- 0.3 trace -----------------------------------------------------------------------------------
TID="ticket-$(jq -r .ticket_id "$V")"
row=$(docker exec aiinfra-postgres-1 psql -U llm -d litellm -tA -F'|' -c "select request_id, model_group, api_base, total_tokens, status from \"LiteLLM_SpendLogs\" where \"user\"='$TID' order by \"startTime\" desc limit 1" 2>/dev/null)
T="$LAB/answers/trace.json"
if [ -z "$row" ]; then
  for id in 0.3.1 0.3.2 0.3.3; do blocked $id "the ticket row is missing from the spend log - run ./prepare-lab.sh"; done
else
  IFS='|' read -r r_id r_mg r_ab r_tt r_st <<<"$row"
  [ "$(jq -r .request_id "$T" 2>/dev/null)" = "$r_id" ] && pass 0.3.1 "request_id belongs to $TID" || fail 0.3.1 "request_id is not the spend-log row of the ticket's user (filter on the OpenAI user field, mind the decoy tickets)"
  if [ "$(jq -r .model_group "$T" 2>/dev/null)" = "$r_mg" ] && [ "$(jq -r .api_base "$T" 2>/dev/null)" = "$r_ab" ]; then pass 0.3.2 "model_group and api_base match the row"
  else fail 0.3.2 "model_group/api_base differ from the logged row (report what the gateway actually called, not what you assume)"; fi
  if [ "$(jq -r .total_tokens "$T" 2>/dev/null)" = "$r_tt" ] && [ "$(jq -r .status "$T" 2>/dev/null)" = "$r_st" ]; then pass 0.3.3 "total_tokens and status match the row"
  else fail 0.3.3 "total_tokens/status differ from the row (read the same row: prompt + completion)"; fi
fi

# ---- 0.4 ARCH.env -------------------------------------------------------------------------------
declare -A LAYER=( [litellm]=2 [postgres]=2 [valkey]=2 [llama-chat]=3 [llama-coder]=3 [llama-embed]=3 [open-webui]=1 [aider]=1 [seaweedfs]=4 [registry]=4 )
declare -A WHY=( [postgres]="a datastore belongs to the layer that owns its state" [valkey]="a datastore belongs to the layer that owns its state"
  [seaweedfs]="ask what job it performs for the engines" [registry]="ask what job it performs for the engines" [litellm]="ask which job it performs" )
live_port() { docker ps --filter "label=com.docker.compose.project=aiinfra" --filter "label=com.docker.compose.service=$1" --format '{{.Ports}}' 2>/dev/null \
  | tr ',' '\n' | grep -o '127\.0\.0\.1:[0-9]*->' | head -1 | sed 's/127.0.0.1://; s/->//'; }
bad_layer=""; bad_port=""; n=0
for c in $(jq -r '.components[]' "$V"); do
  n=$((n+1)); nm=${c//-/_}
  got_l=$(env_kv "$LAB/ARCH.env" "LAYER_$nm"); got_p=$(env_kv "$LAB/ARCH.env" "PORT_$nm")
  [ "$got_l" = "${LAYER[$c]}" ] || [ -n "$bad_layer" ] || bad_layer="$c (${WHY[$c]:-assign by the job the component performs})"
  want_p=$(live_port "$c"); want_p=${want_p:-none}
  [ "$got_p" = "$want_p" ] || [ -n "$bad_port" ] || bad_port="$c"
done
[ -z "$bad_layer" ] && pass 0.4.1 "all $n components are in the right layer" || fail 0.4.1 "layer of $bad_layer is wrong (theory 2: the assignment rule)"
[ -z "$bad_port" ] && pass 0.4.2 "all PORT_ values match docker ps" || fail 0.4.2 "PORT of $bad_port does not match what docker ps publishes on 127.0.0.1 (none if not running/published)"

# ---- 0.5 planted fault: coder alias --------------------------------------------------------------
if [ "$GW" = 1 ]; then
  c0=$(metric "$LLAMA_CODER_URL" llamacpp:prompt_tokens_total); h0=$(metric "$LLAMA_CHAT_URL" llamacpp:prompt_tokens_total)
  code=$(litellm_code "$LITELLM_KEY" coder "Say OK")
  c1=$(metric "$LLAMA_CODER_URL" llamacpp:prompt_tokens_total); h1=$(metric "$LLAMA_CHAT_URL" llamacpp:prompt_tokens_total)
  if [ "$code" = 200 ]; then pass 0.5.1 "alias coder answers 200"
  else fail 0.5.1 "alias coder returned HTTP $code: the gateway cannot reach its backend (read the gateway log, then probe the engine from inside the network; ladder in theory 6)"; fi
  if ! passed 0.5.1; then blocked 0.5.2 "needs 0.5.1"
  elif awk -v a="${c1:-0}" -v b="${c0:-0}" -v x="${h1:-0}" -v y="${h0:-0}" 'BEGIN{exit !(a>b && x==y)}'; then pass 0.5.2 "the coder engine served it and the chat engine did not move"
  else fail 0.5.2 "a 200 came back but the coder engine's counter did not move alone - the alias points at the wrong backend"; fi
  if ! passed 0.5.1; then blocked 0.5.3 "needs 0.5.1"
  else
    c0=$(metric "$LLAMA_CODER_URL" llamacpp:prompt_tokens_total); h0=$(metric "$LLAMA_CHAT_URL" llamacpp:prompt_tokens_total)
    code=$(litellm_code "$LITELLM_KEY" chat "Say OK")
    c1=$(metric "$LLAMA_CODER_URL" llamacpp:prompt_tokens_total); h1=$(metric "$LLAMA_CHAT_URL" llamacpp:prompt_tokens_total)
    if [ "$code" = 200 ] && awk -v a="${c1:-0}" -v b="${c0:-0}" -v x="${h1:-0}" -v y="${h0:-0}" 'BEGIN{exit !(x>y && a==b)}'; then pass 0.5.3 "alias chat still served by the chat engine only"
    else fail 0.5.3 "alias chat broke or no longer reaches the chat engine alone (HTTP $code)"; fi
  fi
else
  for id in 0.5.1 0.5.2 0.5.3; do blocked $id "gateway is down - fix lab/litellm/config.yaml first"; done
fi
summary
