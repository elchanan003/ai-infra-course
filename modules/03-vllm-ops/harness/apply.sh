#!/usr/bin/env bash
# Restart a mock-vllm with your current flags and show what happened.
#   apply.sh a|b            restart the stack instance (:18021 / :18022) that reads lab/vllm-a|b/{args,gpu.yaml}
#   apply.sh x [--args F] [--gpu F] [--node 1|2] [--scale N]
#                           throwaway scratch instance on :18160 (default time scale 20); --node picks lab/vllm-t/gpu.node<N>.yaml
# The instance is simulated (mock-vllm): same flags/arithmetic/errors as vllm serve, no GPU. See mock/README.md.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/mockrun.sh"
LAB="$MOD_DIR/lab"
t="${1:-}"; shift || true
args=""; gpu=""; node=""; scale=20
while [ $# -gt 0 ]; do case "$1" in
  --args) args="$2"; shift 2;; --gpu) gpu="$2"; shift 2;; --node) node="$2"; shift 2;; --scale) scale="$2"; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac; done
show() { # NAME-or-container
  :
}
case "$t" in
  a|b)
    c="aiinfra-mock-vllm-$t-1"; port=$([ "$t" = a ] && echo 18021 || echo 18022)
    docker inspect "$c" >/dev/null 2>&1 || { echo "apply: $c not found. Run ./prepare-lab.sh first." >&2; exit 1; }
    docker restart "$c" >/dev/null
    for i in $(seq 1 40); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/health")" = 200 ] && { echo "mock-vllm-$t: HEALTHY on :$port"; curl -s "http://127.0.0.1:$port/admin/stats" | python3 -c "import json,sys; c=json.load(sys.stdin)['capacity']; print('  kv_cache_size_tokens',c['kv_cache_size_tokens'],'| max_model_len',c['max_model_len'],'| max_concurrency',c['max_concurrency'],'| gpu_memory_utilization',c['gpu_memory_utilization'])"; exit 0; }
      [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || break
      sleep 0.5
    done
    echo "mock-vllm-$t: NOT HEALTHY (container exited). Log:"; docker logs --tail 25 "$c" 2>&1 | cut -c1-600; exit 1;;
  x)
    [ -n "$node" ] && { gpu="${gpu:-$LAB/vllm-t/gpu.node$node.yaml}"; args="${args:-$LAB/vllm-t/args}"; }
    [ -n "$args" ] || { echo "apply x: give --args FILE (or --node N)" >&2; exit 2; }
    [ -n "$gpu" ] || gpu="$(dirname "$args")/gpu.yaml"
    [ -f "$args" ] && [ -f "$gpu" ] || { echo "apply x: missing $args or $gpu" >&2; exit 2; }
    if mockrun_start x "$args" "$gpu" "$scale" 18160; then
      echo "scratch mock-vllm: HEALTHY on :18160"; curl -s http://127.0.0.1:18160/admin/stats | python3 -c "import json,sys; c=json.load(sys.stdin)['capacity']; print('  kv_cache_size_tokens',c['kv_cache_size_tokens'],'| max_model_len',c['max_model_len'],'| max_concurrency',c['max_concurrency'])"
    else
      echo "scratch mock-vllm: NOT HEALTHY. Log:"; mockrun_logs x | tail -25 | cut -c1-600; exit 1
    fi;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
