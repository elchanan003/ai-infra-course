#!/usr/bin/env bash
# Shared harness library for course scripts (CONVENTIONS.md section 8). FROZEN after WP2: changes only via the coordinator.
# Source it:  source "$(dirname "$0")/../../platform/lib.sh"
# No `set -e` here on purpose: checks must keep running after a failing command.
#
# ---- Checks -------------------------------------------------------------------------------------
#   pass ID MSG | fail ID MSG | blocked ID MSG   print "[PASS] ID MSG" / "[FAIL] ..." / "[BLOCKED] ..."
#   passed ID                                    exit 0 iff check ID passed (use for BLOCKED cascades)
#   warn ID MSG                                  print "[WARN] ID MSG" (unscored)
#   precond DESC CMD...                          run CMD; print "[PRE] DESC: ok|NOT OK" (unscored); returns CMD's status
#   summary                                      print "SCORE: x/y" (y = PASS+FAIL+BLOCKED), write <module dir>/.last-verify
#                                                (timestamp+score); exit 0 only if >=1 check ran and all passed
# ---- Polling / timing ---------------------------------------------------------------------------
#   wait_http URL [TIMEOUT_S=60]                 poll until HTTP 2xx/3xx; 0 ok, 1 timeout
#   within SECS CMD...                           retry CMD every 1 s until it succeeds or SECS elapse; 0/1
#   wait_idle [MAX_BUSY_PCT=60] [TIMEOUT_S=60]   wait until host CPU busy% (2 s samples) < MAX; 1 on timeout
#                                                (verify prints WARN and refuses to score on 1; rule 9)
# ---- Prometheus / Grafana -----------------------------------------------------------------------
#   prom_query EXPR                              instant query -> raw JSON of /api/v1/query
#   prom_value EXPR                              first sample value, or empty string
#   grafana_api PATH [curl args]                 Grafana HTTP API as admin:admin -> body (curl -fsS)
#   promtool_test TESTFILE                       `promtool test rules TESTFILE` from the prometheus image (rule files are
#                                                resolved relative to TESTFILE; PROMTOOL_MOUNT=<dir> widens the mounted dir,
#                                                default dirname TESTFILE); output printed, returns promtool's status
#   promtool_check FILE...                       `promtool check rules FILE...` (same mounting rules, first file's dir)
# ---- LiteLLM gateway ----------------------------------------------------------------------------
#   litellm_api PATH [curl args]                 gateway API (master key sk-aiinfra-master or $LITELLM_KEY); body on stdout,
#                                                no -f (error bodies are returned); e.g. litellm_api /key/generate -d '{"models":["chat"]}'
#   litellm_code KEY MODEL [PROMPT]              one /v1/chat/completions with KEY; prints the HTTP status only
#   litellm_chat KEY MODEL [PROMPT]              same, prints the response body
#   litellm_flush_wait [KEY [N=1 [TIMEOUT_S=30]]]  bounded poll for batch-written spend logs (proxy_batch_write_at: 5, lag 2-5 s):
#                                                with KEY (sk-... or 64-hex hash): until >=N rows in LiteLLM_SpendLogs for it;
#                                                without args: until the total row count is stable for 7 s. 0 ok, 1 timeout
#   litellm_spend KEY                            spend of KEY from /key/info (empty if unknown)
# ---- Mocks / tripwire / sandbox -----------------------------------------------------------------
#   mock_stats [A|B=A]                           GET /admin/stats of mock-vllm A (18021) or B (18022) -> JSON
#   mock_fault [A|B] [METHOD=GET] [JSON]         /admin/fault of mock-vllm: GET read, POST set (JSON body), DELETE reset
#   tripwire_hits [HOST_REGEX]                   number of tripwire hits (all, or hosts matching the regex); 0 if tripwire down
#   tripwire_reset                               DELETE /hits (zero the counter)
#   sandbox_run [docker run flags] IMAGE [CMD..] run a throwaway container on the internal network aiinfra-airgap
#                                                (DNS = tripwire, no route out, label course=aiinfra, caps dropped); needs profile store
# ---- Misc ---------------------------------------------------------------------------------------
#   env_kv FILE KEY                              value of KEY in an env-style file (KEY=VALUE; last wins; quotes stripped)
#   k ...                                        kubectl --context kind-aiinfra ...
# Endpoints overridable: PROM_URL GRAFANA_URL GRAFANA_AUTH LITELLM_URL LITELLM_KEY MOCK_A_URL MOCK_B_URL TRIPWIRE_URL
#                        LLAMA_CHAT_URL LLAMA_CODER_URL LLAMA_EMBED_URL QDRANT_URL REGISTRY_URL S3_URL HFMIRROR_URL OWUI_URL LANGFUSE_URL VLLM_URL

PROM_URL="${PROM_URL:-http://127.0.0.1:18090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:18030}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:admin}"
LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:18040}"
LITELLM_KEY="${LITELLM_KEY:-sk-aiinfra-master}"
MOCK_A_URL="${MOCK_A_URL:-http://127.0.0.1:18021}"
MOCK_B_URL="${MOCK_B_URL:-http://127.0.0.1:18022}"
TRIPWIRE_URL="${TRIPWIRE_URL:-http://127.0.0.1:18072}"
LLAMA_CHAT_URL="${LLAMA_CHAT_URL:-http://127.0.0.1:18011}"
LLAMA_CODER_URL="${LLAMA_CODER_URL:-http://127.0.0.1:18012}"
LLAMA_EMBED_URL="${LLAMA_EMBED_URL:-http://127.0.0.1:18013}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:18033}"
REGISTRY_URL="${REGISTRY_URL:-http://127.0.0.1:18050}"
S3_URL="${S3_URL:-http://127.0.0.1:18070}"
HFMIRROR_URL="${HFMIRROR_URL:-http://127.0.0.1:18071}"
OWUI_URL="${OWUI_URL:-http://127.0.0.1:18080}"
LANGFUSE_URL="${LANGFUSE_URL:-http://127.0.0.1:18060}"
VLLM_URL="${VLLM_URL:-http://127.0.0.1:18023}"
TRIPWIRE_AIRGAP_IP=172.29.231.2

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COURSE_DIR="$(cd "$PLATFORM_DIR/.." && pwd)"
# Directory of the script that sourced this library (the module dir for verify.sh).
_lib_caller="${BASH_SOURCE[1]:-$0}"
MODULE_DIR="${MODULE_DIR:-$(cd "$(dirname "$_lib_caller")" && pwd)}"
export PATH="$HOME/.local/bin:$PATH"
[ -r "$PLATFORM_DIR/versions.env" ] && { set -a; . "$PLATFORM_DIR/versions.env"; set +a; }

_LIB_PASS=0
_LIB_FAIL=0
_LIB_BLOCKED=0
declare -A _LIB_RESULT=()

pass()    { _LIB_PASS=$((_LIB_PASS + 1));       _LIB_RESULT["$1"]=PASS;    echo "[PASS] $1 ${*:2}"; }
fail()    { _LIB_FAIL=$((_LIB_FAIL + 1));       _LIB_RESULT["$1"]=FAIL;    echo "[FAIL] $1 ${*:2}"; }
blocked() { _LIB_BLOCKED=$((_LIB_BLOCKED + 1)); _LIB_RESULT["$1"]=BLOCKED; echo "[BLOCKED] $1 ${*:2}"; }
passed()  { [ "${_LIB_RESULT[$1]:-}" = PASS ]; }
warn()    { echo "[WARN] $1 ${*:2}"; }

precond() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "[PRE] $desc: ok"; return 0; fi
  echo "[PRE] $desc: NOT OK"; return 1
}

summary() {
  local total=$((_LIB_PASS + _LIB_FAIL + _LIB_BLOCKED))
  echo "SCORE: ${_LIB_PASS}/${total}"
  printf '%s SCORE: %s/%s pass=%s fail=%s blocked=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$_LIB_PASS" "$total" "$_LIB_PASS" "$_LIB_FAIL" "$_LIB_BLOCKED" > "$MODULE_DIR/.last-verify" 2>/dev/null || true
  if [ "$total" -gt 0 ] && [ "$_LIB_PASS" -eq "$total" ]; then exit 0; fi
  exit 1
}

wait_http() {
  local url="$1" timeout="${2:-60}" start; start=$(date +%s)
  while :; do
    if curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null; then return 0; fi
    (( $(date +%s) - start >= timeout )) && return 1
    sleep 1
  done
}

within() {
  local secs="$1" start; shift; start=$(date +%s)
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    (( $(date +%s) - start >= secs )) && return 1
    sleep 1
  done
}

_cpu_busy_pct() {  # busy% over a 2 s sample
  local a b idle1 tot1 idle2 tot2
  read -r _ a < <(head -1 /proc/stat); set -- $a
  idle1=$(( $4 + ${5:-0} )); tot1=0; for b in "$@"; do tot1=$((tot1 + b)); done
  sleep 2
  read -r _ a < <(head -1 /proc/stat); set -- $a
  idle2=$(( $4 + ${5:-0} )); tot2=0; for b in "$@"; do tot2=$((tot2 + b)); done
  echo $(( 100 * ( (tot2 - tot1) - (idle2 - idle1) ) / ( (tot2 - tot1) > 0 ? (tot2 - tot1) : 1 ) ))
}

wait_idle() {
  local max="${1:-60}" timeout="${2:-60}" start busy; start=$(date +%s)
  while :; do
    busy=$(_cpu_busy_pct)
    [ "$busy" -lt "$max" ] && return 0
    (( $(date +%s) - start >= timeout )) && { echo "wait_idle: host CPU busy ${busy}% (>= ${max}%)" >&2; return 1; }
  done
}

prom_query() {
  curl -fsS --max-time 10 "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}

prom_value() {
  prom_query "$1" | jq -r '
    if .status != "success" then empty
    elif .data.resultType == "vector" then (.data.result[0].value[1] // empty)
    elif .data.resultType == "scalar" then .data.result[1]
    else empty end' 2>/dev/null
}

grafana_api() {
  local path="$1"; shift
  curl -fsS --max-time 10 -u "$GRAFANA_AUTH" -H 'Content-Type: application/json' \
    "$GRAFANA_URL/${path#/}" "$@" 2>/dev/null
}

_promtool() {  # MOUNTDIR promtool-args...
  local dir; dir="$(cd "$1" && pwd)"; shift
  docker run --rm --label course=aiinfra --user "$(id -u):$(id -g)" --entrypoint promtool \
    -v "$dir:/w:ro" -w /w "$PROMETHEUS_IMAGE" "$@"
}
promtool_test() {
  local f="$1" dir="${PROMTOOL_MOUNT:-$(dirname "$1")}"
  local abs; abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  dir="$(cd "$dir" && pwd)"
  _promtool "$dir" test rules "/w${abs#"$dir"}"
}
promtool_check() {
  local dir="${PROMTOOL_MOUNT:-$(dirname "$1")}" a=() f abs
  dir="$(cd "$dir" && pwd)"
  for f in "$@"; do abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; a+=("/w${abs#"$dir"}"); done
  _promtool "$dir" check rules "${a[@]}"
}

litellm_api() {
  local path="$1"; shift
  curl -sS --max-time 30 -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
    "$LITELLM_URL/${path#/}" "$@" 2>/dev/null
}

_litellm_chat_args() {  # KEY MODEL PROMPT -> prints JSON body
  jq -nc --arg m "$2" --arg p "${3:-ping}" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:16}'
}
litellm_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "$LITELLM_URL/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$(_litellm_chat_args "$@")" 2>/dev/null
}
litellm_chat() {
  curl -sS --max-time 60 "$LITELLM_URL/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$(_litellm_chat_args "$@")" 2>/dev/null
}

_pg() { docker exec aiinfra-postgres-1 psql -U llm -d litellm -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
litellm_flush_wait() {
  local key="${1:-}" n="${2:-1}" timeout="${3:-30}" start cnt last="" stable_since hash
  start=$(date +%s)
  if [ -n "$key" ]; then
    if [[ "$key" =~ ^[0-9a-f]{64}$ ]]; then hash="$key"; else hash=$(printf '%s' "$key" | sha256sum | cut -d' ' -f1); fi
    while :; do
      cnt=$(_pg "select count(*) from \"LiteLLM_SpendLogs\" where api_key='$hash'")
      [ "${cnt:-0}" -ge "$n" ] 2>/dev/null && return 0
      (( $(date +%s) - start >= timeout )) && return 1
      sleep 1
    done
  fi
  stable_since=$(date +%s)
  while :; do
    cnt=$(_pg 'select count(*) from "LiteLLM_SpendLogs"')
    if [ "$cnt" != "$last" ]; then last="$cnt"; stable_since=$(date +%s); fi
    (( $(date +%s) - stable_since >= 7 )) && return 0
    (( $(date +%s) - start >= timeout + 7 )) && return 1
    sleep 1
  done
}

litellm_spend() {
  litellm_api "/key/info?key=$1" | jq -r '.info.spend // empty' 2>/dev/null
}

_mock_url() { case "${1:-A}" in [Bb]) echo "$MOCK_B_URL" ;; *) echo "$MOCK_A_URL" ;; esac; }
mock_stats() { curl -fsS --max-time 10 "$(_mock_url "${1:-A}")/admin/stats" 2>/dev/null; }
mock_fault() {
  local u; u="$(_mock_url "${1:-A}")"; local m="${2:-GET}" body="${3:-}"
  if [ -n "$body" ]; then curl -fsS --max-time 10 -X "$m" -H 'Content-Type: application/json' -d "$body" "$u/admin/fault" 2>/dev/null
  else curl -fsS --max-time 10 -X "$m" "$u/admin/fault" 2>/dev/null; fi
}

tripwire_hits() {  # tolerant of {"total":N,"hosts":{h:n}} / {h:n} / {h:{count:n}} shapes
  local pat="${1:-}"
  curl -fsS --max-time 5 "$TRIPWIRE_URL/hits" 2>/dev/null | jq -r --arg p "$pat" '
    def cnt: if type=="number" then . elif type=="object" then (.count // .hits // 0) else 0 end;
    if $p == "" then (.total // ((.hosts // .) | if type=="object" then ([.[]|cnt]|add // 0) else length end))
    else ((.hosts // .) | if type=="object" then ([to_entries[]|select(.key|test($p))|.value|cnt]|add // 0) else 0 end) end' 2>/dev/null \
    || echo 0
}
tripwire_reset() { curl -fsS --max-time 5 -X DELETE "$TRIPWIRE_URL/hits" >/dev/null 2>&1; }

sandbox_run() {
  docker network inspect aiinfra-airgap >/dev/null 2>&1 || { echo "sandbox_run: network aiinfra-airgap missing (stack.sh up store)" >&2; return 1; }
  docker run --rm --label course=aiinfra --network aiinfra-airgap --dns "$TRIPWIRE_AIRGAP_IP" \
    --cap-drop ALL --security-opt no-new-privileges "$@"
}

env_kv() {
  local f="$1" key="$2"
  [ -r "$f" ] || return 1
  grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$f" | tail -1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${key}=//; s/[[:space:]]+#.*\$//; s/^[\"']//; s/[\"']\$//"
}

k() { kubectl --context kind-aiinfra "$@"; }
