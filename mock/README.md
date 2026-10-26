# aiinfra-mock: course-owned simulators (contract)

Everything here is **simulated** (no GPU, no real model). Module text must say so and say how production differs. This file is the contract: names, flags, formulas and APIs below are fixed. Modules use them as written and do not re-document them.

Images: `aiinfra-mock:1.0` (`mock/Dockerfile`, FROM `python:3.12-slim`, deps in `requirements.txt`, runs as uid 10001, image label `course=aiinfra`) and `aiinfra-tripwire:1.0` (`mock/tripwire/Dockerfile`, FROM `alpine:3.20` + `apk add dnsmasq python3`; the apk step needs internet at build time only).

## 1. Roles and common conventions

`docker run aiinfra-mock:1.0 <role>`; role = first argument. HTTP on container port 8000 (env `MOCK_PORT`, `MOCK_HOST` override; tests use 127.0.0.1:18150-18199).

| Role | What | Mounts |
|---|---|---|
| `vllm` | OpenAI-compatible vLLM V1 look-alike with capacity model, scheduler, metrics, fault API | `/config` (args, gpu.yaml, script.yaml, fault.yaml); models fixtures are baked in at `/models/*` |
| `dcgm` | DCGM-exporter-compatible `/metrics` + fake `nvidia-smi` / `dmesg` inside the same container | `/config/gpus.yaml` (+ optional `fault.yaml`) |
| `hf-mirror` | HF-Hub-compatible read-only mirror of an HF cache dir | `/data` (HF cache layout), env `MOCK_DATA_DIR` |

- `GET /health` -> 200 when ready. `GET /metrics` for `vllm` and `dcgm`. Admin API under `/admin/*` (no auth, lab only).
- Config dir env `MOCK_CONFIG_DIR` (default `/config`). Compose overrides (WP2): `MOCK_VLLM_A_CONFIG_DIR`, `MOCK_VLLM_B_CONFIG_DIR`, `MOCK_DCGM_CONFIG_DIR`.
- Restart semantics: all runtime state (faults, stats, metrics) is in memory and lost on restart. Durable behaviour comes only from the files in `/config` (read at every start). Config is never written by the mock.
- All metric values are derived from a **virtual clock** (section 3.6), not from wall time.
- `nvidia-smi` and `dmesg` are only in the image; use `docker exec <dcgm-container> nvidia-smi ...`.

## 2. Config files

| File | Role | Format |
|---|---|---|
| `/config/args` | vllm | vLLM CLI flags, whitespace/newline separated, `#` comments allowed. Leading `serve` and a positional model are accepted. |
| `/config/gpu.yaml` | vllm | `name` (e.g. `A100-80GB`, `H100-80GB`, `L4`, `L40S`, `A10G`, `T4`; sets defaults), `memory_gib` per GPU (default 80), `count` (default 1), `other_process_gib` (memory held by other processes at startup, default 0), `mem_bandwidth_gbs`, `tflops` (defaults from `name`, A100-80GB: 2039 / 312). Missing file = one A100-80GB. |
| `/config/script.yaml` | vllm | optional scripted mode, section 3.8 |
| `/config/fault.yaml` | vllm | optional **initial** fault values (same keys as `/admin/fault`); the only way `slow_load_s` / `other_gpu_mem_gib` take effect at (re)start. dcgm: `faults: [ {gpu: 1, xid: 79}, ... ]` applied at start. |
| `/config/gpus.yaml` | dcgm | `hostname`, `driver_version` (570.124.06), `cuda_version` (12.8), `gpus:` either `{count: N, model, memory_mib, power_limit_w, util}` or a list of `{model, memory_mib, uuid, pci_bus_id, power_limit_w, util, mem_used_mib, sm_clock_mhz, pod, namespace, container}`. UUIDs default to a stable hash of hostname+index. |

## 3. mock-vllm

### 3.1 Flags (from `/config/args`)

Honoured: `--model` (local dir or HF repo id), `--served-model-name a [b ...]` (first name = `model_name` metric label; all names served; default = `--model`), `--max-model-len` (default = `max_position_embeddings`), `--gpu-memory-utilization` (default **0.92**), `--max-num-seqs` (256), `--max-num-batched-tokens` (8192), `--tensor-parallel-size` (1), `--kv-cache-dtype` (`auto`|`fp8`|`fp8_e4m3`|`fp8_e5m2`), `--enable-prefix-caching` / `--no-enable-prefix-caching` (default **on**, as V1), `--quantization` (`awq gptq gptq_marlin awq_marlin bitsandbytes int4`: 0.5625 B/param; `fp8 int8 compressed-tensors experts_int8`: 1 B/param), `--dtype` (`auto` -> bf16 unless the checkpoint says fp16/fp32 -> fp16; `float32`, `float16`, `bfloat16`), `--block-size` (16), `--seed` (0), `--api-key`, `--download-dir`, `--revision`. Any other flag is accepted and ignored. Mock-only: env `MOCK_TIME_SCALE` (default 1: virtual second = 1 real second; `0` = no pacing, as fast as possible), `MOCK_DEFAULT_OUTPUT_TOKENS` (64), `MOCK_EMBED_DIM` (384), `MOCK_STATS_N` (100), `MOCK_STRICT_MODEL` (0/1 force model-file checks off/on), `MOCK_VLLM_ARGS` (replaces the args file).
Env `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` is honoured like vLLM.

### 3.2 Capacity model (all formulas exact; `mock/aimock/capacity.py`)

Geometry from `<model>/config.json`: `hidden_size, num_hidden_layers, num_attention_heads, num_key_value_heads, head_dim (default hidden/heads), intermediate_size, vocab_size, tie_word_embeddings, max_position_embeddings, torch_dtype`.
Fixtures in `mock/models/` (also `/models/` in the image): `qwen2.5-0.5b` (0.49 B, KV 12,288 B/token bf16), `qwen2.5-7b` (7.62 B, GQA kv=4, 57,344 B/token), `llama-3.1-8b` (8.03 B, GQA kv=8, 131,072 B/token), `llama-3.1-70b` (70.5 B, kv=8, 327,680 B/token), `llama-2-7b-mha` (6.74 B, kv=32, fp16, 524,288 B/token, ctx 4096). Fixture dirs contain only `config.json`.

```
params            = vocab*h*(1 if tie else 2) + L*(h*heads*hd + 2*h*kv*hd + heads*hd*h + 3*h*inter + 2*h) + h
                    (replaced by the real tensor element count when safetensors files are present)
bytes/param (bpp) = dtype bytes (2 bf16/fp16, 4 fp32) or the quantization value above
weights_per_gpu   = params * bpp / TP
total             = gpu.memory_gib * GiB          requested = gpu_memory_utilization * total
activation        = max_num_batched_tokens*(h + 2*inter/TP)*dtype_bytes*2 + max_num_seqs*vocab*4
non_torch         = 0.6 GiB (+0.5 GiB if TP>1)
kv_memory         = requested - weights_per_gpu - activation - non_torch
kv_bytes/token    = 2 * layers * kv_heads * head_dim * kv_dtype_bytes          (whole model)
kv_bytes/token/gpu= 2 * layers * ceil(kv_heads/TP) * head_dim * kv_dtype_bytes
num_gpu_blocks    = floor(kv_memory / (kv_bytes/token/gpu * block_size))       (block 0 is the reserved null block)
usable_blocks     = num_gpu_blocks - 1       kv_cache_size_tokens = num_gpu_blocks * block_size
max_concurrency   = kv_cache_size_tokens / max_model_len
```
The values are exposed in `GET /admin/stats` (`capacity`) and in `vllm:cache_config_info` (`num_gpu_blocks`, `kv_cache_size_tokens`, `kv_cache_max_concurrency`, `kv_cache_memory_bytes`, `block_size`, `enable_prefix_caching`, `gpu_memory_utilization`).

### 3.3 Startup refusal (container exits **1**, error on stdout/stderr, no HTTP server)

Checked in this order; the text after `Error:` is what the log contains (`(EngineCore pid=38) ERROR [core.py:1433] <Type>: <text>`).

| Condition | Error |
|---|---|
| model path/repo missing, offline cache miss, unreachable `HF_ENDPOINT`, tokenizer/weights problems | section 3.4 |
| `num_attention_heads % TP != 0` | `ValueError: Total number of attention heads (28) must be divisible by tensor parallel size (3).` |
| `TP > gpu.count` | `ValueError: World size (4) is larger than the number of available GPUs (2) in this node. ...` |
| `max_model_len > max_position_embeddings` (and no `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`) | `ValueError: User-specified max_model_len (N) is greater than the derived max_model_len (max_position_embeddings=...` |
| `total - other_process_gib - other_gpu_mem_gib < requested` | `ValueError: Free memory on device cuda:0 (60.0/80.0 GiB) on startup is less than desired GPU memory utilization (0.92, 73.6 GiB). Decrease GPU memory utilization or reduce GPU memory used by other processes.` (real v1 text) |
| `weights_per_gpu > free` | `torch.OutOfMemoryError: CUDA out of memory. Tried to allocate ... GPU 0 has a total capacity of ...` (adapted) |
| `kv_memory <= 0` | `ValueError: No available memory for the cache blocks. Try increasing gpu_memory_utilization when initializing the engine.` (+ numbers) |
| `max_model_len` needs more KV than `(num_gpu_blocks-1)*block_size` | verbatim real text from vLLM 0.31.0: `ValueError: To serve at least one request with the model's max seq len (65536), (1.5 GiB KV cache is needed, which is larger than the available KV cache memory (1.0 GiB). Based on the available memory, the estimated maximum model length is 43520. Try increasing `gpu_memory_utilization` or decreasing `max_model_len` when initializing the engine. See https://docs.vllm.ai/en/latest/configuration/conserving_memory/ for more details.` with this model's numbers (the real log mentions "which also controls CPU memory on the CPU backend"; dropped here because the simulated backend is a GPU) |

Real vLLM defaults `max_model_len` to the model's context window, so e.g. `llama-3.1-70b` on 2 GPUs without `--max-model-len` really is refused. That is intended.

### 3.4 Model loading (HF repo id or local dir)

`--model X`: if `X` is a directory it is used as is. Otherwise `X` must be an HF repo id (`org/name`); it is resolved with the **real `huggingface_hub.snapshot_download`** (patterns `*.json *.txt *.model *.safetensors tokenizer* merges.txt vocab.*`), so `HF_HUB_OFFLINE`, `HF_HOME`, `HF_HUB_CACHE`, `HF_ENDPOINT`, `HF_TOKEN`, `HF_HUB_DISABLE_XET`, `--download-dir`, `--revision` behave genuinely:

| Situation | Behaviour |
|---|---|
| `HF_HUB_OFFLINE=1`, complete cache | starts; no network |
| `HF_HUB_OFFLINE=1`, files missing | exit 1: `OSError: We couldn't connect to '<endpoint>' to load the files, and couldn't find them in the cached files. Check your internet connection or see how to run the library in offline mode at 'https://huggingface.co/docs/transformers/installation#offline-mode'.` |
| not offline | contacts `HF_ENDPOINT` (default `https://huggingface.co`; DNS query visible to the tripwire). On the air-gap network it fails with the same OSError (class and message of the underlying hub error appended). With the hf-mirror it downloads and starts |
| repo not found | `OSError: <id> is not a local folder and is not a valid model identifier listed on '<endpoint>/models' ...` |
| local path that does not exist | `OSError: Incorrect path_or_model_id: '<path>'. Please provide either the path to a local folder or the repo_id of a model on the Hub.` |

Integrity checks run when the directory has any `*.safetensors` or `tokenizer*` file (or the model came from the hub; force with `MOCK_STRICT_MODEL=1`). Config-only fixture dirs skip them ("fixture mode", logged).

- tokenizer: needs `tokenizer_config.json` and (`tokenizer.json` or `vocab.json`+`merges.txt` or `tokenizer.model`). Missing -> `OSError: Can't load tokenizer for '<model>'. ... (missing file: tokenizer.json)`.
- weights: every shard (from `model.safetensors.index.json` `weight_map`, else `model.safetensors`) must exist (`OSError: Error no file named <shard> found in directory ...`), have a valid safetensors header whose offsets match the file size (`safetensors_rust.SafetensorError: Error while deserializing header: MetadataIncompleteBuffer`), and match its **sha256**: HF cache blob names that are 64-hex are the expected digest; for plain dirs a `SHA256SUMS` file is used when present. Mismatch -> `RuntimeError: Error loading checkpoint shard 'model.safetensors': sha256 mismatch (expected ..., file content hashes to ...)`. `metadata.total_size` in the index must equal the tensor bytes.
- The header gives the real **tensor count, element count (-> `params`) and dominant dtype**; geometry still comes from `config.json`.
- The startup log prints `Loaded safetensors headers: N shard(s), T tensors, X B params, dtype D`.

### 3.5 HTTP API

| Route | Notes |
|---|---|
| `GET /v1/models` | one entry per served name, with `max_model_len` |
| `POST /v1/chat/completions` | stream and non-stream; `usage` always present (stream: only with `stream_options.include_usage`, as vLLM); tools/`tool_calls` via script mode; `max_tokens`/`max_completion_tokens` |
| `POST /v1/completions` | `prompt` (str / list), `suffix`, `echo`, stream. **FIM**: when `suffix` is set or the prompt contains `<|fim_prefix|>`/`<fim_prefix>`-style sentinels the text returned is `FIM_ECHO prefix_chars=N suffix_chars=M sentinels=fim_middle,fim_prefix,fim_suffix model=<name>`; the request shape is also in `/admin/stats` (`fim`, `prompt_chars`, `suffix_chars`, `prefix_tail`, `suffix_head`) |
| `POST /v1/embeddings` | `float` and `base64` (the openai client default) formats; deterministic feature-hashing vectors (L2-normalised, dim `MOCK_EMBED_DIM`, default 384): texts sharing words have higher cosine, so a retrieval "known fact ranks first" works |
| `GET /health` | 200 (empty body) when ready; 503 while `slow_load_s` is running |
| `GET /version`, `GET /metrics` | |

- Every response `id` is unique (`chatcmpl-`/`cmpl-`/`embd-` + per-process boot nonce + counter + random); unique across restarts too. (LiteLLM uses it as SpendLogs primary key.)
- Tokens are counted by a **mock convention**: `ceil(utf8_bytes/4)` per text, +4 per chat message, +3 priming, tools JSON counted. Not a real tokenizer. Generated text is deterministic words, one token per word; `finish_reason` is `length` when `max_tokens` was given, else `stop` (default output 64 tokens). Header `x-mock-output-tokens: N` forces N output tokens (no `max_tokens`).
- Streaming: one SSE chunk per token (role chunk first, finish chunk, optional usage chunk, `data: [DONE]`).
- Errors use the vLLM shape `{"error":{"message","type","param","code"}}`: 404 unknown model (`The model \`x\` does not exist.`), 400 context overflow (`This model's maximum context length is N tokens. However, you requested T tokens (P in the messages, C in the completion). Please reduce the length of the messages or completion.`), 401 wrong `--api-key`, 503 while loading, 500 injected.

### 3.6 Scheduler, latency and the virtual clock

Continuous batching in steps on a **virtual clock** (starts at 0, advances only by simulated step time; idle time is not counted):
- Admission FIFO (preempted requests go to the front) while `running < max_num_seqs`, step token budget `max_num_batched_tokens` (chunked prefill) and free KV blocks cover the prompt (`ceil(prompt_tokens/block_size)`). A head-of-line request that does not fit waits (`num_requests_waiting`).
- Decode growth allocates a block when a sequence crosses a block boundary; with no free block the **newest running request is preempted** (blocks freed, goes back to waiting, recomputes prompt+generated tokens; `vllm:num_preemptions_total` and `vllm:request_num_preemptions`).
- Prefix caching (when enabled): block hashes (chain over the prompt text, `block_size*4` chars per block) are kept in an LRU; a new request's longest cached prefix is not recomputed -> `prefix_cache_queries_total` (+prompt tokens), `prefix_cache_hits_total` (+cached tokens), `prompt_tokens_by_source{source="local_cache_hit"}`, `usage.prompt_tokens_details.cached_tokens`, shorter prefill/TTFT. Eviction follows the LRU bound = usable blocks. With `--no-enable-prefix-caching` hits stay 0 (queries too).
- Step time: `decode = weights_per_gpu/(0.65*bw) + 1 ms + kv_bytes/token/gpu*sum(ctx)/(0.65*bw) + 20 us*running`; `prefill = tokens/prefill_tps` with `prefill_tps = 0.4*tflops*1e12*TP/(2*params)`. So ITL grows with running sequences and context; TTFT = queue + prefill (+ `latency_ms` fault).
- KV gauge = `(usable - free + pinned)/usable`; `pinned = int(kv_pressure*usable)` blocks held by the `kv_pressure` fault.
- Wall-clock pacing: the engine sleeps `virtual_dt / MOCK_TIME_SCALE` so clients and Prometheus see real occupancy (running/waiting/KV%). Histograms and counters use virtual seconds regardless of scale.

### 3.7 Metrics (names, types, labels, buckets identical to the golden vLLM 0.31.0 capture)

Generated from `mock/tests/golden/vllm-metrics-golden.txt` (spec: `aimock/vllm_metrics_spec.json`); test `test_metric_names_types_buckets_equal_golden` enforces equality. Labels `engine="0",model_name="<first served name>"` on all `vllm:*`. Counters expose `_total` and `_created`.

- gauges: `vllm:num_requests_running`, `vllm:num_requests_waiting`, `vllm:num_requests_waiting_by_reason{reason=capacity|deferred}`, `vllm:kv_cache_usage_perc` (0..1), `vllm:engine_sleep_state{sleep_state}`, `vllm:cache_config_info{...}`.
- counters: `vllm:prompt_tokens_total`, `vllm:prompt_tokens_by_source_total{source=local_compute|local_cache_hit|external_kv_transfer}`, `vllm:prompt_tokens_cached_total`, `vllm:generation_tokens_total`, `vllm:request_success_total{finished_reason=stop|length|abort|error|repetition}`, `vllm:num_preemptions_total`, `vllm:prefix_cache_queries_total`, `vllm:prefix_cache_hits_total`, `vllm:external_prefix_cache_{queries,hits}_total` and `vllm:mm_cache_{queries,hits}_total` (always 0), `vllm:estimated_{flops,read_bytes,write_bytes}_per_gpu_total`.
- histograms: `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, `vllm:request_time_per_output_token_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:request_queue_time_seconds`, `vllm:request_inference_time_seconds`, `vllm:request_prefill_time_seconds`, `vllm:request_decode_time_seconds`, `vllm:request_prompt_tokens`, `vllm:request_generation_tokens`, `vllm:request_max_num_generation_tokens`, `vllm:request_params_n`, `vllm:request_params_max_tokens`, `vllm:request_num_preemptions`, `vllm:request_prefill_kv_computed_tokens`, `vllm:iteration_tokens_total`.
- HTTP (prometheus-fastapi-instrumentator look-alike, only `/v1/*` handlers): `http_requests_total{handler,method,status=2xx|4xx|5xx}`, `http_request_size_bytes`, `http_response_size_bytes` (summaries), `http_request_duration_highr_seconds`, `http_request_duration_seconds{handler,method}`. Durations are virtual (e2e) for completions.
- plus the python client defaults (`python_gc_*`, `python_info`, `process_*`), as in the golden file.
- `vllm:gpu_cache_usage_perc` does not exist (removed upstream); use `vllm:kv_cache_usage_perc`.

### 3.8 Scripted "mock-chat" mode (`/config/script.yaml`)

Rules are evaluated top to bottom; the first whose `match` holds wins (all given keys must match). No rule matches -> normal generated text. File errors fail the start.

```yaml
rules:
  - name: weather                       # shown in /admin/stats last_requests[].rule
    match:                              # all optional
      endpoint: chat                    # chat | completions
      model: chat                       # requested model name
      last_role: user                   # role of the last message (user|tool|assistant)
      has_tool: get_weather             # a tool with this name is in request.tools
      user_regex: "weather in (?P<city>\\w+)"   # re.search on the last user message (or the prompt for /v1/completions)
      any_regex: "..."                  # re.search on the whole conversation
      header: {x-team: "^agents$"}      # header (case-insensitive name) regex
    # exactly one response kind:
    tool_calls:                         # -> finish_reason "tool_calls", ids "call_<hex>"; arguments dict is JSON-encoded
      - {name: get_weather, arguments: {city: "${city}"}}
    # content: "The tool returned {nonce}."
    # edit: {file: src/app.py, search: "def ${1}():", replace: "def ${2}():", lang: python, preface: "Here is the change."}
    usage: {prompt_tokens: 111, completion_tokens: 22}   # optional: fixed usage numbers for this rule
    nonce_regex: "nonce[\"'\\s:=_-]*([A-Za-z0-9_-]{6,})"  # optional (this is the default)
```

- Templates (in `tool_calls`, `content`, `edit`): `${1}`, `${name}` = groups of `user_regex`; `{nonce}` = group 1 (else the whole match, else the whole text) of `nonce_regex` applied to the **last tool message** (the standard "tool result nonce reaches the final answer" check); `{tool_result}`, `{last_user}`, `{model}`.
- `edit` renders an Aider SEARCH/REPLACE block: `<preface>\n\n<file>\n```<lang>\n<<<<<<< SEARCH\n<search>\n=======\n<replace>\n>>>>>>> REPLACE\n```\n`.
- `usage` overrides the reported numbers and the simulated generation length; without it usage is computed by the token convention (3.5). Requests still pass through the scheduler/metrics.
- Streaming works for text (one chunk per word-token) and tool calls (name chunk, arguments chunk, finish chunk).

### 3.9 Fault API

`GET /admin/fault` (read), `POST /admin/fault` (merge JSON), `DELETE /admin/fault` (reset all to defaults). Unknown keys -> 400.

| Key | Default | Effect |
|---|---|---|
| `latency_ms` | 0 | each request stalls this long (virtual) while holding its slot before prefill: raises TTFT/e2e/running, not queue time |
| `error_rate` | 0 | fraction 0..1 of requests answered HTTP 500 (`InternalServerError`), chosen deterministically from `--seed` and the request counter; applies to `/v1/*` only (not `/health`, `/metrics`) |
| `kv_pressure` | 0 | fraction 0..1 of KV blocks pinned -> `kv_cache_usage_perc` rises at once, preemptions and queueing under load |
| `crash` | false | true -> HTTP 500 for the triggering request, then the process exits 1 after 50 ms (restart policy decides what happens next) |
| `slow_load_s` | 0 | POST: `/health` and `/v1/*` return 503 for this many seconds from now. In `fault.yaml`: same, from process start |
| `other_gpu_mem_gib` | 0 | memory held by another process. **Takes effect at the next start** (via `fault.yaml`); at runtime it is stored and reported only (a running vLLM keeps its allocation) |

`GET /admin/stats` fields: `model`, `served_model_names`, `boot_id`, `seed`, `time_scale`, `requests` (`{model: {chat|completions|embeddings: n, status_<code>: n}}`), `tokens {prompt, completion}` (as reported in `usage`), `errors_injected`, `engine {virtual_time_s, running, waiting, kv_cache_usage, kv_peak_usage, free_blocks, usable_blocks, preemptions, completed, steps, prefix_cache_blocks}`, `capacity {...section 3.2 values...}`, `gpu`, `faults`, `script {enabled, rules}`, `last_requests` (last `MOCK_STATS_N`=100; each: `i, endpoint, model, headers` (all request headers, lower-cased, **including Authorization verbatim**), `stream, max_tokens, temperature, user, rule, prompt_tokens_est, tool_choice, n_tools, tools`; chat adds `n_messages, roles, system_chars, last_user` (first 200 chars); completions add `fim, prompt_chars, suffix_chars, prefix_tail, suffix_head`; embeddings `n_inputs, first_input`; `status`). `DELETE /admin/stats` clears these (not the Prometheus counters).

### 3.10 Determinism guarantees

Same `args`/`gpu.yaml`/`script.yaml`/seed and the same request sequence -> identical `/metrics` (all `vllm:*` and `http_*` samples) and identical `usage`, text and token counts. Excluded: `*_created`, `python_*`, `process_*`, response `id`/`created`. Caveat for concurrency: arrivals within a 20 ms collect window after the engine goes idle are batched and ordered by a hash of the prompt (so a burst released together is reproducible); requests arriving while the engine is busy join at the next step boundary, so their order relative to steps can depend on real arrival timing. Graded checks should use sequential load or a barrier-released burst and compare bounds, not exact equality, for bursts at `MOCK_TIME_SCALE=1`.

### 3.11 Not faithful to real vLLM

No weights, tokenizer or real generation (text is filler; token counts by convention); latency is a roofline-style model, not measured; no LoRA, speculative decoding, multimodal, logprobs, `n>1`, guided decoding; `/v1/chat` `max_tokens` default is 64, not "rest of the context"; preemption always recomputes everything (no swap); prefix cache is text-block based and independent of the KV pool; TP is modelled only as division of weights/KV and prefill compute (no communication cost); `other_gpu_mem_gib` and `slow_load_s` act at start; startup is instant apart from the optional `slow_load_s` (real vLLM takes minutes); metric families that exist in later vLLM versions but not in the golden capture are absent; `process_*` metrics describe the mock process.

## 4. mock-dcgm and fake nvidia-smi

`/metrics` renders the DCGM exporter default counter set for each GPU in `gpus.yaml`: `DCGM_FI_DEV_SM_CLOCK, MEM_CLOCK, MEMORY_TEMP, GPU_TEMP, POWER_USAGE, TOTAL_ENERGY_CONSUMPTION, PCIE_REPLAY_COUNTER, GPU_UTIL, MEM_COPY_UTIL, ENC_UTIL, DEC_UTIL, XID_ERRORS, POWER_VIOLATION, THERMAL_VIOLATION, CLOCK_THROTTLE_REASONS, FB_FREE, FB_USED, ECC_SBE_VOL_TOTAL, ECC_DBE_VOL_TOTAL, UNCORRECTABLE_REMAPPED_ROWS, CORRECTABLE_REMAPPED_ROWS, ROW_REMAP_FAILURE, NVLINK_BANDWIDTH_TOTAL` (all `DCGM_FI_DEV_*`) and `DCGM_FI_PROF_{GR_ENGINE_ACTIVE,PIPE_TENSOR_ACTIVE,DRAM_ACTIVE,PCIE_TX_BYTES,PCIE_RX_BYTES}`. Labels: `gpu, UUID, pci_bus_id, device (nvidia<i>), modelName, Hostname, DCGM_FI_DRIVER_VERSION` (+ `container, namespace, pod` when set in gpus.yaml). Types as the real exporter (counters: energy, replay, violations, ECC, remapped rows, nvlink, pcie bytes; the rest gauges). `FB_USED + FB_FREE = memory_mib`.

Baseline: util = `util` + 10*sin(2*pi*t/90 + i) (default `util` 40 + 7*(i mod 3)), temp = 38 + 0.3*util, power = 62 + (limit-62)*util*0.85, FB_USED = `mem_used_mib` (default 45% of memory), SM clock = `sm_clock_mhz` (1410), throttle reasons 0 (0x1 idle when util<1). `t` = seconds since process start. GPU load is **not** coupled to mock-vllm traffic.

Faults: `POST /admin/fault` body `{"gpu": 1 | [0,1] | "all" (default all), <fault>: value, ...}`; value `0|false|null` clears that fault. `GET /admin/fault` -> `{gpu: {faults}}`; `DELETE /admin/fault[?gpu=N]`.

| Fault | Value | Effect |
|---|---|---|
| `xid` | code | `DCGM_FI_DEV_XID_ERRORS` = code (sticks until cleared); xid 79 = fell off the bus: util 0, `nvidia-smi` prints `Unable to determine the device handle for GPU<bus>: Unknown Error` (exit 255); an `NVRM: Xid (PCI:...): <code>` line appears in `dmesg` and `GET /admin/xid-log`; xid 64 sets `ROW_REMAP_FAILURE` |
| `thermal` | `true` (92 C) or degC | temp = value, SM clock x0.57, power x0.7, throttle reasons `0x68` (HW slowdown | HW thermal | SW thermal), `THERMAL_VIOLATION` grows |
| `ecc` | `{"sbe": n, "dbe": m}` or `"sbe"`/`"dbe"` (=1) | absolute volatile totals; dbe>0 also `UNCORRECTABLE_REMAPPED_ROWS=1` |
| `vram_leak` | MiB per virtual minute | FB_USED grows from the fault time, capped at memory; FB_FREE shrinks |

Determinism: `GET /admin/state` is the shared JSON state; `POST /admin/clock {"t": 220}` freezes virtual time at 220 s (env `MOCK_DCGM_FREEZE=100` at start), `DELETE /admin/clock` resumes. With a frozen clock `/metrics` is byte-identical across runs.

`nvidia-smi` (in the image, reads `/admin/state` of the same container): default table, `-L`, `-i <idx|uuid|bus>`, `-q` (sections: FB Memory, Utilization, ECC Errors, Temperature, Power, Clocks, Clocks Event Reasons), `--query-gpu=<fields> --format=csv[,noheader][,nounits]` with fields `index name uuid pci.bus_id driver_version serial memory.total memory.used memory.free utilization.gpu utilization.memory temperature.gpu temperature.memory power.draw power.limit clocks.sm clocks.mem pstate clocks_throttle_reasons.active clocks_event_reasons.active ecc.errors.uncorrected.volatile.total ecc.errors.corrected.volatile.total ecc.mode.current` (units in the header as the real tool, e.g. `memory.used [MiB]`), `--query-compute-apps` (empty). Output ties to the same state as `/metrics`. `dmesg` prints only the NVRM Xid lines. If the server is down: the real "couldn't communicate with the NVIDIA driver" message, exit 9.

Not faithful: only the metrics above (no profiling-field families beyond those listed, no MIG, no per-process lines: "No running processes found"), smooth synthetic load, no Fan/persistence variance, `-q` is a subset, no `topo`, `-l` loops, XML.

## 5. hf-mirror

Serves an HF cache directory (`/data/models--org--name/{blobs,refs/main,snapshots/<sha>/...}`, also under `/data/hub/`). Read-only. Endpoints (those the pinned `huggingface_hub` 2.3.0 / `hf` uses; exact set from the WP0 spike):
1. `GET /api/models/{org}/{name}/revision/{rev}` -> `{id, sha, siblings:[{rfilename,size}]}` (`rev` = `main`, a ref, or the commit sha). `GET /api/models/{org}/{name}` = revision `main`.
2. `GET /api/models/{org}/{name}/tree/{sha}?recursive=true&expand=false` -> `[{type:"file",path,size,oid[,lfs]}]`.
3. `HEAD /{org}/{name}/resolve/{rev}/{path}` -> 200 with `Content-Length`, `ETag` (blob name), `X-Repo-Commit`, `Accept-Ranges` (+`X-Linked-Etag/Size` for sha256-named blobs).
4. `GET /{org}/{name}/resolve/{rev}/{path}` -> bytes, `Range` supported (206).
Also `GET /api/models/.../xet-read-token/...` -> 404 (use `HF_HUB_DISABLE_XET=1` in labs). Unknown repo/revision/entry -> 404 with `X-Error-Code: RepoNotFound|RevisionNotFound|EntryNotFound`.
Request log: `GET /admin/requests[?since=N]` -> `[{i, t, method, path, query, status, range, user_agent, host, authorization(bool)}]` (not `/health` or `/admin`), `DELETE /admin/requests`. Also one line per request on stdout.
Always use explicit `--include` patterns with `hf download` (decisions #8). Not faithful: no auth/gating, no LFS redirects, no datasets/spaces, no search/listing APIs.

## 6. tripwire (`aiinfra-tripwire:1.0`)

`dnsmasq` answers **every name** with `TRIPWIRE_IP` (default: the container's own first IP; set it to the static IP on the air-gap network, which is also where DNS clients must point) and logs queries; the Python process parses that log. Container port 8000:
- `GET /hits` -> `{host: n}`: DNS **A** queries per host since last reset (AAAA ignored so one lookup = one hit). This is the authoritative signal: HTTPS hosts are visible only here. `GET /hits?detail=1` -> `{dns, http, sni, queries}` (`http` = Host headers received on port 80, `sni` = TLS SNI seen on port 443, last 200 raw dnsmasq query lines).
- `DELETE /hits` -> reset. `GET /health`.
- Port 80: HTTP sink answering 200 `tripwire sink` to any method/path. Port 443: accepts TCP, records the SNI, closes (no TLS).
- env: `TRIPWIRE_IGNORE` (comma list not counted, default `host.docker.internal`), `TRIPWIRE_FORWARD` (comma list of domains forwarded to Docker DNS 127.0.0.11 and not counted, e.g. service names that must still resolve).
- Containers on an `internal: true` network cannot publish ports: reach `:8000` from a container on the same network (`docker run --network aiinfra-airgap ... curl http://tripwire:8000/hits`) or via the port published on the `aiinfra` side.

## 7. Tests

`mock/tests/run_tests.sh [pytest args]` (creates `mock/.venv-test` with uv on first use; unit/integration tests start servers as subprocesses on 127.0.0.1:18150-18199; docker tests run under `flock -w 1800 /tmp/aiinfra-course-lab.lock`, label `course=aiinfra`, ports 18190-18199, containers removed afterwards; `SKIP_DOCKER=1` skips them). Covered: capacity math and startup refusals, metric names/types/buckets/labels equal to the golden capture, determinism (two runs, identical `/metrics`), unique ids, streaming, FIM echo, embeddings, queueing/preemption/KV%, prefix caching, fault API (error_rate, latency, kv_pressure, crash, slow_load, other_gpu_mem), scripted mode, model loading (local dir, offline cache, sha mismatch, missing tokenizer, hf-mirror online, unreachable endpoint), dcgm metrics and faults, nvidia-smi outputs, hf-mirror incl. real `hf download`, image runs, `docker exec nvidia-smi`, tripwire DNS counting.
