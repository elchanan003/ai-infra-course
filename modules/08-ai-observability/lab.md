# 08 — Lab: AI dashboards, recording rules, alerts, token accounting, tracing

Time: ~4 h of work plus a few minutes of waiting for `verify.sh` (it generates its own load). Guidance level: guided, then open. Work from `modules/08-ai-observability/`.

**Honesty first.** Prometheus, Grafana, LiteLLM, llama.cpp and Langfuse are real. The vLLM metrics come from **mock-vllm** (simulated engine, real metric names, deterministic virtual clock); production has real GPUs behind the same names. Alert/recording logic is graded with `promtool test rules` on synthetic series (deterministic) plus one bounded live check.

## Starting state

`prepare-lab.sh` converges profiles `gw llm mock obs` (LiteLLM + Postgres + Valkey, llama.cpp, mock-vllm A/B, Prometheus, Grafana), points Prometheus at `lab/prometheus/` and Grafana at `lab/grafana/`, and seeds hidden per-learner variant data in `.state/`. Part L (Langfuse) is a separate gate: `./prepare-lab.sh langfuse` runs profile `lf` **alone** with a minimal gateway + mock (it cannot share the host with `llm`), and `./verify.sh langfuse` grades it.

```bash
./prepare-lab.sh
# Prometheus  http://localhost:18090   Grafana http://localhost:18030 (credentials: platform/stack/README.md)
# reload after editing rules/config:   curl -X POST localhost:18090/-/reload   (lifecycle API is enabled in the lab)
```
Useful tools (Prometheus v3.5.0 image): `promtool check rules`, `promtool check config`, `promtool test rules`:
```bash
docker run --rm --entrypoint promtool -v "$PWD/lab/prometheus:/w:ro" prom/prometheus:v3.5.0 check rules /w/rules/ai-recording.yml
```
(`platform/lib.sh` provides `promtool_test`; `verify.sh` uses it with its own test files and **your** rule files.)

## Ownership

| Path | Status |
|---|---|
| `lab/prometheus/prometheus.yml` | yours — task 8.1 (starter: Prometheus only scrapes itself) |
| `lab/prometheus/rules/ai-recording.yml` | yours — task 8.2 (starter: empty groups) |
| `lab/prometheus/rules/ai-alerts.yml` | yours — task 8.4 (starter: empty groups) |
| `lab/prometheus/tests/*.test.yml` | yours, optional: write your own promtool tests (`verify.sh` brings its own) |
| `lab/grafana/dashboards/ai-serving.json` | yours — tasks 8.3 and 8.6 (starter: one **broken** TTFT panel + empty rows) |
| `lab/grafana/provisioning/` | given (datasource uid `prometheus`, dashboard provider) |
| `lab/answers/tokens.env` | yours — task 8.5 |
| `lab/litellm/config.d/langfuse.yaml` | yours — task 8.7 (part L only) |
| `lab/tools/` (`traffic.sh`, `snapshot-prom.sh`) | given — do not modify |

---

## Task 1 (8.1) — Scrape the three sources

**Goal:** Prometheus scrapes vLLM (mock A and B), llama.cpp chat and LiteLLM and you can prove the series you will depend on exist.

Steps/hints:
1. Look at each target's raw `/metrics` with curl first (ports in `CONVENTIONS.md`; from inside the Docker network use the service names listed in `platform/stack/README.md`). Note the paths and flags: llama.cpp needs `--metrics` (already on), LiteLLM serves `/metrics/`.
2. Add jobs `vllm` (two targets, label `replica` = `a`/`b`), `litellm`, `llamacpp` to `lab/prometheus/prometheus.yml`, 5 s scrape interval (lab-only).
3. `promtool check config`, reload, open Status → Targets.
4. Confirm names exist: `count({__name__=~"vllm:.+"})`, `litellm_proxy_total_requests_metric_total`, `llamacpp:tokens_predicted_total` — send one chat request through LiteLLM first so request-driven series exist.

Success criteria
- `8.1a` targets of jobs `vllm` (2), `litellm` (1), `llamacpp` (1) are `up`.
- `8.1b` `vllm:kv_cache_usage_perc` has a `replica` label with values `a` and `b`; LiteLLM request counter and llama.cpp token counter series exist.

## Task 2 (8.2) — Recording rules for TTFT and ITL

**Goal:** `lab/prometheus/rules/ai-recording.yml` records, per `model_name`: `model:vllm_ttft_seconds:p95_5m` and `model:vllm_itl_seconds:p95_5m`, and `model:vllm_generation_tokens:rate1m` (sum across replicas).

Steps/hints:
1. Quantile last, `sum by (le, model_name)` of `rate()` over `[5m]` first (theory section 3.2).
2. `promtool check rules`, then reload and look at `/rules` in the UI.
3. Write a tiny promtool test of your own with a synthetic histogram to be sure the rule returns what you computed by hand.

Success criteria
- `8.2a` verify's synthetic `promtool test rules` (histogram series with a known p95, two replicas, plus a bucket-boundary case) passes against your rules.
- `8.2b` the live recorded p95 TTFT equals verify's own direct `histogram_quantile` query on the live data within ±10% (verify drives deterministic load on mock A/B).
- `8.2c` the generation-tokens rate equals the sum over both replicas within ±10% (replicas are not averaged).

## Task 3 (8.3) — Dashboard as code

**Goal:** `lab/grafana/dashboards/ai-serving.json` (provisioned; do not edit in the UI and forget to export) with these panels, **titles exactly**: `TTFT p95`, `ITL p95`, `Tokens per second`, `Queue (waiting/running)`, `KV cache usage`, `Preemptions`, `Spend per key`.

Steps/hints:
1. Build panels in the Grafana UI for speed, then export JSON (Share → Export → "export for sharing externally" off, keep the datasource uid `prometheus`) into the file; Grafana reloads provisioned dashboards within ~10 s.
2. Use your recording rules where it makes sense; KV panel unit `percentunit`; spend panel `sum by (api_key_alias)(increase(litellm_spend_metric_total[$__range]))` (or equivalent).
3. Add a template variable `model` for `model_name`.

Success criteria (verify sends traffic with two different keys, then executes every panel's queries through the Grafana API)
- `8.3a` the dashboard is loaded (provisioned) and contains all seven panel titles.
- `8.3b` every panel's query returns at least one series with data.
- `8.3c` `Spend per key` returns two series (one per key alias), `KV cache usage` values lie in 0..1.

## Task 4 (8.4) — Alerts: KVCacheNearFull, TTFTHigh, QueueGrowing

**Goal:** `lab/prometheus/rules/ai-alerts.yml` with, each carrying `severity` and `team: llm-platform` and annotations `summary` (with the value) and `runbook_url`:

| Alert | Spec |
|---|---|
| `KVCacheNearFull` | KV > 0.9 **and** (queue > 0 **or** preemption rate > 0), `for: 2m`, severity warning |
| `TTFTHigh` | recorded p95 TTFT > 1.0 s (the SLO), `for: 2m`, severity critical |
| `QueueGrowing` | waiting requests > 5 for `3m`, severity warning |

Steps/hints:
1. Express "and (…or…)" with PromQL set operators (`and on(model_name)`), mind that each side must carry matching labels.
2. A steady 0.95 KV with an empty queue must stay quiet — that is the point of the compound condition.
3. Write promtool tests: one fire case and one quiet case per alert (your own tests are optional but save time).

Success criteria
- `8.4a` KVCacheNearFull: fires in verify's synthetic test with correct labels/annotations; **quiet** for KV 0.95 steady with empty queue and zero preemptions.
- `8.4b` TTFTHigh: fires only after `for` elapses (quiet before), quiet below SLO.
- `8.4c` QueueGrowing: fires at waiting=8 for 4m; quiet at waiting=3 and for a 1-minute spike.
- `8.4d` live: verify injects the mock `kv_pressure` fault with load; KVCacheNearFull reaches `firing` within a bounded window (≤ `for` + 90 s) and resolves after the fault is removed.

## Task 5 (8.5) — Token reconciliation

**Goal:** after a verify-style traffic run, reconcile tokens across the gateway spend logs, LiteLLM's Prometheus counters and the engine counters, then explain the gap.

Steps/hints:
1. `lab/tools/traffic.sh` sends a fixed, deterministic burst through the gateway **and** (hidden to you) some traffic straight to the engine; it prints the start/end timestamps.
2. Wait for the spend flush (lab: ~5 s; production ~60 s) before reading spend logs: `GET /spend/logs?start_date=...&end_date=...` (or the DB through the LiteLLM API) — poll until the row count is stable.
3. Compute the same window in Prometheus: `increase(litellm_total_tokens_metric_total[...])` and `increase(vllm:prompt_tokens_total[...]) + increase(vllm:generation_tokens_total[...])`. Use `@ <end>` or an instant query at the end timestamp.
4. Fill `lab/answers/tokens.env`: `GATEWAY_TOKENS`, `PROM_GATEWAY_TOKENS`, `ENGINE_TOKENS`, `GAP_CAUSE` ∈ `bypass | cache | lag | restart | none`, and the evidence field for your cause: `BYPASS_REQUESTS=<number of engine requests with no gateway counterpart>` (or `0`).

Success criteria
- `8.5a` `GATEWAY_TOKENS` and `PROM_GATEWAY_TOKENS` match verify's values for the run within ±2%.
- `8.5b` `ENGINE_TOKENS` matches within ±2%.
- `8.5c` `GAP_CAUSE` and `BYPASS_REQUESTS` match the seeded variant (evidence-bound; guessing the enum without the count fails).

## Task 6 (8.6) — Troubleshooting: the flat TTFT panel

**Scenario.** On-call says the starter dashboard's TTFT panel "never moves, even during the incident". Open `lab/grafana/dashboards/ai-serving.json` (starter panel `TTFT p95`), look at its query, inject latency (`curl -X POST localhost:18021/admin/fault -H 'Content-Type: application/json' -d '{"latency": ...}'`, see `mock/README.md` for the field format), and watch. Fix the query (and unit) so the panel is correct.

Success criteria
- `8.6a` the fixed panel query matches verify's reference quantile within ±10% on deterministic data.
- `8.6b` positive/negative pair: with the mock `latency` fault the panel's value rises by ≥ 2× versus baseline (verify measures both on deterministic mode).

## Task 7 (8.7, part L) — Trace a request with Langfuse (separate gate)

Run alone: `./prepare-lab.sh langfuse` (profile `lf`, ~2.75 GB, takes a minute or two to be healthy: ClickHouse migrations). Langfuse (web, worker, Postgres, ClickHouse, Redis, S3) comes up headless with a project and keys seeded by `LANGFUSE_INIT_*`; credentials are in `platform/stack/README.md`.

**Goal:** LiteLLM sends a trace to Langfuse for each request, with the user and the token usage.

Steps/hints:
1. Add the callback in `lab/litellm/config.d/langfuse.yaml` (`litellm_settings.success_callback` / `failure_callback`) and the `LANGFUSE_*` variables (the file says where; the host is the in-network Langfuse web service).
2. Restart LiteLLM (`./lab/tools/restart-litellm.sh`), send a chat completion with `"user": "<your-name>"` and `metadata.trace_name`.
3. Query the Langfuse public API (`/api/public/traces?userId=...`, Basic auth `pk:sk`) — remember ingestion is asynchronous; poll.

Success criteria (`./verify.sh langfuse`)
- `8.7a` a trace for verify's nonce user is found via the API within 60 s, with the model name.
- `8.7b` the trace's input contains the nonce prompt and its token usage equals the response's `usage`.
- `8.7c` a request the mock rejects with an error appears as an error-level observation (failure callback works).

---

## Reference points
- Metric names and PromQL patterns: `theory.md` sections 2-6; `cheatsheets/vllm-flags-metrics.md`.
- If Grafana shows "datasource not found": the dashboard JSON must refer to datasource uid `prometheus`.
