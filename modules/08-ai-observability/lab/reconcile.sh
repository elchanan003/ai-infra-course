#!/usr/bin/env bash
# Reference solution for task 8.5
START="${1:?start}"; END="${2:?end}"; ALIAS="${3:?alias}"
PROM="${PROM_URL:-http://127.0.0.1:18090}"
q() { curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$2" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(sum(float(x['value'][1]) for x in r) if r else 0)"; }
psqlq() { docker exec aiinfra-postgres-1 psql -U llm -d litellm -tAc "$1" | tr -d '[:space:]'; }
GW=$(psqlq "select coalesce(sum(total_tokens),0) from \"LiteLLM_SpendLogs\" where metadata::jsonb->>'user_api_key_alias'='$ALIAS'")
ROWS=$(psqlq "select count(*) from \"LiteLLM_SpendLogs\" where metadata::jsonb->>'user_api_key_alias'='$ALIAS'")
T1=$((END + 12))
PG=$(python3 -c "print(int(round($(q "litellm_total_tokens_metric_total{api_key_alias=\"$ALIAS\"}" $T1) - $(q "litellm_total_tokens_metric_total{api_key_alias=\"$ALIAS\"}" $START))))")
EN=$(python3 -c "print(int(round($(q 'sum(vllm:prompt_tokens_total{replica="a"}) + sum(vllm:generation_tokens_total{replica="a"})' $T1) - $(q 'sum(vllm:prompt_tokens_total{replica="a"}) + sum(vllm:generation_tokens_total{replica="a"})' $START))))")
PER=$(python3 -c "print($GW/max($ROWS,1))")
B=$(python3 -c "print(int(round(max($EN-$GW,0)/max($PER,1))))")
CAUSE=none; [ "$B" -gt 0 ] && CAUSE=bypass
echo "GATEWAY_TOKENS=$GW"; echo "PROM_GATEWAY_TOKENS=$PG"; echo "ENGINE_TOKENS=$EN"; echo "GAP_CAUSE=$CAUSE"; echo "BYPASS_REQUESTS=$B"
