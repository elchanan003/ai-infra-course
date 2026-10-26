# 01 — Serving internals: prefill/decode, KV cache, batching, prompt cache, quantization, sizing

Time: ~5 h (about 1.5 h theory, 3.5 h lab). Profiles: `llm mock`. Real: llama.cpp b11889 on CPU (arm64). **Simulated: mock-vllm** (vLLM-style metrics, capacity model, error strings) — there is no GPU on the lab host. Everything about GPUs, VRAM, tensor parallelism and MIG in this module is calculation and theory; the calculator you write is the "lab" for it.

Units: in this module **GiB = 2^30 bytes, GB = 10^9 bytes**. Mixing them is the most common sizing bug (7% error at this scale). GPU memory is quoted as "80 GB" but is ~80 GiB (an H100 80GB shows 81,559 MiB in `nvidia-smi`).

## 1. What an LLM server actually does

A decoder-only LLM generates text one token at a time. For a request with a prompt of P tokens producing G tokens:

1. **Prefill**: all P prompt tokens go through the network in one pass. Output: the KV entries for every prompt token, and the logits for the first generated token. This is a large matrix-matrix workload: **compute-bound**. Time grows with P.
2. **Decode**: G steps. Each step feeds the single last token, attends to all previous tokens through the cached keys/values, and emits one token. Per step the GPU must read **all the weights** (and the sequence's KV) from memory to do very little arithmetic per byte: **memory-bandwidth-bound**.

Back-of-envelope for decode, single sequence: tokens/s ≲ memory bandwidth / bytes of weights read per token.
- Llama-3-8B in FP16: 16.06 GB; H100 HBM3 ≈ 3.35 TB/s → ≲ 208 tok/s. An A10 (600 GB/s) → ≲ 37 tok/s. A 4-core CPU with ~25-40 GB/s of DRAM bandwidth running a 0.5B Q4 model (0.4 GB) → ~60-100 tok/s theoretical; real results are lower because of kernel efficiency (you measured about 12-18).
- The weights are read once per step **regardless of how many sequences are in the batch**. 32 sequences decoded together cost about the same weight traffic as 1, so aggregate throughput scales almost linearly with batch size until compute (or KV traffic) becomes the limit. This single fact explains why batching is the central idea of LLM serving, and why a lightly loaded GPU is an expensive GPU.

Arithmetic intensity (FLOPs per byte moved): in prefill of 2000 tokens every weight read from memory is reused for 2000 tokens → compute-bound; in decode at batch 1 each weight read is used for one token → memory-bound. The crossover batch size on an H100 is a few hundred tokens per step. That is why `--max-num-batched-tokens` exists (section 3).

### 1.1 The metrics that follow from it
| Metric | Meaning | Dominated by |
|---|---|---|
| **Queue time** | request waiting for a free sequence slot / KV blocks | load, `max_num_seqs`, KV capacity |
| **TTFT** | request arrival → first token | queue + prefill (prompt length) |
| **ITL / TPOT** | time between consecutive output tokens | decode step time = f(batch size, context length) |
| **E2E latency** | arrival → last token | TTFT + (G-1) × ITL |
| **Throughput** | generated (and prompt) tokens per second, aggregate | batch size, GPU, quantisation |

Throughput and latency trade off through batch size: a bigger batch raises tokens/s and raises ITL. An SLO table (e.g. "p95 TTFT < 2 s, p95 ITL < 50 ms") picks the operating point (module 03).

## 2. The KV cache

During attention every token needs the key and value vectors of all previous tokens, in every layer. Recomputing them each step would make decode quadratic; instead they are stored: the **KV cache**.

**Bytes of KV per token = 2 (K and V) × layers × kv_heads × head_dim × bytes_per_element**

Per sequence = that × tokens (prompt + generated so far). Total = per-sequence summed over all concurrent sequences.

### 2.1 Why `kv_heads` and not `attention_heads`
- **MHA** (multi-head): kv_heads = attention heads. Llama-2-7B: 32 layers × 32 × 128 → 2×32×32×128×2 B = 512 KiB/token.
- **GQA** (grouped-query): several query heads share one K/V head. Llama-3-8B: 8 KV heads (of 32) → 2×32×8×128×2 = **128 KiB/token** (4x less than MHA). Llama-3-70B: 8 KV heads → 2×80×8×128×2 = **320 KiB/token**.
- **MQA**: one KV head. Smallest cache, some quality cost.
- **MLA** (DeepSeek-V2/V3 family): caches a compressed latent per token instead of K/V per head; per-token cache is several times smaller than GQA models of similar size. Same formula idea, different shape.
- **Sliding-window / hybrid layers** (e.g. some Gemma/Mistral variants): layers with a window cap their KV at the window size. Read the model's `config.json`, do not assume.

Read the geometry from `config.json`: `num_hidden_layers`, `num_attention_heads`, `num_key_value_heads` (absent → MHA), `head_dim` (absent → `hidden_size / num_attention_heads`).

### 2.2 Worked examples (FP16 KV, 2 bytes)
| Model | layers | kv_heads | head_dim | KV per token | one 4k sequence | one 32k sequence |
|---|---|---|---|---|---|---|
| Qwen2.5-0.5B | 24 | 2 | 64 | 12 KiB (24 KiB in FP32) | 48 MiB | 384 MiB |
| Llama-3-8B | 32 | 8 | 128 | 128 KiB | 0.5 GiB | 4 GiB |
| Qwen2.5-7B | 28 | 4 | 128 | 56 KiB | 224 MiB | 1.75 GiB |
| Llama-2-7B (MHA) | 32 | 32 | 128 | 512 KiB | 2 GiB | 16 GiB |
| Llama-3-70B | 80 | 8 | 128 | 320 KiB | 1.25 GiB | 10 GiB |

Concurrency makes it add up: Llama-3-70B at 64 concurrent 8k-token sequences needs 64 × 2.5 GiB = 160 GiB of KV — more than the weights. **Long context × many users is a memory problem, not a compute problem.**

### 2.3 Quantisation and KV are separate decisions
Quantising weights (AWQ/GPTQ/FP8) shrinks the weights. It does **not** shrink the KV cache. KV precision is its own knob: vLLM `--kv-cache-dtype fp8` (halves KV; needs hardware/kernel support and costs a little accuracy), llama.cpp `-ctk/-ctv q8_0` (`-ctv` needs flash attention). "We quantised the model and it still OOMs at high concurrency" is the usual symptom of forgetting this.

### 2.4 PagedAttention (vLLM)
Naive servers reserve `max_model_len` of contiguous KV per request: huge internal fragmentation (a 200-token chat holding space for 32k). vLLM's **PagedAttention** (Kwon et al., SOSP 2023) splits the KV cache into fixed-size **blocks** (default 16 tokens), keeps a per-sequence **block table** (like an OS page table), and allocates blocks on demand. Consequences:
- Waste is bounded to < 1 block per sequence; the same VRAM serves many more sequences (the paper reports 2-4x throughput over earlier systems at equal latency).
- Blocks can be **shared** between sequences with identical prefixes (prefix caching, parallel sampling with copy-on-write).
- When the pool runs out, the scheduler must **preempt**: in the V1 engine, a preempted sequence's blocks are freed and it is recomputed later (prefill again). Preemption shows up as `vllm:num_preemptions_total` increasing and as TTFT/ITL spikes: the early warning that you are over capacity (module 03).

### 2.5 How vLLM sizes the KV pool at startup (GPU)
At startup vLLM runs a profiling forward pass, then:

`KV pool = gpu_memory_utilization × total_VRAM − weights − peak_activations − non_torch_memory (NCCL, CUDA context, graphs)`

- `--gpu-memory-utilization` is the fraction of **this GPU's** total memory the instance may claim for all of it (weights + activations + KV). It is not "KV only" and it does not limit other processes. The documented default on the pinned line is **0.92** (older releases: 0.9) — check `vllm serve --help` for your version. If another process already holds memory, vLLM refuses to start when the requested fraction exceeds what is free (module 03 planted fault).
- `--kv-cache-memory-bytes` sets the KV pool size directly and overrides the utilisation-based sizing.
- Startup log lines to read: `GPU KV cache size: N tokens` and `Maximum concurrency for M tokens per request: X.XXx`. The second is just `N / M`: how many full-length requests fit.
- If the pool cannot hold even one `max_model_len` sequence, startup fails with: *"To serve at least one request with the model's max seq len (65536), (1.5 GiB KV cache is needed, which is larger than the available KV cache memory (1.0 GiB). Based on the available memory, the estimated maximum model length is …"*. Fixes: lower `--max-model-len`, raise utilisation or free the GPU, add TP, quantise KV or weights, use a bigger GPU. The real vLLM-CPU spike on this host produced exactly this error with 1 GiB of FP32 KV (24,576 B/token → 43,520 tokens usable in blocks of 16); mock-vllm replays it for the GPU-sized models in module 03.

## 3. Batching

| Scheme | Behaviour | Problem |
|---|---|---|
| **Static batching** | collect N requests, run them together until **all** finish | short requests wait for the longest; GPU idles as sequences end; new requests wait for the whole batch |
| **Continuous (iteration-level) batching** (Orca, 2022) | the batch is re-formed **every decode step**: finished sequences leave, waiting ones join | none of the above; the foundation of vLLM, TGI, SGLang, TRT-LLM, llama.cpp (`-cb`, on by default) |

A scheduler step in vLLM V1: take running sequences (decode, 1 token each) and fill the remaining **token budget** (`--max-num-batched-tokens`) with waiting requests' prefill. With **chunked prefill** (default in V1) a long prompt is split into chunks across steps, so one 30k-token prompt does not freeze everyone else's decode for seconds (it bounds the ITL spike). Knobs:
- `--max-num-seqs`: cap on sequences per step. Too low: queueing at low load. Too high: KV exhaustion → preemption, and ITL grows for everyone. 
- `--max-num-batched-tokens`: token budget per step. Larger → better prefill efficiency/throughput, worse ITL for concurrent decodes. Defaults depend on GPU and usage context (a few thousand to ~16k); read the startup log.
- Throughput vs batch size is concave: near-linear at first (weights read amortised), then flat once compute-bound; the latency keeps rising. Past the knee you pay latency for nothing.

### 3.1 llama.cpp's version of this: slots
`llama-server` has **slots** (`-np N` / `--parallel N`): N independent sequences decoded together with continuous batching. Facts you will use in the lab:
- **The context is shared across slots**: with the classic layout `-c 8192 -np 4` each slot gets 8192/4 = **2048 tokens**. A 3000-token prompt on a 2048-token slot fails or is truncated. Newer builds can share one unified KV buffer (`--kv-unified`); on any build check what `GET /slots` reports as `n_ctx` per slot and `GET /props`.
- `-np 1` serves requests strictly one at a time (others queue; `requests_deferred` in `/metrics`). `-np 4` decodes 4 together: aggregate throughput rises well above 1x, per-request speed drops somewhat.
- On a CPU the effect is smaller than on a GPU because a CPU is closer to compute-bound, but decode of a 0.5B model is still dominated by weight reads, so batching still pays. Measure it with counters, not a stopwatch.
- `-b` (logical batch) and `-ub` (physical micro-batch) bound how many prompt tokens are processed per step (the analogue of `max-num-batched-tokens`); `-t` threads; `--metrics` enables `/metrics`; `--slots` (on by default) `/slots`; `/props` shows the effective settings.
- Metrics available (b11889): counters `llamacpp:prompt_tokens_total`, `prompt_tokens_cached_total`, `prompt_seconds_total`, `tokens_predicted_total`, `tokens_predicted_seconds_total`, `n_decode_total`, gauges `requests_processing`, `requests_deferred`, `prompt_tokens_seconds`, `predicted_tokens_seconds`. **There is no KV-usage gauge** — llama.cpp cannot tell you "KV is 87% full" the way vLLM's `vllm:kv_cache_usage_perc` does; you watch `requests_deferred` and context errors instead.

## 4. Prefix (prompt) caching

If two requests start with the same tokens, the KV for that shared prefix is identical and need not be recomputed. Caching it removes the prefill cost: TTFT for the second request drops, and GPU time is saved.

- **vLLM** (Automatic Prefix Caching, on by default in V1): KV blocks are hashed by (parent hash, block tokens, extras); a new request reuses any matching leading blocks still in the pool; unreferenced blocks are evicted LRU when space is needed. Only **full blocks** are matched. Metrics: `vllm:prefix_cache_queries_total` / `vllm:prefix_cache_hits_total`.
- **llama.cpp**: the server keeps each slot's tokens; with `"cache_prompt": true` (the default in current builds) a new request is matched against the slot's cached tokens (longest common prefix) and only the rest is evaluated. The response reports it: `usage.prompt_tokens_details.cached_tokens`, `timings.cache_n` / `timings.prompt_n`; `/metrics` `prompt_tokens_cached_total`. The slot is chosen by prefix similarity, so repeated callers tend to land on their own cached slot.
- The match is a **strict prefix**: one different token early invalidates everything after it. This drives prompt design:
  1. Put **stable** content first (system prompt, tool definitions, the document), **volatile** content last (the user's question, timestamps, request ids).
  2. A timestamp or username at the top of the system prompt ("Current time: …") destroys the cache for every request. This is the most common real-world cause of "caching doesn't work".
  3. Deterministic serialisation: tool lists, JSON key order, whitespace must be identical across calls.
  4. Chat history that is only appended (never edited) keeps hitting the cache — which is why agent loops (each turn resends everything) are cheap *if* the engine caches.
- The cache is **per replica**. With N replicas behind round-robin the hit rate for a given prefix is ~1/N. Production answers: prefix-/KV-aware routing (llm-d, the vLLM production-stack router, Gateway API Inference Extension; consistent hashing on a prompt-prefix key as the poor-man's version) — module 05 touches on routing.
- Some APIs bill cached input tokens cheaper and report them (`cached_tokens`); gateways must read that field for correct cost accounting.
- On CPU-only vLLM prefix-cache hits are not reliable; do not infer anything from them here.

## 5. Quantisation

Weights are stored at lower precision to save memory and bandwidth. Common formats:

| Format | bits/weight (approx) | Where | Notes |
|---|---|---|---|
| FP32 | 32 | CPU debugging | 4 B/param |
| FP16 / BF16 | 16 | default on GPU | 2 B/param; BF16 needs Ampere+; vLLM-CPU on this host needs FP32 |
| **FP8** (E4M3) | 8 | H100/H200/Ada+ (native), Ampere via weight-only Marlin | ~1.5-2x speedups on decode-bound loads, <1% quality loss typical; also usable for KV (`--kv-cache-dtype fp8`) |
| INT8 (W8A8 / SmoothQuant) | 8 | most GPUs | needs calibration |
| **AWQ / GPTQ** (INT4 weight-only, group size 128) | ~4.25 | GPUs; Marlin kernels | 4x smaller than FP16; most speedup at small batch; dequantisation cost shows up at large batch |
| **GGUF k-quants** | Q8_0 8.5; Q6_K 6.56; Q5_K_M ~5.7; **Q4_K_M ~4.9** (mix of q4_K and q6_K tensors); Q4_0 4.5; Q2_K 2.6 | llama.cpp / CPU | self-describing single file; block-wise scales; "_M/_S/_L" = mixes of tensor types |

Block formats explain the odd bit counts: `Q8_0` = 32 int8 weights + one fp16 scale = 34 bytes per 32 weights = **8.5 bits/weight**; `Q4_0` = 32 nibbles + scale = 18 B/32 = 4.5 bpw.

Rules of thumb:
- Memory ≈ params × bits/8. 70B: FP16 140 GB (130 GiB), FP8 70 GB (65 GiB), INT4 ~37 GB (34 GiB incl. scales).
- Quality: INT8/FP8 ≈ lossless in practice; 4-bit costs a measurable but usually acceptable amount; below 4 bits degrades quickly (more on small models). Validate on **your** task, not on someone's leaderboard.
- Smaller does not automatically mean faster. Speed depends on whether your hardware has a kernel for that format. **On the lab's Neoverse-N1 (NEON + dot-product, no i8mm/bf16) we measured prompt processing ~3x faster for Q8_0 than for Q4_K_M** (about 180-225 vs 70-78 tok/s), while generation speed was noise-dominated. Why: prompt processing is compute-bound; Q8_0 maps directly onto int8 dot-product instructions with simple 32-weight blocks, whereas Q4_K must unpack 4-bit values and apply super-block scales and mins per 256 weights — more ALU work per multiply-accumulate. Decode is bandwidth-bound where the smaller file should help, but on a small model with 4 shared cores other effects drown it. On GPUs the same lesson appears differently: W4A16 kernels are great at batch 1-8 and lose ground at large batch (compute-bound, dequant overhead); FP8 needs hardware support to be a win.
- Formats and engines: vLLM loads safetensors in HF layout (FP16/BF16, FP8, AWQ, GPTQ, compressed-tensors); **GGUF support in vLLM is experimental**; llama.cpp needs GGUF. Converting is an offline, versioned step you own (module 02 treats the artefact).
- Quantisation changes behaviour slightly: re-run your evals and tool-calling tests after any change; a quantised model is a different model to the platform.

## 6. Sizing: will it fit?

A first-order budget per GPU:

`need = (weights + KV) / TP + overhead`, must be ≤ `util × GPU_memory`

- **weights** = params × bytes/param (use the format's real bytes: FP8 = 1, INT4 ≈ 0.53 with scales).
- **KV** = KV-bytes/token × max concurrent tokens (concurrency × average sequence length; use *max_model_len* for the worst case). With TP the KV is sharded across GPUs along the KV heads (while TP ≤ kv_heads).
- **overhead** ≈ activations for the largest batch, CUDA context and graphs, NCCL buffers, fragmentation: **1-4 GiB per GPU** is a sane first guess; the engine's startup profile gives the real value. Treat results within ±10% as "marginal".

### 6.1 Worked example: Llama-3-70B (FP16)
- Weights: 70e9 × 2 = 140e9 B = **130.4 GiB**. KV: 320 KiB/token → a 4k sequence is 1.25 GiB.
- **1 × 80 GiB**: impossible (weights alone exceed it).
- **2 × 80 GiB, TP=2, util 0.92**: usable 2 × 80 × 0.92 = 147.2 GiB; minus weights 130.4 = 16.8; minus overhead (2 × 2) = 12.8 GiB for KV → ~10 sequences of 4k or ~5 of 8k. Works, but "a handful of users": **marginal**.
- **4 × 80 GiB, TP=4**: 294.4 − 130.4 − 8 = 156 GiB of KV → ~125 sequences of 4k. Practical.
- **FP8 weights on 2 × 80 GiB**: weights 65.2 GiB → 147.2 − 65.2 − 4 = 78 GiB for KV → ~62 sequences of 4k. This is the common production compromise (plus FP8 KV doubles it again).
- Throughput, not only capacity, decides the real TP/replica count (section 6.3).

### 6.2 Tensor parallelism (TP)
TP shards every weight matrix across G GPUs (column-/row-parallel linear layers, attention heads split across GPUs); each layer needs **two all-reduces** (after attention, after MLP) over the GPU interconnect.
- **Constraint**: TP must divide `num_attention_heads`; for KV, TP should divide `num_key_value_heads` (if TP > kv_heads vLLM replicates KV heads, so KV no longer shrinks per GPU). Llama-3-70B: 64 heads / 8 KV heads → TP ∈ {1, 2, 4, 8}; TP=3, 5, 6, 7 are invalid; TP=16 would replicate KV heads and crosses nodes.
- **Interconnect decides whether TP pays**: NVLink on SXM boards (H100: 900 GB/s per GPU aggregate) makes TP=8 fine; PCIe Gen5 x16 (~64 GB/s per direction) makes TP=4+ painful for latency; across nodes use **pipeline parallelism** (PP) over InfiniBand, never TP.
- TP buys *capacity* (fit the weights) and *latency* (each GPU reads 1/G of the weights per step). It does not buy throughput efficiency: 2 GPUs at TP=2 serve fewer tokens/s per GPU than 2 independent replicas of a model that fits on one GPU. **Rule: use the smallest TP that fits (with KV headroom); scale out with replicas (data parallel).**
- MoE models add expert parallelism (EP): weights are big but only a few experts are active per token; memory still has to hold all experts. Out of scope except for sizing weights by *total* params.

### 6.3 Capacity planning beyond "fits"
1. Pick the model and precision → weights.
2. Pick context limits (`max_model_len`) and target concurrency → KV per sequence × sequences.
3. Choose GPU and the smallest TP that fits with ≥ 15-20% KV headroom.
4. Measure throughput under a realistic prompt/output length distribution (`vllm bench serve`, GuideLLM) at your SLOs → tokens/s per replica.
5. Replicas = peak tokens/s ÷ tokens/s per replica (plus N+1). Remember cold start: loading 140 GB at an effective 2 GB/s is >1 min, from a slow S3 several (module 02).

### 6.4 MIG for small models
A MIG-capable GPU (A100/H100/H200) can be partitioned into hardware-isolated slices with their own memory and SMs. Profiles (name = compute-slices.memory):
- A100/H100 **80 GB**: `1g.10gb`, `1g.20gb`, `2g.20gb`, `3g.40gb`, `4g.40gb`, `7g.80gb` (up to 7 slices).
- A100 **40 GB**: `1g.5gb`, `2g.10gb`, `3g.20gb`, `4g.20gb`, `7g.40gb`.
A slice is a small GPU: memory and bandwidth are proportional, a process can use **one** slice (no TP across slices; no NVLink between them). Good for embedding models, 1-8B quantised models, many small tenants with isolation. Sizing uses the same formula with the slice's memory (slightly less than the nominal number; the lab uses nominal). Time-slicing, which is *not* isolation, is module 09.

## 7. How teams run engines in production (and what bites)

A typical vLLM deployment, as flags (illustrative, not a recipe):
```
vllm serve /models/llama-3.1-70b-instruct-fp8 \
  --served-model-name chat-large --tensor-parallel-size 2 \
  --max-model-len 16384 --gpu-memory-utilization 0.92 \
  --max-num-seqs 128 --enable-auto-tool-choice --tool-call-parser llama3_json
```
- **One model instance per Deployment**, GPUs requested as `nvidia.com/gpu: <TP>`, weights from a node-local NVMe cache or an init step (module 02), `/dev/shm` sized generously (NCCL and multiprocessing use shared memory; the default 64 MB in a pod breaks TP), readiness probe on `/health`, a **long** startup probe (weight load + compile + CUDA-graph capture: 2-15 minutes).
- **`max_model_len` is a capacity decision**, not a model property: every token of allowed context is KV you must be able to hold for at least one request, and the worst-case request defines how many users you can admit. Setting it to the model's maximum (128k) "because the model supports it" is how a 70B instance ends up with room for 1-2 concurrent users.
- **Autoscaling on CPU or RPS does not work**; scale on queue depth (`vllm:num_requests_waiting`), KV usage, or TTFT. Scale-up takes minutes (cold start), so keep headroom or warm spares.
- **Warm-up**: first requests after start are slow (kernel autotuning, graph capture). Health says ready, latency says otherwise; send a few requests before putting the replica behind the gateway.
- **Graceful shutdown**: long streams mean a rolling update must drain; set `terminationGracePeriodSeconds` above your longest generation or clients see truncated streams.
- **Pitfalls checklist**
  1. Mixing GB and GiB in a sizing sheet; forgetting that "80 GB" GPUs are ~79.6 GiB usable.
  2. Sizing for weights only, then discovering concurrency 2.
  3. Setting `--gpu-memory-utilization 0.98` on a node where something else (another instance, a monitoring agent, a MIG/time-sliced neighbour) holds memory: startup OOM.
  4. Using TP across PCIe GPUs for a model that fits on one GPU.
  5. Cache-hostile prompts (timestamps first, tool lists in random order).
  6. Judging an engine by average latency; ignoring p95 TTFT and preemption counters.
  7. Benchmarking with identical short prompts: prefix cache and tiny contexts make every number too good.
  8. Assuming "OpenAI-compatible" means identical: `usage` details, streaming `usage`, `tool_choice` support, `max_completion_tokens` vs `max_tokens`, error codes and model-name handling differ per engine and version; test the client against the engine behind the gateway, not against the OpenAI docs.

### 7.1 Load testing in one paragraph
Use a tool that replays realistic input/output length distributions at fixed concurrency or request rate (`vllm bench serve`, GuideLLM) and records TTFT, ITL and E2E percentiles plus output tokens/s. Sweep concurrency; plot throughput vs p95 ITL; the knee is your operating point. Always run long enough to fill the KV pool, and once with prefix cache disabled to see the worst case.

## 8. Engine choice and what the lab simulates
- **llama.cpp (real, CPU)**: use it to *see* slots, prompt-cache counters, quantised file sizes, token counters. Its absolute speeds are CPU numbers.
- **mock-vllm (simulated)**: exposes vLLM's metric names (`vllm:num_requests_running`, `vllm:kv_cache_usage_perc`, `vllm:num_preemptions_total`, ...) and computes KV capacity from a model's real `config.json` geometry, so sizing questions have realistic answers; its latency is a model, not a measurement. Its exact behaviour is documented in `mock/README.md` (the contract).
- **Production**: vLLM on GPUs with real CUDA OOM behaviour, NCCL, CUDA graphs, real preemption. Never quote a lab latency as an expected production number.
- **Counters over clocks**: the lab is on a shared 4-core machine; wall-clock numbers move by +-30% between runs. Learn to read token counters, cache counters and file sizes (they are exact) and use timing only as a ratio between two runs made back to back.

## Key takeaways
1. Prefill is compute-bound and sets TTFT; decode is memory-bandwidth-bound and sets ITL. Batching amortises weight reads: throughput up, latency up.
2. KV per token = 2 × layers × **kv_heads** × head_dim × bytes. GQA/MLA shrink it; context length × concurrency grows it; weight quantisation does not touch it.
3. PagedAttention removes fragmentation; when the block pool is exhausted the engine preempts (recompute): watch `num_preemptions_total` and KV usage.
4. `--gpu-memory-utilization` is the fraction of this GPU the instance claims for weights + activations + KV; `max_model_len` must fit in the resulting KV pool or startup fails.
5. Continuous batching re-forms the batch each step; chunked prefill protects ITL from long prompts; `max_num_seqs` and `max_num_batched_tokens` are the throughput/latency dials.
6. Prefix caching is a strict-prefix match per replica: stable content first, volatile last, deterministic serialisation, prefix-aware routing at scale.
7. Quantisation is "memory ≈ params × bits/8" plus kernel support: smaller is not always faster (Q8 beat Q4_K_M on prompt processing on this CPU).
8. Sizing: `(weights + KV)/TP + overhead ≤ util × VRAM`; smallest TP that fits (must divide heads), replicas for throughput, MIG for small models. Use GiB consistently.

## Check yourself
1. Why does decoding 32 sequences together cost far less than 32x the time of decoding one, but prefilling 32 prompts together does not?
2. Llama-3-8B: how much KV does one 8k sequence need in FP16? What if the model were MHA? What if KV were FP8?
3. `-c 4096 -np 4` in llama-server: what is the longest prompt one request can have, and what would you change for 4 slots of 2048?
4. Your agent's requests all share a 6k-token system prompt but the prompt cache never hits. Name two likely causes.
5. A 70B FP16 model "fits" on 2 × 80 GiB at TP=2 — why do experienced teams still prefer FP8 on 2 GPUs or FP16 on 4?
