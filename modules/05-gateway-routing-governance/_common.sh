# Shared helpers for module 05 scripts (sourced). Not a learner file.
source "$(dirname "${BASH_SOURCE[0]}")/../../platform/lib.sh"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"
GW="${LITELLM_URL:-http://127.0.0.1:18040}"; MASTER="${LITELLM_KEY:-sk-aiinfra-master}"
PGC=aiinfra-postgres-1
mkdir -p "$STATE"
pg() { docker exec "$PGC" psql -U llm -d litellm -tAc "$1" 2>/dev/null | tr -d '\r'; }
admin() { local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' -d "$d" "$GW$p"
  else curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" "$GW$p"; fi; }
# req KEY MODEL PROMPT [EXTRA_JSON] -> HTTP status; body $TMP/body, headers $TMP/hdr
req() { local key="$1" model="$2" prompt="${3:-ping}" extra="${4:-}"
  local body; body=$(jq -nc --arg m "$model" --arg p "$prompt" --argjson e "${extra:-{\}}" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:20}+$e')
  curl -sS -o "$TMP/body" -D "$TMP/hdr" -w '%{http_code}' --max-time 120 "$GW/v1/chat/completions" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo 000; }
mhits() {  # chat requests seen by mock A|B (all statuses), from /admin/stats
  mock_stats "$1" | jq -r '[.requests[]?.chat // 0] | add // 0'; }
mfail() { mock_stats "$1" | jq -r '.errors_injected // 0'; }
gw_wait() { wait_http "$GW/health/liveliness" "${1:-120}"; }
gw_restart() { "$PLATFORM_DIR/stack.sh" compose restart litellm >/dev/null 2>&1; sleep 3; gw_wait 150; }
stack_up() { export LITELLM_CONFIG_DIR="${LITELLM_CONFIG_DIR:-$LAB/litellm}" MOCK_VLLM_A_CONFIG_DIR="$MODULE_DIR/env/mock-a" MOCK_VLLM_B_CONFIG_DIR="$MODULE_DIR/env/mock-b"
  chmod -R a+rX "$LAB/litellm" "$MODULE_DIR/env"; "$PLATFORM_DIR/stack.sh" up gw mock; }
reset_mocks() { for p in A B; do mock_fault "$p" DELETE >/dev/null 2>&1; done; }
vget() { env_kv "$STATE/variant.env" "$1"; }
