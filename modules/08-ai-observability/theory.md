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

## 11. Histogram quantiles by hand (what `histogram_quantile` really does)

Given cumulative bucket rates for TTFT over the last 5 minutes (requests/s with TTFT ≤ le): `0.25 → 4.0`, `0.5 → 7.0`, `0.75 → 9.0`, `1.0 → 9.6`, `2.5 → 10.0`, `+Inf → 10.0`. Total 10 req/s, p95 → rank `0.95 × 10 = 9.5`. The first bucket whose cumulative value is ≥ 9.5 is `le=1.0` (9.0 at `le=0.75` is below the rank, 9.6 at `le=1.0` is above it). Interpolate inside `(0.75, 1.0]`: lower count 9.0, bucket count 0.6 → `0.75 + 0.25 × (9.5 − 9.0)/0.6` = **0.958 s**. The result moves only inside the bucket: whether the true p95 is 0.76 s or 0.99 s, Prometheus reports a point on a straight line. Three consequences:
- Resolution is the bucket width. vLLM's TTFT buckets are fine below 1 s and coarse above (1 → 2.5 → 5 → 7.5 → 10 → 20 …): a 2-second p95 and a 2.4-second p95 look similar, but 2.4 vs 2.6 jumps across a boundary.
- The top finite bucket caps quantiles: values beyond 2560 s are reported as 2560 s; `+Inf` bucket members are invisible.
- SLO attainment (`le="1.0"` over `_count`) is exact and composable across replicas and time windows (sum numerators and denominators); quantiles are not composable. Multi-window burn-rate alerts use attainment.

Counter hygiene: `rate()` handles resets (engine restart) by assuming the counter restarted from zero; `increase()` extrapolates to the window edges and is therefore *not* an integer — use differences of instant queries (`query?time=`) when you need an exact total for a bounded interval (token reconciliation, billing). `irate()` is for spiky dashboards only — never in alert rules (a single pair of samples).

Staleness: when a replica disappears, its series go stale after one missed scrape; `sum` over replicas then drops abruptly — a **replica restart looks like a traffic drop** on a throughput panel. Annotate deploys and use `up` panels.

## 12. A complete alert, unit-tested

```yaml
# rules/ai-alerts.yml
groups:
  - name: vllm.alerts
    rules:
      - alert: KVCacheNearFull
        expr: |
          max by (model_name) (vllm:kv_cache_usage_perc) > 0.9
          and on (model_name) (
                sum by (model_name) (vllm:num_requests_waiting) > 0
             or sum by (model_name) (rate(vllm:num_preemptions_total[5m])) > 0
          )
        for: 2m
        labels: {severity: warning, team: llm-platform}
        annotations:
          summary: "KV cache {{ $value | humanizePercentage }} full on {{ $labels.model_name }} with queueing or preemption"
          runbook_url: https://runbooks.example.internal/llm/kv-cache-near-full
```
```yaml
# tests/kv.test.yml  (promtool test rules tests/kv.test.yml)
rule_files: [../rules/ai-alerts.yml]
evaluation_interval: 15s
tests:
  - interval: 15s
    input_series:
      - {series: 'vllm:kv_cache_usage_perc{model_name="chat",replica="a"}',  values: '0.95x40'}
      - {series: 'vllm:num_requests_waiting{model_name="chat",replica="a"}', values: '4x40'}
    alert_rule_test:
      - {eval_time: 1m, alertname: KVCacheNearFull, exp_alerts: []}               # pending, not firing yet
      - eval_time: 5m
        alertname: KVCacheNearFull
        exp_alerts:
          - exp_labels: {severity: warning, team: llm-platform, model_name: chat}
            exp_annotations:
              summary: "KV cache 95% full on chat with queueing or preemption"
              runbook_url: https://runbooks.example.internal/llm/kv-cache-near-full
```
A good suite has: a **fire** case with exact labels/annotations, a **quiet-before-`for`** assertion, a **quiet** case where one half of the condition is false (KV high but no queue — the case that teaches the rule's purpose), and a **mutation check** (delete the `and` clause: the quiet case must fail). Notes on `promtool`: `values: '0.95x40'` means 41 samples; use `a+bxN` for counters; `eval_time` must be a multiple of the interval; `exp_alerts: []` asserts "not firing" (pending alerts do not count as firing in `alert_rule_test`); label sets must match exactly, which is why alert label contracts matter. The verify script of this lab uses `promql_expr_test` on `ALERTS{...}` to avoid coupling to annotation text.

Alertmanager is covered in the alerting module; the AI-specific part is routing: **who owns `TTFTHigh`** (platform team) vs **`SpendAnomaly`** (FinOps/ team lead) vs **GPU XID** (infra on-call). Put `team`, `service`, `model_name` on every alert and route on `team`.

## 13. SLO attainment and burn rates for TTFT

Define the SLI as *the fraction of requests with TTFT ≤ 1.0 s* (exact from the `le="1.0"` bucket) and the SLO as 99% over 30 days (error budget 1% = 7.2 h of "bad" requests-time equivalent in request terms). Burn rate = observed bad fraction / budget fraction. A multi-window multi-burn-rate alert pages when both a long and a short window burn fast:

```promql
# bad fraction over a window W
1 - (sum(rate(vllm:time_to_first_token_seconds_bucket{le="1.0"}[W])) / sum(rate(vllm:time_to_first_token_seconds_count[W])))

# page: 14.4x burn over 1h AND 5m  (budget gone in ~2 days)
(1 - sum(rate(..._bucket{le="1.0"}[1h])) / sum(rate(..._count[1h])) ) > (14.4 * 0.01)
and
(1 - sum(rate(..._bucket{le="1.0"}[5m])) / sum(rate(..._count[5m])) ) > (14.4 * 0.01)
```
Why attainment instead of `p95 > 1`: it is exact, aggregates correctly across replicas, has a budget you can spend and report on, and the two-window form suppresses blips while still catching a real regression within minutes. For low traffic services the denominator is tiny: add a traffic floor (`and sum(rate(_count[1h])) > 0.1`). A p95-threshold alert (`TTFTHigh` in the lab) is the simpler first alert; attainment burn-rate is the mature one.

## 14. Series count, cardinality and cost

Rule of thumb: each vLLM replica exposes ~590 lines, of which histograms dominate (`request_*` histograms have 8-22 buckets each × 3 series). Estimate: 1 replica ≈ 450 active series; 50 replicas ≈ 22,500 — trivial for Prometheus. LiteLLM is the cardinality risk: `litellm_*` metrics multiply by `model × api_key × team × user × status_code × exception`. 500 keys × 10 models × 8 status codes = 40,000 series per metric × ~8 metrics = 320k series — uncomfortable. Controls: `prometheus_metrics_config` (select metric groups and label sets), drop `end_user`/`user` labels, aggregate by team in recording rules and **drop raw per-key series** via `metric_relabel_configs` if per-key detail lives in spend logs instead. Never use request ids, prompts or free text as label values (Langfuse is the place for per-request data). Retention: 15 days locally is typical; use a remote-write backend (Thanos/Mimir/VictoriaMetrics) for long SLO windows. `scrape_interval` 15-30 s in production halves storage vs 5 s; histogram `rate()` windows must be ≥ 4 × scrape interval.

## 15. Kubernetes shape (how this looks outside the lab)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata: {name: vllm, labels: {release: kube-prometheus-stack}}
spec:
  selector: {matchLabels: {app: vllm}}
  podMetricsEndpoints: [{port: http, path: /metrics, interval: 15s}]
  podTargetLabels: [model, replica]      # copy pod labels onto series: model_name is not unique per replica
```
Also scraped in a real platform: the DCGM exporter (GPU Operator ServiceMonitor; module 09), kube-state-metrics (pod restarts, `Pending` pods), node-exporter (host RAM — vLLM CPU-RAM OOM kills), the gateway (LiteLLM), Postgres/Redis exporters (gateway state), Langfuse's own metrics. Grafana dashboards are shipped as ConfigMaps with the sidecar loader or via Grafana Operator `GrafanaDashboard` CRs; rules as `PrometheusRule` objects (the same YAML you wrote in the lab under `groups:`). The alert → ticket path (Alertmanager receivers, silences for maintenance, `inhibit_rules` so `EngineDown` mutes the latency alerts of the same model) is the alerting module's.

## 16. Langfuse operations notes

- **Sizing**: ClickHouse dominates disk (traces with full prompts: 5-50 KB each; 1M traces/month ≈ 10-50 GB). Set a retention TTL (project-level data retention in newer versions, or a ClickHouse TTL) and an S3 lifecycle on the event/media bucket. Postgres stays small (projects, keys, prompts, users). The worker is the throughput bottleneck for ingestion bursts: scale workers horizontally; a growing Redis queue (`bull` queues) means ingestion lag, not data loss.
- **High availability** needs a replicated ClickHouse (ClickHouse Keeper), managed Postgres, Redis with persistence off but HA, and a durable S3; the lab single-node compose is for learning.
- **Air-gap**: no telemetry (`TELEMETRY_ENABLED=false`), no external auth, images mirrored; the langfuse-web image needs no internet at runtime. Prompt-management and evals are optional features worth knowing: prompt versions with labels (`production`), datasets/experiments, LLM-as-judge evaluators (the judge model must be reachable internally — your own gateway).
- **Masking and consent**: mask at the source if possible (LiteLLM `turn_off_message_logging: true` logs metadata only; per-key/team overrides exist) — retrofitting masking after prompts are stored is much harder. Decide who can open the UI: traces include whatever users pasted.
- **Trace anatomy** from LiteLLM: one trace per request (name from `trace_name`, `user_id`, `session_id`, `tags`), one `generation` observation with model, input messages, output, `usage` (input/output/total tokens), cost if the model has a price, start/end/completion-start timestamps (TTFT for streams), and `level=ERROR` + status message for failures. Retries/fallbacks appear as separate generations when enabled.
- **Correlation**: LiteLLM response header `x-litellm-call-id`; pass `trace_id` in metadata to join with application traces. Spend logs, Langfuse and engine logs share timestamps; use the call id as the join key.

## 17. OpenTelemetry route (know it exists)

vLLM can export request spans via OTLP (`--otlp-traces-endpoint`, with the `opentelemetry-*` packages installed); LiteLLM has `otel` and `langfuse_otel` callbacks; Langfuse ingests OTLP at `/api/public/otel`. The attraction: one standard pipeline (OTel Collector → Tempo/Jaeger/Langfuse) and trace context propagation from the client through the gateway to the engine, so a slow request shows queue time, prefill and decode as spans of one trace. The cost: more moving parts; sampling decisions; GenAI semantic conventions are still evolving (attribute names change between releases) — pin versions and test. Teams with an existing OTel stack should start there; teams without one usually start with the LiteLLM→Langfuse callback and add OTel later.

## 18. An incident, end to end (what you will do in the capstone)

Page: `TTFTHigh` for `model_name="chat"`, p95 3.2 s (SLO 1 s). Walk:
1. Dashboard row 1: TTFT p95 up since 14:05; ITL p95 normal; tokens/s flat. → it is **queueing or prefill**, not decode speed.
2. Row 2: `num_requests_waiting` 0 → 35 at 14:05; `running` pinned at 64 (= `max_num_seqs`); KV 0.52; preemption rate 0. → the **sequence cap** binds, KV has room.
3. Row 5 (gateway): requests per key: `agent-batch` key went from 2 to 40 req/s at 14:04 with 3,000-token prompts. → a new client; LiteLLM per-key limits missing (module 05).
4. Langfuse sample of slow traces: same 2,800-token system prompt, user id `etl-bot`. → a looping automation.
5. Actions: (short) gateway `max_parallel_requests` for that key; (medium) separate team/pool for batch traffic; (long) raise `max_num_seqs` only after checking KV, add a replica, prefix-aware routing for the shared prompt.
6. Postmortem fields: detection time (alert `for` + scrape), time to attribute (per-key metrics), what the dashboard lacked (per-key TTFT?), alert quality (did `QueueGrowing` fire first?).

## 19. Exercises

1. Write the expression for "fraction of requests with ITL ≤ 50 ms" per model. (`sum by (model_name) (rate(vllm:inter_token_latency_seconds_bucket{le="0.05"}[5m])) / sum by (model_name) (rate(vllm:inter_token_latency_seconds_count[5m]))`.) Why is `le="0.05"` a legal literal here? (It is a real bucket boundary; `le="0.06"` would return nothing.)
2. Your dashboard shows tokens/s dropping to zero for 20 s every deploy. Is the service down? (No: per-replica counters reset and series go stale during rolling updates; check `up`, readiness and the gateway error rate before alarming.)
3. LiteLLM metrics show 1,000 requests, the spend logs 970. Name two harmless and one harmful explanation. (Harmless: batch lag at the time of the query, requests still in flight; harmful: dropped spend writes — check Postgres errors.)
4. Why record `sum by (le, model_name) (rate(..._bucket[5m]))` as its own series in a large fleet? (Quantiles over 50 replicas × 22 buckets per dashboard refresh are expensive and the aggregated buckets can be re-quantiled for any quantile or SLO threshold.)
5. A teammate proposes alerting on `avg_over_time(vllm:kv_cache_usage_perc[5m]) > 0.8`. Critique. (KV is expected to be high on a healthy busy replica; average over replicas hides a single full one — use `max by`; no co-condition on queue/preemptions; fires daily and gets muted.)

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

## 20. Reference: PromQL cookbook for the AI stack

| Question | Query |
|---|---|
| Output tokens/s per model | `sum by (model_name) (rate(vllm:generation_tokens_total[1m]))` |
| Input tokens/s per model | `sum by (model_name) (rate(vllm:prompt_tokens_total[1m]))` |
| Mean output length | `sum(rate(vllm:request_generation_tokens_sum[5m])) / sum(rate(vllm:request_generation_tokens_count[5m]))` |
| Share of requests ending by length cap | `sum(rate(vllm:request_success_total{finished_reason="length"}[5m])) / sum(rate(vllm:request_success_total[5m]))` |
| Client aborts per second | `sum(rate(vllm:request_success_total{finished_reason="abort"}[5m]))` |
| Prefix cache hit rate | `sum(rate(vllm:prefix_cache_hits_total[5m])) / sum(rate(vllm:prefix_cache_queries_total[5m]))` |
| Queue time p95 | `histogram_quantile(0.95, sum by (le) (rate(vllm:request_queue_time_seconds_bucket[5m])))` |
| Prefill vs decode time share | `rate(vllm:request_prefill_time_seconds_sum[5m]) / rate(vllm:request_inference_time_seconds_sum[5m])` |
| Mean preemptions per request | `rate(vllm:request_num_preemptions_sum[5m]) / rate(vllm:request_num_preemptions_count[5m])` |
| Gateway error ratio | `sum(rate(litellm_proxy_failed_requests_metric_total[5m])) / sum(rate(litellm_proxy_total_requests_metric_total[5m]))` |
| Tokens per key (24 h) | `sum by (api_key_alias) (increase(litellm_total_tokens_metric_total[24h]))` |
| llama.cpp generation tokens/s | `rate(llamacpp:tokens_predicted_total[1m])` |
| Engine up | `up{job="vllm"}` |
| Metric disappeared | `absent(vllm:kv_cache_usage_perc)` |

Conventions: aggregate before dividing (`sum(rate(a)) / sum(rate(b))`, not an average of ratios); keep `model_name` on every aggregation that feeds a per-model alert; and always check a new query against a number you can compute by hand from raw `/metrics` once.

## 21. Dashboard review checklist (use it on any AI dashboard you inherit)

1. Every latency panel is a quantile of histogram buckets (not `_sum` alone, not an average of quantiles) and shows the SLO as a threshold line.
2. Counters are always wrapped in `rate()`/`increase()`; gauges never are.
3. Units are right (`s`, `percentunit`, `reqps`); KV is 0..1; tokens/s is not labelled requests/s.
4. The top row answers "are users OK?" (TTFT, ITL, error rate, tokens/s), the next rows "why?" (queue, KV, preemptions, batch), the bottom "who/how much?" (per key/team, cost).
5. There is a panel that fails loudly when scraping fails (`up`, number of series) — an empty dashboard must not look like a healthy one.
6. Template variables have an "All" value that works with `=~` and the panel queries use it.
7. Panels are readable at the default time range (15 m) and at 6 h; `$__rate_interval` instead of hard-coded windows.
8. The dashboard JSON is in Git, provisioned with a stable uid, and has a version history; nobody edits it only in the UI.
