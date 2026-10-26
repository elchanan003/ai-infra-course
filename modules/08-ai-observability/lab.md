# 08 — Lab: AI dashboards, recording rules, alerts, token accounting, tracing

Time: ~4 h of work plus a few minutes of waiting for `verify.sh` (it generates its own load). Guidance level: guided, then open. Work from `modules/08-ai-observability/`.

**Honesty first.** Prometheus, Grafana, LiteLLM, llama.cpp and Langfuse are real. The vLLM metrics come from **mock-vllm** (simulated engine, real metric names, deterministic virtual clock); production has real GPUs behind the same names. Alert/recording logic is graded with `promtool test rules` on synthetic series (deterministic) plus one bounded live check.

## Starting state

`prepare-lab.sh` converges profiles `gw llm mock obs` (LiteLLM + Postgres + Valkey, llama.cpp, mock-vllm A/B, mock-dcgm, Prometheus, Grafana), points Prometheus at `lab/prometheus/` and Grafana's dashboard folder at `lab/grafana/dashboards/`, and seeds hidden per-learner variant data in `.state/`. Part L (Langfuse) is a separate gate: `./prepare-lab.sh langfuse` runs profile `lf` **alone** with a minimal gateway + mock (it cannot share the host with `llm`), and `./verify.sh langfuse` grades it.

```bash
./prepare-lab.sh
# Prometheus  http://localhost:18090   Grafana http://localhost:18030 (admin/admin)
# reload after editing rules/config:   platform/stack.sh reload-prometheus   (= POST /-/reload)
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
| `lab/reconcile.sh` | yours — task 8.5 (starter prints `REPLACE_ME`) |
| `lab/grafana/dashboards/ai-serving.json` | yours — tasks 8.3 and 8.6 (starter: one **broken** TTFT panel + empty rows) |
| `lab/litellm/config.yaml` | yours — task 8.7 (part L only) |
| `lab/tools/` (`traffic.sh`, `restart-litellm.sh`) | given — do not modify |

---

## Task 1 (8.1) — Scrape the three sources

**Goal:** Prometheus scrapes vLLM (mock A and B), llama.cpp chat and LiteLLM and you can prove the series you will depend on exist.

Steps/hints:
1. (verify reloads Prometheus for you; you reload it while working with `platform/stack.sh reload-prometheus`.) Look at each target's raw `/metrics` with curl first (ports in `CONVENTIONS.md`; from inside the Docker network use the service names listed in `platform/stack/README.md`). Note the paths and flags: llama.cpp needs `--metrics` (already on), LiteLLM serves `/metrics/`.
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
- `8.2a` verify's synthetic `promtool test rules` (two replicas with different volume and speed, a known combined p95/ITL p95 and token rate) passes against your rules (it also checks the ITL and token-rate rules).
- `8.2b` the live recorded p95 TTFT equals verify's own direct `histogram_quantile` query on the live data within ±10% (verify reloads Prometheus and drives its own load first).

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
0. Contract: a firing alert carries exactly the labels `alertname`, `model_name`, `severity`, `team` (aggregate with `by (model_name)`).
1. Express "and (…or…)" with PromQL set operators (`and on(model_name)`), mind that each side must carry matching labels.
2. A steady 0.95 KV with an empty queue must stay quiet — that is the point of the compound condition.
3. Write promtool tests: one fire case and one quiet case per alert (your own tests are optional but save time).

Success criteria
- `8.4a` KVCacheNearFull: fires in verify's synthetic test with labels `severity=warning team=llm-platform` after its `for: 2m` (also when only preemptions, not the queue, are non-zero), and is quiet for high queue/preemptions with KV 0.5; **quiet** for KV 0.95 steady with empty queue and zero preemptions.
- `8.4b` TTFTHigh: fires only after `for` elapses (quiet before), quiet below SLO.
- `8.4c` QueueGrowing: fires at waiting=8 after `for: 3m`; quiet at waiting=3 and for a 1-minute spike.
- `8.4d` live: verify injects the mock `kv_pressure` fault with 40 concurrent clients; KVCacheNearFull reaches `firing` within 240 s.
- `8.4e` the firing alert's rendered annotations: `summary` contains the value, `runbook_url` is an http(s) URL.
- `8.4f` after the fault and load are removed the alert stops firing within 150 s.

## Task 5 (8.5) — Token reconciliation

**Goal:** write `lab/reconcile.sh START END KEY_ALIAS` that reconciles tokens for one traffic run across the gateway spend logs, LiteLLM's Prometheus counters and the engine counters, and explains the gap. Verify runs fresh traffic and then **executes your script** on it.

Steps/hints:
1. `./lab/tools/traffic.sh` shows what a run looks like: sequential requests through the gateway with a fresh key alias, plus (hidden to you) some engine traffic that does not go through the gateway. It prints `START`, `END`, `KEY_ALIAS`.
2. Spend logs are batch-written (lab ~5 s lag; production ~60 s): your script reads them for the alias in the window (Postgres `LiteLLM_SpendLogs`, or the LiteLLM spend API); verify waits for the flush before calling you, but while experimenting wait yourself.
3. Prometheus: the alias is unique to the run, so the series starts at zero: compare an instant query at `END+12` with one at `START` (instant queries are exact; `increase()` extrapolates at the window edges and can be off by several %). Engine = mock A (`replica="a"`): prompt + generation token counters, same two instants.
4. Print the five `KEY=VALUE` lines listed in the starter. `BYPASS_REQUESTS` = engine requests the gateway never saw: derive it from the token gap and the tokens per gateway request.

Success criteria
- `8.5a` gateway tokens from the spend logs (±2%) and from the Prometheus counters (±3%) match the run.
- `8.5b` engine tokens match within ±3%.
- `8.5c` `GAP_CAUSE=bypass` and `BYPASS_REQUESTS` equals the exact hidden count (evidence-bound).

## Task 6 (8.6) — Troubleshooting: the flat TTFT panel

**Scenario.** On-call says the starter dashboard's `TTFT p95` panel "never moves, even during the incident". Open `lab/grafana/dashboards/ai-serving.json` (starter panel `TTFT p95`), read its query, inject a slowdown for a while (`curl -X POST localhost:18021/admin/fault -H 'Content-Type: application/json' -d '{"latency_ms": 2000}'` plus some traffic; remove it with `DELETE`) and watch. Fix the query so the panel shows a real p95.

Success criteria (promtool on synthetic series — deterministic — using **your** panel query)
- `8.6a` on steady data your query returns the true combined p95 within ±10%.
- `8.6b` it stays below 0.6 s when healthy and exceeds 2 s after 20% of the requests turn slow.

## Task 7 (8.7, part L) — Trace a request with Langfuse (separate gate)

Run alone: `./prepare-lab.sh langfuse` (profile `lf`, ~2.75 GB, takes a minute or two to be healthy: ClickHouse migrations). Langfuse (web, worker, Postgres, ClickHouse, Redis, S3) comes up headless with a project and keys seeded by `LANGFUSE_INIT_*`; credentials are in `platform/stack/README.md`.

**Goal:** LiteLLM sends a trace to Langfuse for each request, with the user and the token usage.

Steps/hints:
1. Add the callbacks in `lab/litellm/config.yaml` (`litellm_settings.success_callback` / `failure_callback`). The `LANGFUSE_*` variables are already in the LiteLLM container's environment (`platform/stack/README.md`).
2. Restart LiteLLM (`./lab/tools/restart-litellm.sh`; verify restarts nothing, so do this yourself), send a chat completion with `"user": "<your-name>"` and `metadata.trace_name`.
3. Query the Langfuse public API (`/api/public/traces?userId=...`, Basic auth `pk:sk`) — remember ingestion is asynchronous; poll.

Success criteria (`./verify.sh langfuse`)
- `8.7a` a trace for verify's nonce user is found via the API within 60 s, with the model name.
- `8.7b` the trace's input contains the nonce prompt and its token usage equals the response's `usage`.
- `8.7c` a request the mock rejects with an error appears as an error-level observation (failure callback works).

---

## Reference points
- Metric names and PromQL patterns: `theory.md` sections 2-6; `cheatsheets/vllm-flags-metrics.md`.
- If Grafana shows "datasource not found": the dashboard JSON must refer to datasource uid `prometheus`.
