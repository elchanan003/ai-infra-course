#!/usr/bin/env bash
# Module 08. `prepare-lab.sh` = profiles gw llm mock obs (tasks 8.1-8.6); `prepare-lab.sh langfuse` = profiles lf gw mock alone (task 8.7).
# Idempotent; never overwrites lab/; seeds the hidden variant for 8.5.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
PLATFORM="$MOD/../../platform"
mkdir -p "$MOD/.state"
[ -f "$MOD/.state/variant.json" ] || python3 - "$MOD/.state/variant.json" <<'PY'
import json, random, sys
i = random.SystemRandom().randrange(3)
json.dump({"index": i, "n_gateway": [24, 28, 32][i], "bypass": [7, 9, 11][i]}, open(sys.argv[1], "w"))
PY
if [ "${1:-}" = langfuse ]; then
  echo "$MOD" > /dev/null
  export LITELLM_CONFIG_DIR="$MOD/lab/litellm"
  "$PLATFORM/stack.sh" up lf gw mock || { echo "prepare: stack up lf gw mock failed (RAM guard: lf never with llm)" >&2; exit 1; }
  precond "langfuse-web healthy (:18060)" wait_http "http://127.0.0.1:18060/api/public/health" 120
  precond "litellm healthy" wait_http "$LITELLM_URL/health/liveliness" 60
  echo "Langfuse gate ready. Edit lab/litellm/config.yaml, then ./lab/tools/restart-litellm.sh and ./verify.sh langfuse"
  exit 0
fi
export PROM_CONFIG_DIR="$MOD/lab/prometheus" GRAFANA_DASHBOARDS_DIR="$MOD/lab/grafana/dashboards"
chmod -R a+rX "$MOD/lab"
"$PLATFORM/stack.sh" up gw llm mock obs || { echo "prepare: stack up gw llm mock obs failed" >&2; exit 1; }
for t in a b; do docker restart "aiinfra-mock-vllm-$t-1" >/dev/null 2>&1; done
precond "prometheus ready (:18090)" wait_http "$PROM_URL/-/ready" 60
precond "grafana ready (:18030)" wait_http "$GRAFANA_URL/api/health" 60
precond "litellm healthy (:18040)" wait_http "$LITELLM_URL/health/liveliness" 60
precond "mock-vllm A/B healthy" bash -c "curl -sf $MOCK_A_URL/health >/dev/null && curl -sf $MOCK_B_URL/health >/dev/null"
echo "Ready. Read modules/08-ai-observability/lab.md"
