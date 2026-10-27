#!/usr/bin/env bash
# Task 8.5: reconcile tokens for one traffic run.   usage: lab/reconcile.sh START_EPOCH END_EPOCH KEY_ALIAS
# Print exactly these five lines (KEY=VALUE) on stdout; verify runs this script on fresh traffic.
#   GATEWAY_TOKENS       total tokens the gateway recorded in its spend logs for KEY_ALIAS
#   PROM_GATEWAY_TOKENS  the same from LiteLLM's Prometheus counters (litellm_total_tokens_metric_total)
#   ENGINE_TOKENS        prompt+generation tokens counted by the mock-vllm A engine during the run (Prometheus)
#   GAP_CAUSE            bypass | cache | lag | restart | none : why engine and gateway differ
#   BYPASS_REQUESTS      number of engine requests with no gateway counterpart (0 if none)
START="${1:?start}"; END="${2:?end}"; ALIAS="${3:?alias}"
echo "GATEWAY_TOKENS=REPLACE_ME"
echo "PROM_GATEWAY_TOKENS=REPLACE_ME"
echo "ENGINE_TOKENS=REPLACE_ME"
echo "GAP_CAUSE=REPLACE_ME"
echo "BYPASS_REQUESTS=REPLACE_ME"
