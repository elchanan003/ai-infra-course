#!/usr/bin/env bash
# Shared helpers for the capstone scripts (sourced by prepare-lab.sh, verify.sh, cleanup.sh, verify-clean.sh, apply-solution.sh).
CAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MODULE_DIR="$CAP"
source "$CAP/../../platform/lib.sh"
LAB="$CAP/lab"; STATE="$CAP/.state"; LIB="$CAP/lib"
P="$PLATFORM_DIR"
PY="$PLATFORM_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3
GW1="$LITELLM_URL"; GW2="http://127.0.0.1:18041"
AIINFRA_CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
export AIINFRA_CACHE
# Calibration constants (virtual-clock seconds / counters on deterministic mock data). One place, see .tutor/design.md.
SLO_TTFT_S="${CAP_SLO_TTFT_S:-10}"          # incident 2 peak replay, TTFT p95 (virtual seconds; histogram bucket edge, buckets ... 5 7.5 10 20 ...)
SLO_TTFT_GW_S="${CAP_SLO_TTFT_GW_S:-2.5}"   # incident 1 chat probe, TTFT p95 (virtual seconds; bucket edge)
I3_SICK_MAX_HITS="${CAP_I3_SICK_MAX_HITS:-10}"   # incident 3: max requests the sick backend may serve out of 40
I3_MAX_WALL_S="${CAP_I3_MAX_WALL_S:-5.5}"   # incident 3: no user may wait about as long as the sick node stalls (6 s)

die() { echo "prepare-lab: ERROR $*" >&2; exit 1; }
rhex() { od -An -N"${1:-3}" -tx1 /dev/urandom | tr -d ' \n'; }
pick() { local a=("$@"); echo "${a[RANDOM % ${#a[@]}]}"; }   # pick a b c -> one of them
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
nwords() { printf '%s' "$1" | wc -w; }
isint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
inrange() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }

# ---- hidden state -------------------------------------------------------------------------------------
current() { cat "$STATE/current" 2>/dev/null; }
vget() { env_kv "$STATE/$1/variant.env" "$2"; }    # vget N KEY  (hidden variant; never printed to the learner)
tget() { env_kv "$STATE/$1/truth.env" "$2"; }      # tget N KEY  (evidence truth recorded at plant time)
kvf() { env_kv "$@" | sed -E 's/[[:space:]]+$//'; }   # learner answer files: KEY=value (inline "  # note" stripped)
# write KEY=VALUE lines to a state file (atomic)
state_write() { local f="$1"; shift; mkdir -p "$(dirname "$f")"; : > "$f.tmp"; local kv; for kv in "$@"; do printf '%s=%s\n' "${kv%%=*}" "${kv#*=}" >> "$f.tmp"; done; mv "$f.tmp" "$f"; }

# ---- stack / cluster ---------------------------------------------------------------------------------
kind_up() { kind get clusters 2>/dev/null | grep -qx aiinfra; }
mock_chat_count() {  # A|B -> total chat requests the mock-vllm has served since its start
  mock_stats "${1:-A}" | jq '[.requests[]? | (.chat // 0)] | add // 0' 2>/dev/null || echo 0
}
snap_metrics() { curl -fsS --max-time 10 "$(case "$1" in B|b) echo "$MOCK_B_URL";; *) echo "$MOCK_A_URL";; esac)/metrics" > "$2" 2>/dev/null; }
gw_wait() { wait_http "${1:-$GW1}/health/liveliness" "${2:-120}"; }
gw_key() {  # METHOD PATH [JSON] against replica 1 with the master key
  local m="$1" path="$2" d="${3:-}"
  if [ -n "$d" ]; then curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' -d "$d" "$GW1$path"
  else curl -sS --max-time 30 -X "$m" -H "Authorization: Bearer $LITELLM_KEY" "$GW1$path"; fi
}
req_code() {  # BASE KEY MODEL [PROMPT] -> HTTP status
  local b="$1" key="$2" model="$3" pr="${4:-ping}"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "$b/v1/chat/completions" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$model" --arg p "$pr" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:8}')" 2>/dev/null || echo 000
}
chmod_pub() { chmod -R a+rX "$@" 2>/dev/null; }

# Per-incident environment for stack.sh (config dirs of THE LEARNER'S files; hidden hardware state from .state).
inc_env() {
  unset LITELLM_CONFIG_DIR MOCK_VLLM_A_CONFIG_DIR MOCK_VLLM_B_CONFIG_DIR MOCK_DCGM_A_CONFIG_DIR MOCK_DCGM_B_CONFIG_DIR MOCK_TIME_SCALE
  case "$1" in
    1) export LITELLM_CONFIG_DIR="$LAB/incident-1/litellm" ;;
    2) export MOCK_VLLM_A_CONFIG_DIR="$LAB/incident-2/mock-vllm-a" MOCK_TIME_SCALE=2 ;;
    3) export LITELLM_CONFIG_DIR="$LAB/incident-3/litellm" MOCK_VLLM_A_CONFIG_DIR="$STATE/3/mock-vllm-a" MOCK_VLLM_B_CONFIG_DIR="$STATE/3/mock-vllm-b" \
              MOCK_DCGM_A_CONFIG_DIR="$STATE/3/dcgm-a" MOCK_DCGM_B_CONFIG_DIR="$STATE/3/dcgm-b" MOCK_TIME_SCALE=1 ;;
  esac
  chmod_pub "$LAB/incident-$1" "$STATE/$1" 2>/dev/null
}
inc_profiles() { case "$1" in 1) echo "gw gw2 mock obs";; 2|3) echo "gw mock obs";; 4) echo "store";; esac; }
stack_up_inc() {  # converge the profiles of incident N with its env; extra tolerance for deliberately broken mocks
  inc_env "$1"; "$P/stack.sh" up $(inc_profiles "$1") >/dev/null 2>&1
}
recreate() {  # recreate compose services (re-read their config dirs) and wait for health; env must be set (inc_env)
  "$P/stack.sh" compose up -d --force-recreate --no-deps "$@" >/dev/null 2>&1
}
svc_port() { case "$1" in mock-vllm-a) echo 18021;; mock-vllm-b) echo 18022;; mock-dcgm-a) echo 18031;; mock-dcgm-b) echo 18032;; litellm) echo 18040;; litellm-2) echo 18041;; esac; }
svc_health() { local s="$1"; if [ "$s" = litellm ] || [ "$s" = litellm-2 ]; then wait_http "http://127.0.0.1:$(svc_port "$s")/health/liveliness" "${2:-120}"; else wait_http "http://127.0.0.1:$(svc_port "$s")/health" "${2:-60}"; fi; }
svc_log_error() {  # last error-looking line of a service's log (for FAIL messages; real engine text, not an answer)
  "$P/stack.sh" logs "$1" --tail 40 2>/dev/null | grep -E "Error|error|ERROR" | tail -1 | sed -E 's/^[^|]*\| *//' | cut -c1-260
}
prom_ready() { wait_http "$PROM_URL/-/ready" "${1:-60}"; }

# ---- incident window / results / small helpers --------------------------------------------------------
win_set() { printf '%s %s\n' "$2" "$3" > "$STATE/$1/win"; }       # win_set N start_epoch end_epoch
win_get() { cat "$STATE/$1/win" 2>/dev/null; }                      # -> "start end"
utc_hms() { date -u -d "@$1" +%H:%M:%S; }
win_text() { local w; w=$(win_get "$1"); set -- $w; echo "Incident window (UTC): $(utc_hms "$1") - $(utc_hms "$2")  (epoch $1 - $2; Prometheus keeps the data)"; }
save_result() { mkdir -p "$STATE"; printf '%s/5 %s\n' "$_LIB_PASS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/result-$1"; }
num() { printf '%s' "${1:-}" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; }
tmpl() { case "${1:-}" in ""|*"<"*|*">"*) return 0;; esac; return 1; }   # empty or still a template placeholder
# PromQL over the incident window of incident N, evaluated at the window end:  pq_win N 'increase(m{...}[%D%])'
pq_win() {
  local w d e q="$2"; w=$(win_get "$1"); set -- $w
  d=$(( $2 - $1 )); e="$2"
  prom_value "${q//\[%D%\]/[${d}s] @ ${e}}"
}
write_restart() {  # N FILE "what it does" -> GIVEN helper next to the learner's files
  local n="$1" f="$2" what="$3"
  cat > "$f" <<SH
#!/usr/bin/env bash
# GIVEN (do not edit). $what
exec "\$(cd "\$(dirname "\$0")/../.." && pwd)/lib/restart.sh" $n
SH
  chmod +x "$f"
}
