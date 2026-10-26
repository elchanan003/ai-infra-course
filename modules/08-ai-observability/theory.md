# 08 — AI observability: scrape, TTFT/ITL/KV rules, dashboards, alerts, token accounting, tracing

Pinned: Prometheus v3.5.0, Grafana 12.1.1, LiteLLM v1.106.4, vLLM 0.31/0.32 metric names, llama.cpp b11889, Langfuse v3 (3.225.14). Prerequisites: module 03 (what the vLLM numbers mean), module 05 (gateway), and general Prometheus/Grafana/Alertmanager skills (from the DevOps track: PromQL basics, `rate`, `for:`, routing are assumed; the AI-specific traps are the subject here).

What is real and what is simulated: **Prometheus, Grafana, LiteLLM, llama.cpp and Langfuse are real.** The vLLM series come from **mock-vllm** (simulated engine, real metric names, deterministic virtual clock) — production exposes the same names from a real vLLM on GPUs. Rule/alert logic is graded with `promtool test rules` on synthetic series (deterministic) plus one bounded live check.

---

## 1. Why LLM observability is not "just more dashboards"

Classic web SLIs (request rate, errors, latency) are necessary but wrong in three ways for LLM serving:

1. **Latency is two numbers.** *TTFT* (time to first token: queue + tokenization + prefill) is what a chat user feels as "it's thinking"; *ITL* (inter-token latency: one decode step) is what they feel as "typing speed". An average over a streaming response hides both. A request can have excellent E2E average and awful TTFT.
2. **Cost is in tokens, not requests.** One request can be 20 tokens or 100k. Capacity (tokens/s), cost (spend per key/team) and abuse detection are all token-denominated.
3. **Saturation is KV cache and queue, not CPU/GPU util.** "GPU util 100%" says the GPU is busy, not that it is useful (preemption recompute is busy work). The signals that precede an incident are `kv_cache_usage_perc`, `num_requests_waiting`, preemption rate.

Plus two things classic APM lacks: **content** (prompt/response traces for debugging quality; PII!) and **per-tenant attribution** (which key/team/user spent or caused load).

The stack has three layers of telemetry, each answering a different question:

| Layer | Source | Answers | Tool |
|---|---|---|---|
| Engine metrics | vLLM / llama.cpp `/metrics` | Is the engine healthy and saturated? TTFT/ITL/KV/queue/preemptions | Prometheus |
| Gateway metrics + spend | LiteLLM `/metrics`, spend logs (Postgres) | Who sent what, to which model, how many tokens, what it cost, failures/latency at the edge | Prometheus + SQL/API |
| Traces | LiteLLM callback → Langfuse | What exactly was asked/answered, per-request latency/tokens, per user/session | Langfuse |
| Hardware | DCGM exporter (module 09) | Is the GPU throttling/failing? | Prometheus |

## 2. Scraping the three sources

### 2.1 vLLM (and mock-vllm)
`GET /metrics` on the API port (8000 in the container; 18021/18022 on this host for mock A/B). Prometheus text format, `engine="0"` and `model_name="<served-model-name>"` labels (note `model_name` is whatever `--served-model-name` says, e.g. `chat`, not the HF id). No auth by default unless `--api-key` is set — then `/metrics` is still open in current versions, but check your deployment; if the gateway fronts vLLM the scrape goes **direct to the engine**, not through the gateway.

Counters end in `_total` (and each has a `_created` timestamp series you ignore), histograms have `_bucket/_sum/_count`. **Series disappear and reappear on engine restart** (counters reset to 0): `rate()`/`increase()` handle resets, `delta()` does not.

Instance identity: Prometheus's `instance` is the scrape target. In Kubernetes you want `pod`/`node` labels from service discovery, and the model/replica relation in a recording rule (`label_replace` or relabeling), because `model_name` is the same across replicas.

### 2.2 llama.cpp server
`--metrics` flag enables `/metrics`. Names are `llamacpp:...` (colon is legal in Prometheus names; it is conventionally reserved for recording rules, so some tools mangle it — Grafana is fine). Useful: `llamacpp:prompt_tokens_total`, `llamacpp:tokens_predicted_total`, `llamacpp:prompt_seconds_total`, `llamacpp:tokens_predicted_seconds_total`, `llamacpp:requests_processing`, `llamacpp:requests_deferred`, `llamacpp:n_decode_total`. **There is no TTFT/ITL histogram and, on the pinned build, no KV gauge** — you derive throughput as `rate(tokens_predicted_total)` and prompt speed from `prompt_tokens_total / prompt_seconds_total` ratios. Know what each engine can and cannot tell you before promising an SLO dashboard for it.

### 2.3 LiteLLM
`GET /metrics/` (it 307-redirects from `/metrics`; point Prometheus at `metrics_path: /metrics/` or follow redirects). In the pinned version the endpoint is not enterprise-gated; the lab config sets `require_auth_for_metrics_endpoint: false` — in production set it true and give Prometheus a bearer token (`authorization:` in the scrape config). The `prometheus` success/failure callback must be enabled in `litellm_settings`. Main families (names from the pinned docs; confirm against your live `/metrics`, they change between releases and with `prometheus_metrics_config` label selection):

| Family | Meaning | Typical labels |
|---|---|---|
| `litellm_proxy_total_requests_metric_total` | requests that hit the proxy | `requested_model`, `status_code`, `api_key_alias`, `team_alias` |
| `litellm_proxy_failed_requests_metric_total` | failures at the proxy | same + `exception_class` |
| `litellm_input_tokens_metric_total`, `litellm_output_tokens_metric_total`, `litellm_total_tokens_metric_total` | tokens by tenant | `model`, `hashed_api_key`, `api_key_alias`, `team`, `team_alias`, `user` |
| `litellm_spend_metric_total` | USD spend | same |
| `litellm_request_total_latency_metric_bucket`, `litellm_llm_api_latency_metric_bucket` | gateway-total vs backend latency | `model`, `api_key_alias` |
| `litellm_llm_api_time_to_first_token_metric_bucket` | TTFT as the gateway sees it (streaming) | `model` |
| `litellm_remaining_requests_metric`, `litellm_remaining_tokens_metric` | rate-limit headroom | key/team |
| `litellm_deployment_state` / `_cooldown_*` / `_failure_responses` | router health per deployment | `litellm_model_name`, `api_base` |

Pitfalls: label cardinality (per-user labels explode series — keep `user` off unless you need it), `hashed_api_key` is a hash (use `api_key_alias`), and in-memory metrics are **per replica**: always `sum by (...)` across replicas, and the counters reset when a replica restarts.

### 2.4 Scrape config shape (what you write in lab 8.1)
```yaml
scrape_configs:
  - job_name: vllm
    scrape_interval: 5s            # lab-only; production 15-30s
    static_configs:
      - targets: ['mock-vllm-a:8000']
        labels: {replica: a, model: chat}
      - targets: ['mock-vllm-b:8000']
        labels: {replica: b, model: chat}
  - job_name: litellm
    metrics_path: /metrics/
    static_configs: [{targets: ['litellm:4000']}]
  - job_name: llamacpp
    static_configs: [{targets: ['llama-chat:8080']}]
```
Check `up == 1` first (Prometheus UI → Targets), then that the **metric names you rely on exist** (`count({__name__=~"vllm:.+"})`). A target that is `up` but exposes no series (wrong path → 404 counts as down, but a 200 with an HTML page or an empty `--metrics`-less llama.cpp does not) silently starves your alerts.

Scrape interval and `rate()` windows: window ≥ 4× scrape interval (rule of thumb) — with 5 s scrape a `[1m]` window is fine, `[10s]` is not. Histogram quantiles need windows with enough observations.

## 3. The PromQL of LLM serving

### 3.1 Gauges vs counters vs histograms (the #1 source of wrong panels)
- **Gauge** (`kv_cache_usage_perc`, `num_requests_running/waiting`): plot directly; use `avg_over_time`/`max_over_time` for windows; **never `rate()` a gauge** (the lab's troubleshooting task is exactly this). `kv_cache_usage_perc` is a **0..1 fraction**: use unit "percent (0.0-1.0)" in Grafana.
- **Counter** (`prompt_tokens_total`, `generation_tokens_total`, `num_preemptions_total`, `request_success_total`): only meaningful through `rate()`/`increase()`. `rate(generation_tokens_total[1m])` = tokens/s.
- **Histogram** (`time_to_first_token_seconds_*`): quantiles via `histogram_quantile(q, sum by (le) (rate(..._bucket[5m])))`; mean via `rate(_sum)/rate(_count)`.

### 3.2 TTFT and ITL
```promql
# p95 TTFT per model across replicas  (le MUST stay in the by clause)
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))

# p95 inter-token latency
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:inter_token_latency_seconds_bucket[5m])))

# Mean TTFT (only as a trend line; never an SLO)
sum(rate(vllm:time_to_first_token_seconds_sum[5m])) / sum(rate(vllm:time_to_first_token_seconds_count[5m]))
```
Rules of the road:
- **Aggregate buckets first, quantile last.** `avg(histogram_quantile(...))` over replicas is wrong (the average of p95s is not the p95); `sum by (le)` the rates across replicas and then take the quantile.
- Quantile accuracy depends on bucket layout: vLLM's TTFT buckets jump 0.75 → 1.0 → 2.5 → 5 s. An SLO of 1.5 s sits in the 1.0-2.5 bucket where interpolation is crude — the answer can be off by hundreds of ms. Put thresholds **on a bucket boundary** (`le="1.0"`) when you can, or compute SLO attainment instead: `sum(rate(..._bucket{le="1.0"}[5m])) / sum(rate(..._count[5m]))` (fraction of requests under 1 s; exact).
- Quantile of an empty window is `NaN`: alerts on `> x` are quiet (NaN comparisons are false) — good — but dashboards show gaps; guard with `and on() sum(rate(..._count[5m])) > 0` when it matters.
- TTFT includes queueing; to tell queue from prefill, plot `request_queue_time_seconds` and `request_prefill_time_seconds` p95 beside it.
- Streaming and gateways: the **client-observed** TTFT = engine TTFT + gateway overhead + network. LiteLLM's `litellm_llm_api_time_to_first_token_metric` shows what the gateway sees; compare to the engine's to localise slowness (engine vs gateway/network).

### 3.3 Saturation and capacity
```promql
max by (model_name) (vllm:kv_cache_usage_perc)                   # worst replica
sum by (model_name) (vllm:num_requests_waiting)
sum by (model_name) (rate(vllm:num_preemptions_total[5m]))
sum by (model_name) (rate(vllm:generation_tokens_total[1m]))      # output tokens/s
sum by (model_name) (rate(vllm:prompt_tokens_total[1m]))          # input tokens/s
rate(vllm:prefix_cache_hits_total[5m]) / rate(vllm:prefix_cache_queries_total[5m])   # prefix hit rate
sum(rate(vllm:request_success_total{finished_reason="abort"}[5m])) / sum(rate(vllm:request_success_total[5m]))  # client aborts
```
Remember: `request_success_total` counts *finished* requests with `finished_reason` (`stop`, `length`, `abort`, `error`, `repetition`) — "success" is a misnomer; error rate = `finished_reason="error"` share, but engine crashes and HTTP 5xx before scheduling appear only at the gateway (`litellm_proxy_failed_requests_metric_total`) — use both.

### 3.4 Recording rules
Why: dashboards and alerts on `histogram_quantile(sum by (le) (rate(...)))` re-evaluate expensive expressions at every refresh; recording rules compute once per rule interval and give stable names (`level:metric:operations` convention):
```yaml
groups:
  - name: vllm.rules
    interval: 15s
    rules:
      - record: model:vllm_ttft_seconds:p95_5m
        expr: histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))
      - record: model:vllm_generation_tokens:rate1m
        expr: sum by (model_name) (rate(vllm:generation_tokens_total[1m]))
```
Gotchas: a recorded quantile **cannot be re-aggregated** (do not `avg` p95s — record the bucket rate `sum by (le, ...)` if you need flexible re-aggregation); the rule evaluation interval must be ≤ the dashboard step or you plot stair-steps; renaming a recorded series breaks every consumer — treat recording-rule names as an API; unit-test them (`promtool test rules`).

## 4. Alerts that matter (and ones that do not)

Principles (as in the alerting module): page on **symptoms** with a clear action; use leading indicators as warnings/tickets; every alert has `severity`, `team`, a `summary` with the value, a runbook.

| Alert | Expression sketch | `for` | Severity | Why |
|---|---|---|---|---|
| `TTFTHigh` | p95 TTFT (recorded) `> SLO` | 2-5m | page | user-visible symptom |
| `KVCacheNearFull` | `max by (model_name)(kv_cache_usage_perc) > 0.9` **and** (`sum by (model_name)(num_requests_waiting) > 0` **or** `sum by (model_name)(rate(num_preemptions_total[5m])) > 0`) | 2-5m | warning | leading indicator; KV alone is not a problem, KV plus queue/preemption is |
| `QueueGrowing` | `sum(num_requests_waiting) > N` **and** rising: `deriv(...[5m]) > 0` or `> N for 5m` | 3-5m | warning→page if TTFT also high | capacity shortfall |
| `PreemptionsSustained` | `rate(num_preemptions_total[5m]) > 0` | 10m | warning | batch cap above KV |
| `EngineDown` | `up{job="vllm"} == 0` | 1m | page | no metrics = blind |
| `NoTokensFlowing` | `sum(rate(generation_tokens_total[5m])) == 0 and sum(num_requests_running) > 0` | 5m | page | engine hung |
| `GatewayErrorRate` | 5xx share at LiteLLM | 5m | page | users failing |
| `SpendAnomaly` | spend/key `> k × 7d baseline` | 15m | ticket | runaway client |

Notes:
- **KV near full is not by itself an outage.** A cache that is 95% full and stable with zero preemptions and no queue is a *working* system (that is what the memory is for). Combine: KV high AND (queue or preemptions). A page on KV% alone teaches the on-call to ignore pages.
- Absent metrics: `up == 0` or `absent(vllm:kv_cache_usage_perc)` — an alert on a metric that stopped existing never fires. Add an `absent()`/`up` companion for every important alert.
- `for:` vs scrape/eval: `for` is counted in evaluation intervals; with 5 s scrape and 15 s rule interval `for: 30s` is two evaluations.
- Multi-window multi-burn-rate SLO alerts (from the Prometheus/SRE track) apply to "fraction of requests under 1 s TTFT" — compute with the `le="1.0"` bucket ratio.
- **Testing** alerts: `promtool test rules` with synthetic `input_series` (fires / quiet pair; assert labels and annotation text; assert nothing fires before `for`). A live smoke (inject the mock fault, watch the alert go `pending → firing`) proves wiring, not logic; use both, rely on the unit test.

## 5. Dashboards as code

A useful AI serving dashboard, in reading order (top row = "are users happy", middle = "why", bottom = "who/cost"):

1. Stat row: p95 TTFT, p95 ITL (vs SLO lines), tokens/s out, error rate.
2. Saturation: `num_requests_running` vs `max_num_seqs` (from `cache_config_info`/a constant), `num_requests_waiting`, `kv_cache_usage_perc` (percentunit, thresholds 0.8/0.9), preemption rate.
3. Latency decomposition: TTFT p50/p95/p99, queue time p95, prefill time p95, ITL p95.
4. Throughput: prompt vs generation tokens/s, prefix hit rate, request outcome by `finished_reason`.
5. Gateway: requests by status/model, p95 gateway latency vs engine latency, spend per key/team (`litellm_spend_metric_total` via `increase(...[1h])`), tokens per key.
6. Hardware (module 09): GPU util, FB used, temperature, XID.

Practices:
- **Provision, don't click**: dashboards as JSON in Git, loaded via a Grafana provisioning provider (`/etc/grafana/provisioning/dashboards/*.yaml` pointing at a folder), datasources provisioned with a fixed `uid` (dashboard JSON refers to the datasource by uid; a mismatched uid yields "datasource not found" panels). Dashboards edited in the UI are lost on redeploy unless exported.
- Use template variables (`$model`, `$replica`) with `label_values(vllm:kv_cache_usage_perc, model_name)`; use `$__rate_interval` instead of hard-coded windows when the scrape interval varies.
- Units matter: seconds (`s`), `percentunit` for 0..1, `reqps`, `tokens/s` as custom suffix.
- A panel that "has data" is not a correct panel: verify each panel's query against a number you can compute by hand (lab 8.3 does it through the Grafana API: each panel query is executed and must return series).
- The classic wrong panels (lab 8.T): `rate()` on a gauge; mean-of-`_sum` only (no `/ _count`) or `avg()` of per-replica quantiles; `histogram_quantile` without `le`; missing `sum by (le)`; counter plotted raw (sawtooth that resets on restart).

## 6. Token accounting and reconciliation

Three places record tokens: the **engine** (`vllm:prompt_tokens_total`, `generation_tokens_total`), the **gateway** (`litellm_*_tokens_metric_total`, and spend logs in Postgres `LiteLLM_SpendLogs` with `prompt_tokens`, `completion_tokens`, `spend`), and the **client** (`usage` in the response). They should agree, within known gaps:

| Gap | Cause |
|---|---|
| Gateway < engine | traffic that bypasses the gateway (direct clients, health/benchmarks, the platform's own probes) |
| Gateway > engine | gateway cache hits (no engine call), requests that failed after counting, retries counted once at gateway but twice at engine |
| Spend log lag | batch-written: `proxy_batch_write_at` (lab sets 5 s; production default is 60 s) → reconcile only after a flush barrier; a "total spend" query right after load under-reports |
| Counter resets | replica/engine restart → use `increase()`/`rate()`, not raw differences |
| Streaming | usage counted at end of stream; with `stream_options.include_usage` missing, a gateway may estimate tokens with its own tokenizer (small mismatch with the engine's) |
| Different tokenizers | gateway token counter for a model whose tokenizer it lacks falls back to tiktoken — a few % off |

Cost accounting = tokens × price map (`model_info.input_cost_per_token` / `output_cost_per_token` in LiteLLM) — for self-hosted GPUs "price" is an internal chargeback rate you choose (GPU-hour cost ÷ sustained tokens/hour). Reconcile: **window → flush barrier → compare SpendLogs sum vs `increase(litellm_total_tokens_metric_total[window])` vs `increase(vllm:prompt_tokens_total + generation_tokens_total[window])`**, expect agreement within ~2% for traffic that goes only through the gateway; investigate the gap, don't paper over it (lab 8.5).

Chargeback and abuse: `sum by (api_key_alias) (increase(litellm_spend_metric_total[1d]))`; top-N keys; anomaly alert versus a trailing baseline (`offset 7d`). PII: spend logs and metrics carry key *aliases*; never put user emails/prompts in label values.

## 7. Tracing and content logging: Langfuse (v3)

**Metrics tell you a request class is slow; a trace tells you which request, what it said, and where the time went.** Langfuse is an open-source LLM observability platform you can self-host (air-gap friendly). The pinned v3 architecture:

```
SDK / LiteLLM callback ──HTTPS──> langfuse-web (API + UI)
                                     │ write raw event batch to S3 (blob store), enqueue job in Redis
                                     ▼
                              langfuse-worker ──> ClickHouse (traces/observations/scores, analytics)
                                     │                       Postgres (projects, users, API keys, prompts)
                                     └── reads S3 batches
```
Components: web, worker, **Postgres** (transactional data), **ClickHouse** (analytical store; v3 3.225.x needs ClickHouse 25.8; Langfuse v4 needs ≥ 25.12 and is not used here), **Redis/Valkey** (queue + cache), **S3-compatible blob storage** (event batches, media, exports; SeaweedFS in this course). It is ~2.75 GB RAM here, so the lab runs it alone (profile `lf`) next to a minimal gateway and mock.

Wiring LiteLLM (callback, no application change):
```yaml
litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]
environment_variables:      # or process env
  LANGFUSE_PUBLIC_KEY: pk-lf-...
  LANGFUSE_SECRET_KEY: sk-lf-...
  LANGFUSE_HOST: http://langfuse-web:3000
```
Per-request attribution goes in the request body `metadata` (`trace_user_id`, `session_id`, `trace_name`, `tags`, `generation_name`) or the `user` field. Langfuse stores model, input/output, tokens (usage), cost (if the model price is defined), latency, time-to-first-token for streams, and the status.

Headless setup for self-hosting: `LANGFUSE_INIT_ORG_ID`, `LANGFUSE_INIT_PROJECT_ID`, `LANGFUSE_INIT_PROJECT_PUBLIC_KEY`, `LANGFUSE_INIT_PROJECT_SECRET_KEY`, `LANGFUSE_INIT_USER_EMAIL/PASSWORD` create the project and keys at first start (what `prepare-lab.sh` uses). Public API: `GET /api/public/traces?userId=...`, `GET /api/public/observations`, Basic auth `pk:sk`. **Ingestion is asynchronous** (S3 → queue → worker → ClickHouse): a trace appears seconds after the request — poll with a timeout, never assert immediately.

Production concerns:
- **Privacy**: traces contain prompts and answers (PII, secrets pasted by users, source code). Decide retention, masking (`LANGFUSE_...` masking hooks / LiteLLM `turn_off_message_logging`, per-key `logging` controls), access control per project. In air-gapped on-prem this is *the* argument for self-hosting.
- **Cost/volume**: ClickHouse disk and S3 grow with content size; sampling (`LANGFUSE_SAMPLE_RATE` on SDKs) and retention windows.
- **Not a metrics system**: use Prometheus for SLOs/alerts; traces for forensics, evaluation sets, per-user debugging, prompt versions, and offline cost analysis.
- Alternatives you will meet: OpenTelemetry with GenAI semantic conventions (vLLM can emit OTLP traces with `--otlp-traces-endpoint`; LiteLLM has `otel` and `langfuse_otel` callbacks), Arize Phoenix, OpenLLMetry, Helicone (proxy-based), vendor APMs. Choose by: self-hostable offline, ClickHouse ops burden, OTLP compatibility.

## 8. Correlation: from alert to cause

A practical incident flow: **TTFT alert** → dashboard: queue? KV? → engine vs gateway latency (is it the engine?) → which tenant/model (gateway per-key tokens/spend, see who spiked) → sample slow traces (Langfuse: long prompts? one user looping?) → engine config/capacity (module 03) → GPU health (module 09). Put a **request id** through every layer (client → gateway `x-litellm-call-id` → engine `x-request-id`/logs → Langfuse trace id) so you can jump between tools. Exemplars (Prometheus ↔ trace links) exist in Grafana but are not wired in the lab.

## 9. Lab-vs-production differences (honest list)

| Lab | Production |
|---|---|
| 5 s scrape, 15 s rule interval, `proxy_batch_write_at: 5` | 15-30 s scrape, default 60 s spend batch (reconcile windows must be ≥ that) |
| vLLM metrics from mock-vllm (virtual clock, deterministic) | real engines: noisy, GPU-bound, restarts, many replicas, `pod` labels |
| Single Prometheus, no retention/HA | Thanos/Mimir/VictoriaMetrics, retention policy, HA pairs |
| Static targets | Kubernetes SD / ServiceMonitor (+ GPU Operator's DCGM ServiceMonitor) |
| Langfuse alone on one host, headless init | HA ClickHouse, S3 lifecycle, SSO, masking, retention |
| `require_auth_for_metrics_endpoint: false` | bearer token for `/metrics` |

## 10. Pitfalls

1. `rate()` on a gauge, raw counters on panels, `avg()` of quantiles.
2. `histogram_quantile` without `le` (empty/NaN) or thresholds between buckets.
3. KV panel in "percent" for a 0..1 metric; old `gpu_cache_usage_perc` queries.
4. Alerting on KV% alone (cries wolf) or on GPU util (not saturation).
5. Silent alerts: metric renamed/absent, `for:` longer than the incident, window shorter than scrape.
6. Reconciling spend immediately after load (batch lag) and concluding "tokens are lost".
7. Label explosions (per-user/per-request labels in Prometheus).
8. Langfuse trace asserted before async ingestion finished; Langfuse and the LLM engine on the same small host.
9. Dashboards edited in the UI and lost at the next deploy; datasource uid mismatch.
10. Prompt content in logs and traces without a retention/PII decision.

---

## Key takeaways

- LLM latency is TTFT (queue + prefill) and ITL (decode), as **quantiles from histogram buckets**; averages and `avg(p95)` mislead; thresholds belong on bucket boundaries.
- Gauge → plot/`*_over_time`; counter → `rate`; histogram → `sum by (le)` then `histogram_quantile`. `kv_cache_usage_perc` is 0..1.
- Saturation signals are KV usage, queue length, preemption rate; alert on leading indicators with context, page on the TTFT symptom; unit-test rules with `promtool`, add `up`/`absent` guards.
- Dashboards are code (provisioned, uid-bound, units right); verify panel queries against hand numbers.
- Tokens reconcile across engine, gateway counters, spend logs and client usage within ~2% after a flush barrier; the gaps have named causes.
- Langfuse (web + worker + Postgres + ClickHouse + Redis + S3) gives per-request traces with async ingestion and a privacy burden; Prometheus for SLOs, traces for forensics.

## Check yourself

1. Write the PromQL for p95 TTFT across two vLLM replicas and explain why `avg(histogram_quantile(...))` is wrong.
2. Your SLO is "p95 TTFT < 1.5 s". Why is the computed p95 unreliable around that value with vLLM's buckets, and what do you compute instead?
3. A KV-cache alert pages every afternoon although users are fine. What is wrong with it and how do you re-scope it?
4. Spend logs show 8% fewer tokens than `increase(vllm:generation_tokens_total[1h])`. List three causes you check.
5. A trace you just sent is not in Langfuse yet. Is something broken? Explain the ingestion path.
