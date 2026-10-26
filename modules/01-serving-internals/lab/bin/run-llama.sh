#!/usr/bin/env bash
# Given. Start (or restart) your lab llama-server from lab/llama.env on 127.0.0.1:18120.
#   run-llama.sh [stop]        optional env overrides: MODEL=... PARALLEL=... CTX=... PORT=18120..18124 NAME=...
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../../../platform/lib.sh"
LAB="$HERE/.."
get() { local v="${!1:-}"; [ -n "$v" ] || v="$(env_kv "$LAB/llama.env" "$1")"; echo "$v"; }
PORT="${PORT:-18120}"; NAME="${NAME:-aiinfra-lab01-llama}"
docker rm -f "$NAME" >/dev/null 2>&1
[ "${1:-}" = stop ] && { echo "stopped $NAME"; exit 0; }
CTX="$(get CTX)"; PARALLEL="$(get PARALLEL)"; THREADS="$(get THREADS)"; MODEL="$(get MODEL)"
docker run -d --name "$NAME" --label course=aiinfra --label module=01 -p "127.0.0.1:$PORT:8080" \
  -v "${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/models:/models:ro" "$LLAMACPP_IMAGE" \
  -m "/models/$MODEL" --host 0.0.0.0 --port 8080 --metrics -c "$CTX" -np "$PARALLEL" -t "$THREADS" >/dev/null || exit 1
wait_http "http://127.0.0.1:$PORT/health" 60 && echo "run-llama: $NAME ready on 127.0.0.1:$PORT (ctx=$CTX parallel=$PARALLEL threads=$THREADS model=$MODEL)" \
  || { echo "run-llama: server did not become healthy: docker logs $NAME"; exit 1; }
