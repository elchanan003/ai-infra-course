# 05 — Gateway routing and governance: load balancing, fallbacks, cooldowns, budgets, traffic separation

Time: ~1 h reading with the tutor. Prerequisites: module 04 (keys, teams, limits, Valkey). Pinned: LiteLLM proxy `v1.106.4`. Statements marked "measured" were observed on this version in the course lab; statements marked "documented" come from LiteLLM docs for the v1.10x line and are re-confirmed by a lab task where noted — in production, confirm with `curl -i` and a canary before you rely on them.

Honesty box. Real: LiteLLM routing, Postgres spend, Valkey. Simulated: the two "GPU replicas" are mock-vllm A and B (OpenAI-compatible, deterministic, fixed `usage`, unique response ids, a fault API to make A fail or slow down). They let us count exactly which backend served what and compute spend to the cent. In production the replicas are vLLM pods on real GPUs, errors are OOMs/timeouts/driver faults, and traffic is noisy; thresholds you tune against a mock must be re-tuned on real traffic.

---

## 1. Model groups and deployments

In LiteLLM's router a **deployment** is one `model_list` entry (one backend). Entries that share a `model_name` form a **model group**; clients address the group, the router picks a deployment per request.

```yaml
model_list:
  - model_name: chat                       # group "chat" has two deployments
    litellm_params: {model: openai/chat, api_base: http://mock-vllm-a:8000/v1, api_key: none, rpm: 600}
    model_info: {id: chat-a}
  - model_name: chat
    litellm_params: {model: openai/chat, api_base: http://mock-vllm-b:8000/v1, api_key: none, rpm: 600}
    model_info: {id: chat-b}
  - model_name: chat-small                 # a different group, used as a fallback target
    litellm_params: {model: openai/qwen-0.5b, api_base: http://llama-chat:8080/v1, api_key: none}
```

Always set a stable `model_info.id`: it labels metrics (`litellm_deployment_*`), response headers (`x-litellm-model-id`) and logs, and is how you tell A from B when debugging. Without it LiteLLM derives an id from the params (a hash that changes when you edit the entry).

## 2. Load-balancing strategies

`router_settings.routing_strategy`:

| Strategy | Picks | Needs shared state | When teams use it |
|---|---|---|---|
| `simple-shuffle` (default) | random, optionally weighted by `weight` (or `rpm`/`tpm` values) | no | **the production default**: no feedback loop, no hot spots from stale metrics, cheapest |
| `least-busy` | deployment with the fewest in-flight requests (per-replica view) | memory/Redis | uneven request sizes, no better signal |
| `latency-based-routing` | lowest recent latency (rolling, `lowest_latency_buffer`) | memory/Redis | multi-region/SaaS mixes; dangerous on LLMs because latency is dominated by output length, not health |
| `usage-based-routing(-v2)` | lowest TPM/RPM usage relative to deployment `tpm`/`rpm` | **Redis required** across replicas; adds Redis calls to every request | respect per-deployment quotas (SaaS keys with rate limits) |
| `cost-based-routing` | cheapest deployment | no | mixed SaaS + on-prem pools |

Why `simple-shuffle` wins on GPU fleets: the *engines* already do the hard scheduling (continuous batching, queues — modules 01/03). The gateway balancer only needs to avoid pathological choices. Latency- or load-reactive strategies herd traffic onto the "fast" replica until it is slow (oscillation), and per-gateway-replica load views are wrong anyway when several gateways exist. A smarter layer, if needed, is **KV/prefix-aware routing** inside an inference-aware router (vLLM production-stack router, llm-d, Envoy AI Gateway extensions): it routes by the engine's own queue/KV metrics and prefix-cache locality. That is where "load balancing for LLMs" is heading; LiteLLM's balancer is deliberately simple. Know both exist.

Weights: with `simple-shuffle` set `weight: 4` / `weight: 6` in `litellm_params` to split 40/60 (useful for canarying a new engine version at 5-10 %). With the same `weight` all deployments are equal. `order: 1/2` instead gives **priority** (use deployment 2 only when 1 is unavailable) — a different thing from weights.

**Verification math you will use in the lab.** A weighted random split of n=100 calls at p=0.4 has mean 40, standard deviation √(n p (1−p)) = 4.9. So "40 ± 10" is a ~2σ band (about 95 % of runs) — a test that demands exactly 40 would be flaky by construction. Use bounds that follow from the distribution (or more calls), never exact counts, for anything random.

### 2.1 Choosing a strategy by scenario

| Scenario | Strategy | Why | Watch out |
|---|---|---|---|
| 2-10 identical vLLM replicas of one model | `simple-shuffle`, equal weights | engines schedule internally; no feedback loop | a sick replica still gets its share until cooldown |
| Replicas of different size (8 GPU vs 4 GPU) | `simple-shuffle` with `weight` proportional to capacity | static, predictable split | re-tune weights when hardware changes |
| Canary of a new engine version | `simple-shuffle` with 5/95 weights | exact control of exposure | the canary needs its own `model_info.id` for metrics |
| Primary on-prem, spare elsewhere | `order: 1` / `order: 2` (priority) or a fallback group | spare takes traffic only when primary is unavailable | spare idle means unknown health; probe it |
| SaaS keys with provider rate limits | `usage-based-routing-v2` + router Redis | respects per-key `tpm`/`rpm` | one extra Redis round trip per request; per-gateway counters without Redis |
| Mixed SaaS + on-prem, price matters | `cost-based-routing` | cheapest first | ignores quality and privacy; combine with tags |
| Single gateway, wildly different request sizes | `least-busy` | in-flight count approximates load better than request count | the view is per gateway replica |
| Latency-sensitive, many regions | `latency-based-routing` | picks nearest healthy | LLM latency tracks output length, so it herds on short-answer deployments |

Rule of thumb: start at the first row, change only with a measured problem (a dashboard showing one replica with higher queue time than another for hours). A strategy you cannot explain during an incident is a liability.

### 2.2 Worked example: statistics of a weighted split

Two deployments, `weight: 3` and `weight: 7`, so p(A) = 3/(3+7) = 0.30. The number of A hits in n calls is Binomial(n, 0.3):

| n | mean | std dev | ~95 % band (mean ± 2σ) | ~99.7 % band (± 3σ) |
|---|---|---|---|---|
| 50 | 15 | 3.2 | 9 to 21 | 6 to 24 |
| 200 | 60 | 6.5 | 47 to 73 | 41 to 79 |
| 1000 | 300 | 14.5 | 271 to 329 | 257 to 343 |

The relative error shrinks as 1/√n: at n=50 the 2σ band is ±43 % of the mean, at n=1000 it is ±9.7 %. For a canary at p=0.05 and n=2000 requests the mean is 100 and σ=9.7, so seeing 80 or 120 is unremarkable; seeing 40 means the weight is not what you think. A lab test for a split should pick n so that the band is tight enough to distinguish the intended weights from the nearest wrong alternative (30/70 versus 50/50 differ by 20 hits at n=100, which is 4σ, so n=100 suffices; 30/70 versus 35/65 differs by 5 hits, which needs n of several hundred).

Two traps: (1) weights apply per request, not per token, so token or GPU-seconds load can deviate from the weight split when one deployment attracts longer prompts (it should not, but check with `vllm:prompt_tokens_total`); (2) retries re-run the draw, so the observed share of a flaky deployment is lower than its weight because failed attempts are replaced by attempts on the other one. Count *successful* responses per `x-litellm-model-id`, not attempts.

### 2.3 Priority, tags and access groups

- **Priority by `order`** (documented): deployments carry `order: 1`, `order: 2`; the router uses the lowest order that is currently healthy and only then the next. It gives an in-group "primary and spare" without a separate fallback group. Confirm on v1.106.4 with a canary that cooldown of the order-1 deployment really moves traffic to order 2, and that traffic returns afterwards.
- **Request priority queue** (documented, confirm): the router can schedule requests with a `priority` field (lower number first) when requests queue at the gateway. It orders the *gateway* queue; it does not preempt a request already inside a vLLM engine. For real isolation of interactive from batch traffic the engine side matters (vLLM priority scheduling policy, or separate pools). Treat gateway priorities as a smoothing tool, not a guarantee.
- **Tag-based routing** (documented): `router_settings.enable_tag_filtering: true`, deployments get `litellm_params.tags: ["team-a"]`, requests (or keys) send `tags`; only matching deployments are eligible, with an optional `default` tag for untagged traffic. Use it for dedicated GPU pools per tenant inside one group name, or to keep regulated data on certain deployments. A tag with no matching deployment gives an error, not a silent fallback to any deployment: test the failure path.
- **Model access groups** (documented): `model_info.access_groups: ["chat-models"]` lets a key or team be granted `models: ["chat-models"]` instead of listing each group; adding a new model to the access group grants it to everyone with the group. Convenient and dangerous in equal measure: new expensive models become reachable without touching any key. Review membership changes like firewall rules.
- **Provider budgets** (documented): `provider_budget_config` caps spend per provider (e.g. SaaS fallback at $50/day), which turns "unbounded off-prem fallback" into a bounded one. It needs router Redis to be accurate across gateway replicas.

## 3. Retries, fallbacks, cooldowns — three different mechanisms

A request that fails at a backend goes through (documented):

```
call deployment X ──error──▶ retry? (num_retries, retry_policy, same group, router picks again — may choose Y)
                               └─ exhausted ──▶ fallback? (fallbacks[...] → another GROUP)
                                                  └─ fails ──▶ error to client
every failure also feeds  ──▶ cooldown bookkeeping (X may be removed from the group for cooldown_time)
```

### 3.1 Retries

`router_settings.num_retries` (e.g. 2), `retry_policy` (per exception class: `TimeoutError`, `RateLimitError`, `InternalServerErrorRetries`, `ContentPolicyViolationErrorRetries`, `BadRequestErrorRetries: 0`…), `retry_after`. Retries re-enter the balancer within the *same group*, so with two deployments a retry normally lands on the other one. Never retry what cannot succeed: 400s (bad request, context too long), 401/403, and content-policy blocks.

### 3.2 Fallbacks

```yaml
router_settings:
  fallbacks:                 [{"chat": ["chat-small"]}]               # general errors / exhausted retries
  context_window_fallbacks:  [{"chat": ["chat-long"]}]                # ContextWindowExceeded → bigger-window group
  content_policy_fallbacks:  [{"chat": ["chat-other"]}]
  default_fallbacks:         ["chat-small"]
  enable_pre_call_checks: true                                          # skip deployments whose context window is too small
```

- Fallbacks go **group → group**, not deployment → deployment. "A fails so use B" within one group is the *balancer + retries* job; a fallback is "the whole group is unavailable, degrade to something else" (smaller model, other region, SaaS).
- **A context-length error is a 400, not a 5xx.** The generic `fallbacks` list does not fire on it (measured in the lab task 5.6 — the planted trap): the request fails with `ContextWindowExceededError` unless `context_window_fallbacks` points at a group with a larger window. Likewise `content_policy_fallbacks` for policy blocks. This is the single most common "my fallback never fires" report.
- A fallback is a **product decision**: answer quality changes (0.5B instead of 70B), cost changes, privacy may change (a SaaS fallback sends prompts off-prem — often forbidden in air-gapped shops; say so in the design doc). Silent degradation hides outages: expose `x-litellm-attempted-fallbacks` and count fallbacks per hour as a metric.
- Fallback targets must have headroom: when A's traffic lands on B (or small-model) you have *created* the load B must absorb. Many "fallback worked, then everything died" incidents are capacity, not routing.
- Streaming: once the first token reached the client the HTTP status is already 200; retries/fallbacks only cover failures **before** the first byte (connection errors, 5xx at start, TTFT timeouts). A mid-stream engine crash surfaces as a truncated stream; the client must handle it. Do not design around mid-stream failover.

### 3.3 Cooldowns (passive health checking)

When a deployment fails, the router can temporarily **remove it from the group**:

| Setting (`router_settings`) | Default (documented) | Meaning |
|---|---|---|
| `allowed_fails` | 3 | failures per minute tolerated before cooldown |
| `cooldown_time` | 5 s | how long the deployment stays out |
| `allowed_fails_policy` | — | per-exception thresholds (`RateLimitErrorAllowedFails`, `TimeoutErrorAllowedFails`, …) |

Documented behaviour: certain errors cool a deployment down **immediately** (429 from the backend, 401, 404, 408); other errors (e.g. 500) only after more than `allowed_fails` failures within the current minute. Edge cases to verify on your version (task 5.3 does it for v1.106.4): what happens with a single-deployment group (recent versions avoid cooling down the only deployment — otherwise it would be a self-inflicted outage), and whether cooldown state is shared between gateway replicas (it is only if router Redis is configured: `router_settings.redis_*` — here, *this* is the right place for Redis, unlike rate limits in module 04).

Tuning intuition: a 5 s cooldown with a dead backend still sends probes every 5 s, each costing a failed request unless retries rescue it (`num_retries` ≥ 1 makes users not notice). A 60 s cooldown reduces wasted calls but keeps a recovered replica idle for a minute. For GPU replicas that restart in minutes, 30-60 s is typical; for flaky SaaS keys 5-10 s. There is no active health probe by default: the first failed requests *are* the probe (`background_health_checks: true` + `health_check_interval` adds active `/health`-style probes and marks deployments unhealthy — more moving parts; many teams rely on cooldown + engine-level K8s readiness).

Observability: metric `litellm_deployment_state` (0 healthy, 1 partial outage, 2 complete outage), `litellm_deployment_success_responses_total` / `_failure_responses_total` per deployment, `litellm_deployment_latency_per_output_token`. Build the "which replica is serving, which is cooled" panel from these (module 08).

### 3.4 Timeouts

`litellm_params.timeout` (whole request) and `stream_timeout` (time to first token for streams). A hung engine with no timeout holds client connections forever and never triggers retry/fallback — the failure mode of an overloaded vLLM at KV 100 %. Set a timeout that reflects your SLO (e.g. 30-60 s for chat, shorter for FIM), not the default of minutes.

### 3.5 Worked example: retry probability tree with a dead deployment

Setup: N deployments in a group, one of them dead (every call fails fast), `num_retries = r` so a request makes up to r+1 attempts. Assume each attempt draws uniformly among deployments, including ones that already failed this request (the simplest case; some versions steer retries away from the failed deployment or from cooled-down ones: documented, confirm with a canary).

- Probability that one attempt hits the dead one: 1/N.
- Probability that the client sees an error (all attempts hit it): (1/N)^(r+1).
- Probability the client sees a retry (extra latency): 1/N (first attempt dead).
- Expected backend calls per request: 1 + 1/N + ... + (1/N)^r.

| N | r | P(client error) | P(first attempt wasted) | Expected attempts |
|---|---|---|---|---|
| 2 | 0 | 50 % | 50 % | 1.00 |
| 2 | 2 | 12.5 % | 50 % | 1.75 |
| 4 | 2 | 1.6 % | 25 % | 1.31 |
| 10 | 2 | 0.1 % | 10 % | 1.11 |
| 2 | 5 | 1.6 % | 50 % | 1.97 |

Lessons: with two replicas, retries alone leave one request in eight failing; adding a third replica helps more than raising r (r=2, N=3: 3.7 %). More retries also multiply load on the survivors when the cause is overload rather than a dead host. Cooldown is the real fix because it cuts the 1/N term itself: once the dead one is removed, P(first attempt wasted) drops to about zero. Clients that also retry multiply this again: client retries (c) x gateway retries (r) can produce (c+1)(r+1) backend calls per user action. Decide where retries live and give the other layer zero.

With `allowed_fails: 3` and 50 req/s the dead deployment sees ~25 req/s of the traffic, so it crosses "more than 3 failures in the minute" in about 0.2 s and is cooled almost at once; at 0.2 req/s total it takes ~40 s to accumulate four failures, during which about 1 in 2 requests pay a retry. The slower the traffic, the longer a failing replica stays in rotation. Errors in the immediate class (429, 401, 404, 408; documented) skip the counter.

### 3.6 Expected wasted probes during cooldown

A cooled-down deployment re-enters the group after `cooldown_time`. If it is still dead, the next failure puts it back out (the per-minute failure count is still above `allowed_fails`: documented behaviour, confirm in lab task 5.3). Each re-entry costs about one wasted attempt (more if several requests arrive before the first failure returns, roughly `rate x failure latency`).

| cooldown_time | probes per hour (k=1) | probes per hour if 3 requests slip in each time | average idle time of a replica that recovers mid-window |
|---|---|---|---|
| 5 s | 720 | 2160 | 2.5 s |
| 30 s | 120 | 360 | 15 s |
| 60 s | 60 | 180 | 30 s |
| 300 s | 12 | 36 | 150 s |

Each wasted probe costs one failed backend call plus, if retries rescue it, one extra round trip for one user (fast failure: milliseconds; connect timeout or hang: the full per-try timeout, section 3.7). So the cost of a short cooldown is dominated by *how fast the failure is*: instant 500s make 5 s cooldown cheap, hangs make it expensive. The cost of a long cooldown is lost capacity: if a replica recovers uniformly within a window its mean idle time is cooldown/2, and at N=2 you are running at half capacity for that time. Typical choice: cooldown near the replica's real restart time divided by 2 to 3 (restart 90 s: 30 s cooldown gives ~3 probes per restart), and a hard timeout so that probes fail quickly. In the lab, mock replicas answer with an instant 500 (fault `error_rate: 1`), so probes are almost free; on real GPUs a hung engine makes them cost a full timeout.

### 3.7 Retry and timeout budget arithmetic

Total latency of a failing request is the sum of every attempt, not one timeout:

```
worst case = (r + 1) x t_try  +  F x (r_f + 1) x t_try_f      (r: retries, F: fallback groups tried)
```

Example: client timeout T_c = 60 s, gateway `timeout` t_try = 30 s, `num_retries` = 2, one fallback group with t_try_f = 20 s and the same retries: worst case = 3 x 30 + 3 x 20 = 150 s. The client gave up at 60 s, so for 90 s the gateway keeps working for nobody: the backend slot stays busy, spend accrues if the call completes, and the client's own retry arrives on top. Whether the gateway cancels upstream work when the client disconnects is version-dependent (documented, confirm with a canary and `vllm:num_requests_running`).

Design inequality: `(r + 1) x t_try + t_fallback <= T_c - margin`, with margin ~ 10 % for queueing and TLS. For T_c = 60: r=1, t_try = 20, fallback 15 gives 55 s. If a request legitimately takes 40 s (long generations), you cannot also have retries: either raise T_c, allow a long `timeout` and set `num_retries: 0` for that group, or use streaming (section 3.8) where progress, not completion, defines health. Different groups deserve different budgets: FIM (client timeout 1 s, backend p99 300 ms) cannot afford any retry whose timeout is above 300 ms; agent groups tolerate 120 s tries but should not retry at all on `TimeoutError` when the engine is saturated, since a retry adds load to the thing that is slow.

Retry amplification under overload: if the pool is saturated and a fraction f of requests time out, retries raise the offered load to roughly (1 + f x r) times the base load. At f = 0.5 and r = 2 that is 2x, which pushes f up: a positive feedback loop (retry storm). Defences: `retry_policy` with `TimeoutErrorRetries: 0` for saturated groups, `max_parallel_requests` at the edge, and fallback to a *different* pool rather than retry into the same one.

### 3.8 Streaming and time-to-first-token timeouts

For streams two clocks matter: time to first token (TTFT: queueing plus prefill) and the gap between tokens (ITL). `stream_timeout` bounds the wait for the first chunk (documented); `timeout` on a stream bounds the whole request, so a 2 000-token answer at 20 tok/s (100 s) needs a `timeout` above 100 s or it will be cut mid-answer. Pick them from measured engine histograms (`vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, module 03): `stream_timeout` about 5x the TTFT p99 at normal load (p99 = 2 s gives 10 s), `timeout` from the p99 of e2e latency times 2.

TTFT includes queue time, so under saturation a healthy-but-busy engine looks like a hung one. A TTFT timeout then triggers retries into a busy pool (section 3.7). Prefer a TTFT timeout that is generous plus an admission limit (`max_parallel_requests`) so that queues do not grow without bound; use the engine's `vllm:num_requests_waiting` for the alert, not the gateway timeout count. After the first chunk the status is 200 and retries are impossible: a mid-stream failure arrives as an aborted stream, and the client (Open WebUI, an agent loop) decides whether to resend. Agents should treat an aborted stream like a failed tool call and resume from the last complete message.

### 3.9 Health checking: passive cooldown, active probes, Kubernetes readiness

| Layer | Detects | Latency of detection | Cost | Blind spot |
|---|---|---|---|---|
| Router cooldown (passive) | failures real users hit | seconds at high traffic, long at low traffic | real failed requests | idle or low-traffic deployments; a hung engine costs a full timeout per probe |
| Gateway active checks (`background_health_checks`, `health_check_interval`; documented) | endpoint answers a tiny completion | the interval (e.g. 60 s) | synthetic tokens, extra spend and load | a deployment that answers tiny prompts but fails on 50k-token ones |
| Kubernetes readiness probe on the engine (`/health`) | process up and model loaded | probe period x failures (e.g. 5 s x 3) | negligible | `/health` is 200 while the KV cache is thrashing |
| Engine-level SLO alerts (queue, KV, preemptions) | degradation | scrape interval | none | humans must act |

Layering: readiness keeps unloaded replicas out of the endpoint list (the gateway never sees them), cooldown handles what readiness cannot see (500s, 429s, hangs under real load), and alerts handle slow degradation neither can classify as failure. Do not rely on the gateway's active check to decide *routing* until you have confirmed on v1.106.4 how its result feeds the router (documented as a separate `/health` report; whether it removes deployments from rotation depends on version: confirm with a canary). Mock note: the mock's `/health` returns 200 or 503 during `slow_load_s`, but a mock never degrades "softly", so lab tests cover only the clear-failure case.

### 3.10 Fallback graph design rules

1. **Acyclic.** `chat -> chat-small -> chat` must not exist; a cycle makes a failing request bounce until a depth limit. Draw the graph; verify it is a DAG.
2. **Shallow.** Depth 1, at most 2. Each hop adds a full retry budget (section 3.7) and a larger quality drop. Prefer one fallback target with high availability (a different failure domain) over a chain of weak ones.
3. **Different failure domain.** A fallback to a group on the same GPUs, same node or same upstream fails together with the primary.
4. **Never from critical to best-effort,** and never from agent pools into chat pools or the reverse (a fallback is also a route for overload).
5. **Headroom check.** Let group S (source) have concurrency L_S, target group T have its own steady concurrency L_T, capacity C_T (sum of `max_num_seqs` or KV-bound limit) and a safe utilisation rho (about 0.7). When a fraction q of S falls back to T: `L_T + q x L_S x (s_T / s_S)` must stay below `rho x C_T`, where s is mean service time (a smaller model finishes faster, so the same request needs fewer slot-seconds on T). Example: chat L_S=40, small group C_T=64 with its own L_T=10, s_S/s_T = 3: full outage q=1 gives 10 + 13 = 23 < 44.8, fine; with s_S/s_T = 1 it would be 50 > 44.8, so the target would saturate in turn.
6. **Typed fallbacks.** `fallbacks` for availability, `context_window_fallbacks` for length (needs a group with a larger window and the capacity to hold its KV), `content_policy_fallbacks` for policy. Using only the first leaves long-prompt traffic unprotected (lab task 5.6).
7. **Observable and bounded.** Count fallbacks, alert on a non-zero rate lasting minutes, and put a spend cap on any metered fallback target.
8. **Tested.** Kill the primary in a canary and watch the target's queue, not just the 200s.

## 4. Cost, spend and budgets (governance)

### 4.1 How spend is computed

`spend = prompt_tokens × input_cost_per_token + completion_tokens × output_cost_per_token`, taken from the backend's `usage` and the deployment's `model_info`. Self-hosted models have **no built-in price**: without `model_info` costs, spend is 0 and budgets never trigger. On-prem teams define an *internal* price (GPU cost per hour ÷ expected tokens per hour, plus overhead) so that teams see a number — showback (report) or chargeback (invoice). The number is a **policy object**, not physics.

Example (the style of check in the lab): prices 0.000002/prompt token and 0.000004/completion token; the mock reports usage 12 prompt + 18 completion tokens per call → 12×2e-6 + 18×4e-6 = 9.6e-5 per call; 25 calls = 0.0024 exactly. Because the mock's usage is fixed, you can hand-compute the expected spend and compare to `/key/info` after the flush barrier (module 04 section 6). Real engines report real usage, so the same check in production is "spend ≈ Σ usage × price" over the logs, not a constant.

### 4.2 Budgets

Budgets exist at several levels and all that apply are enforced:

| Level | Set via | Typical use |
|---|---|---|
| key | `max_budget`, `budget_duration` on `/key/generate` | per application; short window for risky agents |
| user | `/user/new` | individual developer quota |
| team | `/team/new` `max_budget` | department budget (the main control) |
| team member | per-member budget inside a team | stop one member eating the team budget |
| end user | request field `user` + end-user budget | per-customer inside an app |
| model on a key | `model_max_budget` | cap expensive model per key |
| proxy-wide | `litellm_settings.max_budget` | safety net |
| provider | `provider_budget_config` (router) | cap SaaS provider spend |

`budget_duration` (`30s`, `24h`, `30d`) resets the *counter* at the end of the period (a background job; not exactly on the second). **Exceeded budget → HTTP 422 with error type `budget_exceeded`** (measured), the message includes `Current cost` and `Max budget`; assert on status class + error type, not on text. One request may overshoot (check = spend so far). Under parallel bursts the logged "Current cost" numbers were erratic (measured), so budget logic is tested with **sequential** requests only; in production expect modest overshoot with concurrency — set budgets with margin and use alerts at 80 %.

Budget vs rate limit: a budget bounds *total money over a period* (slow, accounting); a rate limit bounds *instantaneous load* (fast, protection). Agents need both; chat keys usually only a team budget.

### 4.3 Reporting and attribution

`GET /key/info`, `GET /spend/logs`, `GET /spend/tags`, `GET /global/spend/report?group_by=team`, and the UI usage pages. Use **tags** (`tags: ["project-x"]` in key metadata or request metadata) for cost centres that cut across teams. Prometheus `litellm_spend_metric_total{team,api_key_alias,model}` is the time-series view (module 08). For chargeback accuracy remember lag (section 6 of module 04), failed requests (spend 0) and that streaming usage depends on `stream_options.include_usage` / backend support — otherwise LiteLLM estimates tokens with a tokenizer and spend is approximate.

### 4.4 Worked example: an internal price from GPU TCO

Policy inputs (assumptions to replace with your finance numbers): 8 GPUs at an all-in $2.50 per GPU-hour (depreciation of the server over 4 years, power, cooling, rack, network share) = $20/h; operations, spares and platform overhead +30 % = $26/h, paid whether or not anyone uses them.

Throughput: two replicas, tensor-parallel 4 each, sustaining about 2 500 generated tokens/s per replica at healthy batch sizes (assumed; measure with your own benchmark, module 03) = 5 000 tok/s peak. Average utilisation of that peak over the month: 35 % (nights and weekends). Effective output: 5 000 x 0.35 x 3 600 = 6.3 Mtok/h. Assume an input:output volume ratio of 4:1 (chat and agents with long prompts) = 25.2 Mtok/h input.

Pricing rule (policy): input tokens cost one quarter of output tokens, because prefill is batched compute and decode is memory-bound. Break-even scale solves `p_out x 6.3 + (p_out / 4) x 25.2 = 26`, i.e. `p_out x 12.6 = 26`, `p_out` = $2.06/Mtok output and $0.52/Mtok input. Round to $2.00 and $0.50: revenue at 35 % utilisation is 6.3 x 2 + 25.2 x 0.5 = $25.2/h, 97 % of cost. In LiteLLM: `input_cost_per_token: 5.0e-7`, `output_cost_per_token: 2.0e-6` in `model_info`.

Sensitivity: at 20 % utilisation the same prices recover 55 % of cost ($14.4/h); the gap is "idle capacity" and belongs in the platform's budget, not in a surprise rate hike for teams. At 60 % utilisation the break-even price falls to about $1.20 per Mtok output. Showback (publish the number, nobody pays) is the right first step; chargeback needs a stable price, a dispute process and an agreed treatment of failed requests (spend 0) and of fallbacks (the team is charged the *serving* group's price, which can differ from what it asked for: decide and document it). Reserve capacity (a dedicated agent pool) is usually billed per GPU-hour as a reservation, not per token.

### 4.5 Spend and budget arithmetic, including the overshoot bound

Take the section 4.4 prices and an agent key. One agent call: 30 000 prompt tokens and 800 completion tokens costs 30 000 x 5e-7 + 800 x 2e-6 = $0.015 + $0.0016 = $0.0166. A loop with 30 parallel subagents each in a 25 s call generates 30 / 25 = 1.2 requests per second (Little's law again), so spend rate = 1.2 x 0.0166 = $0.0199/s = $71.7/h = $1 720/day. A daily key budget of $50 is exhausted after 50 / 0.0199 = 2 510 s, about 42 minutes. Hence the pitfall "agent key dead by 10 a.m.": either the budget is wrong or prompts are being resent inefficiently (module 06, prefix caching).

Overshoot. The budget check compares spend so far with the maximum before admitting a request, so the request that crosses the limit is admitted (measured: one overshoot is allowed when requests are sequential), then the next one gets HTTP 422 `budget_exceeded`. With concurrency c in flight and a spend lag `d` (2-5 s measured: spend is written in batches) the counter underestimates by what is in flight and what has not been flushed:

```
overshoot  <=  (c_inflight + rate x d) x cost_per_request
```

For the agent key: c = 30 (its `max_parallel_requests`), rate 1.2/s, d = 5 s: (30 + 6) x 0.0166 = $0.60, 1.2 % of the $50 budget. This is an engineering estimate, not a measured guarantee (parallel behaviour was erratic in the lab, which is why budget tests are sequential). Practical rule: choose `max_budget` as intended limit minus the bound, and combine it with `max_parallel_requests`, which also shrinks the bound.

### 4.6 Budget alerts and reset pitfalls

- **Alert at 80 % and at 100 %.** Use `litellm_remaining_team_budget_metric` and `litellm_remaining_api_key_budget_metric` (names to confirm on `/metrics/`), or the built-in alerting (`budget_alerts` via Slack webhook; documented). Alert on *burn rate* too: "projected to exhaust the budget within 4 h at the current rate" fires before the percentage rule when an agent loops (from the example above: 80 % of $50 is reached in 34 minutes, which is no notice for a human).
- **Spend lag.** Alerts read the same lagged counter: they are 2-5 s late, and Prometheus adds a scrape interval. Irrelevant for monthly budgets, relevant for $50/day agent keys.
- **Reset semantics.** `budget_duration: 30d` resets from creation or last reset, not at calendar month end (documented, confirm); finance month and gateway month then drift. The reset runs in a background job, so a team may stay blocked for up to a few minutes after the boundary, and many keys created together reset together, producing a synchronised burst of renewed demand (stagger durations or creation times).
- **Several budgets, the tightest wins.** A key under a team under a global limit can be blocked by any of them; error text names the one that fired, but assert on type `budget_exceeded` only.
- **Raising a budget mid-period** takes effect for the next request but does not reset the counter; resetting requires an explicit call or waiting for the window.
- **A budget is not a rate limit** (section 4.2): exhausting $50 in 42 minutes is allowed and instant 422s afterwards are the intended behaviour; the unhappy path is the client retrying 422s (never retry `budget_exceeded`).

## 5. Chat vs agent traffic: separation by design

Interactive chat and autonomous agents have opposite shapes:

| | Chat (humans) | Coding agent / autonomous loop |
|---|---|---|
| Request rate | low, bursty, think-time between turns | high, continuous, can loop forever |
| Prompt size | grows slowly | **huge and growing** (system prompt + tool schemas + full history resent each turn; see module 06) |
| Concurrency | ~1 per user | many parallel tool-using subagents |
| Tolerance | latency-sensitive (TTFT) | throughput-oriented, retries on failure (and amplifies load) |
| Failure mode | slow answer | retry storm, runaway cost, KV cache exhausted for everyone |

A single shared pool with a single key makes the agent's worst day everyone's worst day (capstone scenario 1 and 2 are built on this). Layers of separation, cheapest first:

1. **Identity**: separate teams and keys for chat and agent workloads (never share a key across human and automated clients).
2. **Limits tuned to the workload**: agents get `max_parallel_requests` (the most effective: caps in-flight load regardless of how clever the loop is), a `tpm_limit` (large prompts), an RPM cap and a budget with a short `budget_duration`; humans get RPM only and a team budget.
3. **Model groups**: expose `chat` and `agent` as different groups, even if they start on the same GPUs, so you can later move agents to their own replicas without touching clients.
4. **Dedicated capacity**: separate engine replicas (or a separate GPU pool) for agents; the gateway routes by group. This is the only real isolation: limits only shed excess, they cannot make a shared KV cache bigger.
5. **Priority/queueing**: LiteLLM has request prioritisation on the router (scheduler with priorities); engines such as vLLM have priority scheduling options. Treat as advanced; separate pools are simpler to reason about and operate.
6. **Fallback hygiene**: never let agent traffic fall back *into* the chat pool; configure fallbacks per group.

Calculation habit — protecting a pool: if 4 engine slots serve chat well (`max_num_seqs` budget) and one agent key may have `max_parallel_requests: 2`, the worst case for chat is 2 of 4 slots taken, not all of them. If you only set `rpm_limit: 60` on the agent, 60 slow generations per minute can still keep 4+ slots busy forever (60 requests × 20 s each = 20 concurrent). Concurrency = rate × latency (Little's law); limit the thing that is scarce.

## 6. Capacity sizing with Little's law (chat, agent, FIM pools)

Little's law: average concurrency L = arrival rate λ x mean time in system W. An engine can hold at most `max_num_seqs` sequences at once (and fewer if the KV cache fills first, module 03), so a pool's capacity in "slots" is C = replicas x min(`max_num_seqs`, KV-bound sequences). Keep planned utilisation at rho of about 0.7: above that, queue time grows sharply (an M/M/c queue at rho 0.9 waits several times longer than at 0.7), and TTFT is queue plus prefill.

Worked example, `max_num_seqs = 64` per replica, N+1 redundancy (the pool must survive losing one replica):

| Pool | Workload shape | λ | W | L = λW | Slots needed at rho 0.7 | Replicas (with N+1) |
|---|---|---|---|---|---|---|
| chat | 200 humans, one request per user per ~40 s while active, 8 s answers | 5 req/s | 8 s | 40 | 40 / 0.7 = 57 | 1 needed, so 2 |
| agent | 30 subagents in closed loops, 25 s calls | 1.2 req/s | 25 s | 30 (equal to the parallel cap) | 43 | 1 needed, so 2 |
| FIM | keystroke-debounced completions, 15 req/s, 0.3 s each, tiny model | 15 req/s | 0.3 s | 4.5 | 6.4 | 2 small replicas for availability, not for slots |

Reading the table: chat and agents together need L = 70 > 64 slots (one replica) and above the 45-slot comfort level of two replicas losing one. Separate pools make each group's saturation visible and keep their failure modes apart; combined, the agent's 30 slots are 47 % of one replica. FIM is a latency product, not a throughput one: its pool is sized by availability and by TTFT target (a short-prompt, small-model replica, never sharing slots with long agent prompts, because one 30 000-token prefill delays every FIM request in the same engine step budget).

Limits derived from the numbers: agent `max_parallel_requests` = 30 (the planned L); chat team-wide parallel cap = 60 (headroom over L = 40 for bursts, still below the 2-replica comfort level of about 90 slots); FIM key cap 12 (about 2.5 x L). Check `sum(caps) <= rho x C` for the pool each key may use; if the sum is above it the caps are over-committed (acceptable for non-simultaneous peaks, but then say so in the design and alert on queue time).

Why RPM misleads: an RPM limit bounds λ, but the pool is loaded by λW. An agent at 30 RPM with W = 40 s (long context, slow engine) holds 20 slots; if W doubles because the pool is slower, concurrency doubles without any rate change. Concurrency limits bound the thing that is scarce; RPM is for protecting a provider's quota or catching loops. Mock note: the mock's capacity model (`mock/README.md` capacity formulas) lets you set `max_num_seqs` and watch `vllm:num_requests_running/waiting`, but its virtual clock is not a real GPU; use it to see the shape of queueing, not to predict real throughput.

## 7. Multi-tenant fairness and the noisy neighbour

### 7.1 Mechanisms

| Mechanism | Guarantees | Does not guarantee | Cost |
|---|---|---|---|
| Per-team `max_parallel_requests` (hard cap) | no team exceeds N in-flight | idle capacity unused: a team capped at 12 stays at 12 even in an empty pool; sum of caps may exceed the pool | trivial; the default tool |
| Per-team RPM/TPM | bounded rate/tokens | concurrency | trivial |
| Weighted fair queuing (WFQ) | each backlogged team gets its weight's share, unused share is redistributed | needs a scheduler that sees all requests and per-request cost; not what the LiteLLM limits do | engine or inference-aware router level (vLLM priority policy, llm-d style routers); documented gateway priority is only a coarse version |
| Dedicated pools | physical isolation | efficiency (idle GPUs) | most GPUs, simplest reasoning |

Hard caps are strict but work-conserving only if you let caps overlap; WFQ is work-conserving by design but needs shared state and a cost model (tokens, not requests: one request of 100 000 tokens is not one request of 100). In practice: start with caps plus a separate agent pool; add WFQ-like behaviour only when a measured fairness problem remains.

### 7.2 Noisy-neighbour incident walkthrough

Setup: chat pool of one replica with 64 slots, chat load L = 30 at 8 s per request, TTFT p95 0.4 s. Team `data` runs a nightly enrichment job whose script was changed to use 100 worker threads against `chat`, with no parallel cap.

1. 02:10: 100 requests arrive within a second. Demand 130 versus 64 slots; the engine admits 64, 66 wait. The slot turnover rate is 64 / 8 s = 8 per second, so a new chat request now waits about 66 / 8 = 8 s plus prefill: TTFT p95 jumps from 0.4 s to about 8-9 s. Humans see a frozen UI; some retry, adding demand.
2. Signals, in the order an on-call should read them: engine `vllm:num_requests_waiting` is non-zero for minutes; `vllm:time_to_first_token_seconds` p95 rises while `vllm:kv_cache_usage_perc` may still be moderate (a *slot* problem, not a KV problem; if KV is also high, preemptions follow); gateway per-key request rates show one `team_id` dominating; 429 rates for `data` are zero because it has no limit.
3. Mitigation, fastest first: set `max_parallel_requests: 12` on the `data` team (takes effect on the next request, documented; confirm propagation delay), which caps it at 12 slots and leaves 52 for chat; the job slows but progresses. Then drain the queue (it empties at 8 requests/s: 66 requests clear in about 8 s once the flood stops).
4. Root cause fixes: caps for every team (default cap in team template), a separate batch group with its own pool for jobs, alert "waiting > 0 for 3 min on chat", and a rule that batch jobs use a key whose model group maps to `batch-chat`, with a lower `priority` (documented, confirm) or an off-peak window.
5. Check afterwards: sum of caps against the pool (section 6) and whether chat p95 TTFT recovered below its SLO; write the incident number (130 versus 64) into the runbook.

Lab 5.5 reproduces the small version: two keys on one mock pool, the agent key with only RPM limits versus with `max_parallel_requests`, and shows that the second protects the chat key. The mock cannot reproduce real GPU effects (KV preemption storms, prefill interference); it simulates slots, queueing and the fixed latencies only.

## 8. Rollouts: canary and blue-green of an engine version

**Canary by weights.** Give the new engine version its own deployment in the same group (`model_info.id: chat-v2`) and shift the weight in stages: 5 % for 30 min, 25 % for 1 h, 50 % for 2 h, 100 %. At 100 req/s, 5 % is 5 req/s, 300 requests per minute, enough to see a 2 % versus 0.5 % error difference after roughly 500 requests (the standard error on 500 requests at 1 % is 0.45 percentage points); with 1 req/s you need hours at 5 %, so use a bigger step or a synthetic load from a test key.

**Metrics to compare, canary versus stable, by `model_info.id` / `model_name` label:**
- failure rate (`litellm_deployment_failure_responses` / total) and gateway 5xx;
- TTFT p95 and ITL p95 (`vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`);
- `vllm:request_success_total{finished_reason}` mix (a rising `length` share can mean broken stop tokens or a changed chat template), `abort`;
- preemptions (`vllm:num_preemptions_total` rate) and KV usage (`vllm:kv_cache_usage_perc`) at equal traffic share;
- generated tokens per request (`vllm:request_generation_tokens`), because a new version that rambles costs money and slots;
- output quality: a small replay set with golden answers or a judge (module 09), since latency and error metrics cannot see wrong answers.

**Rollback criteria (agree before starting).** Examples: canary failure rate above stable plus 1 percentage point over at least 500 requests; TTFT p95 above 1.5 x stable for 10 minutes; any increase in `abort`; replay-set score drop above a set threshold. Rollback is a weight change to 0 (config reload or the model-management API; documented, confirm that a reload applies without dropping requests) with the deployment left in place for debugging; its `model_info.id` keeps its history in the metrics.

**Blue-green.** Run two groups (`chat-blue`, `chat-green`) and expose `chat` through an alias or by moving weights from 100/0 to 0/100 in a single change; rollback is the same change reversed. It costs double capacity during the window but avoids a long mixed-version period (important when a version changes the tokenizer or chat template and mixed answers confuse users). Limit: keep prefix caches in mind, a cutover starts with a cold cache on the new side so expect a TTFT bump for minutes (module 03).

Lab note: the lab does the weight arithmetic with mock A/B (a "canary" is just a differently weighted mock); it cannot tell you whether a real engine version is better.

## 9. An annotated router_settings

```yaml
router_settings:
  routing_strategy: simple-shuffle        # default; weights come from litellm_params.weight
  num_retries: 2                          # attempts = 3; retries stay inside the group (section 3.5)
  timeout: 60                             # per attempt, seconds; keep (r+1) x timeout under the client timeout
  stream_timeout: 15                      # wait for the first chunk of a stream (documented)
  retry_policy:                           # per exception class (documented field names)
    TimeoutErrorRetries: 1                # a timeout on a saturated pool: retry once at most
    BadRequestErrorRetries: 0             # never retry what cannot succeed
    ContentPolicyViolationErrorRetries: 0
    RateLimitErrorRetries: 2
  allowed_fails: 3                        # failures per minute before cooldown
  cooldown_time: 30                       # seconds out of rotation; about restart time / 3
  allowed_fails_policy:                   # stricter for hard failures
    InternalServerErrorAllowedFails: 2
  fallbacks:                              # availability: group -> group
    - {chat: [chat-small]}
    - {agent: [agent-small]}              # never into chat
  context_window_fallbacks:               # 400 context errors need their own list (lab 5.6)
    - {chat: [chat-long]}
  enable_pre_call_checks: true            # skip deployments whose context window is too small
  # enable_tag_filtering: true            # only if you use tag routing (section 2.3)
  redis_host: os.environ/REDIS_HOST       # shares cooldown state between gateway replicas
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD
```

Field names are the documented ones for the v1.10x line; confirm each against the pinned `v1.106.4` by starting the proxy with the file and reading its startup log and `/router/settings` (or the UI), then proving behaviour with a canary request. In the lab config the same idea applies without Redis for router state, because one gateway replica is the main test subject; the second replica on port 18041 is used for the limit-sharing lesson in module 04.

## 10. Observability for routing

Names below are the documented Prometheus metrics of the LiteLLM proxy; run `curl -s localhost:<port>/metrics/ | grep -E 'litellm_(deployment|.*fallback)'` on the pinned version to confirm exact spelling and labels (the `/metrics/` path redirects; this lab does not gate the endpoint).

| Question | Metric (confirm labels) | Panel / alert in words |
|---|---|---|
| Which replica serves what | `litellm_deployment_success_responses_total` by `model_id` | stacked rate per deployment; a flat line on one means it is out of rotation |
| Is a replica failing | `litellm_deployment_failure_responses_total` | alert when a deployment failure ratio exceeds 5 % for 5 minutes |
| Is it cooled down | `litellm_deployment_state` (0 healthy, 1 partial, 2 complete outage), `litellm_deployment_cooled_down_total` | alert when any deployment is non-zero for more than 2 x `cooldown_time` |
| Are fallbacks firing | `litellm_deployment_successful_fallbacks_total`, `litellm_deployment_failed_fallbacks_total` | alert when the fallback rate is above zero for 10 minutes; page when failed fallbacks appear |
| Latency per deployment | `litellm_llm_api_latency_metric`, `litellm_llm_api_time_to_first_token_metric`, `litellm_deployment_latency_per_output_token` | p95 TTFT per deployment against its SLO |
| Budgets | `litellm_remaining_team_budget_metric`, `litellm_remaining_api_key_budget_metric`, `litellm_spend_metric_total` | 80 % and burn-rate alerts (section 4.6) |
| Engine truth | `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`, `vllm:num_preemptions_total` | alert on waiting > 0 for 3 minutes per pool (noisy neighbour, section 7.2) |

Correlate by response headers when debugging a single request: `x-litellm-model-id` (which deployment answered), `x-litellm-attempted-fallbacks`, `x-litellm-attempted-retries` (documented). Because the lab sets `model_info.id` explicitly and the mocks return unique response ids and fixed usage, you can reconcile "requests per deployment" from three sources (response headers, gateway metrics, mock `/admin/stats` `requests`) and expect them to agree exactly for a sequential test; that three-way agreement is the quickest check that your routing configuration did what you think.

## 11. How teams run it in production

- Router config is code: `routing_strategy: simple-shuffle`, explicit `num_retries`, per-group `fallbacks`/`context_window_fallbacks`, `enable_pre_call_checks: true`, timeouts per group, `cooldown_time` tuned to restart time. Test changes on a canary with fault injection (kill a replica, inject latency) *before* the incident.
- Map each model group to a documented capacity and an owner; the fallback graph is a diagram in the runbook (no cycles; no fallback from critical to best-effort pools).
- Router Redis (`router_settings.redis_*`) so replicas share cooldown state; `litellm_settings.cache` (module 04) so they share rate limits.
- Budgets: team monthly budget + alert at 80 % (Prometheus `litellm_remaining_*_budget_metric`); agent keys have a daily budget; budget reset schedule matches finance.
- Weekly review: top spenders by team/key/model, 429 rate per key (limits too tight or misbehaving client), fallback count (hidden capacity problem), cooldown events.
- Don't over-engineer: for one or two replicas of one model, `simple-shuffle` + retries + a single fallback beats a clever policy nobody understands at 3 a.m.

## 12. Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Fallback never fires on very long prompts | context errors are 400s, need `context_window_fallbacks` | add it; enable `enable_pre_call_checks` |
| Failing replica keeps getting traffic | no cooldown/`allowed_fails` too high, errors are 5xx counted per minute, retries mask it | check `litellm_deployment_state`; tune |
| Failing replica gets *all* retries | retries random, may hit same deployment | more deployments; `retry_policy`; cooldown |
| Spend is 0 for local models | no `model_info` prices | set costs per token |
| "Budget exceeded" for a whole team at midnight | `budget_duration` window boundary | stagger, alert at 80 % |
| Agent killed chat latency despite RPM limit | RPM bounds rate, not concurrency | `max_parallel_requests`, separate pool |
| Usage-based routing weird with 2 gateway replicas | per-replica counters without Redis | router Redis, or use simple-shuffle |
| 40/60 split test flaky | exact-count assertion on a random process | statistical bounds |
| All traffic fell to the small model for hours | fallback hides an outage | alert on fallback count |
| Spend inconsistent under load tests | parallel bursts race the budget counter | test budgets sequentially |

## 13. What the lab simulates, and how production differs

| Lab | Production |
|---|---|
| mock-vllm A/B with fault API (`error_rate`, `latency`) | vLLM replicas; OOM, hang, XID, node loss |
| fixed `usage` → exact spend arithmetic | variable usage → statistical reconciliation |
| 2 deployments, cooldown seconds | tens of replicas, cooldown tuned to restart time, real health probes |
| prices invented per variant | internal price from GPU TCO |
| chat-vs-agent separation by limits on one pool | separate GPU pools, scheduler priorities |
| canary/blue-green is a weight change between two mocks | real engine versions with real quality and latency differences |
| probes against a mock fail instantly (`error_rate`) | hangs and slow failures make probes and timeouts expensive |

---

## Key takeaways

- Same `model_name` = one group; the router balances inside a group and **fallbacks cross groups**. Set stable `model_info.id`s.
- `simple-shuffle` (optionally weighted) is the sane default; reactive strategies need shared state and can oscillate; inference-aware routing (KV/prefix) belongs to a smarter layer.
- Retries, fallbacks and cooldowns are different tools; a context-length 400 needs `context_window_fallbacks`, not `fallbacks`.
- Cooldown = passive health check: `allowed_fails` per minute, `cooldown_time`; immediate for some error classes; shared across replicas only with router Redis.
- Spend = usage × your internal price; no price → no spend → no budget. Budget exceeded is HTTP 422 `budget_exceeded`; test it sequentially; RPM resets are 60 s fixed windows.
- Agents and chat need different identities, limits (`max_parallel_requests`!), budgets and, ideally, pools. Concurrency = rate × latency.
- Fallbacks are product/privacy decisions and capacity demands; alert on them. Keep the graph acyclic, shallow, in a different failure domain, and check headroom: `L_T + q x L_S x (s_T / s_S) < rho x C_T`.
- Total latency of a failing request is (retries + 1) x per-try timeout (+ fallback), which can far exceed the client timeout; budget it. Retries under overload amplify load.
- Cooldown trades wasted probes (about one per `cooldown_time` per dead replica) against idle recovered capacity (about half a cooldown); pick it near restart time / 3.
- Size pools with Little's law (L = lambda x W against `max_num_seqs`, rho about 0.7, N+1); cap agents by concurrency, not RPM; fairness comes from per-team caps plus separate pools.
- Internal price = all-in GPU cost / effective tokens at real utilisation; budget overshoot is bounded by in-flight plus lag x rate x cost; alert on burn rate, not only percent.
- Roll out engines by weights with pre-agreed rollback criteria; verify routing with `x-litellm-model-id`, deployment metrics and engine metrics. Where this text says "documented, confirm", prove it with a canary on v1.106.4.

## Check yourself

1. Two deployments share `model_name: chat`. Deployment A returns 500 on every call. With `num_retries: 2`, no fallbacks, `allowed_fails: 3`: what does a client see, and how does it change after A is cooled down?
2. A 90 000-token prompt returns an error instead of using your configured `fallbacks: [{chat: [chat-big]}]`. Why, and what two settings fix it?
3. Prices are 2e-6 / 4e-6 per prompt / completion token; a call reports 30 + 20 tokens. What does key spend show after 40 calls, and what two things can make the number you read right now smaller?
4. A weighted 30/70 split over 200 calls: what range of deployment-A hits is "normal"?
5. An agent key has `rpm_limit: 30` and chat users still suffer. Explain with Little's law and give the better limit.
6. N=3 deployments, one dead, `num_retries: 2`, uniform draws: what fraction of requests fail for the client, and what is the expected number of backend attempts per request?
7. Client timeout 45 s, gateway `timeout` 20 s, `num_retries: 2`, one fallback with the same settings. What is the worst-case gateway time, and how would you redesign it?
8. 8 GPUs at $2.50/h, +30 % overhead, 5 000 tok/s peak output, 40 % utilisation, input price one quarter of output price, input:output volume 4:1. What is the break-even output price per Mtok?
9. A chat pool has one replica with `max_num_seqs: 64`; a team launches 100 parallel calls on top of a chat load of 30. What happens to TTFT, which engine metric shows it first, and what limit do you set?
10. Name three metrics you watch during a 5 % canary and one rollback criterion for each.
