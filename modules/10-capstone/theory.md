# 10 — Capstone: running an AI-platform incident end to end

Module time: ~5 h (25 min reading, five incidents of ~50 min each).
Goal: given only a symptom page, find the cause layer by layer, fix it durably, prove the fix with
data, name the root cause precisely, and write the postmortem a team would actually read.

You already know every tool in this module (modules 00-09). What is new is the **order** you use
them in and the discipline of not guessing. An AI platform has more layers than a classic web
service, and the same user-visible symptom ("it is slow", "I get errors") can come from any of them.

Honesty box. In this lab the gateway (LiteLLM, Postgres, Valkey), Prometheus, the registry,
hf-mirror and the tripwire are **real**. The serving engine and the GPUs are **simulated**
(`mock-vllm`, `mock-dcgm`, `kind` with patched node capacity). Faults are planted with the same
mechanisms a real incident has (a config value, a flag, a corrupted file, a metric that looks
like a failing GPU), but production adds things the lab cannot: real GPU memory, real NCCL/driver
failures, real cold-start times, real traffic with long tails. The method transfers; the
numbers do not.

---

## 1. The investigation loop

```
orient -> hypothesize -> test (cheapest signal first) -> mitigate -> fix -> prove -> learn
   ^            |
   +-- refuted -+
```

| Step | Question | Typical evidence |
|---|---|---|
| Orient | What do users see, since when, how many? Which model/alias, which key/team? | gateway error ratio and latency by `model`/`api_key_alias`, the page text |
| Hypothesize | What changed, or what is saturated? | release notes, config diff, rollout history, queue and KV panels |
| Test | Which single signal refutes this fastest? | one PromQL query, one `/admin/stats` call, one log line, one `kubectl describe` |
| Mitigate | How do I stop user pain without destroying evidence? | shift traffic, cap a client, drain a node, roll back |
| Fix | What removes the cause **in the source of truth**? | the config/manifest/artifact that gets re-applied on restart |
| Prove | Does the same signal that showed the problem now show health? | same query, a synthetic probe, a counter that stays flat |
| Learn | Why was it possible, why did we not see it sooner? | postmortem + action items |

Two rules that save hours:

1. **"What changed?" first.** A new `--max-num-seqs`, a new key, a node-pool change, a model sync,
   a new client rollout. AI platforms change often (models and flags are config, not code), and
   most of these changes have no CI test. Read config diffs and release notes before graphs.
2. **Note timestamps as you go.** The postmortem timeline comes from your notes, not memory.

## 2. Triage by layer

Think of a request travelling down five layers; a failure at one layer shows up as a symptom
in all layers above it.

```
client / agent  ->  gateway (LiteLLM)  ->  router/replicas  ->  serving engine (vLLM-like)  ->  GPU / node / k8s
                                           \_ artifacts: weights, tokenizer, images (air-gap, registry, mirror)
```

| Layer | Question | First signals |
|---|---|---|
| L1 client / traffic | Who is sending what? One key hammering, retry storms, huge prompts? | requests per `api_key_alias`, prompt-token histogram, request rate by team |
| L2 gateway | Is the gateway rejecting, queuing or mis-routing? Are limits what we think? | HTTP status split (401/403/422/429/5xx), `litellm_*` metrics, per-replica differences |
| L3 router / replicas | Is traffic going to a sick backend? Do cooldowns/fallbacks work? | per-deployment request counts, cooldown state, error ratio per backend |
| L4 serving engine | Is the engine saturated (queue, KV) or crashed/unready? | `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`, `vllm:num_preemptions_total`, TTFT/ITL histograms |
| L5 GPU / node / k8s | Hardware, driver, scheduling, capacity? | `DCGM_FI_*` (XID, temp, ECC, FB used), node capacity/allocatable, taints, pod events |
| X artifacts / air-gap | Does the model start, is it the model we think, did anything phone home? | sha256 vs manifest, file presence, registry digest, tripwire hits |

**The deepest layer that shows the problem is the suspect; the layers above it are victims.**
Slow TTFT at the gateway with a long queue in the engine and a pegged KV gauge points to L4, not
to the gateway. A 429 at the gateway with an idle engine points to L2.

### 2.1 Ten-minute sizing queries

```promql
# gateway: error ratio by status class (use [2m] or longer: scrape interval is 5 s in the lab, 15-60 s in production)
sum by (status_code) (rate(litellm_proxy_total_requests_metric_total[2m]))

# engine: is it queuing, is KV full, is it preempting?
vllm:num_requests_waiting
vllm:kv_cache_usage_perc
increase(vllm:num_preemptions_total[5m])

# TTFT p95 (sum over the buckets, never average percentiles)
histogram_quantile(0.95, sum by (le, instance) (rate(vllm:time_to_first_token_seconds_bucket[2m])))

# GPU: XID events, temperature, framebuffer used
DCGM_FI_DEV_XID_ERRORS
DCGM_FI_DEV_GPU_TEMP
DCGM_FI_DEV_FB_USED
```

Metric names are the ones taught in modules 03, 08 and 09 and documented in `mock/README.md`; use
`/metrics` of the component itself when a name is in doubt. Exact LiteLLM metric and label names
depend on the callback configuration (module 08); look them up on `/metrics/` instead of
guessing.

## 3. Signals per layer, and the traps in each

### 3.1 Client and traffic (L1)
- **Who**: break gateway metrics down by key alias / team / model before anything else. One heavy
  client is a *very* different incident from "everybody is slow".
- **Shape of traffic**: agent loops send many sequential calls with growing prompts (module 06); chat
  sends few, interactive ones. Tokens per request and requests per minute tell them apart.
- Trap: a "runaway client" is only the *cause* if the platform's limits were correct and the client
  broke an agreement. If limits were never set, the client is the **trigger**, the missing limit is
  the cause.

### 3.2 Gateway (L2)
- Status split matters: `401/403` auth/model access, `422` budget exceeded (LiteLLM v1.106), `429`
  rate/parallel limits, `5xx` upstream or gateway failure. A 429 is the gateway working as
  configured; ask **whose limit and which scope** (key, team, model deployment, global).
- **Limit scope.** RPM/TPM counters live in process memory unless the replicas share a cache. With
  two replicas and no shared Redis/Valkey cache, a key limit of N is effectively up to 2N, and
  model-deployment limits and cooldown state diverge per replica (module 04.5, decision: the shared
  state needs `litellm_settings.cache: true` with a redis `cache_params`; the router's redis
  setting alone is not enough). RPM is a **60 s fixed window**, so a limit looks "stuck" for up to a minute.
- `max_parallel_requests` bounds concurrency per key; a looping agent without it can occupy
  every engine slot while its RPM stays under the limit.
- Spend logs lag by seconds (`proxy_batch_write_at: 5` in the lab; lab-only value); metrics do not.
- Trap: a gateway that is healthy but whose **backend** is slow still reports slow requests;
  compare `litellm_request_total_latency_metric` with the backend-latency series to see where time goes.

### 3.3 Router and replicas (L3)
- Load balancing (`simple-shuffle` default), `allowed_fails`, `cooldown_time`, `num_retries`,
  `fallbacks`, per-request `timeout`. A sick backend that still answers (slowly, or with 500s
  mixed in) keeps receiving its share unless failures are counted and cooled down.
- Without a **timeout**, a slow backend holds a worker for minutes; without **cooldown**, errors
  never eject it; fallbacks only fire on the error classes you configured (module 05).
- Trap: removing the sick node from rotation is a **mitigation**; the durable fix includes making
  the router eject unhealthy deployments on its own, because the next sick node is a matter of time.

### 3.4 Serving engine (L4)
The engine's queue, KV cache and scheduler are the capacity model (modules 01 and 03):

| Signal | Reads as |
|---|---|
| `num_requests_running` at `max_num_seqs` and `num_requests_waiting` > 0 | engine saturated by sequence slots |
| `kv_cache_usage_perc` near 1.0 | KV cache full: new sequences wait, running ones may be **preempted** |
| `increase(num_preemptions_total)` > 0 | preempted sequences are **recomputed**: TTFT and ITL spikes, throughput drops while "utilisation" looks maximal |
| `prefix_cache_hits_total / prefix_cache_queries_total` falling | repeated prefixes (system prompts, RAG context) are recomputed instead of reused |
| `request_queue_time_seconds` histogram | time waiting before the first schedule: the queue's share of TTFT |
| startup failure / `/health` 503 | config does not fit (KV too small for `--max-model-len`), missing/corrupt files |

- Raising `--max-num-seqs` is not free capacity: KV is shared by all running sequences; more slots
  than KV can hold turns into preemption churn at peak. The KV budget is
  `blocks * block_size` tokens; sequences that fit = budget / mean tokens per sequence.
- Latency problems that appear "after a release" at **peak** only are typical of saturation
  effects: off-peak the cache is not full, so tests pass.
- Trap: reading GPU utilisation as "healthy". 100% means busy, not productive (module 09).

### 3.5 GPU, node and Kubernetes (L5)
- **XID** errors (`DCGM_FI_DEV_XID_ERRORS` holds the last XID): 79 = GPU fell off the bus (drain,
  replace); 48 / 94 / 95 = double-bit / contained / uncontained ECC (drain; reset may clear 94 only);
  63 / 64 = row-remap events (schedule a reset, can wait for a window); 13 / 31 / 43 are usually application
  faults (look at the workload, not the GPU). Thermal throttling shows as temperature near limit
  with falling clocks/throughput; it is reversible (cooling), but a throttled replica is slow.
- **Scheduling**: `Pending` pods say why in events: `untolerated taint`, `Insufficient nvidia.com/gpu`,
  `didn't match Pod's node affinity/selector`. Several reasons stack: fixing the first reveals the
  next, so read the event again after each change. Capacity comes from the device plugin config
  (time-slicing `replicas`, MIG strategy); a node-pool change can reset it.
- The scheduler counts **extended resources** only as whole integers and checks the exact name
  (`nvidia.com/gpu`, not `nvidia.com/gpus`).
- In the lab the plugin and node capacity are simulated (node-status patch plus a small controller
  that reads the time-slicing ConfigMap); in production the GPU Operator's device plugin does it.

### 3.6 Artifacts and the air gap (X)
- A model "rollout that won't start" is usually one of: **file missing** (tokenizer, config,
  chat template), **corrupt/partial file** (silent: the engine may start and serve garbage or crash
  later; only a checksum against the signed manifest proves integrity), **wrong revision**, or
  **a loader that tries the network**.
- `HF_HUB_OFFLINE=1` makes a missing file fail **fast and closed** with a local error; without it, a
  loader on an isolated network retries a remote host until a timeout (looks like a hang). An env var
  is a policy, not isolation: the **tripwire** (DNS query log) is how you prove nothing left the
  network (module 02).
- Trap: fixing the symptom (copy the missing file from a laptop) without fixing how the artifact was
  synced and verified. Integrity checks belong in the pipeline, before the rollout.

## 4. Pivoting between signals

| You have | You want | Go to |
|---|---|---|
| gateway 429s | whose limit, what scope | per-key request/429 series, key settings (`/key/info`), config, replica comparison |
| gateway latency up | engine or router? | engine TTFT/queue/KV; per-backend latency and request split |
| engine TTFT up | saturation or hardware? | queue + KV + preemptions (saturation) vs DCGM temp/XID/clock (hardware) |
| one backend slow | the node or the load? | the same backend's DCGM series, request share, others' latency |
| pod Pending | which constraint | `kubectl describe pod` events, node taints/capacity/labels |
| startup failure | config or files | engine log first error, file listing, sha256 vs manifest, tripwire hits |

## 5. Mitigate, fix, prove

| Phase | Goal | Examples | Pitfall |
|---|---|---|---|
| Mitigate | stop user pain now | cap a client, drain a backend, lower concurrency, roll back | destroys evidence if you did not capture it first (save metrics views, note timestamps) |
| Fix | remove the cause in the **source of truth** | edit the config/manifest/artifact that is re-applied on restart | a runtime tweak (admin API, `kubectl exec`, `/admin/fault`, patching a node by hand) is undone by the next restart |
| Prove | show with data | same query now flat, synthetic probe, counters stay flat for N minutes | "it feels fine" |

In this module `verify.sh` restarts the affected components (and re-asserts the hardware fault
where the fault is "hardware") before it probes, so only a fix in the source of truth survives.

## 6. Root cause is a chain, and the enum is a discipline

A root cause names a **component** (which layer and which piece) and a **cause class** (why). Real
incidents have a trigger, a missing guard and a late detection. The enum forces you to pick the
**most specific class that, if it had been right, would have prevented the incident**:

| CAUSE | Choose it when |
|---|---|
| `bad-release` | a deployed change in the component's own behaviour (code/image) broke it |
| `misconfiguration` | a wrong value (URL, flag, env) that is simply wrong, with no more specific class |
| `rate-limit-misconfig` | limits/quotas are absent, mis-scoped or not shared, so one client can starve others |
| `kv-cache-exhaustion` | engine KV memory is the saturated resource (preemption, queueing) |
| `capacity-overload` | genuine demand exceeds provisioned capacity with everything configured correctly |
| `hardware-fault` | GPU/node/NIC fault (XID, ECC, thermal) |
| `artifact-integrity` | model artifact is missing, partial or corrupt versus its manifest |
| `air-gap-leak` | something reaches outside the isolated network that must not |
| `scheduling-config` | scheduler constraints (taints, selectors, resource names, device-plugin config) prevent placement |
| `dependency-outage` | a downstream system (DB, cache, registry, mirror) is down |
| `runaway-client` | a client breaks a *correct* agreement (limits exist and are right) |

Rules of thumb: prefer the specific class over `misconfiguration`; if a limit was missing the cause is
`rate-limit-misconfig` even though a client is hammering; `capacity-overload` is only right when
**nothing is mis-set** and demand really exceeds supply (prove it: queue grows with KV low and
slots full at a sane config). Secondary factors (a contributing leak, a late alert) go into the
postmortem, not into the enum.

The `COMPONENT` enum is the layer: `gateway`, `router`, `serving`, `gpu`, `artifact`, `kubernetes`,
`client`. The exact instance (which replica, which node, which key) goes into the evidence file.

## 7. Evidence discipline

- Evidence values must come from the signals (a Prometheus range, a stats endpoint, a checksum,
  an event). `verify.sh` checks them against live data that depends on your hidden variant, so a
  guess or a copied number from another run fails.
- Write down **how** you got each number (the query). It becomes the "Detection"/"Resolution" part of the postmortem.
- Absence is evidence only when the pipeline is healthy: check the series are fresh before reading
  "no errors" as health.

## 8. Writing the postmortem

Same principles as in the observability course:

- **Blameless**: systems, signals and decisions, never people.
- **Facts first**: every claim traceable to a query, log line, file hash or event.
- **UTC timeline**: start of impact, detection, findings, mitigation, recovery. Measure time to
  detect and time to mitigate.
- **Root cause as a chain**: a change made X possible, nothing validated it, the failure was
  invisible because Y. Name the component and the mechanism.
- **Detection**: if a human noticed before an alert, that is a finding. Say which alert or
  dashboard would have caught it earlier.
- **Action items**: specific, owned, testable; at least one that **detects sooner** (alert on
  KV%, per-key 429 ratio, XID, tripwire hits, pending GPU pods) and one that **prevents
  recurrence** (CI check of config, canary, limit-by-default key template, checksum gate in the sync
  pipeline, admission policy).

Template (shipped in `lab/postmortem-N.md`): `Summary / Impact / Timeline / Root cause / Mitigation and fix / Detection / Action items`.

AI-specific postmortem prompts: which model/alias and which teams were affected? Did tokens or
spend change (cost impact)? Were any completions wrong rather than failed (artifact integrity)? Did
anything leave the air gap?

## 9. How the capstone works

- `./prepare-lab.sh N` converges the profiles incident N needs, writes the incident's files under
  `lab/incident-N/`, replays a short healthy baseline ("before"), then plants the fault and prints
  only the page, including the UTC **incident window** you should query in Prometheus. Re-running gives
  a fresh copy with a new hidden variant (your previous folder is saved as `lab.bak-prepare-*`).
- Incidents 1-3 run on the compose stack (`gw`, `gw2`, `mock`, `obs`), incident 4 on `store` plus a throw-away
  engine container on the air-gapped network, incident 5 on `kind` (compose is stopped). `prepare-lab.sh`
  converges the stack, so earlier incidents' containers are replaced.
- You investigate with the signals, fix the files, restart with the given helper (`restart.sh`, `apply.sh`,
  `apply-keys.sh`, `rollout.sh` inside `lab/incident-N/`), fill `lab/answers/N-*.env` and
  `lab/postmortem-N.md`, then run `./verify.sh N`.
- `verify.sh` re-creates the situation itself: it restores the GIVEN files, restarts the affected components
  from **your** files, re-asserts simulated hardware faults, generates its own load with fresh nonces and measures
  behaviour. Runtime-only changes (admin APIs, `docker exec`, hand-patched nodes) do not survive that.
- Graded per incident: N.1 and N.2 (durable fix and live behaviour, incident-specific), N.3 root cause, N.4 evidence
  against live data of your variant, N.5 postmortem. `./verify.sh --status` shows your scores.
- Simulated: the engines, GPUs and Kubernetes GPU capacity. Real: gateway, Postgres/Valkey, Prometheus, registry,
  tripwire, the Docker air-gap network, the Kubernetes scheduler.

## Key takeaways

- Triage by layer: the deepest layer that shows the problem is the suspect, the layers above are victims.
- "What changed?" first; AI platforms change config and artifacts more often than code.
- 429 is a configured behaviour: ask whose limit, which scope, and whether replicas share the counters.
- KV exhaustion shows up as queue + KV near 1.0 + preemptions; more slots than KV is a self-inflicted outage at peak.
- GPU health lives in DCGM (XID, temperature, ECC), not in utilisation; a sick replica must be ejected by the router, not by a human at 3 a.m.
- A model that will not start: files and checksums first; offline env makes it fail closed, the tripwire proves it.
- A Pending pod has stacked reasons; fix, re-read the event, repeat.
- Fix in the source of truth, prove with the same query, write a blameless chain with detect-sooner and prevent-recurrence items.

## Check yourself

1. Gateway p95 is 6 s, the engine's TTFT p95 is 5.5 s and `num_requests_waiting` is 40. At which layer do you look next, and which two engine gauges separate "too few slots" from "KV full"?
2. A key has `rpm_limit: 60` and two gateway replicas share no cache. How many requests per minute can it send at most, and what config change makes the limit global?
3. Why is "GPU utilisation 98%" not evidence of a healthy replica? Name two DCGM signals you would check.
4. A pod is Pending with `untolerated taint`. After you add the toleration it is still Pending. Why, and how do you find out?
5. When is `capacity-overload` the right cause, and what would you show to prove it?
