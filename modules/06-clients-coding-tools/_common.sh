# Shared helpers for module 06 scripts (sourced). Not a learner file.
source "$(dirname "${BASH_SOURCE[0]}")/../../platform/lib.sh"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"
GW="${LITELLM_URL:-http://127.0.0.1:18040}"; MASTER="${LITELLM_KEY:-sk-aiinfra-master}"
OWUI="${OWUI_URL:-http://127.0.0.1:18080}"
PY="$PLATFORM_DIR/../platform/.venv/bin/python"
PGC=aiinfra-postgres-1; OWUIC=aiinfra-open-webui-1
pg() { docker exec "$PGC" psql -U llm -d litellm -tAc "$1" 2>/dev/null | tr -d '\r'; }
admin() { local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' -d "$d" "$GW$p"
  else curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $MASTER" "$GW$p"; fi; }
gw_wait() { wait_http "$GW/health/liveliness" "${1:-120}"; }
stack_up() { export LITELLM_CONFIG_DIR="$MODULE_DIR/env/litellm" MOCK_VLLM_A_CONFIG_DIR="$MODULE_DIR/env/mock-a" MOCK_VLLM_B_CONFIG_DIR="$MODULE_DIR/env/mock-b"
  chmod -R a+rX "$MODULE_DIR/env"; "$PLATFORM_DIR/stack.sh" up gw ui mock llm; }
reset_mocks() { for p in A B; do mock_fault "$p" DELETE >/dev/null 2>&1; done; }
keyhash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
owui_token() { curl -sS --max-time 20 "$OWUI/api/v1/auths/signin" -H 'Content-Type: application/json' \
  -d '{"email":"admin@aiinfra.local","password":"Admin-pass-1"}' | jq -r '.token // empty'; }
# spend rows for a key value: count (optionally model_group)
spend_rows() { local h; h=$(keyhash "$1"); pg "select count(*) from \"LiteLLM_SpendLogs\" where api_key='$h'${2:+ and model_group='$2'}"; }
. "$LAB/env.sample"
