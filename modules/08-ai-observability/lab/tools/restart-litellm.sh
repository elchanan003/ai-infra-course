#!/usr/bin/env bash
# Restart LiteLLM so it re-reads lab/litellm/config.yaml, then wait until healthy.
docker restart aiinfra-litellm-1 >/dev/null || { echo "litellm container not found: run ./prepare-lab.sh langfuse"; exit 1; }
for i in $(seq 1 60); do curl -sf http://127.0.0.1:18040/health/liveliness >/dev/null && { echo "litellm healthy"; exit 0; }; sleep 2; done
echo "litellm did not become healthy (docker logs aiinfra-litellm-1)"; exit 1
