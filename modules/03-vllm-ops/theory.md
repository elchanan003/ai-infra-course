# 03 — vLLM operations: flags, startup memory, KV cache, preemption, queueing, SLO tuning

Pinned for this course: vLLM **0.31.x / 0.32.x** docs. The real-vLLM-CPU option runs **v0.31.0** (v0.32.0 CPU is broken on this host — see 12.2). Everything graded in this module runs on **mock-vllm**, a course-owned simulator. Section 12 says exactly what is simulated.

Read module 01 first (prefill/decode, KV cache, batching, VRAM math). This module is the operator's view: which flag moves which number, what the engine does at startup, what the metrics say while it runs, and what to change when an SLO is missed.

---

## 1. The operator's mental model in one page

A vLLM instance is **one engine on one set of GPUs** (a tensor-parallel group) serving one model:

```
client ──HTTP──> API server (FastAPI, OpenAI-compatible)
                    │  tokenize, validate (max_model_len), apply chat template
                    ▼
               EngineCore (separate process; busy loop)
                 Scheduler:  waiting queue ─> running batch   (decides per step)
                 KV block manager: pool of fixed-size blocks, ref-counted, prefix-hashed
                 Executor ─> Worker(s) ─> model runner ─> GPU kernels (one process per GPU)
```

Per engine **step** the scheduler builds a batch under two budgets and one pool:

| Budget | Flag | Meaning |
|---|---|---|
| Sequences | `--max-num-seqs` | max requests in the running batch at once |
| Tokens per step | `--max-num-batched-tokens` | max tokens (decode tokens + prefill chunk tokens) computed in one step |
| KV blocks | derived at startup | can this request get blocks for its next tokens? |

Everything an operator tunes is one of: **(a)** how much memory the instance may use (startup), **(b)** what one request may cost (`max_model_len`, `max_tokens`), **(c)** how many requests run together (the two budgets), **(d)** how to shrink bytes (dtype, kv dtype, quantization, TP). Metrics tell you which budget is binding.

Two failure families:
1. **Startup failures** (deterministic, from flags + hardware): the engine computes memory, finds no room, exits. The container restarts in a loop. Cheap to diagnose if you can read the error and do the arithmetic.
2. **Runtime pressure** (load-dependent): KV pool fills → queue grows → preemptions → TTFT/E2E blow up. Diagnosed from metrics, in a fixed order (section 8).

## 2. Memory at startup: where the bytes go

For one GPU (per worker) vLLM claims at most:

```
budget  = gpu_memory_utilization × total_gpu_memory          # per instance
kv_pool = budget − weights − peak_activations − non_torch_overhead (CUDA graphs, NCCL, context)
```

- **`--gpu-memory-utilization`** (default **0.92** in the pinned docs; read it from the `cache_config_info` metric or the startup log `non-default args`, never from memory). It is the fraction of *this GPU's total memory this one instance may claim* for weights + activations + KV. It is **not** "KV only" and **not** a cap on other processes. Two instances on one GPU each need their own fraction and the sum must fit; since the 0.10-era rework each instance's fraction is independent of what others already hold.
- **Peak activations** are measured by a **profiling run**: at startup vLLM executes a dummy forward pass at `max_num_batched_tokens` (and a sampler pass at `max_num_seqs`) and records peak memory. A bigger `--max-num-batched-tokens` → bigger activation peak → less KV. Quantized weights, multimodal encoders, and big vocab (logits) all enlarge it.
- **Non-torch memory**: CUDA context (~0.5-1 GB), NCCL buffers (TP), CUDA graphs (captured per batch size; `--enforce-eager` skips them and saves memory at the cost of decode speed; `--max-cudagraph-capture-size` / compilation config bound them).
- What remains is divided into **blocks** (`--block-size`, 16 tokens on CUDA by default; the CPU backend picked 128 in our spike — see the `cache_config_info` golden line). `num_gpu_blocks × block_size = kv_cache_size_tokens`.
- `--kv-cache-memory-bytes` (e.g. `--kv-cache-memory-bytes 8G`) **overrides** the utilization calculation for the KV pool: you state the pool size directly; weights/activations are then outside the fraction logic. Useful for reproducibility across GPU types; on CPU the equivalent env var is `VLLM_CPU_KVCACHE_SPACE` (integer GiB).
- Startup **pre-check**: if free memory on the device is already less than `util × total` (another process holds memory), vLLM refuses to start with an error of the form *"Free memory on device … on startup is less than desired GPU memory utilization (…). Decrease GPU memory utilization or reduce GPU memory used by other processes."* This is the classic **0.98 on a shared GPU** failure (lab task 3.8).

### 2.1 Worked example (compute it; used in the lab)

Model: 7B-class, 28 layers, 4 KV heads, head_dim 128, bf16 → KV/token = `2 × 28 × 4 × 128 × 2 B` = **57,344 B = 56 KiB**. Weights ≈ 15.2 GB (7.6B × 2 B). GPU: 24 GB (22.4 GiB usable-ish; use decimal 24 GB for arithmetic in labs unless the lab says otherwise).

```
util 0.90  → budget 21.6 GB
weights 15.2 + activations ~1.5 + overhead ~1.0 = 17.7 GB
kv_pool ≈ 3.9 GB  →  3.9e9 / 57,344 ≈ 68,000 tokens
```

One sequence at `max_model_len 32768` needs 32,768 × 57,344 = 1.88 GB → fits, **max concurrency at full length ≈ 2.1** (vLLM prints this as "Maximum concurrency for 32768 tokens per request: 2.08x" and exposes `kv_cache_max_concurrency` in `cache_config_info`). Real traffic is shorter than max, so far more than 2 sequences run — until they grow.

Raise `max_model_len` to 131072: one sequence needs 7.5 GB > 3.9 GB pool → startup error (next section). The fix is **not** always "lower max_model_len": more utilization, an FP8 KV cache (halves bytes/token), a bigger GPU, or tensor parallelism (weights and KV are sharded) all move the numbers.

## 3. The startup error everyone hits: "max seq len larger than KV cache"

Real text (captured from vLLM 0.31.0 in the course spike, EngineCore `ValueError`, container exits 1):

```
ValueError: To serve at least one request with the model's max seq len (65536), (1.5 GiB KV cache is needed,
which is larger than the available KV cache memory (1.0 GiB). Based on the available memory, the estimated
maximum model length is 43520. Try increasing `gpu_memory_utilization` (which also controls CPU memory on the
CPU backend) or decreasing `max_model_len` when initializing the engine. See
https://docs.vllm.ai/en/latest/configuration/conserving_memory/ for more details.
RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
```

How to read it:
- Check being done: `kv_bytes_per_token × max_model_len ≤ kv_pool`. The engine insists that **one** maximum-length request can fit, otherwise a lone long request could never finish. It says nothing about concurrency.
- "estimated maximum model length is N" is the engine doing your division. Use it: it is the largest `--max-model-len` that works with *current* other flags.
- The traceback root cause is **at the bottom of the first ERROR block**, the final `RuntimeError: Engine core initialization failed` is a generic wrapper (note `Failed core proc(s): {}`: the useful message is above it). Reading only the last line is the #1 time-waster.
- Levers, in the order a team usually tries them: (1) is `max_model_len` bigger than any real request? lower it to the product requirement (+ margin) — cheapest; (2) raise `--gpu-memory-utilization` if the GPU is dedicated (0.92 → 0.95; beyond ~0.95 you risk runtime OOM from non-torch growth); (3) `--kv-cache-dtype fp8` (halves KV bytes/token; accuracy impact small but not zero; needs hardware/kernel support); (4) smaller activations: lower `--max-num-batched-tokens`; (5) quantized weights (AWQ/GPTQ/FP8) to free weight memory — shrinks weights, **not** KV; (6) more GPUs (`--tensor-parallel-size`).
- A model whose config `max_position_embeddings` is smaller than the requested `--max-model-len` is refused unless `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` (we needed this to reproduce the error above with a 32k-context model at 65536). Never set it in production without knowing the model supports the extension (RoPE scaling).

## 4. Concurrency, the two budgets, and chunked prefill

- **`--max-num-seqs`**: size of the running batch. More seqs → more parallel decode → higher **throughput** (decode is memory-bandwidth-bound: weights are read once per step regardless of batch size, so batch is nearly free until compute saturates) — but each running sequence holds KV, and each step takes slightly longer (**ITL** rises). The default is hardware-dependent in recent versions (historically 256; check the startup log).
- **`--max-num-batched-tokens`** (per-step token budget): every running decode sequence consumes 1; the remainder is spent on prefill. V1 always uses **chunked prefill**: a long prompt is split across steps so decode sequences keep getting tokens. Small budget (e.g. 512): smooth ITL, but a long prompt needs many steps → higher TTFT for that prompt. Big budget (8192+): prompts prefill in one or two steps (low TTFT, good throughput) but each such step is long, spiking ITL for everyone in the batch.
- Rule of thumb used by teams: leave the budget at the default unless ITL SLO is violated during prefill-heavy traffic (lower it) or TTFT of long prompts is the problem and ITL has slack (raise it).
- **`--max-model-len`**: per-request cap on prompt + generated tokens. Requests above it are rejected **at the API** with HTTP 400 (`maximum context length is N tokens …`), they never reach the scheduler. It also sizes the startup check (section 3) and, with `--max-num-seqs`, the *theoretical* worst case that `kv_cache_max_concurrency` reports.
- **Worst case vs typical case**: with `S` average live tokens per sequence, KV supports about `kv_pool_tokens / S` concurrent sequences. Plan `max_num_seqs` near that number, not at 256; a batch cap far above what KV can hold is the setup for preemption storms (section 6).

## 5. The KV cache at runtime: blocks, prefix caching, what "usage" means

- The pool is split into blocks of `block_size` tokens. A sequence owns `ceil(tokens / block_size)` blocks; the last block is partly empty (internal fragmentation ≤ one block per sequence — the reason PagedAttention beats contiguous reservation, where `max_model_len` bytes were reserved per request).
- **`vllm:kv_cache_usage_perc`** = used blocks / total blocks, as a **fraction 0..1** ("1 means 100 percent"), despite `perc` in the name. It replaced the old `vllm:gpu_cache_usage_perc` (gone — dashboards from 2024 are silently empty). A Grafana percent unit must multiply by 100 or use unit `percentunit`.
- **Prefix caching** (`--enable-prefix-caching`; on by default in V1 — the golden `cache_config_info` shows `enable_prefix_caching="True"`): full blocks are hashed by (parent hash, token ids, extra keys such as LoRA id / `cache_salt`); a new request whose prompt starts with already-computed blocks **reuses them** and prefills only the rest. Finished sequences' blocks are not freed immediately: they move to a free list in LRU order and remain reusable until evicted. Consequences:
  - "KV usage" counts blocks held by running requests; cached-but-evictable blocks are available capacity.
  - Hit rate = `rate(vllm:prefix_cache_hits_total) / rate(vllm:prefix_cache_queries_total)` (both in **tokens**). Also `vllm:prompt_tokens_by_source_total{source="local_cache_hit"}`.
  - Only **full blocks** hit: with `block_size 128` a 36-token prompt can never hit (this is why we never grade prefix caching on the CPU build). With block 16 on GPU, prompts shorter than 16 never hit.
  - Hits need **byte-identical prefixes**: a timestamp or request id at the top of the system prompt zeroes the hit rate. A frequent production finding.
  - Hits reduce **TTFT** and prefill compute, not memory use per se (shared blocks are ref-counted, so they also save KV).
  - Multi-tenant caution: prefix-cache timing can leak whether another tenant used a prefix; `cache_salt` scopes the hash per tenant.
- **Memory levers for KV bytes** (recap): `--kv-cache-dtype fp8` (÷2 vs bf16), TP (each GPU stores `kv_heads / TP` heads), sliding-window/hybrid models (fewer layers keep full KV), MLA models such as DeepSeek (much smaller KV/token). Weight quantization does not touch KV.
- **CPU offload / KV connectors** (`--kv-offloading-backend`, LMCache, NIXL for disaggregated prefill/decode): extend capacity beyond HBM; the `external_prefix_cache_*` and `prompt_tokens_by_source{source="external_kv_transfer"}` series exist for them. Out of scope for the lab; know the names.

## 6. Preemption: what it is, why it is the symptom to fear

When running sequences need new blocks (each decoded token may cross a block boundary) and the pool is empty, the scheduler **preempts** the lowest-priority running request: its blocks are freed and it goes back to the front of the waiting queue. In V1 the policy is **recompute**: when the request is scheduled again its whole prompt *plus tokens generated so far* are prefilled again (prefix-cache hits can soften this if its old blocks survive). Older versions also had swap-to-CPU; V1 does not.

Consequences, in the order they appear:
1. `vllm:num_preemptions_total` starts increasing (rate > 0). One-off preemptions are normal at the edge; a **sustained rate** means the batch cap is above what KV holds.
2. Wasted compute: preempted tokens are computed twice → throughput (generation tokens/s) flattens or drops even though "GPU util" looks great (util is not saturation).
3. `vllm:request_num_preemptions` histogram shows requests preempted multiple times; E2E latency tail grows; ITL for the victim has a multi-second gap.
4. Waiting queue grows because victims re-enter it → TTFT p95 of *new* requests rises.
5. `kv_cache_usage_perc` sits at ~1.0.

Remedies, cheapest first: **lower `--max-num-seqs`** to what KV holds (trade a little throughput for stability); shorten `max_tokens` / `max_model_len` at the gateway (stop wasting KV on 4k-token completions nobody reads); increase KV (util, fp8 KV, bigger GPU, TP); enable prefix caching and fix prompt prefixes; scale out replicas; use priority scheduling (`--scheduling-policy priority`) so batch/agent traffic is the one preempted. Raising `--max-num-seqs` "for throughput" without checking KV is the most common self-inflicted incident (capstone scenario 2).

## 7. Queueing: when requests wait and how to see it

A request waits when any of the three budgets (seqs, tokens, blocks) cannot admit it. `vllm:num_requests_waiting_by_reason{reason="capacity"|"deferred"}` splits "no room" from "scheduler deferred it" (e.g. prefill budget used up this step, structured-output compile pending). Key series:

| Series | Reads as |
|---|---|
| `vllm:num_requests_running` | gauge, size of the batch now (≤ `max_num_seqs`) |
| `vllm:num_requests_waiting` | gauge, queue length |
| `vllm:request_queue_time_seconds` | histogram, time spent WAITING per request |
| `vllm:request_prefill_time_seconds`, `request_decode_time_seconds` | RUNNING-phase split |
| `vllm:time_to_first_token_seconds` | histogram; **includes queue time + prefill** (and tokenization) |
| `vllm:inter_token_latency_seconds` | histogram; gap between consecutive output tokens (decode step time) |
| `vllm:e2e_request_latency_seconds` | whole request |
| `vllm:request_time_per_output_token_seconds` | per-request average ITL (hides spikes) |

Little's law is the sanity tool: `running ≈ arrival_rate × service_time`. If `waiting` is persistently > 0 while `running < max_num_seqs`, the limiter is KV or the token budget, not the seq cap. If `running == max_num_seqs` and `waiting > 0`, the seq cap is binding: raising it may help *if* KV has room.

Gateway-side protections complement the engine: LiteLLM `max_parallel_requests` / rpm per team (module 04-05) keep one client from filling the queue. vLLM itself has `--max-num-seqs` but no per-tenant fairness.

## 8. Diagnosing a latency complaint: the order

1. **Is the engine up and healthy?** `/health` (200), `/v1/models`, container restart count, startup log (`non-default args`, KV size, "Maximum concurrency"). A restart loop = startup failure (section 3).
2. **Queue**: `num_requests_waiting` > 0 and `request_queue_time` p95? If TTFT is high and queue time is the bulk → capacity problem, not prefill speed.
3. **KV**: `kv_cache_usage_perc` near 1? → pressure path (step 4). Low KV but queue? → seq cap or token budget is binding.
4. **Preemptions**: `rate(num_preemptions_total[5m]) > 0`? → section 6.
5. **Prefill vs decode**: TTFT high with low queue → long prompts / chunk budget / cold prefix cache (check hit rate); ITL high → batch too big, large prefill chunks interleaving, or GPU throttling (module 09).
6. **Throughput** `rate(generation_tokens_total[1m])` vs the capacity you measured in a benchmark: well below → preemption waste or CPU-bound API server/tokenizer.
7. **Upstream**: is it actually the engine? Gateway latency vs engine latency (module 08), network, client retries doubling load.

Symptom order under rising load (what lab 3.5 makes you observe): `kv_cache_usage_perc` climbs → `num_requests_waiting` rises (or preemptions first if the seq cap is high) → `num_preemptions_total` rate > 0 → TTFT p95 and E2E tail rise → throughput stalls/falls → timeouts and client retries → more load. Alert on the *leading* indicators (KV, queue), page on the *symptom* (TTFT SLO) — module 08.

## 9. SLO tuning: a procedure, not a guess

Define the SLOs per traffic class: e.g. interactive chat **p95 TTFT < 1 s, p95 ITL < 60 ms**; agents/batch: throughput. Then:

1. **Characterize traffic**: prompt-length and output-length distributions (`request_prompt_tokens`, `request_generation_tokens` histograms), prefix sharing, arrival rate and burstiness.
2. **Compute the KV ceiling**: `kv_pool_tokens / (avg_prompt + avg_output/2…avg_output)`; that is the concurrency KV can sustain. Set `max_num_seqs` ≈ 70-90% of it.
3. **Sweep** `max_num_seqs` (and possibly `max_num_batched_tokens`) under a replay of real traffic (tools: `vllm bench serve`, GuideLLM, a captured trace); record p95 TTFT, p95 ITL, tokens/s, preemptions. The curve: throughput rises then flattens; TTFT p95 is flat until the batch cap/KV is reached and then **hockey-sticks**; ITL rises roughly linearly with batch.
4. **Pick the knee** that satisfies both SLOs with margin, with preemptions == 0 at p95 load. Re-test at 1.5× peak.
5. **Scale out, don't over-pack**: one more replica beats a batch cap that lives on the cliff. Capacity planning then = replicas × sustained tokens/s per replica vs forecast.
6. Tuning is **per model + GPU + traffic mix**. A config copied from another team's cluster is a hypothesis.

Beyond flags (know they exist): speculative decoding (`--speculative-config`) cuts ITL at low batch, helps less at high batch; FP8/AWQ weights speed up memory-bound decode; prefix-aware routing (llm-d, vLLM production-stack router, Gateway API Inference Extension) multiplies prefix-cache hit rate across replicas; disaggregated prefill/decode separates TTFT and ITL pools.

## 10. Production flags checklist (what a team's `args` usually contains)

```
--model <path-or-hf-id>            --served-model-name chat        # name clients/gateway use
--max-model-len 16384              # product requirement + margin, not the model's maximum
--gpu-memory-utilization 0.90      # dedicated GPU: 0.90-0.95; shared GPU: leave room, see section 2
--max-num-seqs 64                  # sized from the KV ceiling (section 9)
--max-num-batched-tokens 4096      # default unless ITL/TTFT evidence
--tensor-parallel-size 2           # must divide attention heads AND KV heads (8 KV heads: TP 1,2,4,8)
--kv-cache-dtype fp8               # when KV is the constraint
--enable-prefix-caching            # (default on in V1; keep prompts prefix-stable)
--enable-auto-tool-choice --tool-call-parser hermes   # tool calling needs BOTH; parser depends on model family
--dtype auto  --quantization <awq|gptq|fp8>            # per checkpoint
--api-key <token>  --host 0.0.0.0 --port 8000          # behind the gateway only, never public
--max-log-len, --disable-log-requests                  # avoid logging prompts (PII)
```
Also: `--generation-config vllm` vs `auto` (by default vLLM applies the model's `generation_config.json` sampling defaults — a surprise when temperature/top_p differ from what clients assume), `--chat-template` for models without one, `--lora-modules` for adapters, `--enforce-eager` (debugging, memory), `--max-cudagraph-capture-size`.
Containers: `--shm-size`/`--ipc=host` (NCCL, worker IPC), pin the image tag (never `latest`), mount HF cache read-only with `HF_HUB_OFFLINE=1` in air-gap, GPU access via NVIDIA runtime/CDI, readiness probe on `/health`, **startup probe generous** (weight load + compile/graph capture takes minutes: 70B from NFS can take 10+ min), liveness not too aggressive or a slow start loops forever.

## 11. Observability hooks you will use (module 08 builds on them)

- `/metrics` on the API port (Prometheus text). Label set: `engine="0"`, `model_name=<served name>`. Every counter has `_total` and `_created`; histograms have `_bucket/_sum/_count`.
- **Histogram quantiles**: p95 TTFT = `histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[5m])))`. Buckets are fixed by the engine (TTFT in 0.31: 0.001, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10, 20, 40, 80, 160, 640, 2560 s; ITL: 0.01 … 80 s); quantile accuracy is bounded by bucket width — linear interpolation inside the bucket. Computing it by hand from raw `_bucket` counts is lab 3.4.
- `vllm:cache_config_info`: a labeled info-gauge (value 1) with `block_size`, `gpu_memory_utilization`, `cache_dtype`, `kv_cache_size_tokens`, `kv_cache_max_concurrency`, `kv_cache_memory_bytes`, `enable_prefix_caching`… — put it on the dashboard to see what the running instance actually decided.
- `vllm:iteration_tokens_total` histogram: tokens per engine step; shows whether the token budget is saturated.
- `vllm:request_success_total{finished_reason="stop|length|abort|error|repetition"}`: `length` dominating = clients truncating; `abort` = client disconnects (timeouts upstream).
- Logs: periodic "Avg prompt throughput … Running: N reqs, Waiting: M reqs, GPU KV cache usage: X%, Prefix cache hit rate: Y%" line — the poor man's dashboard when Prometheus is down.
- Request/response logging is off by default; if enabled it contains prompts (PII) — treat logs as sensitive.

## 12. What this lab simulates, and how production differs (honest section)

12.1 **mock-vllm (graded path, simulated).** A FastAPI service from the course image `aiinfra-mock:1.0` (role `vllm`). It:
- parses the **same CLI flags** you pass to `vllm serve` from `/config/args`;
- reads real model geometry from a `config.json` (layers, KV heads, head_dim) and a simulated GPU from `/config/gpu.yaml`, and runs the **same arithmetic as section 2** (weights + activation estimate + overhead → KV pool → blocks);
- fails at startup with the **real vLLM error strings** (the KV error in section 3 is copied byte-for-byte; unhealthy containers exit non-zero);
- exports the **real metric names** (copied from a real vLLM 0.31 `/metrics` dump);
- models latency with a **deterministic virtual clock** (TTFT = queue + prefill(tokens); ITL grows with batch size) and a capacity model that produces KV growth, preemptions and queueing. Numbers are plausible, **not measured** from a GPU. Do not carry them to production as capacity figures.
- supports faults (`/admin/fault`: latency, error_rate, kv_pressure, crash, slow_load, other_gpu_mem).

What it does not model: kernel behaviour, CUDA graphs, real activation peaks (a fixed per-token estimate is used), NCCL/TP communication, speculative decoding, LoRA, quantization kernels, real tokenizers (token counts come from a simple tokenizer or the scripted pattern).

12.2 **Real vLLM-CPU (optional task 3.7, unscored).** Image `vllm/vllm-openai-cpu` **v0.31.0**, `--dtype float32`, `VLLM_CPU_KVCACHE_SPACE=1`, ~6 GB RAM, ~10 tokens/s on this arm64 host. Pinned reasons: v0.32.0's CPU build crashes on the first request on this host; float16 is unusable on this CPU (no bf16/fp16 fast path). The CPU backend uses `block_size 128` and system RAM instead of VRAM, so KV arithmetic is real but in fp32 (Qwen2.5-0.5B: 24,576 B/token → 1 GiB = 43,520 tokens). Prefix-cache hits do not occur for short prompts (block 128) — never rely on them here. Run it **alone** (profile `vllm`): it is the heaviest container in the course.

12.3 **Production differs**: a real GPU has memory fragmentation and non-torch growth that make util > 0.95 risky; activation peaks depend on the real kernels; CUDA graph capture takes memory and minutes; TP adds NCCL and needs NVLink/PCIe topology awareness; GPU throttling and XID errors (module 09) change latency; real engines have many more flags and per-version defaults — always diff your `args` against `vllm serve --help` of the pinned image and read the startup log.

## 13. Pitfalls (each of these has been a real incident somewhere)

1. Reading `RuntimeError: Engine core initialization failed` and stopping; the cause is the `ValueError`/`OutOfMemoryError` above it.
2. `--gpu-memory-utilization 0.98` "to get more KV": no headroom for non-torch memory → OOM at first CUDA-graph capture or under load; or refused at startup because another process (monitoring agent, a second instance, a notebook) holds memory.
3. Assuming utilization is a cap on others, or that two instances at 0.9 each fit on one GPU.
4. Setting `--max-model-len` to the model's maximum (128k) "just in case" on a 24 GB GPU — KV for one sequence exceeds the pool.
5. `--max-num-seqs` raised without KV evidence → preemption storm, throughput *down*.
6. Dashboards on `vllm:gpu_cache_usage_perc` (removed) or `*_total` without `rate()`; KV panel in percent but values 0..1.
7. Average TTFT/ITL instead of quantiles; `request_time_per_output_token` hides ITL spikes.
8. TP degree not dividing KV heads (8 KV heads, TP=3 → startup error); assuming TP doubles throughput linearly (communication cost) — TP is mostly for *fitting* a model.
9. Prefix cache expected but prompts begin with a timestamp / uuid → hit rate 0.
10. Tool calling "doesn't work": missing `--enable-auto-tool-choice --tool-call-parser` (or wrong parser for the model family) — an engine config issue, not a gateway one.
11. Liveness probe too tight for weight loading → endless restart.
12. Sampling defaults silently coming from the model's `generation_config.json`.

## 14. Reading a real startup log (what to look for, in order)

A `vllm serve` start prints a few hundred lines; five matter. Real lines captured in the course spike (vLLM 0.31/0.32 on the CPU backend; on a GPU the same lines say `GPU`):

```
(APIServer pid=1)  INFO [api_utils.py:286] non-default args: {'model': 'Qwen/Qwen2.5-0.5B-Instruct', 'dtype': 'float32', 'max_model_len': 2048, 'max_num_batched_tokens': 512, 'max_num_seqs': 4}
(APIServer pid=1)  INFO [model.py:2152] Using max model len 2048
(APIServer pid=1)  INFO [scheduler.py:307] Chunked prefill is enabled with max_num_batched_tokens=512.
(EngineCore pid=38) INFO [core.py:133] Initializing a V1 LLM engine (v0.31.0) with config: model='...', dtype=..., max_seq_len=2048, tensor_parallel_size=1, ... enable_prefix_caching=True ...
(EngineCore pid=38) INFO [kv_cache_utils.py:2464] CPU KV cache size: 87,296 tokens, Maximum concurrency for 2,048 tokens per request: 42.62x
(EngineCore pid=38) INFO [core.py:380] init engine (profile, create kv cache, warmup model) took 0.17 s
(EngineCore pid=38) INFO [loggers.py:320] Engine 000: Avg prompt throughput: 3.6 tokens/s, Avg generation throughput: 0.3 tokens/s, Running: 1 reqs, Waiting: 0 reqs, CPU KV cache usage: 0.1%, Prefix cache hit rate: 0.0%
```
1. **`non-default args`** — the ground truth of what you actually configured (after env vars and defaults). Compare it with your Helm values/Compose file in every incident: a flag that silently did not arrive (typo in a templated args list) shows up here, nowhere else.
2. **`Using max model len`** — the value of `--max-model-len` after deriving from the model config. If you did not set it, this is the model's maximum (131072 for Llama-3.1) — the usual cause of the section-3 failure.
3. **`Initializing a V1 LLM engine … with config`** — one long line: dtype, quantization, TP/PP sizes, KV dtype, prefix caching, compilation level, tokenizer. Grep it for `kv_cache_dtype`, `enable_prefix_caching`, `max_seq_len`.
4. **`KV cache size: N tokens`** and **`Maximum concurrency for M tokens per request: X.XXx`** — the result of the memory arithmetic. `N` is your capacity in tokens; `X` is `N / max_model_len`. These two numbers are the whole planning story; copy them into the runbook for each model/GPU pair. (They are what `vllm:cache_config_info` exposes as `kv_cache_size_tokens` and `kv_cache_max_concurrency`.)
5. **The periodic stats line** (every ~10 s when there is traffic): `Running`, `Waiting`, `KV cache usage`, `Prefix cache hit rate`, prompt/generation throughput. This line is also what you get from `docker logs` when Prometheus is down.

Other lines you will meet: `Casting torch.bfloat16 to torch.float16` (a dtype override that changes numerics and memory), `No available shared memory broadcast block found in 60 seconds` (a worker is busy — compilation, CUDA graph capture, quantization — or hung; normal during long warmups, a hang if it repeats after warmup), `Model Runner V2 requires Triton; using the V1 model runner` (a fallback, harmless), per-weight `Attempted to load weight ... with dtype bfloat16 into parameter with dtype float16` (noise when casting). **Time to healthy** is part of the capacity plan: weights load + profiling + compile/graph capture. On the CPU spike it was 3-4 minutes for a 0.5B model on a warm cache and over 18 minutes (never healthy) for 0.32.0 in default compiled mode — on GPUs, 70B from network storage takes 5-15 minutes. Probes must be sized for that (section 18).

## 15. The scheduler, one step at a time (with numbers)

Setup: `max_num_seqs 4`, `max_num_batched_tokens 512` (budget B), `block_size 16`, pool of 40 free blocks (640 tokens), prefix cache empty. Requests arrive: R1 (prompt 200, will generate 50), R2 (prompt 300, 50), R3 (prompt 100, 50).

| Step | Running before | What the scheduler does | Tokens computed | Notes |
|---|---|---|---|---|
| 1 | none | admit R1: needs ceil(200/16)=13 blocks, budget 512 → prefill all 200 tokens of R1; R2 needs 19 blocks (13+19=32 ≤ 40) and 300 > remaining budget 312? 300 ≤ 312 → prefill R2 entirely | 500 | both in one step; R3 (7 blocks, 100 tokens) does not fit the budget (12 left) → partial/chunk or waits |
| 2 | R1, R2 | decode R1, R2 (1 token each) = 2 tokens; remaining budget 510 → prefill R3 (100) | 102 | R3 gets blocks 7 → 39 of 40 used |
| 3...49 | R1,R2,R3 | decode 3 tokens/step; each sequence crosses a block boundary every 16 tokens → allocates a new block | 3 | free blocks: 1 → after the first boundary crossings the pool is empty |
| ~5 | R1,R2,R3 | R1 needs a block, none free: **preempt the newest running request** (R3): free its 7+ blocks, put it at the front of waiting | — | `num_preemptions_total` +1; R3 will recompute prompt + tokens so far |
| later | R1,R2 | R1 finishes → blocks freed → R3 is admitted again (re-prefill) | 100+k | R3's TTFT was already paid once; its E2E includes the wasted work |

What it teaches: (1) **prefill competes with decode for the same token budget**, so a big prompt arriving in a busy batch slows everyone's next token by the time of that prefill chunk — hence smaller chunk budgets for tight ITL; (2) admission needs blocks for the *prompt*, but growth needs blocks later: the engine admits optimistically, which is why a full pool shows up as preemptions mid-flight rather than as rejections; (3) preempting the *newest* request protects older ones from repeated waste (FCFS fairness); (4) the cost of a preemption is proportional to tokens already computed for the victim.

Priority scheduling (`--scheduling-policy priority`, requests carry `priority`) changes the victim choice and admission order: batch traffic gets lower priority and absorbs preemptions. The OpenAI-compatible API accepts `priority` as an extra body field; the gateway must not let untrusted clients set it.

## 16. Roofline: where tokens per second come from

Decode of one step reads *all* weights once from HBM (plus the KV of every running sequence) and does little math per byte. So a first-order estimate of the decode step time is `t_step ≈ (weights_bytes + Σ kv_bytes(seq)) / HBM_bandwidth / efficiency`, and **throughput ≈ batch / t_step**.

| GPU | HBM bandwidth | 8B bf16 weights (16 GB) step floor | batch 32 → tokens/s (efficiency 0.65) |
|---|---|---|---|
| A10G / L4 (24 GB) | ~600 GB/s / ~300 GB/s | 27 ms / 53 ms | ~700 / ~390 |
| A100 80 GB | ~2,000 GB/s | 8 ms | ~2,600 |
| H100 80 GB | ~3,350 GB/s | 4.8 ms | ~4,300 |

(Illustrative; real engines reach 50-80% of the bandwidth bound and add overheads. The mock uses exactly `weights/(0.65·bw)` plus a KV term and a per-sequence term.) Consequences you can reason about without a benchmark: (1) decode is memory-bound, so **quantizing weights to FP8/INT4 speeds decode up** nearly proportionally (fewer bytes to read), unlike compute-bound training; (2) doubling the batch almost doubles throughput until KV reads dominate or compute saturates — that is why `max_num_seqs` matters; (3) ITL ≈ `t_step`: it rises with batch (KV reads) and with prefill chunks sharing the step; (4) **prefill is compute-bound**: time ≈ `2 · params · tokens / (TFLOPs · efficiency)` — 8B model, 4,000-token prompt, A100 (312 TFLOPs dense bf16, ~40% efficiency): `2·8e9·4000 / (312e12·0.4)` ≈ 0.5 s; on an L4 (121 TFLOPs) about 1.3 s. This is why TTFT for long prompts is the metric that hurts most on small GPUs and why prefix caching and chunking exist.

## 17. Parallelism and how many GPUs per replica

| Mode | Splits | Needs | Use |
|---|---|---|---|
| Tensor parallel (`--tensor-parallel-size`) | each layer's matrices (and attention heads) across GPUs; all-reduce twice per layer | fast interconnect (NVLink); TP divides attention and KV heads | fit a model that does not fit one GPU; reduce per-GPU weights → more KV; keep within one node |
| Pipeline parallel (`--pipeline-parallel-size`) | layers across GPUs/nodes; micro-batches | tolerates slower links | models beyond one node (e.g. 405B across 2 nodes) |
| Data parallel (`--data-parallel-size` or more replicas) | whole replicas | memory for full weights each | throughput; independent failure domains; preferred scale-out for ≤70B |
| Expert parallel | MoE experts across GPUs | MoE models (DeepSeek, Mixtral) | very large MoE; interacts with DP |

Rules of thumb: smallest TP that fits weights + a useful KV pool; then add replicas. TP across PCIe-only GPUs can be *slower* than a smaller TP plus quantization. 8 KV heads limit useful TP to 8 (beyond, KV heads are replicated and KV per GPU stops shrinking). A 70B bf16 model needs ≥ 2×80 GB just for weights (140 GB) and is **practical** on 4×80 GB or FP8 on 2×80 GB (cheatsheet `vram-kv-math`). Failure isolation: a TP group is a single failure domain — one GPU XID kills the whole replica (module 09).

## 18. Running vLLM on Kubernetes (what teams actually write)

```yaml
containers:
- name: vllm
  image: vllm/vllm-openai:v0.31.0            # pin; never :latest; mirrored to the internal registry
  args: ["--model","/models/llama-3.1-8b-instruct","--served-model-name","chat","--max-model-len","16384",
         "--gpu-memory-utilization","0.90","--max-num-seqs","64","--enable-prefix-caching"]
  env: [{name: HF_HUB_OFFLINE, value: "1"}]
  resources: {limits: {nvidia.com/gpu: 1}}
  volumeMounts: [{name: models, mountPath: /models, readOnly: true}, {name: shm, mountPath: /dev/shm}]
  startupProbe:   {httpGet: {path: /health, port: 8000}, periodSeconds: 10, failureThreshold: 90}   # up to 15 min
  readinessProbe: {httpGet: {path: /health, port: 8000}, periodSeconds: 5}
  livenessProbe:  {httpGet: {path: /health, port: 8000}, periodSeconds: 30, failureThreshold: 6}
volumes: [{name: shm, emptyDir: {medium: Memory, sizeLimit: 8Gi}}, {name: models, persistentVolumeClaim: {claimName: weights}}]
```
- **Startup probe first.** Weight load + profiling + graph capture takes minutes; a liveness probe that starts at t=0 kills the pod forever. `/health` returns 200 when the engine is ready (and 503 or no connection before). It does not mean "not overloaded".
- **Shared memory**: workers communicate through `/dev/shm`; the default 64 MiB container shm breaks TP and large batches ("bus error" / worker timeouts). Use a memory `emptyDir` or `--ipc=host`.
- **Weights from a read-only volume** (PVC populated from the internal registry/S3 — module 02), `HF_HUB_OFFLINE=1`, no network egress needed. Cold start is dominated by reading weights: local NVMe cache per node beats NFS; pre-pull/warm nodes before shifting traffic.
- **Rolling updates**: `maxUnavailable: 0, maxSurge: 1` with GPUs scarce means you need a spare GPU, or accept brief capacity loss; `terminationGracePeriodSeconds` ≥ longest generation (in-flight streams die otherwise); a preStop sleep lets the gateway/Service drain.
- **Autoscaling**: CPU/GPU util are poor signals. Scale on **`vllm:num_requests_waiting` / queue time / KV usage** (KEDA with the Prometheus scaler, or HPA on a custom metric) with long stabilization windows because new replicas take minutes to become ready; scale-to-zero is rarely acceptable for chat.
- **Routing**: a plain Service round-robins and destroys prefix-cache locality; prefix/KV-aware routers (llm-d, vLLM production-stack router, Gateway API Inference Extension) or sticky routing by conversation id raise hit rates. LiteLLM/Envoy in front of replicas should use least-busy or queue-aware routing rather than blind round-robin.
- **Security**: the engine's OpenAI API is unauthenticated unless `--api-key`; keep it on a ClusterIP behind the gateway; NetworkPolicy so only the gateway reaches port 8000; `/metrics` is open — scrape from inside the namespace only.

## 19. Capacity planning, worked end to end

Question: "Chat product, 200 concurrent users at peak, avg prompt 1,500 tokens (system prompt 800 of it shared), avg answer 300 tokens, p95 TTFT < 1.5 s, p95 ITL < 60 ms, Llama-3-8B bf16 on 80 GB GPUs."

1. **KV per sequence at completion**: (1,500 + 300) × 128 KiB = 225 MiB. **KV pool per GPU** at util 0.90: 72 GB − 16 GB weights − ~3 GB = ~53 GB ≈ 440,000 tokens → ~245 sequences of 1,800 tokens at once (prefix sharing of the 800-token system prompt raises this: shared blocks count once).
2. **Concurrency per GPU**: "200 concurrent users" ≠ 200 concurrent *sequences*: users think/read; typical active fraction 10-30% → 20-60 running sequences. Set `max_num_seqs 64`.
3. **Decode throughput**: 64 sequences × (1 token / ~12 ms) ≈ 5,300 tok/s (A100/H100 class; roofline above). Demand: 60 active × ~25 tok/s each (reading speed) = 1,500 tok/s → one GPU has 3× headroom on decode.
4. **Prefill load**: arrival rate λ = active users / (think + service time). With 200 users, 30 s mean cycle → ~6.7 req/s × 700 unshared prompt tokens (cache hit on 800) = ~4,700 prompt tokens/s. Prefill capacity on an A100 for 8B ≈ 0.4·312e12/(2·8e9) ≈ 7,800 tok/s → prefill utilization 60% **and it competes with decode in the same steps** → ITL spikes, queueing → plan **2 replicas** (and 3 for N+1 and rolling updates).
5. **Check TTFT**: at 60% prefill utilization, M/M/1-style waiting ≈ ρ/(1−ρ) × service time = 1.5 × 0.1 s = 0.15 s on top of the 0.1 s prefill itself → p95 well under 1.5 s with margin; at 85% utilization the same formula gives 5.7 × service = 0.6 s mean and the tail blows through the SLO → keep prefill utilization ≲ 65%.
6. **Validate** with a replay benchmark (`vllm bench serve` or GuideLLM with your prompt/output distributions and a Poisson arrival rate) and compare p95 TTFT/ITL/preemptions with the SLO; capacity numbers from vendor blogs are not yours.

## 20. Features that change the math

| Feature | Flag | Effect on memory | Effect on speed | Watch out |
|---|---|---|---|---|
| FP8 / INT4 weights | `--quantization fp8\|awq\|gptq` (or pre-quantized checkpoint) | weights ×0.5 / ×0.28 (bytes/param 1 / ~0.56) | decode faster (fewer bytes); kernel support per GPU (FP8 needs Ada/Hopper+) | accuracy; Marlin kernels for INT4 on Ampere |
| FP8 KV cache | `--kv-cache-dtype fp8` | KV ×0.5 → 2× tokens | slight attention cost; usually faster at long ctx | accuracy impact small, workload-dependent |
| Prefix caching | `--enable-prefix-caching` | none (shared blocks save) | prefill skipped for hits | prefix must be identical; tenant isolation (`cache_salt`) |
| Chunked prefill | always on (V1) | none | smooth ITL | chunk size = `max_num_batched_tokens` |
| Speculative decoding | `--speculative-config '{...}'` (draft model / n-gram / EAGLE / MTP) | draft weights + KV | lower ITL at low batch; none/negative at high batch | acceptance rate depends on text; adds startup complexity |
| LoRA adapters | `--enable-lora --lora-modules name=path --max-loras N` | adapter slots | small overhead | adapter name = `model` in the request; per-tenant routing |
| Structured outputs | `response_format` / `guided_*` | grammar state | compile cost for new schemas (`deferred` waiting reason) | first request with a new schema is slow |
| Multimodal | model-dependent | encoder activations, `mm` cache | encoder time in TTFT | `--limit-mm-per-prompt`; image tokens count against context |
| Long context | `--max-model-len` > training length + RoPE scaling | KV per sequence ↑ | prefill O(n²) attention cost | `VLLM_ALLOW_LONG_MAX_MODEL_LEN` risk (section 3) |

## 21. Failure catalog (symptom → first check → usual cause)

| Symptom | First check | Usual cause |
|---|---|---|
| Container restarts every 1-2 min | `docker logs` first ERROR; `kubectl describe` (OOMKilled? probe?) | startup arithmetic (section 3), liveness killing a slow start, host-RAM OOM kill (not GPU) |
| `OutOfMemoryError` at startup | which allocation: weights (model too big for the GPU/TP) or activation profiling | model > GPU; `max_num_batched_tokens` too large; other process on GPU |
| OOM after hours | KV usage ~1.0 and `util 0.95+`; non-torch growth | util too high; fragmentation; a long-context outlier request |
| Every request 400 `maximum context length` | request token count vs `max_model_len` | client sends more than the cap; system prompt grew; chat template adds tokens |
| 5xx / connection reset under load | engine log, `num_requests_waiting`, gateway timeouts | queue so long clients time out; engine crash (XID) |
| TTFT fine at 1 user, awful at 20 | waiting, queue time, KV, prefill share | seq cap or KV binding; long prompts monopolizing steps |
| Throughput flat when load rises | `generation_tokens_total` rate vs `running` | preemption recompute; CPU-bound API server/tokenizer; GPU throttling (module 09) |
| Output differs from other engine/provider | `generation_config` defaults, chat template, dtype cast, quantization | sampling defaults from the model's `generation_config.json`; template mismatch |
| Tool calls come back as plain text | `--enable-auto-tool-choice`/`--tool-call-parser` present and right for the family? | missing/wrong parser; model too small (module 07) |
| Hit rate 0 on a shared system prompt | first 100 tokens of two requests | timestamp/ID at the top; block size; eviction |
| Pods Pending | `nvidia.com/gpu` capacity, taints | module 09 |
| Slow start on new node | weights read time, image pull | cold NFS, no node cache |

## 22. Worked exercises (answers in `.tutor/answers.md` follow the same method)

1. Qwen2.5-7B (28 layers, 4 KV heads, head_dim 128) bf16, A10G 24 GiB, util 0.90, activations+overhead 2 GiB. KV/token = 57,344 B. Weights 15.2 GB = 14.2 GiB → budget 21.6 GiB − 14.2 − 2 = 5.4 GiB = 5.8e9 B → ~101,000 tokens. At `max_model_len 32768` max concurrency 3.1x. With FP8 KV: ~202,000 tokens, 6.2x.
2. A team reports "vLLM only uses 60% of the GPU memory". They set `--gpu-memory-utilization 0.6`. What is unused? (Answer: they asked for it; the unused 40% is simply not claimed; KV pool is smaller; raise it or run a second model there.)
3. TTFT p95 doubled after a deploy; `kv_cache_usage_perc` 0.97, preemptions rate 3/s, waiting 25. Diff of `non-default args` shows `--max-num-seqs 256` (was 64) and prefix caching disabled in the new template. Explain the chain and the fix (restore seq cap sized from KV; re-enable prefix caching; capstone scenario 2).
4. Why can lowering `--max-num-batched-tokens` from 8192 to 512 increase p95 TTFT for 4k-token prompts but decrease p95 ITL? (A 4k prompt now needs 8+ steps interleaved with decode, so its first token comes later; decoders stop being stalled behind a 4k-token prefill step.)
5. Compute `kv_cache_max_concurrency` for Llama-3-70B FP8 weights on 2×80 GB TP=2, util 0.90, `max_model_len 32768`, bf16 KV: budget 2×72 = 144 GB − 70 weights − ~8 overhead ≈ 66 GB → 66e9 / 327,680 ≈ 201,000 tokens → 6.1x. With FP8 KV: 12.3x.

## 23. Glossary and quick numbers

| Term | Meaning |
|---|---|
| Block / page | fixed-size group of KV slots (`--block-size`, 16 tokens on CUDA); unit of allocation, hashing and eviction |
| `num_gpu_blocks` | blocks in the KV pool after profiling; `kv_cache_size_tokens = blocks × block_size` |
| Null block | reserved block 0, never allocated to requests (the mock and the engine both exclude it from the usable count) |
| Prefill / decode | processing the prompt (compute-bound, parallel over tokens) / producing one token per step (memory-bound) |
| Chunked prefill | splitting a long prompt across steps under the token budget so decodes keep running |
| Preemption (recompute) | freeing a running request's blocks and re-prefilling it later |
| TTFT / ITL / E2E / TPOT | time to first token / gap between tokens / whole request / mean time per output token |
| Goodput | throughput of requests that met their SLO (the number that matters when tuning) |
| Prefix cache | reuse of KV blocks of identical prompt prefixes (hash chain over full blocks) |
| TP / PP / DP / EP | tensor / pipeline / data / expert parallelism |

Numbers worth remembering: KV/token bf16 — 8B GQA 128 KiB, 70B GQA 320 KiB, 7B (4 KV heads) 56 KiB, 0.5B 12 KiB; 1 GiB of KV holds 8,192 tokens of Llama-3-8B; A100 80 GB decode floor for 8B ≈ 8 ms/token-step; H100 ≈ 5 ms; prefill of 4,000 tokens for 8B on A100 ≈ 0.5 s; vLLM default utilization 0.92 (pinned docs); 8 KV heads → TP ∈ {1,2,4,8}.

## 24. Checklist before you put a vLLM config into production

1. `non-default args` reviewed against the template; image tag pinned and mirrored; `--served-model-name` equals the alias in the gateway.
2. `--max-model-len` = product requirement + margin; `kv_cache_size_tokens` and `max_concurrency` recorded in the runbook.
3. `--gpu-memory-utilization` chosen with headroom (0.90 default posture; lower on shared GPUs); no other GPU tenants unless intended.
4. `--max-num-seqs` sized from the KV ceiling; load-tested at 1.5× peak with zero preemptions.
5. Startup probe sized for the cold-start measured on that node type; `/dev/shm` configured; weights read-only and offline.
6. Metrics scraped; alerts: `EngineDown`, `TTFTHigh`, `QueueGrowing`, `KVCacheNearFull` (with queue/preemption condition), `PreemptionsSustained`.
7. Gateway limits in front (per-team parallelism, max tokens, context-length checks) so one client cannot fill the queue or the KV.
8. Logging policy: prompts not logged by default; access restricted; retention set.
9. Rollback plan: previous image + previous args kept; model artifact immutable (digest).
10. Failure drill done once: kill a replica, fill KV on purpose, remove a node's GPU memory (task 3.8) — and the on-call knows which metric shows each.

---

## Key takeaways

- Startup memory = `util × total GPU` split into weights, profiled activations, overhead and **KV pool**; the engine refuses to start if one `max_model_len` sequence does not fit in the pool. The real error even prints the largest model length that would fit — do the division yourself first.
- Levers for KV: `max_model_len` (to the requirement), utilization (dedicated GPU only), FP8 KV, TP, bigger GPU; quantized weights shrink weights, not KV.
- `--max-num-seqs` and `--max-num-batched-tokens` set concurrency and per-step work; size `max_num_seqs` from the KV ceiling, not from hope. Chunked prefill is always on in V1.
- Preemption (recompute) is the cliff: it wastes compute, grows the queue and the TTFT tail; the order is KV usage → waiting/preemptions → TTFT/E2E → throughput.
- `kv_cache_usage_perc` is a 0..1 fraction; TTFT includes queueing; quantiles come from histogram buckets (`histogram_quantile`), never from averages.
- SLO tuning is a measured sweep per model/GPU/traffic; prefer scaling out to over-packing one replica.
- In this lab the engine is simulated with the real flag semantics, error strings and metric names; absolute numbers are plausible, not measured.

## Check yourself

1. A 70B model on 2×80 GB at `--gpu-memory-utilization 0.9` fails with "estimated maximum model length is 12000". List four distinct changes that could fix it and what each costs.
2. Why does the engine require one full `max_model_len` sequence to fit even if no client ever sends one?
3. TTFT p95 doubled, `kv_cache_usage_perc` is 0.55, `num_requests_running` is at `max_num_seqs`, `waiting` is 40. What is binding, and what do you try first?
4. What does a preemption do (V1), and why can throughput drop while GPU utilization shows 100%?
5. Give two reasons the prefix-cache hit rate is 0 although `--enable-prefix-caching` is on.
