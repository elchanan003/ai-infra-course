# 08 — Hint ladder (H1 nudge, H2 concept, H3 partial, H4 full; log per task, H3/H4 -> Weak areas)

## 8.1 Scrape
- H1: Open each target's raw `/metrics` with curl and the Prometheus Targets page. Which one answers with a redirect?
- H2: LiteLLM serves `/metrics/`; names in-network are `mock-vllm-a:8000`, `mock-vllm-b:8000`, `litellm:4000`, `llama-chat:8080`.
- H3: three `job_name`s: `vllm` with two `static_configs` entries carrying `labels: {replica: a|b}`, `litellm` with `metrics_path: /metrics/`, `llamacpp`.
- H4: `.tutor/solution/lab/prometheus/prometheus.yml`.

## 8.2 Recording rules
- H1: Where do the replicas get combined, and where does the quantile go?
- H2: `histogram_quantile(q, sum by (le, model_name) (rate(..._bucket[5m])))`. `le` must survive the `by`.
- H3: The token rate is `sum by (model_name) (rate(vllm:generation_tokens_total[1m]))`.
- H4: `.tutor/solution/lab/prometheus/rules/ai-recording.yml`.

## 8.3 Dashboard
- H1: Build one panel in the UI, check the query returns data, export JSON.
- H2: Keep uid `ai-serving`, datasource uid `prometheus`, panel titles exactly as listed. Unit `percentunit` for the KV panel.
- H3: Spend per key: `sum by (api_key_alias) (increase(litellm_total_tokens_metric_total[$__range]))` (or spend metric); KV: `max by (model_name, replica) (vllm:kv_cache_usage_perc{model_name=~"$model"})`.
- H4: `.tutor/solution/lab/grafana/dashboards/ai-serving.json`.

## 8.4 Alerts
- H1: What must be true for KVCacheNearFull besides KV > 0.9?
- H2: `A and on (model_name) (B or C)` with `B = sum by (model_name)(waiting) > 0`, `C = sum by (model_name)(rate(preemptions[5m])) > 0`.
- H3: `for: 2m`, labels `severity`, `team: llm-platform`; annotation `summary` with `{{ $value ... }}` and `runbook_url`. TTFTHigh can read the recorded series.
- H4: `.tutor/solution/lab/prometheus/rules/ai-alerts.yml`.

## 8.5 Reconciliation
- H1: Three numbers, three sources; which source is batch-written?
- H2: The key alias is unique to the run, so its counter starts at zero: query the counter at `START` and at `END+12` and subtract; same for the engine.
- H3: Postgres `LiteLLM_SpendLogs`, filter `metadata->>'user_api_key_alias'`; bypass = (engine - gateway) / (tokens per gateway request).
- H4: `.tutor/solution/lab/reconcile.sh`.

## 8.6 Flat TTFT panel
- H1: What does the starter query compute? Is it a quantile? Over which time range?
- H2: Sum of all observations divided by count of all observations since process start is a lifetime mean.
- H3: Windowed buckets: `rate(..._bucket[$__rate_interval])`, aggregate `sum by (le)`, then `histogram_quantile`.
- H4: panel 1 of the solution dashboard.

## 8.7 Langfuse
- H1: Which two LiteLLM settings make it send success and failure events somewhere?
- H2: `litellm_settings.success_callback: ["langfuse"]` and `failure_callback: ["langfuse"]`; keys/host come from the container env.
- H3: Restart LiteLLM, send a request with `user`, poll the Langfuse API (ingestion is asynchronous).
- H4: `.tutor/solution/lab/litellm/config.yaml`.
