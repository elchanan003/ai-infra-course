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

## 9. Worked sizing walk-throughs (do them with your own `sizing.py` afterwards)

All results in GiB, overhead 2 GiB per GPU unless stated.

**A. Llama-3.1-8B, BF16, one 24 GiB GPU, util 0.9, 8k context.**
| Step | Value |
|---|---|
| weights | 8.03e9 × 2 B = 16.06e9 B = **14.96 GiB** |
| budget | 24 × 0.9 = 21.6 GiB |
| KV pool | 21.6 − 14.96 − 2.0 = **4.64 GiB** |
| KV per token | 2 × 32 × 8 × 128 × 2 B = 131,072 B (128 KiB) |
| tokens in the pool | 4.64 GiB / 128 KiB ≈ 38,000 tokens |
| sequences of 8k | ≈ 4 |
Verdict: it fits, four concurrent 8k users. The usual fixes if that is too few: FP8 weights (7.5 GiB → pool 12 GiB → ~12 sequences), FP8 KV (doubles the token count), 4k context (doubles the sequences), or a 40-80 GiB GPU.

**B. Qwen2.5-7B, BF16, one 24 GiB GPU.** KV per token is 56 KiB (4 KV heads), less than half of Llama-3.1-8B's: the pool of 5.4 GiB holds ~100k tokens, i.e. ~12 sequences of 8k. Two models of the same "size" differ 2.3x in concurrency purely because of the KV-head count: always compute from `config.json`.

**C. Llama-3.1-70B, FP16, KV FP16, 2 × 80 GiB, TP=2, util 0.92, 8k context, overhead 2 GiB per GPU.**
| Step | Per GPU |
|---|---|
| weights / 2 | 130.4 / 2 = 65.2 GiB (the model uses 70.55e9 params: 131.4 GiB total, 65.7 per GPU) |
| budget | 80 × 0.92 = 73.6 GiB |
| KV pool | 73.6 − 65.7 − 2.0 ≈ **5.9 GiB per GPU** → 11.8 GiB across the pair |
| KV per sequence (8k) | 320 KiB × 8192 = 2.5 GiB total = 1.25 GiB per GPU |
| sequences | 5.9 / 1.25 ≈ **4** |
Verdict: "fits" but four users. With FP8 weights: pool ≈ 38.5 GiB per GPU → ~30 sequences. With TP=4 FP16: per GPU weights 32.9 GiB, pool ≈ 38.7 GiB → ~30 sequences and half the per-token latency. Which is cheaper depends on GPU count, not on fit.

**D. The same model on MIG.** A 7g.80gb slice is a whole 80 GiB GPU; a 3g.40gb slice holds an 8B FP8 model (7.5 GiB) plus KV for tens of sequences; a 1g.10gb slice holds a 3B-4B model with a short context or an embedding model. Slices cannot be pooled for one process, so MIG is for **many small models**, not for fitting a big one.

## 10. Reading an engine: logs and metrics you should recognise

### 10.1 vLLM start-up (GPU), lines to look for
```
Loading weights took 14.2 seconds ... Model loading took 14.99 GiB
Memory profiling takes 6.3 seconds
the current vLLM instance can use total_gpu_memory (79.65GiB) x gpu_memory_utilization (0.92) = 73.28GiB
model weights take 14.99GiB; non_torch_memory takes 0.13GiB; PyTorch activation peak memory takes 1.35GiB;
  the rest of the memory reserved for KV Cache is 56.81GiB.
GPU KV cache size: 465,360 tokens
Maximum concurrency for 8,192 tokens per request: 56.81x
Capturing CUDA graphs ...
```
(Wording varies between versions; the structure — weights, non-torch, activation peak, remainder for KV, tokens, concurrency — is stable.) The **remainder for KV** line is the number your sizing sheet should predict; if your estimate and this line differ by more than ~10%, find out why (overhead guess, TP split, FP8 KV, quantised weights counted at the wrong width).

### 10.2 vLLM metrics and what each is for
| Metric | Reads as | Alert on |
|---|---|---|
| `vllm:num_requests_running` | sequences being decoded now | near `max_num_seqs` for long periods |
| `vllm:num_requests_waiting` | admission queue length | non-zero for minutes; the autoscaling signal |
| `vllm:kv_cache_usage_perc` | fraction of KV blocks in use (0-1) | > 0.9 sustained |
| `vllm:num_preemptions_total` | recompute events | any sustained rate |
| `vllm:prefix_cache_hits_total` / `..._queries_total` | prefix cache hit ratio | collapse after a prompt change |
| `vllm:time_to_first_token_seconds` | TTFT histogram | p95 vs SLO |
| `vllm:inter_token_latency_seconds` | ITL histogram | p95 vs SLO |
| `vllm:request_queue_time_seconds` | time waiting before prefill | separates "queue" from "prefill" in TTFT |
| `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` | token throughput (use `rate()`) | capacity planning |
(Module 03 and 08 use these; mock-vllm exposes the same names with simulated values.)

### 10.3 llama.cpp (b11889) load log and metrics
- Load log: `print_info: file type = Q4_K - Medium`, `file size = ... (... BPW)`, `llama_model_loader: - type q4_K: N tensors` lines (which tensor types the file contains), context and slot lines (`n_ctx_seq` / slots). Task 1.5 reads these.
- `/metrics` counters used in this module: `llamacpp:tokens_predicted_total`, `llamacpp:prompt_tokens_total`, `llamacpp:prompt_seconds_total`, `llamacpp:prompt_tokens_cached_total`; gauges `requests_processing`, `requests_deferred`. Throughput = Δcounter / Δtime; **never** multiply a single request's tokens by guessed time.

## 11. The scheduler, step by step (vLLM V1 model; mock-vllm implements the same shape)

State: a **waiting** queue (FIFO, preempted requests go to the front), a **running** set, a pool of free KV blocks. Each step:
1. Every running sequence gets one decode token (1 token of budget each). If a sequence needs a new block and none is free, the **newest** running sequence is preempted (its blocks are freed; it returns to waiting and will recompute prompt + generated tokens).
2. The remaining token budget (`max_num_batched_tokens` minus the decode tokens) is given to the head of the waiting queue as a prefill chunk, if its prompt blocks can be allocated and `running < max_num_seqs`.
3. The step runs; sequences that hit EOS/`max_tokens` leave and free blocks.

Worked example with `max_num_batched_tokens = 2048`, `max_num_seqs = 256`: 120 sequences are decoding (120 tokens of budget), a new request with a 9,000-token prompt arrives. It gets 1,928 tokens of prefill in step 1, 1,928 in step 2, ... five steps in total; during those steps each running stream still receives one token per step, but each step takes longer (it does prefill work too), so **ITL rises for everyone** for ~5 steps and the newcomer's TTFT is about 5 steps long. With a budget of 8192 the same prompt takes two steps: lower TTFT for the newcomer, a bigger ITL bump for everyone else. This is the trade-off `max_num_batched_tokens` controls.

Head-of-line blocking: the waiting queue is FIFO. A request whose prompt does not currently fit in free blocks blocks those behind it even if they are tiny. Under KV pressure you therefore see queueing of small requests behind one large one: another reason to cap context length per tenant at the gateway.

Preemption cost: a preempted 6k-token sequence is prefilled again, consuming budget that waiting requests needed; preemption feeds on itself near the capacity edge (more recompute → less budget → longer queue → more KV held by waiting-but-prefilled work). That is why preemptions appearing at all is an alert, not a statistic.

## 12. Latency and throughput arithmetic

TTFT ≈ queue + prefill = queue + prompt_tokens / prefill_rate. Prefill rate is roughly `0.4 × peak FLOPs × TP / (2 × params)` tokens/s for a well-batched engine (the mock uses this model): an 8B model on a GPU with 990 dense BF16 TFLOP/s gives about 25,000 prompt tokens/s per GPU, so a 3,000-token prompt prefills in ~120 ms when unqueued.

ITL(batch) rises slowly with batch size while memory-bound. Illustrative numbers (8B BF16 on one H100-class GPU, not a benchmark):
| Concurrent sequences | ITL | Aggregate tokens/s |
|---|---|---|
| 1 | 7 ms | 143 |
| 16 | 9 ms | 1,780 |
| 64 | 14 ms | 4,570 |
| 128 | 22 ms | 5,820 |
| 256 | 40 ms | 6,400 |
The curve flattens: going from 128 to 256 sequences adds 10% throughput and nearly doubles ITL.

SLO-driven sizing example: SLO p95 ITL ≤ 25 ms and p95 TTFT ≤ 1.5 s; load 40,000 output tokens/s at peak. From the table the operating point is ~128 sequences per GPU (≈5,800 tok/s) → 40,000 / 5,800 ≈ 7 GPUs, plus N+1 → 8. Check the KV side: 128 sequences × 4k average tokens × 128 KiB = 64 GiB, which does not fit next to 15 GiB of weights on an 80 GiB GPU at util 0.92 (73.6 − 15 − 2 = 56.6 GiB): the KV capacity, not the compute, caps the batch at ~110 → recompute with ~110 sequences per GPU (~5,500 tok/s) → 40,000 / 5,500 = 7.3 → 8 GPUs, plus N+1 → 9. **Always run both checks: the compute/latency curve and the KV budget; the binding constraint decides.**

## 13. Prefix caching: details that matter in production
- vLLM hashes full blocks (block size 16 by default) chained with the parent hash, so a block matches only if **all earlier blocks matched too**; the last partial block is never cached. A 6,000-token shared prefix caches 5,984 tokens.
- Eviction is LRU among blocks with zero references; under memory pressure the cache is the first thing to give way, so hit rates fall exactly when load rises.
- Anything that changes the token stream before the shared part changes the hash: different system prompts per tenant, a different chat template or tokenizer revision, LoRA adapters (adapter id is part of the hash), multimodal inputs.
- **Multi-tenant caution**: a cache hit is observable as a lower TTFT, so tenants sharing a cache can in principle probe for each other's prompts. Recent vLLM versions accept a per-request cache salt to isolate tenants; decide this explicitly for shared deployments.
- Gateways can help: some route requests with the same prefix hash to the same replica; LiteLLM itself does not do prefix-aware routing, dedicated routers do (module 05 mentions them).
- Measure it: `rate(prefix_cache_hits_total) / rate(prefix_cache_queries_total)` per engine, plus TTFT split by "cached vs not". A prompt-template change is the most common cause of a sudden drop.

## 14. Quantisation in practice
- **Calibration**: AWQ and GPTQ need a small calibration set to choose scales/rounding (use text close to your workload); FP8 dynamic quantisation needs none, static FP8 uses calibrated activation scales. A quantised checkpoint is an artefact you produce and version (module 02), not a flag.
- **Method trade-offs**: GPTQ (layer-wise error minimisation) and AWQ (protects salient channels) give similar 4-bit quality with different kernel stories; FP8 is nearly lossless where supported; INT8 weight+activation (SmoothQuant) helps compute-bound serving on hardware without FP8.
- **GGUF names**: `Q4_K_M` = 4-bit k-quant, "medium" mix (some tensors at higher precision); `Q5_K_M`, `Q6_K`, `Q8_0` trade size for fidelity; IQ-types use lookup tables for very low bit widths; an **imatrix** (importance matrix from calibration text) improves low-bit quality at the same size.
- **KV quantisation** (`--kv-cache-dtype fp8`, llama.cpp `-ctk q8_0 -ctv q8_0`): halves KV memory, small accuracy loss that grows with context length; test on long-context tasks, not on short prompts.
- **Evaluation checklist before promoting a quantised model**: (1) your own task set, not only perplexity; (2) tool-calling and JSON-validity rates; (3) long-context retrieval; (4) latency/throughput on the target GPU with the real prompt mix; (5) a rollback artefact. A 1% average drop can be a 20% drop on one critical task.
- **What speeds up**: decode-bound loads at low batch (less memory to read); **what does not**: compute-bound prefill without hardware support for the low-precision matmul, and large-batch decode where dequantisation overhead appears. The lab's Q8-vs-Q4 result is the CPU version of this lesson.

## 15. Serving failure modes (and the first command to run)
| Symptom | Likely cause | First look |
|---|---|---|
| Fails at start with "max seq len larger than KV cache" | `max_model_len` > KV pool | start-up log: KV tokens vs `max_model_len` |
| Fails at start with "free memory less than desired utilisation" | another process holds GPU memory | `nvidia-smi` (module 09) |
| Starts, then CUDA OOM under load | utilisation too high (activations spike), fragmentation, a larger batch than profiled | lower `--gpu-memory-utilization`, `--max-num-batched-tokens` |
| Throughput fine, p99 TTFT terrible | head-of-line blocking behind long prompts, preemption | waiting queue, preemption counter, per-request prompt length |
| Throughput collapses after a deploy | prefix cache hit rate fell, or a quantisation/kernel change | cache hit ratio, engine version diff |
| Streams stall for seconds then continue | a long prefill is occupying the step budget | `max_num_batched_tokens`, chunked prefill setting |
| One replica slower than its siblings | thermal throttling, ECC, noisy neighbour (time-slicing) | DCGM clocks/temperature (module 09) |
| Memory grows until restart | leak in the engine/client, unbounded concurrent long contexts | KV and process memory over days |

## 16. How the lab maps to this theory
| Task | Concept | Section |
|---|---|---|
| 1.1, 1.2 | KV and weight formulas, GiB, GQA, head_dim | 2, 6, 9 |
| 1.3 | slots, continuous batching, aggregate throughput from counters | 3, 3.1, 12 |
| 1.4 | strict-prefix cache, prompt layout | 4, 13 |
| 1.5 | quantisation formats, kernels vs size | 5, 14 |
| 1.6 | TP divisibility, MIG profiles, headroom | 6.2, 6.4 |
| 1.7 | debugging a calculator (units, KV heads, TP split) | 2.1, 6 |

## 17. Flag reference for sizing work

### 17.1 vLLM (serve) flags that move memory or latency
| Flag | Effect | Typical use |
|---|---|---|
| `--tensor-parallel-size N` | shard weights and KV across N GPUs | smallest N that fits with headroom |
| `--pipeline-parallel-size N` | split layers across stages (multi-node) | only when TP across nodes would be needed |
| `--gpu-memory-utilization F` | fraction of one GPU's memory the instance may claim | 0.90-0.95; lower when sharing a GPU or when activations spike |
| `--kv-cache-memory-bytes B` | fixed KV pool size, overrides the utilisation-based sizing | when several instances share a GPU |
| `--max-model-len L` | longest prompt+completion admitted | set from the product requirement, not the model maximum |
| `--max-num-seqs N` | cap on sequences per step | tune against KV capacity and ITL SLO |
| `--max-num-batched-tokens N` | per-step token budget (chunked prefill) | larger = better prefill throughput, worse ITL |
| `--kv-cache-dtype fp8` | KV in FP8 | doubles KV capacity; validate accuracy |
| `--quantization <method>` (awq, gptq, fp8, ...) | weight format (usually auto-detected) | match the checkpoint |
| `--enable-prefix-caching` / `--no-enable-prefix-caching` | prefix cache (on by default in V1) | disable only to measure the worst case |
| `--block-size N` | KV block size in tokens (default 16) | rarely changed |
| `--served-model-name a b` | names the API accepts | stable names behind the gateway |
| `--enable-auto-tool-choice --tool-call-parser P` | tool calling | per model family |

### 17.2 llama-server flags used in the lab
| Flag | Effect |
|---|---|
| `-m FILE` | the GGUF to load (`-hf REPO` downloads: never in an air gap) |
| `-c N` | total context; with the classic layout split across slots |
| `-np N` / `--parallel N` | number of slots (concurrent sequences) |
| `-t N`, `-tb N` | generation / batch threads |
| `-b N`, `-ub N` | logical / physical batch size for prompt processing |
| `-ctk TYPE`, `-ctv TYPE` | KV cache types (`f16`, `q8_0`, `q4_0`; V quantisation needs flash attention) |
| `--metrics` | enable `/metrics` |
| `--embeddings --pooling cls` | embedding mode |
| `--jinja` | use the model's Jinja chat template (needed for tools) |
| `--alias NAME` | model name reported by the API |
| `--cache-reuse N`, `--slot-prompt-similarity F`, `--slot-save-path DIR` | partial KV reuse, slot selection by prefix similarity, save/restore slot state |

## 18. A capacity worksheet you can reuse
Fill one row per model deployment; every cell is a number you can defend.
| Item | How to get it | Example (Llama-3.1-70B FP8, 2 × H100-80) |
|---|---|---|
| params, bytes/param | `config.json`, quantisation format | 70.55e9, 1 → 65.7 GiB |
| layers, kv_heads, head_dim | `config.json` | 80, 8, 128 |
| KV dtype → bytes/token | formula | FP16 → 320 KiB; FP8 → 160 KiB |
| required `max_model_len` | product requirement | 16,384 |
| average and p95 sequence length | gateway logs | 3k / 12k |
| target concurrent sequences | peak users × activity | 40 |
| KV needed | seqs × average length × bytes/token (+ headroom for p95 tail) | 40 × 3k × 160 KiB = 18.3 GiB (+ tail) |
| GPU memory × util, overhead | hardware, engine log | 2 × 80 × 0.92, 2 GiB each |
| TP | smallest valid that fits | 2 |
| tokens/s per replica at SLO | load test | 2,500 |
| replicas | peak tokens/s ÷ per-replica + N+1 | 5,000 / 2,500 + 1 = 3 |
| cold start | weights size ÷ effective bandwidth | 70 GB ÷ 2 GB/s ≈ 35 s + start-up ≈ 3-5 min |
Two numbers from this table decide most reviews: **KV needed vs KV pool** and **tokens/s per replica at the SLO**.

## 19. Common misreadings (and the fix)
- "The model is 8B so it needs 16 GB": the weights do; the **service** needs weights + KV for the users + overhead.
- "Concurrency 64 means 64 requests per second": it means 64 sequences alive at the same time; requests per second = concurrency / mean request duration.
- "The GPU is 95% utilised so we are out of capacity": `GPU_UTIL` only says a kernel was running in the sample window; a memory-bound decode loop shows ~100% while using a fraction of peak FLOPs. Saturation is read from queue time and KV usage (module 08/09).
- "More replicas always lower TTFT": only if the bottleneck is queueing; if prefill dominates (long prompts), more replicas help throughput but not the single request's TTFT, and they split the prefix cache.
- "Quantise more to make it faster": only when the format has an efficient kernel on that hardware and the workload is memory-bound; measure.
- "Our benchmark shows 5,000 tok/s": with which prompt/output lengths, cache state, concurrency and SLO? A number without those is not a capacity.

## 20. Incident walk-throughs (what you would see, in the order you would look)

### 20.1 "TTFT doubled after the weekend deploy"
1. Is it queueing or prefill? Compare `vllm:request_queue_time_seconds` (histogram, time spent in WAITING) with `vllm:request_prefill_time_seconds`. Queue time up, prefill flat means admission pressure; prefill up means longer prompts or a lost prefix cache.
2. Check `vllm:gpu_prefix_cache_hit_rate` (or hits/queries counters): a drop from 0.8 to 0.0 after a deploy usually means the prompt template changed (a timestamp or request id near the top), or the router stopped being prefix-aware and spreads sessions across replicas.
3. Check `vllm:num_requests_waiting` and `vllm:gpu_cache_usage_perc`. Waiting > 0 with KV usage near 1.0 means the KV pool is the limit: a longer `max_model_len` or fewer GPUs per replica shrank the pool.
4. Only then look at hardware (clock throttling, a neighbour process on a time-sliced GPU).
In the lab, mock-vllm exposes the same metric names, so you rehearse this reading order on counters, not on wall-clock.

### 20.2 "The server starts, then every long request is rejected"
- vLLM refuses to start when `max_model_len` needs more KV than the pool holds ("The model's max seq len (N) is larger than the maximum number of tokens that can be stored in KV cache (M)"). That is the friendly failure. The unfriendly one is a pool that fits exactly one maximum-length sequence: the server starts, but concurrency is 1 and everything else queues.
- Fix order: lower `--max-model-len` to what the product needs (not what the model advertises), raise `--gpu-memory-utilization` only if nothing else lives on the GPU, quantise the KV (`--kv-cache-dtype fp8`) or add TP. Quantising the weights helps only indirectly, by freeing bytes for the pool.
- llama.cpp analogue (lab 1.3): `-c 4096 -np 4` gives each slot 1024 tokens; a 1800-token prompt gets a 400 error. The context is divided, not shared.

### 20.3 "Throughput is great in the benchmark, terrible in production"
Typical causes, in order of frequency: the benchmark used identical prompts (everything is a prefix-cache hit); the benchmark used short outputs (decode never dominates); the benchmark ran one replica while production routes round-robin and splits the cache; the benchmark measured average latency of streams, hiding a slow first token. A load test is only a capacity number if it states prompt length distribution, output length distribution, concurrency, cache state and the SLO it was checked against.

### 20.4 "OOM after hours of running fine"
On real GPUs, KV is pre-allocated, so a steady-state OOM is almost never "KV grew". Suspects: activation spikes from an unusually large `max_num_batched_tokens` batch, a LoRA adapter loaded at runtime, CUDA graph capture at a new batch size, a sidecar process (profiler, a second engine) taking memory the utilisation fraction assumed was free, or fragmentation in the non-KV allocator. Look at `nvidia-smi` per-process memory first, then engine logs around the OOM; teach the learner that the utilisation flag budgets only this instance.

## 21. Three arithmetic drills (check with your own `sizing.py`)
1. **GQA payoff.** A 32-layer model with 32 attention heads, 8 KV heads, head_dim 128, FP16 KV. Per token: 2 x 32 x 8 x 128 x 2 = 131,072 B = 128 KiB. An 8k sequence: 1 GiB. Same model as MHA (32 KV heads): 4 GiB per 8k sequence. On a 24 GiB card with ~8 GiB left for KV, that is 8 sequences versus 2.
2. **Concurrency from a budget.** 80 GiB GPU, util 0.90, 14 GiB weights, 3 GiB overhead: pool = 72 - 14 - 3 = 55 GiB. At 1 GiB per 8k sequence that is 55 simultaneous full-length sequences; real chat traffic averages maybe 1.5k tokens, so the same pool carries several hundred sequences, which is why `max_num_seqs` (default 256 in V1) becomes the next limit.
3. **Throughput bound from bandwidth.** Decode reads all weights once per step. 14 GiB weights on a 2 TB/s card: at best 2000/14.0 ~ 140 steps per second per batch; at batch 32 that is ~4,500 tok/s before KV reads and kernel overheads. The same weights on a 60 GB/s CPU memory system give ~4 steps/s, which is why the lab measures *ratios* (batch 4 vs batch 1) and not absolute speeds.

## 22. What to say when someone proposes...
- "Let's just raise `--gpu-memory-utilization` to 0.98": ask what else is on the GPU (monitoring agents, a second model, MIG neighbours) and what the headroom for activation spikes is. 0.90 is the common default for a reason.
- "Use the biggest context the model supports": every extra token of `max_model_len` is a requirement on the pool at startup and a cost in worst-case scheduling; size to the 99th percentile of real prompts plus output.
- "Swap in a 4-bit model, it is cheaper": cheaper in weights; check quality on your eval set, kernel support (Marlin, FP8 needs Hopper/Ada or later), and that KV did not change.
- "Run two engines on one GPU": time-slicing gives no isolation and no memory partitioning; MIG does (on supported cards) but fixes the slice sizes.

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
