#!/usr/bin/env bash
# Reference method for the answer files (what a learner does with curl/jq/psql/docker ps).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; V="$MODULE_DIR/.state/variant.json"
# 0.2: replay the request as a stream with usage and read it
jq '. + {stream_options:{include_usage:true}}' "$LAB/request.json" |
curl -sSN "$LITELLM_URL/v1/chat/completions" -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' -d @- > /tmp/aiinfra-00-stream.txt
grep '^data: {' /tmp/aiinfra-00-stream.txt | sed 's/^data: //' | jq -s '{
  content_chunks: ([.[] | select((.choices[0].delta.content // "") != "")] | length),
  prompt_tokens: ([.[] | .usage // empty][0].prompt_tokens),
  completion_tokens: ([.[] | .usage // empty][0].completion_tokens),
  finish_reason: ([.[] | .choices[0].finish_reason // empty][0]),
  usage_chunk_present: (([.[] | .usage // empty] | length) > 0)}' > "$LAB/answers/stream.json"
rm -f /tmp/aiinfra-00-stream.txt
# 0.3: the ticket row
TID="ticket-$(jq -r .ticket_id "$V")"
docker exec aiinfra-postgres-1 psql -U llm -d litellm -tA -F'|' -c "select request_id, model_group, api_base, total_tokens, status from \"LiteLLM_SpendLogs\" where end_user='$TID' order by \"startTime\" desc limit 1" |
  jq -R 'split("|") | {request_id:.[0], model_group:.[1], api_base:.[2], total_tokens:(.[3]|tonumber), status:.[4]}' > "$LAB/answers/trace.json"
# 0.4: layers + ports
declare -A LAYER=( [litellm]=2 [postgres]=2 [valkey]=2 [llama-chat]=3 [llama-coder]=3 [llama-embed]=3 [open-webui]=1 [aider]=1 [seaweedfs]=4 [registry]=4 )
{ echo "# solved"; for c in $(jq -r '.components[]' "$V"); do
    p=$(docker ps --filter "label=com.docker.compose.service=$c" --format '{{.Ports}}' | tr ',' '\n' | grep -o '127\.0\.0\.1:[0-9]*->' | head -1 | sed 's/127.0.0.1://; s/->//')
    echo "LAYER_${c//-/_}=${LAYER[$c]}"; echo "PORT_${c//-/_}=${p:-none}"; done; } > "$LAB/ARCH.env"
