# vLLM flags and metrics cheatsheet (0.31/0.32)

Defaults are version- and hardware-dependent: read the startup log line `non-default args` and `vllm serve --help` of the pinned image. Values below are the docs' defaults at the pin unless marked.

## Flags
| Flag | Effect / default | Raise it when | Lower it when |
|---|---|---|---|
| `--model`, `--served-model-name` | weights; name clients use (label `model_name`) | | |
| `--max-model-len` | per-request cap prompt+output; sizes startup check | product needs more context (KV permitting) | KV error at startup, KV tight |
| `--gpu-memory-utilization` | fraction of this GPU this instance may claim (default **0.92**); weights+act+KV | dedicated GPU, need KV (≤0.95) | shared GPU / startup refuses / OOM at runtime |
| `--kv-cache-memory-bytes` | sets KV pool directly, overrides util logic | reproducible sizing | |
| `--kv-cache-dtype` | `auto`; `fp8` halves KV bytes | KV-bound | accuracy issues |
| `--max-num-seqs` | running-batch size (default hardware-dependent; historically 256) | queue with `running==cap`, KV has room | preemptions, ITL SLO |
| `--max-num-batched-tokens` | per-step token budget (decode + prefill chunk) | long-prompt TTFT bad, ITL slack | ITL spikes, activation memory |
| `--tensor-parallel-size` | shard weights/KV across GPUs; must divide heads | model doesn't fit | NCCL/PCIe overhead dominates |
| `--pipeline-parallel-size` | layers across GPUs/nodes | multi-node | |
| `--enable-prefix-caching` | reuse KV of identical prefixes (default on in V1) | | |
| `--block-size` | tokens per KV block (16 GPU, 128 CPU build) | | |
| `--enforce-eager` | no CUDA graphs (less memory, slower decode) | debugging | |
| `--quantization` / `--dtype` | awq/gptq/fp8; bf16/fp16/float32 (CPU lab: float32) | | |
| `--enable-auto-tool-choice --tool-call-parser <p>` | tool calling needs both; parser per model family | | |
| `--api-key`, `--host`, `--port` | auth (not on `/metrics`, `/health`); bind | | |
| `--scheduling-policy priority` | priority-based admission/preemption | | |
| `--generation-config` | `auto` uses model's generation_config.json sampling defaults | | |
| `--speculative-config` | speculative decoding | low-batch ITL | high batch |
Env: `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` (len above model config), `VLLM_CPU_KVCACHE_SPACE=<GiB int>` (CPU KV), `HF_HUB_OFFLINE=1`, `HF_HOME`.

## Startup errors
| Message (shape) | Meaning | Fix |
|---|---|---|
| `To serve at least one request with the model's max seq len (N), (X GiB KV cache is needed, which is larger than the available KV cache memory (Y GiB). Based on the available memory, the estimated maximum model length is M. Try increasing gpu_memory_utilization … or decreasing max_model_len` | one max-len sequence doesn't fit KV pool | lower `--max-model-len` ≤ M, raise util, fp8 KV, TP, bigger GPU |
| `Free memory on device … on startup is less than desired GPU memory utilization (…)` | other process holds GPU memory | lower util or free the GPU |
| `RuntimeError: Engine core initialization failed … Failed core proc(s): {}` | generic wrapper | read the ERROR above it |
| TP does not divide heads | invalid `--tensor-parallel-size` | choose a divisor of KV heads |
| `max_model_len > model max position embeddings` | context beyond model config | lower it or `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` knowingly |

## Metrics (`/metrics`, labels `engine`, `model_name`; counters have `_total`)
| Metric | Type | Use |
|---|---|---|
| `vllm:num_requests_running` | gauge | batch size now (≤ max_num_seqs) |
| `vllm:num_requests_waiting` / `_by_reason{reason=capacity\|deferred}` | gauge | queue |
| `vllm:kv_cache_usage_perc` | gauge **0..1** | KV pressure (old `gpu_cache_usage_perc` is gone) |
| `vllm:num_preemptions_total` | counter | recompute preemptions; `rate()` > 0 sustained = trouble |
| `vllm:prompt_tokens_total`, `generation_tokens_total` | counter | tokens/s in/out, accounting |
| `vllm:prompt_tokens_by_source_total{source=local_compute\|local_cache_hit\|external_kv_transfer}` | counter | prefix-cache contribution |
| `vllm:prefix_cache_queries_total`, `prefix_cache_hits_total` | counter (tokens) | hit rate = hits/queries |
| `vllm:request_success_total{finished_reason=stop\|length\|abort\|error\|repetition}` | counter | outcomes |
| `vllm:time_to_first_token_seconds` | histogram | TTFT (queue + prefill) |
| `vllm:inter_token_latency_seconds` | histogram | ITL (decode step) |
| `vllm:request_queue_time_seconds`, `request_prefill_time_seconds`, `request_decode_time_seconds`, `request_inference_time_seconds` | histogram | latency decomposition |
| `vllm:e2e_request_latency_seconds`, `request_time_per_output_token_seconds` | histogram | whole request; per-request avg ITL |
| `vllm:request_prompt_tokens`, `request_generation_tokens`, `request_max_num_generation_tokens`, `request_params_max_tokens`, `request_params_n` | histogram | traffic shape |
| `vllm:request_num_preemptions` | histogram | per-request preemptions |
| `vllm:iteration_tokens_total` | histogram | tokens per engine step |
| `vllm:cache_config_info{block_size,gpu_memory_utilization,cache_dtype,kv_cache_size_tokens,kv_cache_max_concurrency,...}` | info gauge | what the engine decided |
| `vllm:engine_sleep_state{sleep_state}` | gauge | awake/sleeping |
TTFT buckets (s): .001 .005 .01 .02 .04 .06 .08 .1 .25 .5 .75 1 2.5 5 7.5 10 20 40 80 160 640 2560. ITL buckets: .01 .025 .05 .075 .1 .15 .2 .3 .4 .5 .75 1 2.5 5 7.5 10 20 40 80.

## PromQL
```promql
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))   # p95 TTFT
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:inter_token_latency_seconds_bucket[5m])))   # p95 ITL
sum(rate(vllm:time_to_first_token_seconds_bucket{le="1.0"}[5m])) / sum(rate(vllm:time_to_first_token_seconds_count[5m]))  # SLO attainment (<1s)
sum by (model_name) (rate(vllm:generation_tokens_total[1m]))            # output tok/s
max by (model_name) (vllm:kv_cache_usage_perc)                          # worst-replica KV
sum by (model_name) (rate(vllm:num_preemptions_total[5m]))              # preemption rate
rate(vllm:prefix_cache_hits_total[5m]) / rate(vllm:prefix_cache_queries_total[5m])
```
Never `rate()` a gauge; never `avg()` quantiles; keep `le` in `by`; rate window ≥ 4 × scrape interval.

## Diagnose in order
health/restart log → queue (waiting, queue_time) → KV usage → preemptions → prefill vs decode (TTFT vs ITL, hit rate) → throughput vs benchmark → upstream (gateway, network, retries) → GPU health (module 09).

## Other engines
llama.cpp `--metrics`: `llamacpp:prompt_tokens_total`, `tokens_predicted_total`, `prompt_seconds_total`, `tokens_predicted_seconds_total`, `requests_processing`, `requests_deferred` (no TTFT histogram, no KV gauge on the pinned build). LiteLLM `/metrics/`: `litellm_proxy_total_requests_metric_total`, `litellm_total_tokens_metric_total`, `litellm_spend_metric_total`, `litellm_llm_api_time_to_first_token_metric_bucket` (confirm against live output).
