#!/usr/bin/env bash
# Given. Restart LiteLLM so it re-reads lab/litellm/config.yaml, then wait until it is healthy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../../../platform/lib.sh"
"$PLATFORM_DIR/stack.sh" compose restart litellm >/dev/null 2>&1 || { echo "reload-gateway: restart failed"; exit 1; }
wait_http "$LITELLM_URL/health/liveliness" 90 && echo "reload-gateway: LiteLLM is up" \
  || { echo "reload-gateway: LiteLLM did not come up - read: platform/stack.sh logs litellm (invalid config?)"; exit 1; }
