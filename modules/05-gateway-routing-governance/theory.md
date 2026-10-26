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

## 6. How teams run it in production

- Router config is code: `routing_strategy: simple-shuffle`, explicit `num_retries`, per-group `fallbacks`/`context_window_fallbacks`, `enable_pre_call_checks: true`, timeouts per group, `cooldown_time` tuned to restart time. Test changes on a canary with fault injection (kill a replica, inject latency) *before* the incident.
- Map each model group to a documented capacity and an owner; the fallback graph is a diagram in the runbook (no cycles; no fallback from critical to best-effort pools).
- Router Redis (`router_settings.redis_*`) so replicas share cooldown state; `litellm_settings.cache` (module 04) so they share rate limits.
- Budgets: team monthly budget + alert at 80 % (Prometheus `litellm_remaining_*_budget_metric`); agent keys have a daily budget; budget reset schedule matches finance.
- Weekly review: top spenders by team/key/model, 429 rate per key (limits too tight or misbehaving client), fallback count (hidden capacity problem), cooldown events.
- Don't over-engineer: for one or two replicas of one model, `simple-shuffle` + retries + a single fallback beats a clever policy nobody understands at 3 a.m.

## 7. Pitfalls

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

## 8. What the lab simulates, and how production differs

| Lab | Production |
|---|---|
| mock-vllm A/B with fault API (`error_rate`, `latency`) | vLLM replicas; OOM, hang, XID, node loss |
| fixed `usage` → exact spend arithmetic | variable usage → statistical reconciliation |
| 2 deployments, cooldown seconds | tens of replicas, cooldown tuned to restart time, real health probes |
| prices invented per variant | internal price from GPU TCO |
| chat-vs-agent separation by limits on one pool | separate GPU pools, scheduler priorities |

---

## Key takeaways

- Same `model_name` = one group; the router balances inside a group and **fallbacks cross groups**. Set stable `model_info.id`s.
- `simple-shuffle` (optionally weighted) is the sane default; reactive strategies need shared state and can oscillate; inference-aware routing (KV/prefix) belongs to a smarter layer.
- Retries, fallbacks and cooldowns are different tools; a context-length 400 needs `context_window_fallbacks`, not `fallbacks`.
- Cooldown = passive health check: `allowed_fails` per minute, `cooldown_time`; immediate for some error classes; shared across replicas only with router Redis.
- Spend = usage × your internal price; no price → no spend → no budget. Budget exceeded is HTTP 422 `budget_exceeded`; test it sequentially; RPM resets are 60 s fixed windows.
- Agents and chat need different identities, limits (`max_parallel_requests`!), budgets and, ideally, pools. Concurrency = rate × latency.
- Fallbacks are product/privacy decisions and capacity demands; alert on them.

## Check yourself

1. Two deployments share `model_name: chat`. Deployment A returns 500 on every call. With `num_retries: 2`, no fallbacks, `allowed_fails: 3`: what does a client see, and how does it change after A is cooled down?
2. A 90 000-token prompt returns an error instead of using your configured `fallbacks: [{chat: [chat-big]}]`. Why, and what two settings fix it?
3. Prices are 2e-6 / 4e-6 per prompt / completion token; a call reports 30 + 20 tokens. What does key spend show after 40 calls, and what two things can make the number you read right now smaller?
4. A weighted 30/70 split over 200 calls: what range of deployment-A hits is "normal"?
5. An agent key has `rpm_limit: 30` and chat users still suffer. Explain with Little's law and give the better limit.
