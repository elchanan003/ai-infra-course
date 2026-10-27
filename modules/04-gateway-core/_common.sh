# Shared helpers for module 04 scripts (sourced). Not a learner file.
source "$(dirname "${BASH_SOURCE[0]}")/../../platform/lib.sh"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"
GW="${LITELLM_URL:-http://127.0.0.1:18040}"; GW2="http://127.0.0.1:18041"
MASTER="${LITELLM_KEY:-sk-aiinfra-master}"
PGC=aiinfra-postgres-1; GW1C=aiinfra-litellm-1; GW2C=aiinfra-litellm-2-1; VALKEYC=aiinfra-valkey-1
CLIENT_C=aiinfra-lab04-client; CLIENT_NET=aiinfra-lab04-client

pg() { docker exec "$PGC" psql -U llm -d litellm -tAc "$1" 2>/dev/null | tr -d '\r'; }
admin() {  # admin METHOD PATH [JSON]  -> body on stdout (master key)
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' -d "$d" "$GW$p"
  else curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" "$GW$p"; fi
}
# req BASE KEY MODEL [PROMPT] [EXTRA_JSON_FIELDS]  -> HTTP status on stdout, body in $TMP/body, headers in $TMP/hdr
req() {
  local base="$1" key="$2" model="$3" prompt="${4:-ping}" extra="${5:-}"
  local body; body=$(jq -nc --arg m "$model" --arg p "$prompt" --argjson e "${extra:-{\}}" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:16}+$e')
  curl -sS -o "$TMP/body" -D "$TMP/hdr" -w '%{http_code}' --max-time 90 "$base/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo 000
}
embed_req() { curl -sS -o "$TMP/body" -w '%{http_code}' --max-time 60 "$1/v1/embeddings" -H "Authorization: Bearer $2" -H 'Content-Type: application/json' -d '{"model":"embed","input":"hello"}' 2>/dev/null || echo 000; }
gw_wait() { wait_http "${1:-$GW}/health/liveliness" "${2:-120}"; }
gw_restart() { "$PLATFORM_DIR/stack.sh" compose restart litellm >/dev/null 2>&1; sleep 3; gw_wait "$GW" 150; }
stack_up() {  # stack_up CONFIG_DIR profile...
  local d="$1"; shift
  chmod -R a+rX "$d" 2>/dev/null
  LITELLM_CONFIG_DIR="$d" "$PLATFORM_DIR/stack.sh" up "$@"
}
mounted_cfg() { docker inspect "${1:-$GW1C}" --format '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null; }
keyhash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
kv() { env_kv "$LAB/out/keys.env" "$1"; }
