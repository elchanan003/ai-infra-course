# Helpers to run throwaway mock-vllm containers (sourced by apply.sh, snapshot.sh, verify.sh). Needs docker + image aiinfra-mock:1.0.
MOCK_IMAGE="${MOCK_IMAGE:-aiinfra-mock:1.0}"
_MR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$_MR_DIR/.." && pwd)"
RUN_DIR="$MOD_DIR/.state/run"

# mockrun_start NAME ARGSFILE GPUFILE [SCALE=20] [PORT=18160]   -> 0 healthy, 1 exited/unhealthy (container kept for logs)
mockrun_start() {
  local name="aiinfra-lab03-$1" args="$2" gpu="$3" scale="${4:-20}" port="${5:-18160}" d="$RUN_DIR/$1"
  docker rm -f "$name" >/dev/null 2>&1
  rm -rf "$d"; mkdir -p "$d"; cp "$args" "$d/args"; cp "$gpu" "$d/gpu.yaml"; chmod -R a+rX "$d"
  docker run -d --name "$name" --label course=aiinfra --label lab=03-vllm-ops -p "127.0.0.1:$port:8000" \
    -e MOCK_TIME_SCALE="$scale" -v "$d:/config:ro" --memory 256m "$MOCK_IMAGE" vllm >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/health")" = 200 ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || return 1
    sleep 0.5
  done
  return 1
}
mockrun_stop() { docker rm -f "aiinfra-lab03-$1" >/dev/null 2>&1; }
mockrun_logs() { docker logs "aiinfra-lab03-$1" 2>&1; }
# classify the startup failure of a stopped container: start | fail-kv | fail-gpu-free | fail-other
mockrun_outcome() {
  local n="$1" port="${2:-18160}"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/health")" = 200 ]; then echo start; return; fi
  local l; l=$(mockrun_logs "$n")
  case "$l" in
    *"To serve at least one request"*) echo fail-kv ;;
    *"Free memory on device"*) echo fail-gpu-free ;;
    *) echo fail-other ;;
  esac
}
mockrun_fit() { mockrun_logs "$1" | grep -o 'estimated maximum model length is [0-9]*' | head -1 | grep -o '[0-9]*$'; }
mockrun_first_error() { mockrun_logs "$1" | grep -m1 -E 'ERROR|Error' | sed 's/^.*\] //' | cut -c1-400; }
