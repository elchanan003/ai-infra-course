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

## 9. Worked examples with the numbers

The five incidents of this module are drawn from these patterns. Work the arithmetic once on paper; in the lab you
will do it against live data. Figures follow the formulas of `mock/README.md` (the engine is simulated); the method is
the one you would use on a real vLLM 0.31/0.32 deployment, where you read the same numbers from the engine's start-up log.

### 9.1 KV budget: how many sequences really fit
Model geometry decides the price of one token of context in the KV cache:
`kv_bytes_per_token = 2 (K and V) x layers x kv_heads x head_dim x bytes_per_element`.
For a 7B GQA model (28 layers, 4 KV heads, head_dim 128, bf16): `2 x 28 x 4 x 128 x 2 = 57,344 B` (56 KiB) per token.
The memory left for KV is what remains of the *requested* share of the GPU after weights, activations and non-torch overhead:

```
requested  = gpu_memory_utilization x total_memory
kv_memory  = requested - weights - activation_peak - non_torch (~0.6 GiB)
kv_tokens  = floor(kv_memory / (kv_bytes_per_token x block_size)) x block_size      # block_size 16 by default
sequences that fit = kv_tokens / (mean prompt tokens + mean output tokens)
```
Example: 24 GiB GPU, another process holds 5 GiB, `--gpu-memory-utilization 0.77` (the highest sensible value is
(24-5)/24 = 0.79: above it the engine refuses to start with "Free memory on device ... is less than desired GPU memory
utilization"). Weights 7.6 B x 2 B = 14.2 GiB, activations about 1.4 GiB at `--max-num-batched-tokens 8192`, so KV is
roughly 2.4 GiB (the engine prints the exact figure at start), i.e. about 45,000 tokens. With ~1,500-token prompts and 96 output tokens, a sequence costs about 1,600
tokens: **about 28 sequences fit**. A release that sets `--max-num-seqs 96` promises three and a half times what memory
can hold. At off-peak (10 concurrent requests) nothing happens, which is why the release test passed.

What the scheduler does at the edge (vLLM V1 semantics, reproduced by the mock): new requests are admitted while a free
block can hold their prompt; during decoding every sequence that crosses a block boundary needs one more block; with
no free block the **newest running request is preempted**: its blocks are freed, it goes back to the front of the waiting
queue, and when it runs again its prompt **and everything it already generated are recomputed** as prefill. So:
`kv_cache_usage_perc` pins at 1.0, `num_preemptions_total` climbs, `num_requests_waiting` grows, and
generation tokens per second *fall* while the GPU is 100 % busy redoing prefill. A safe `max_num_seqs` leaves margin:
about 85 % of the fit (24 here) keeps the gauge under the 90 % alert line, and extra requests queue, which costs one
decode duration of waiting instead of a recompute storm.

TTFT = queue time + prefill time (+ any stall). Prefill speed is compute-bound (`tokens / prefill_tps`); with prefix
caching, blocks whose text chain was already computed are reused, so a workload whose prompts share 80 % of their tokens
(a system prompt) prefills about five times fewer tokens. A flag change that turns prefix caching off is invisible at
low load and costs seconds of TTFT at peak. In real vLLM the V1 engine enables prefix caching by default; a "debug"
flag that disables it is a classic undocumented capacity regression. **Do not** treat the prefix-cache hit ratio as a CPU-lab
property: the mock models it; the real CPU backend of this course does not give you reliable hits.

### 9.2 Limits across replicas, quotas and concurrency
- RPM is a **60 s fixed window**: a limit of 30 admits 30 requests whenever they arrive inside the window, then answers 429
  until the window ends (up to 60 s of "stuck"). It is not a token bucket.
- Counters live where the limiter keeps its state. Two replicas without a shared cache each admit 30: the key effectively has
  60. The same applies to a **team** quota: a team limit of 30 with the agents consuming it leaves the chat key rejected, and
  without shared state the platform owner's number is wrong by the replica count. In LiteLLM v1.106.4 the shared state needs
  `litellm_settings.cache: true` with a redis-type `cache_params` pointing at Valkey and `supported_call_types: []` (limit counters
  only, no response caching); the router's own `redis_host` is not enough.
- Policy by arithmetic: team quota 30 rpm, chat must keep 12 -> the agent key gets at most 18. Put it on the key (`rpm_limit`),
  not on trust. Add `max_parallel_requests`: by Little's law concurrency = arrival rate x latency, so an agent loop with 3 workers
  at 0.7 s per call runs 250 rpm and occupies 3 engine slots all the time even if its rpm limit is raised later.
- Where to see it: per-key request counters split by status code (the gateway's Prometheus callback), `/key/info` and `/team/info`
  for the configured numbers, and a two-replica probe with a throw-away key whose limit is 3 (the check `1.1` of this module): 3 x 200 across
  both replicas means the counter is shared; 5 means it is not.
- Honest note: in production the gateway also has a separate set of cooldown and spend counters; spend logs are batch-written
  (60 s by default; 5 s in this lab), so budget-driven 422s lag behind the request that caused them.

### 9.3 Router ejection: what the numbers buy you
Settings of the LiteLLM router that matter for a sick deployment: `timeout` (per request), `num_retries` (retry on another deployment),
`allowed_fails` (failures tolerated in a window before the deployment is cooled down), `cooldown_time` (seconds out of rotation),
`fallbacks` (another model group when the group is exhausted). Defaults differ from what a "load test tuning" may have left
behind (`allowed_fails: 1000`, `num_retries: 0` means: never eject, never retry).
- With simple shuffle over two deployments and one sick, half of the requests land on it. If it stalls 6 s and fails 30 % of the time,
  40 sequential requests see about 20 slow or failed responses: the "half the requests are slow, a few time out" of the page.
- With `timeout: 2`, `num_retries: 2`, `allowed_fails: 1`, `cooldown_time: 30`: the first request to the sick node is cut at 2 s and
  retried on the peer (user latency about 2 s + healthy latency), the second failure ejects the node, and for 30 s everything goes to
  the peer. A user never waits for 6 s, and the sick node serves two or three requests instead of twenty.
- Cooldown must be **temporary**: when the node recovers (reset, cooled down) it has to take traffic again without a human; verify
  checks both directions. A permanent removal from the config is a mitigation, not a router policy.
- Trade-offs: a timeout shorter than the real p99 of long generations cuts good requests (use streaming: time-to-first-token is the
  right timeout for chat, whole-response time for batch); retries multiply load on the survivor (retry budget); a cooldown of one
  deployment out of two doubles load on the other (check its KV and queue before celebrating).
- Details to confirm on the pinned version, not assume: which errors cool a deployment down immediately (timeouts and some status
  codes do on recent releases), and whether `allowed_fails` counts per minute. Module 05 measures these live.

### 9.4 GPU signals: which XID means "drain"
| Signal | Meaning | Action |
|---|---|---|
| XID 79 | GPU fell off the bus (`nvidia-smi` cannot get the device handle) | cordon + drain now, replace/RMA; nothing to wait for |
| XID 48 | double-bit ECC error | drain; the memory is unreliable, a reset may clear a contained case |
| XID 94 / 95 | contained / uncontained ECC | 94: affected workload dies, reset can recover; 95: drain, reset the GPU before reuse |
| XID 63 / 64 | row-remap pending / failed | schedule a reset in a low-traffic window; 64 (failed) means replace |
| XID 13 / 31 / 43 | application faults (illegal access, page fault, stopped processing) | look at the workload and driver first, not at the hardware |
| temperature at the limit + clocks/power falling | thermal throttling (`CLOCK_THROTTLE_REASONS` non-zero, `THERMAL_VIOLATION` growing) | reversible; fix cooling, expect slow replica meanwhile |
Before draining check: how many replicas serve this model (can you lose one?), the PodDisruptionBudget, in-flight long
generations (drain waits for them, so set a deadline), and whether other GPUs on the node are affected. The node fix and the routing
fix are independent: draining removes the symptom for this node; the router policy of 9.3 protects users from the next one.
The lab's DCGM values are produced by `mock-dcgm` (simulated); the XID semantics above are the real ones.

### 9.5 Artifact integrity and the air gap
A safetensors file is: 8 bytes little-endian header length, a JSON header (tensor names, dtypes, shapes, `data_offsets`), then raw
tensor bytes. The loader checks that the header parses and that offsets match the file size, which catches **truncation** and bad
transfers. A flipped bit inside a tensor changes nothing structural: the file loads, the pod is Running, answers look plausible and are
subtly wrong. Real engines do not hash weights at load (hashing 15 GB takes seconds you do not want in every cold start), so integrity
is a **pipeline** property: a manifest of sha256 values produced on the connected side, shipped with the artifact (ideally signed), and
verified at least when the artifact enters the registry and again before the rollout (`sha256sum -c MANIFEST` is about one second per GB
on local disk). A registry digest is the same idea for OCI artifacts.

The loader's network behaviour is a second, independent property. On an isolated network a loader that is allowed to look for a hub
resolves a name, retries until a timeout and then fails or falls back, which looks like a hang. `HF_HUB_OFFLINE=1` makes the same
failure immediate and local. But an environment variable is a request, not a barrier: the proof that nothing left the network is a
counter outside the process (the tripwire's DNS query log; in production egress firewall logs or a DNS sinkhole). Test the
**negative case** too: remove a file on a copy and show that the rollout fails closed with zero lookups. A missing tokenizer and a corrupt
shard are two faults; fixing the first reveals the second, which is why "fix everything, then prove" beats "fix the first error".
In this lab the model is tiny synthetic data in real safetensors framing, the engine is `mock-vllm` (it implements the loader checks), and
the registry, mirror, tripwire and air-gap network are real.

### 9.6 Why a pod is Pending, in the order the scheduler tells you
The scheduler filters nodes and reports **per-node reasons in one line**, for example
`0/3 nodes are available: 1 node(s) had untolerated taint {pool-x: gpu}, 2 node(s) didn't match Pod's node affinity/selector.`
Fix the taint (a toleration with the same key/effect) and the line changes to
`... 1 Insufficient nvidia.com/gpu, 2 node(s) didn't match ...`: the pod now fits the node's *policy* but the node advertises no GPU.
Capacity is published by a chain: driver -> device plugin (a DaemonSet that needs the same toleration as your pods, otherwise it never
starts on a tainted pool) -> kubelet extended resource `nvidia.com/gpu` -> scheduler. A node-pool change that adds a taint therefore breaks
**two** things: your workload and the plugin DaemonSet. Time-slicing multiplies the advertised count (`replicas: 2` on 2 GPUs gives 4
allocatable) without memory isolation; MIG partitions with hardware isolation. The resource name is matched literally, in the pod spec
and in the plugin config, so `nvidia.com/gpus` is a different resource. Never patch a node's capacity by hand as a fix: the next plugin
sync or node re-registration removes it.
Honest scope: kind has no GPU and no driver; the lab's plugin (`gpu-plugin-sim.sh`) is a simulation of the plugin's observable effect
(it publishes capacity from the time-slicing ConfigMap and it advertises 0 when the configured resource is not `nvidia.com/gpu`; the real
plugin's behaviour for unknown names differs by version). The Kubernetes scheduler, taints, tolerations and events are real.

### 9.7 The first five minutes (runbook skeleton)
1. Page text -> who, what, since when; open the gateway panel by key alias and status class (L1/L2).
2. Engine panel of each replica: running, waiting, KV %, preemptions, TTFT; DCGM XID/temperature for the same node (L4/L5).
3. "What changed in the last day?": release notes, config diff, key changes, node-pool changes, model syncs.
4. Pick the deepest layer whose own signals are abnormal; write the hypothesis with the signal that would refute it.
5. Capture evidence (queries + timestamps), then mitigate in the least destructive way, then fix in the source of truth.

## 10. How the capstone works

- `./prepare-lab.sh N` converges the profiles incident N needs, writes the incident's files under
  `lab/incident-N/`, replays a short healthy baseline ("before"), then plants the fault and prints
  only the page, including the UTC **incident window** you should query in Prometheus. Re-running gives
  a fresh copy with a new hidden variant (your previous folder is saved as `lab.bak-prepare-*`).
- Incidents 1-3 run on the compose stack (`gw`, `gw2`, `mock`, `obs`), incident 4 on `store` plus a throw-away
  engine container on the air-gapped network, incident 5 on `kind` (compose is stopped). `prepare-lab.sh`
  converges the stack, so earlier incidents' containers are replaced.
- You investigate with the signals, fix the files, restart with the given helper (`restart.sh`,
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
