#!/usr/bin/env bash
# Course base stack driver (Docker Compose project "aiinfra"). See platform/stack/README.md.
#
#   stack.sh up <profile...>        run exactly these profiles: gw llm mock obs ui rag store lf vllm
#                                   (+ gw2 = second LiteLLM replica). Other profiles' services are removed
#                                   (volumes kept). Waits for health (STACK_UP_TIMEOUT, default 240 s;
#                                   600 s with vllm). Exit 1 if unhealthy or a container exited non-zero
#                                   (STACK_ALLOW_EXITED=1 tolerates exited containers, e.g. a mock-vllm
#                                   deliberately started with a broken config).
#   stack.sh down [--volumes]       remove course containers + networks (and data volumes)
#   stack.sh status                 containers, health, published ports
#   stack.sh logs <svc> [args]      docker compose logs for one service
#   stack.sh build                  (re)build aiinfra-mock:1.0 (mock/) and aiinfra-tripwire:1.0 (mock/tripwire/)
#   stack.sh reload-prometheus      POST /-/reload (after editing prometheus.yml / rules)
#   stack.sh reset-openwebui        remove the Open WebUI container + data volume (fresh admin bootstrap)
#   stack.sh compose <args...>      raw docker compose passthrough (all profiles enabled)
#
# RAM guard: `llm` is refused together with `lf` or `vllm`; `vllm` is refused with `lf`.
# Config dir overrides (env): LITELLM_CONFIG_DIR PROM_CONFIG_DIR GRAFANA_PROVISIONING_DIR
#   GRAFANA_DASHBOARDS_DIR SEAWEEDFS_CONFIG_DIR MOCK_VLLM_A_CONFIG_DIR MOCK_VLLM_B_CONFIG_DIR
#   MOCK_DCGM_CONFIG_DIR (or MOCK_DCGM_A_CONFIG_DIR / MOCK_DCGM_B_CONFIG_DIR)
# Model overrides: LLAMA_CHAT_MODEL LLAMA_CODER_MODEL LLAMA_EMBED_MODEL (file names in ~/.cache/aiinfra-course/models)
set -euo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COURSE_DIR="$(cd "$PLATFORM_DIR/.." && pwd)"
STACK_DIR="$PLATFORM_DIR/stack"
set -a; source "$PLATFORM_DIR/versions.env"; set +a
export PATH="$HOME/.local/bin:$PATH"

ALL_PROFILES=(gw gw2 llm mock obs ui rag store lf vllm)
CONFIG_VARS=(LITELLM_CONFIG_DIR PROM_CONFIG_DIR GRAFANA_PROVISIONING_DIR GRAFANA_DASHBOARDS_DIR SEAWEEDFS_CONFIG_DIR
             MOCK_VLLM_A_CONFIG_DIR MOCK_VLLM_B_CONFIG_DIR MOCK_DCGM_CONFIG_DIR MOCK_DCGM_A_CONFIG_DIR MOCK_DCGM_B_CONFIG_DIR)

# Relative override paths are resolved against the caller's cwd (compose would resolve
# them against platform/stack/ otherwise).
for v in "${CONFIG_VARS[@]}"; do
  val="${!v:-}"
  if [ -n "$val" ]; then
    [ -d "$val" ] || { echo "stack.sh: $v=$val is not a directory" >&2; exit 2; }
    export "$v=$(cd "$val" && pwd)"
  fi
done

export AIINFRA_CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
export AIINFRA_UID="$(id -u)" AIINFRA_GID="$(id -g)"

# UIs are also published on the Tailscale IP. If it is not configured on this host, fall
# back to 127.0.0.2 (still loopback) so the port binding does not fail.
export TAILSCALE_IP="${TAILSCALE_IP:-100.127.87.65}"
if ! ip -4 -o addr show 2>/dev/null | grep -qw "${TAILSCALE_IP}"; then
  echo "stack.sh: WARN Tailscale IP $TAILSCALE_IP not present; binding UIs to 127.0.0.1 only" >&2
  export TAILSCALE_IP=127.0.0.2
fi

dc() { docker compose --project-name aiinfra --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yaml" "$@"; }
dc_all() { local a=(); for p in "${ALL_PROFILES[@]}"; do a+=(--profile "$p"); done; dc "${a[@]}" "$@"; }

build_images() {
  [ -f "$COURSE_DIR/mock/Dockerfile" ] || { echo "stack.sh: $COURSE_DIR/mock/Dockerfile missing (mock/ not built yet)" >&2; return 1; }
  docker build -q --label course=aiinfra --build-arg "PYTHON_IMAGE=$PYTHON_IMAGE" -t "$MOCK_IMAGE" "$COURSE_DIR/mock" >/dev/null || return 1
  echo "stack.sh: built $MOCK_IMAGE"
  if [ -f "$COURSE_DIR/mock/tripwire/Dockerfile" ]; then
    docker build -q --label course=aiinfra --build-arg "PYTHON_IMAGE=$PYTHON_IMAGE" -t "$TRIPWIRE_IMAGE" "$COURSE_DIR/mock/tripwire" >/dev/null || return 1
    echo "stack.sh: built $TRIPWIRE_IMAGE"
  else echo "stack.sh: WARN mock/tripwire/Dockerfile missing" >&2; fi
}

check_images() {  # images needed by the selected profiles must exist (pull_policy: never)
  local img missing=()
  for img in $(dc "$@" config --images | sort -u); do
    docker image inspect "$img" >/dev/null 2>&1 || missing+=("$img")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "stack.sh: images missing: ${missing[*]}" >&2
  echo "stack.sh: run platform/setup.sh (connected side); course images: platform/stack.sh build" >&2
  return 1
}

wait_healthy() {
  # Wait (max $1 s) until every course container with a healthcheck is healthy.
  local timeout="${1:-240}" start; start=$(date +%s)
  while :; do
    local bad
    bad=$(docker ps --filter label=com.docker.compose.project=aiinfra --format '{{.Names}} {{.Status}}' \
          | grep -E '\((health: starting|unhealthy)\)|Restarting' || true)
    [ -z "$bad" ] && break
    if (( $(date +%s) - start >= timeout )); then
      echo "stack.sh: not healthy after ${timeout}s:" >&2; echo "$bad" >&2; return 1
    fi
    sleep 3
  done
  local exited
  exited=$(docker ps -a --filter label=com.docker.compose.project=aiinfra --filter status=exited --format '{{.Names}} {{.Status}}' \
           | grep -vE 'Exited \(0\)' || true)
  if [ -n "$exited" ]; then
    echo "stack.sh: containers exited non-zero (stack.sh logs <svc>):" >&2; echo "$exited" >&2
    [ "${STACK_ALLOW_EXITED:-0}" = 1 ] || return 1
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    [ $# -ge 1 ] || { echo "usage: stack.sh up <profile...>  (${ALL_PROFILES[*]})" >&2; exit 2; }
    profiles=()
    for p in "$@"; do
      [[ " ${ALL_PROFILES[*]} " == *" $p "* ]] || { echo "unknown profile: $p" >&2; exit 2; }
      profiles+=("$p")
    done
    has() { [[ " ${profiles[*]} " == *" $1 "* ]]; }
    if has llm && { has lf || has vllm; }; then echo "stack.sh: RAM guard: 'llm' cannot run together with 'lf' or 'vllm'" >&2; exit 2; fi
    if has vllm && has lf; then echo "stack.sh: RAM guard: 'vllm' cannot run together with 'lf'" >&2; exit 2; fi
    if has gw2 && ! has gw; then echo "stack.sh: gw2 needs gw" >&2; exit 2; fi
    args=(); for p in "${profiles[@]}"; do args+=(--profile "$p"); done
    check_images "${args[@]}" || exit 1
    has vllm && mkdir -p "$AIINFRA_CACHE/vllm-home"
    # The stack converges to exactly the requested profiles: services of other profiles
    # are stopped and removed (their data volumes are kept).
    wanted=$(dc "${args[@]}" config --services | sort)
    every=$(dc_all config --services | sort)
    extra=$(comm -13 <(echo "$wanted") <(echo "$every") | tr '\n' ' ')
    removed=""
    if [ -n "${extra// /}" ]; then
      # shellcheck disable=SC2086
      removed=$(dc_all ps -aq $extra 2>/dev/null)
      # shellcheck disable=SC2086
      [ -n "$removed" ] && dc_all rm -sf $extra >/dev/null 2>&1
    fi
    if ! out=$(dc "${args[@]}" up -d --remove-orphans --quiet-pull 2>&1); then
      echo "$out" >&2; echo "stack.sh: compose up failed" >&2; exit 1
    fi
    # Prometheus DNS-SD keeps the last resolved targets when a name stops resolving, so
    # removed components would linger as "down" targets. Restart it to rediscover.
    if [ -n "$removed" ] && [ -n "$(dc ps -q prometheus 2>/dev/null)" ]; then
      dc restart prometheus >/dev/null
    fi
    t="${STACK_UP_TIMEOUT:-240}"; has vllm && t="${STACK_UP_TIMEOUT:-600}"
    rc=0; wait_healthy "$t" || rc=1
    dc_all ps -a --format 'table {{.Service}}\t{{.Status}}'
    exit $rc
    ;;
  down)
    if [ "${1:-}" = "--volumes" ] || [ "${1:-}" = "-v" ]; then
      dc_all down --remove-orphans --volumes
    else
      dc_all down --remove-orphans
    fi
    ;;
  status)
    dc_all ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
    ;;
  reload-prometheus)
    curl -fsS -X POST http://127.0.0.1:18090/-/reload && echo "prometheus: reloaded"
    ;;
  reset-openwebui)
    dc_all rm -sfv open-webui >/dev/null 2>&1 || true
    docker volume ls -q --filter label=course=aiinfra --filter name='^aiinfra_openwebui-data$' | xargs -r docker volume rm >/dev/null
    echo "open-webui: container and data volume removed (next 'up ui' bootstraps a fresh admin)"
    ;;
  logs)
    [ $# -ge 1 ] || { echo "usage: stack.sh logs <service> [docker compose logs args]" >&2; exit 2; }
    svc="$1"; shift; dc_all logs "$@" "$svc"
    ;;
  build)
    build_images
    ;;
  compose)
    dc_all "$@"
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | grep -v '^set' | sed 's/^# \{0,1\}//'; exit 2
    ;;
esac
