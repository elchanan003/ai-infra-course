#!/usr/bin/env bash
# Task 2.4 - reference: llama-server on the air-gapped network, DNS = tripwire, local GGUF only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../../../platform/lib.sh"
GGUF="$(env_kv "$HERE/../REPOS.env" GGUF_FILE)"
docker rm -f aiinfra-lab02-serve >/dev/null 2>&1
docker run -d --name aiinfra-lab02-serve --label course=aiinfra --label module=02 \
  --network aiinfra-airgap --dns "$TRIPWIRE_AIRGAP_IP" \
  -v "${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/models:/models:ro" "$LLAMACPP_IMAGE" \
  -m "/models/$GGUF" --host 0.0.0.0 --port 8080 -c 2048 -t 2
