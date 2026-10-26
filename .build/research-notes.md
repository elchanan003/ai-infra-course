# Research notes (planning phase, 2026-10-26)

Sources: Sonnet researcher (read-only: `docker buildx imagetools inspect`, GitHub/PyPI/npm APIs, docs), Sonnet designer, Sonnet critic. Nothing was pulled or run; RAM/throughput = estimates until the WP0 spike. Items marked UNVERIFIED must be confirmed in WP0.

## Host
arm64 Neoverse-N1 (fp asimd asimddp atomics; no bf16/i8mm/SVE), 4 vCPU, 23 GB RAM (~15 GB available; rakazo-* ~7 GB), no GPU, 133 GB free, Docker 29.8 containerd store, compose v5.5.1, kind/kubectl/helm/uv in ~/.local/bin, python3 3.10. Ports in use: 22,80,111,443,3001,3100,5173,5190,5191,5900,6080,8317,8765,9222,27017 (+ obs course 3000,3200,4317,4318,5001,8000-8002,8080,8888,9090,9093,9100,12345,13000-13010). 18000-18199 free.

## Component pins / arm64 (manifest-verified unless noted)
| Component | Candidate pin | arm64 | Notes |
|---|---|---|---|
| Ollama | ollama/ollama:0.40.11 | yes (2.8 GB) | NO native Prometheus /metrics (PRs #16998, #18508 open) |
| llama.cpp | ghcr.io/ggml-org/llama.cpp:server-b11900 (only :server inspected) | yes | `--metrics`: llamacpp:prompt_tokens_total, prompt_seconds_total, tokens_predicted_total, requests_processing, requests_deferred, n_decode_total...; no KV-usage metric in current README (UNVERIFIED); /infill FIM; --embeddings; --jinja for tools |
| vLLM CPU | vllm/vllm-openai-cpu:v0.32.0 | yes (1.24 GB) | needs NEON; bf16 needs ARMv8.6 -> use --dtype float16; N1 support UNVERIFIED; run flags: seccomp=unconfined, SYS_NICE, shm 4g, VLLM_CPU_KVCACHE_SPACE / --kv-cache-memory-bytes |
| vLLM GPU image | vllm/vllm-openai:v0.32.0 | 10.3 GB compressed | theory only |
| LiteLLM | ghcr.io/berriai/litellm-database (latest release v1.106.4; `v1.106.4-stable` tag absent) | yes | prometheus callback not enterprise-gated per docs; /metrics needs key unless require_auth_for_metrics_endpoint:false; routing strategies simple-shuffle(default), least-busy, latency-based, usage-based(-v2), cost-based; allowed_fails default 3/min, cooldown_time 5s; MCP gateway real; spend logs batch-written (proxy_batch_write_at) |
| Postgres/pgvector | pgvector/pgvector:pg17 | yes | |
| Valkey | valkey/valkey:9 (9.1.2) | yes | LiteLLM compat UNVERIFIED |
| Open WebUI | ghcr.io/open-webui/open-webui:v0.12.4 | yes | PersistentConfig: env only on first boot; RAG_EMBEDDING_ENGINE=openai to avoid sentence-transformers download; tiktoken cache |
| Langfuse | langfuse/langfuse:3 (3.225.14) + worker; v4.70.1 latest | yes | needs Postgres+ClickHouse(25.8)+Redis+S3, ~4-5 GB |
| Object store | chrislusf/seaweedfs:4.51 | yes (188 MB) | MinIO repo archived 2026-04-25; alt rustfs/rustfs:1.0.4, garage v2.1.0 |
| Registry | registry:3 (distribution 3.1.2) | yes | Zot v2.1.22 alt; ORAS 1.3.6; KitOps 1.16.0 |
| Qdrant | qdrant/qdrant:v1.20.0 | yes (72 MB) | |
| TEI | text-embeddings-inference:cpu-1.9 | **amd64 only** | not usable |
| Prometheus/Grafana | v3.5.0 / 12.1.1 (sibling pins, cached) | yes | |
| DCGM exporter | dcgm-exporter:4.6.1-4.8.4-distroless (GPU Operator v26.7.2) | yes | names: DCGM_FI_DEV_GPU_UTIL, FB_USED/FB_FREE (MiB), GPU_TEMP, POWER_USAGE, PROF_GR_ENGINE_ACTIVE, XID_ERRORS; labels gpu/UUID/device/modelName/Hostname UNVERIFIED |
| GPU Operator | v26.7.2 (toolkit 1.20.1, device-plugin 0.20.1, mig-manager 0.15.1) | — | theory |
| fake-gpu-operator | v0.2.1 (run-ai) | device-plugin arm64 | kind support UNVERIFIED -> optional |
| KWOK | v0.8.0 | | alt |
| kubeconform | v0.8.0 | arm64 binary | |

## vLLM facts (current docs)
- Metrics: gauges vllm:num_requests_running, vllm:num_requests_waiting, vllm:kv_cache_usage_perc (replaces gpu_cache_usage_perc); counters vllm:prompt_tokens_total, vllm:generation_tokens_total, vllm:request_success_total, vllm:prefix_cache_queries, vllm:prefix_cache_hits; histograms vllm:time_to_first_token_seconds, vllm:inter_token_latency_seconds, vllm:request_time_per_output_token_seconds, vllm:e2e_request_latency_seconds, vllm:request_queue_time_seconds, vllm:request_prefill_time_seconds, vllm:request_decode_time_seconds. Preemption counter name UNVERIFIED (check live/source).
- --gpu-memory-utilization default 0.92 (docs); --kv-cache-memory-bytes overrides; TP/PP default 1; --kv-cache-dtype auto; tool calling needs --enable-auto-tool-choice + --tool-call-parser. Other defaults UNVERIFIED.

## Python / clients
huggingface_hub 2.3.0 (`hf` CLI; HF_HOME, HF_HUB_CACHE, HF_HUB_OFFLINE, HF_ENDPOINT, HF_TOKEN), safetensors 0.8.0, picklescan 1.0.5, modelscan 0.8.8, fickling 0.1.12, aider-chat 0.86.2, openai 3.38.0, @continuedev/cli 1.5.47, mcp 2.3.0, fastmcp 4.1.4, MCP Inspector 2.12.0, guidellm 0.8.1. MCP spec 2026-07-28 (stateless, server/discover); previous 2025-11-25. gVisor release-20261019.0 (needs daemon change -> theory only).

## Models
Qwen2.5-0.5B-Instruct (988 MB safetensors, Q4_K_M 491 MB, Apache-2.0); Qwen2.5-Coder-0.5B base (FIM; GGUF size UNVERIFIED); bge-small-en-v1.5 (GGUF 25 MB, MIT); nomic-embed-text-v1.5 (GGUF 90 MB); SmolLM2-360M-Instruct (724 MB, Apache-2.0) for HF-layout lab. Speed estimates (Q4, 4×N1): 0.5B ~20-40 tok/s (UNMEASURED).

## Math checks
KV bytes/token = 2 × layers × kv_heads × head_dim × bytes. Llama-3-70B FP16: 2×80×8×128×2 = 327,680 B ≈ 0.31 MB/token ≈ 1.25 GB per 4k seq. 70B FP16 weights 140 GB: 2×80 marginal, 4×80 practical, FP8 on 2×80 common.

## Critic findings adopted (summary)
1. LiteLLM spend-log batching + limiter window semantics -> bounded polls, proxy_batch_write_at 5, burst-based 429 checks, spend graded on mock backends with fixed usage.
2. 0.5B model unreliable for tool calls/Aider/FIM -> scripted mock-chat mode is the graded path.
3. Open WebUI automation: admin bootstrap env, API signin, PersistentConfig pitfall, fresh volume per prepare.
4. CPU timing noise -> counters (/slots, /metrics, /props) over wall clock; ratio thresholds + median-of-3; wait_idle.
5. Alerts/rules -> promtool test rules + one bounded live smoke, 5 s scrape.
6. Mock fidelity = single point of failure -> contract fixed in CONVENTIONS before authors; WP3 gates B/D/E.
7. HF_ENDPOINT needs an HF-API-compatible mirror -> course-owned hf-mirror.
8. Tripwire mechanism: dnsmasq address=/#/sink on internal network.
9. Sandbox: timeouts + tight caps; decoy docker socket (never real).
10. kind GPUs: node-status patch primary; fake-gpu-operator optional.
11. Whole-cycle flock with timeout + owner file; serialized test queue; evidence files + validate-module.sh run by coordinator.
12. Answer files reject template values; enums paired with variant-bound evidence; preconditions unscored.
