# 00 — Orientation: the 4-layer architecture, the lab stack, one request end to end

Time: ~1.5 h (about 35 min theory, 55 min lab). Profiles: `gw llm`. Real: LiteLLM, Postgres, Valkey, llama.cpp. Simulated: nothing runs in this module, but layer 4 (GPUs) is only described — the lab host has no GPU.

Goal of the module: when someone says "the model is slow / returns 500 / the key was rate limited", you know which of four layers to open first, and you have already traced one request through all of them.

## 1. Why AI infrastructure is not "web infrastructure with bigger boxes"

You already run stateless services behind a load balancer. An LLM platform breaks several of your defaults:

| Classic web service | LLM serving |
|---|---|
| Artifact: image of tens to hundreds of MB | Artifact: **weights** of 1 GB to 800 GB (a 70B model in FP16 is ~140 GB), plus an engine image of ~5-10 GB (vLLM GPU images are ~10 GB compressed) |
| Scale-out: start another pod in seconds | Cold start = scheduling a GPU + pulling the image + **loading weights** into VRAM: minutes |
| Memory: CPU RAM, elastic-ish | **VRAM** is the hard limit: weights + KV cache must fit on the GPU; no swap that is usable in practice |
| Request: ms, small payload, one response | Request: seconds to minutes, **streamed** token by token (SSE), a long-lived connection |
| Cost per request roughly constant | Cost proportional to **tokens in + tokens out**; one request can cost 1000x another |
| Rate limits in requests/s | Limits in **tokens/minute** as well as requests/minute |
| Latency: one number (p95) | Latency: **TTFT** (time to first token), **ITL** (inter-token latency), end-to-end — different causes, different SLOs |
| Health: HTTP 200 on `/health` | Engine can be up while the GPU is throwing XID errors or the KV cache is full and every request queues |
| Output is deterministic code | Output is sampled text: the same request gives different answers; "correct" cannot be asserted with `==` |
| Data: logs contain metadata | Logs contain **prompts**: source code, customer data, secrets (a governance problem, module 08) |

The consequence: the platform team owns a chain — client, gateway, engine, GPU/storage — and every link has its own failure modes and metrics. This course is organised along that chain.

## 2. The four layers

```
 L1  Clients & agents      Open WebUI · IDE assistants (Continue, Cline) · Aider / CLI agents · internal apps
          │   OpenAI-style REST (chat/completions, embeddings, completions/FIM), SSE streaming, tools
          ▼
 L2  AI gateway / control  LiteLLM proxy: virtual keys, teams, RPM/TPM limits, budgets, routing,
          │                fallbacks, spend logs, metrics.  State: Postgres (+ Redis/Valkey)
          ▼
 L3  Inference engines     vLLM · SGLang · TensorRT-LLM · llama.cpp / Ollama · TEI (embeddings) · TGI (maintenance mode)
          │   one process (or a few, with tensor parallelism) per model instance; owns the KV cache and batching
          ▼
 L4  Hardware & platform   GPU servers · driver + container toolkit · Kubernetes + GPU Operator ·
                           weight storage (NVMe, S3, NFS) · OCI registry · networks · air gap

 Cross-cutting:  observability (DCGM, engine metrics, gateway metrics, traces) · security & governance · weights lifecycle
```

The rule for assigning a component to a layer: **a component belongs to the layer whose job it performs; a datastore belongs to the layer that owns its state.** So Postgres/Valkey behind LiteLLM are L2 (they hold keys, spend, rate-limit counters), SeaweedFS holding weights is L4, Qdrant for RAG is application-level state (it appears from module 07 on, sitting beside L1/L2).

### 2.1 Layer 1: clients and agents
- The lingua franca is the **OpenAI REST API**: `POST /v1/chat/completions` (messages, optional `tools`, `stream`), `POST /v1/embeddings`, `POST /v1/completions` (legacy text and FIM-style autocomplete), `GET /v1/models`. A client needs two things: a base URL and a bearer key. That is why a gateway can sit in the middle without changing any client.
- Clients differ wildly in what they send. A chat UI sends a short history. A coding agent sends a 10-30k-token system prompt, a file tree, tool definitions and the whole previous conversation on every turn (module 06). An autocomplete plugin sends many tiny FIM requests per second and wants a very low TTFT.
- Clients are where "prompt injection" and "agent runs code" risks start (module 07), but the platform team's first concern is traffic shape and identity: who is calling, with which key, with how many tokens.

### 2.2 Layer 2: the AI gateway
The gateway (here **LiteLLM proxy v1.106.4**) is a reverse proxy that understands LLM traffic. What it adds over nginx:

| Function | Why it matters |
|---|---|
| **Virtual keys / teams** | Each user or app gets its own key with model allow-list, budget, RPM/TPM. The engines never see real identities |
| **Normalisation** | One API shape in front of vLLM, llama.cpp, Ollama, or an external provider |
| **Limits** | RPM and TPM per key/team/model; protects engines from a runaway agent loop |
| **Routing** | Load balancing across replicas, fallbacks A→B, cooldown of unhealthy backends (module 05) |
| **Accounting** | Spend logs per request: tokens, cost, key, model, latency. This is how "who used what" is answered |
| **Logging and callbacks** | Prometheus metrics, Langfuse traces; also the place where prompt logging becomes a compliance decision |

Costs of a gateway: an extra hop (a few ms, more under load), a new single point of failure (so: replicas + shared state), and state to operate (Postgres for keys/spend, Redis for shared counters). The gateway is **Python**; at high request rates it, not the GPU, can become the bottleneck — teams scale it horizontally and keep the hot path lean (fewer callbacks).

Lab-only: `proxy_batch_write_at: 5` makes spend rows appear 2-5 s after a request. The default batch interval is longer (tens of seconds), so in production "spend logs lag" is normal and dashboards built on them must tolerate it.

### 2.3 Layer 3: inference engines
An engine loads weights onto the accelerator and runs the generation loop for many concurrent requests, managing the **KV cache** and **batching** (module 01 is entirely about this). Landscape (check the team's choice in week one):

| Engine | Notes |
|---|---|
| **vLLM** | The default open-source GPU engine: PagedAttention, continuous batching, prefix caching, tensor/pipeline parallelism, many quantisation formats, OpenAI-compatible server, rich Prometheus metrics. Pinned in this course: 0.31/0.32 line |
| SGLang | Similar scope, strong on structured output and prefix reuse (RadixAttention) |
| TensorRT-LLM / NVIDIA NIM / Triton | NVIDIA's optimised stack: fastest on NVIDIA hardware when you accept the build/compile step and vendor packaging |
| **llama.cpp** (`llama-server`) | CPU-first (also GPU), GGUF weights, very light, slots + `/metrics` + `/slots`. **The real engine in this lab** because it runs on CPU |
| Ollama | Convenient wrapper around llama.cpp-style engines; **no native Prometheus metrics** — fine for laptops, awkward for platform teams |
| TEI | Embedding/rerank server (CPU image is amd64-only, so not used here) |
| TGI | Hugging Face's server, now in maintenance mode; you will still meet it in older setups |

All of them expose (roughly) the OpenAI API. "Roughly" is the catch: parameters, tool-call parsers, `usage` details, error codes and streaming chunk shapes differ in small ways that break clients (see Check yourself).

### 2.4 Layer 4: hardware and platform
- **GPU servers**: typically 8 GPUs per node (H100/H200/A100/L40S, or AMD MI-series). VRAM per GPU 24-192 GB. NVLink inside a node, InfiniBand/RoCE between nodes (relevant for multi-node tensor/pipeline parallelism, rare for the first deployments).
- **Driver + container toolkit + device plugin**: the chain that makes `nvidia.com/gpu` appear to Kubernetes (module 09; the GPU Operator v26.7.2 automates it).
- **Weight storage**: NVMe on each node, an internal S3 (SeaweedFS in the lab; MinIO's community repo was archived in April 2026), NFS, or an OCI registry (module 02).
- **Image registry** for engine images, **networks** (in an air gap: no internet at all), and the Kubernetes that schedules it all.

### 2.5 What crosses the layers
Observability (DCGM GPU metrics from L4, engine metrics from L3, gateway metrics and spend from L2, traces from L1/L2), security (keys at L2, network isolation at L4, sandboxing for agents), and the weights lifecycle (download, scan, store, deploy: L4 → L3). Module 08 ties the metrics together.

## 3. Tokens: the unit everything is measured in
- A **token** is a sub-word piece produced by the model's tokenizer. English averages roughly 0.75 words per token (about 4 characters). Code and non-Latin scripts cost more: **Hebrew often takes 2-3x the tokens of the equivalent English text**, so the same sentence is more expensive and fills the context window faster.
- Every model has a **context window** (e.g. 8k, 32k, 128k tokens): prompt + generated tokens must fit. Long contexts cost memory (KV cache, module 01), not just money.
- **`usage`** in the response reports `prompt_tokens`, `completion_tokens`, `total_tokens` (some engines add details such as cached tokens). These counts come from the engine's tokenizer; the gateway copies them into spend logs and rate-limit counters. When two systems disagree about token counts (module 08), the cause is usually a different tokenizer or a streamed response without usage.
- TPM limits are enforced on these counts, with an estimate before the response and the true count after.

## 4. Anatomy of one request

```
curl → LiteLLM (:18040)  --auth key--> pick backend (router) --> llama.cpp / vLLM (:8080 in container)
          │                                   │
          │ spend log row (batched) ◄─────────┘ usage in the response (or last stream chunk)
          └─ Prometheus counters
```

1. **Client → gateway.** `POST /v1/chat/completions` with `Authorization: Bearer <key>`, body `{"model": "chat", "messages": [...], "stream": true}`. `model` is an **alias** defined in the gateway config; it is not the engine's model name.
2. **Gateway.** Authenticates the key, checks the model allow-list, limits and budget, picks a backend deployment for the alias, rewrites the request (`model` becomes the backend's served name; the `openai/` prefix in LiteLLM's `litellm_params.model` means "speak the OpenAI protocol to `api_base`"), forwards it. It adds response headers such as `x-litellm-call-id` (inspect them with `curl -i`).
3. **Engine.** Tokenises the prompt, runs **prefill** (processes all prompt tokens, produces the first token), then **decode** (one token per step) until EOS or `max_tokens`. With `stream: true` each token (or small group) is flushed as an SSE chunk.
4. **Back.** The gateway relays chunks, counts tokens, and after the stream ends writes accounting (spend log, metrics).

### 4.1 The SSE stream, concretely
```
data: {"id":"chatcmpl-…","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-…","choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}

data: {"id":"chatcmpl-…","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}

data: {"id":"chatcmpl-…","choices":[],"usage":{"prompt_tokens":23,"completion_tokens":16,"total_tokens":39}}

data: [DONE]
```
Points to internalise:
- Chunks are lines starting with `data: `, separated by blank lines; the stream ends with the literal `data: [DONE]`.
- The first chunk usually carries only the `role`; content chunks follow; one chunk carries `finish_reason` (`stop` = model emitted EOS, `length` = hit `max_tokens`/context, `tool_calls`, ...).
- **`usage` is not sent in a stream unless requested**: `"stream_options": {"include_usage": true}` adds a final chunk with `choices: []` and the usage. Without it, a gateway that must account for tokens has to count them itself or logs zeros. This is a classic source of "spend does not match" tickets.
- Chunk count is roughly the completion token count plus 2-3 bookkeeping chunks, but engines may batch several tokens into one chunk; do not equate them in production.
- Proxies in the path (nginx, ingress) must not buffer: `proxy_buffering off`, long `proxy_read_timeout`, otherwise streaming looks like one big delayed response and the client's idle timeout kills long generations.

### 4.2 Where time goes (TTFT vs the rest)
TTFT = network + gateway auth/routing + **queue wait in the engine** + **prefill time** (grows with prompt length) . Everything after the first token is **decode**: ITL is roughly constant per step and grows with batch size and context length. A "slow start" complaint is a prefill or queue problem; a "slow typing" complaint is decode. Averaging total latency hides which one it is (module 08 builds the dashboards).

### 4.3 Reading a request in the gateway's data
LiteLLM's Postgres table `LiteLLM_SpendLogs` has one row per request (columns include `request_id`, `call_type`, `api_key` (hashed), `model`, `model_group`, `api_base`, `user`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `spend`, `startTime`, `endTime`, `status`, `metadata`). The admin API exposes the same data under `/spend/logs`, and the UI has a Logs page. The `request_id` is taken from the backend's response `id` — which is why a backend that returns the same `id` twice breaks spend logging (the lab's mock-vllm returns unique ids for that reason). Rows are **batch-written**: right after a request they are not there yet.

## 5. The lab stack (what you will run)
`platform/stack.sh up <profiles>` converges the compose project `aiinfra` to exactly the profiles you list and waits for health. Other profiles' containers are removed (volumes are kept). Every container, volume and network carries the label `course=aiinfra`; you only ever act on that label.

| Profile | Services | Real/sim | Used from |
|---|---|---|---|
| `gw` | LiteLLM, Postgres, Valkey | real | 00 |
| `llm` | 3x llama.cpp: chat, coder (FIM), embed | real (CPU) | 00 |
| `mock` | mock-vllm A/B, mock-dcgm | **simulated** | 01 |
| `obs` | Prometheus, Grafana | real | 08 |
| `ui` | Open WebUI | real | 06 |
| `rag` | Qdrant | real | 07 |
| `store` | SeaweedFS (S3), OCI registry, hf-mirror, tripwire | real | 02 |
| `lf`, `vllm` | Langfuse stack / real vLLM-CPU | real, run alone | 08 / 03 |

Ports (always `127.0.0.1`; the host is internet-facing, so nothing binds `0.0.0.0`): LiteLLM 18040, llama.cpp chat/coder/embed 18011/18012/18013, Open WebUI 18080, Grafana 18030, Prometheus 18090, registry 18050, S3 18070, hf-mirror 18071 (full map in `CONVENTIONS.md`). UIs are also reachable over Tailscale on `100.127.87.65`.

RAM budget: peak 8 GB for everything the course runs; `lf`, `vllm` and kind never together with `llm`. `platform/doctor.sh` checks free ports, MemAvailable (warns under 6 GB) and image presence. After `platform/setup.sh` (the "connected side") nothing needs the internet: compose uses `pull_policy: never`.

### 5.1 What is real and what is simulated
- **Real:** the gateway (LiteLLM with Postgres and Valkey), llama.cpp engines on CPU with small GGUF models (Qwen2.5-0.5B class), all the HTTP and SSE behaviour.
- **Simulated (from module 01):** vLLM on GPUs (mock-vllm exposes real vLLM metric names and real error strings, driven by a capacity model from real `config.json` geometry), DCGM metrics, `nvidia-smi`, GPU nodes in Kubernetes.
- **Consequence:** CPU llama.cpp teaches the *shape* of serving (slots, caches, tokens, counters) but its timings say nothing about GPU performance: CPU decode is limited by memory bandwidth of 4 cores and prefill by core count. A 0.5B model is also too small to judge model quality or tool-calling reliability. In production, layer 3 is vLLM on GPUs and layer 4 is a GPU Operator-managed Kubernetes cluster; the lab states this again wherever it matters.

## 6. How teams debug: a ladder, not a guess
When "the AI is broken" arrives, go down the layers and stop at the first layer that disagrees with the one above:

1. **Client**: exact request (URL, model alias, key, stream or not), exact error. `curl -i` with the same key reproduces most issues.
2. **Gateway**: `docker compose logs litellm` / the Logs page: was it received? auth error (401/403), limit (429), budget, route, upstream error? `GET /v1/models` with the key shows what that key may call.
3. **Engine**: call the engine directly from inside the network (`curl http://llama-chat:8080/v1/models` from another container, or the published port on the host): does it answer? `/health`, `/metrics`, `/slots`, its logs.
4. **Infra**: container/pod state, OOM kills, GPU health (`nvidia-smi`, DCGM), disk, DNS, network policy.

Typical symptom → layer map:

| Symptom | First suspect |
|---|---|
| `401`/`403` from `/v1/...` | L2: wrong key, key not allowed that model alias |
| `429` | L2 limit (RPM/TPM) — or L3 saturation returned as 429/503 by the engine; check who sent it (response headers, gateway log) |
| `500` with "connection refused / no route / cannot connect" in the gateway log | L2→L3 wiring: wrong `api_base` host or port, engine down |
| `200` but empty or truncated text | L3 `max_tokens`/context limit (`finish_reason: length`), template/EOS issue; not a gateway bug |
| Long wait before the first token | L3 queue (KV cache full / too many concurrent requests) or very long prompt (prefill) |
| Spend or token counts "wrong" | L2 batching lag, stream without `include_usage`, different tokenizers |
| Model "loads for 10 minutes" after a rollout | L4 weights pull (module 02) |

## 7. Practical commands used in the lab
```bash
platform/stack.sh up gw llm            # converge to these profiles, wait for health
platform/stack.sh status
platform/doctor.sh                     # ports, RAM, images
curl -s localhost:18040/v1/models -H "Authorization: Bearer $KEY" | jq '.data[].id'
curl -sN localhost:18040/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":16,"stream":true,
       "stream_options":{"include_usage":true}}'
curl -i localhost:18040/v1/chat/completions ...   # -i: look at the response headers
docker ps --filter label=course=aiinfra --format '{{.Names}}\t{{.Ports}}'
```
`curl -N` disables curl's output buffering (without it a stream looks like it arrives at once). The master key and the other credentials are in `platform/stack/README.md`.

## Key takeaways
1. Four layers: clients → gateway → engines → hardware/platform; cross-cutting observability, security and the weights lifecycle. Always ask "which layer?" first.
2. The OpenAI REST API is the contract between layers 1, 2 and 3; the gateway's alias (`model: chat`) decouples clients from engine names and ports.
3. A request is a stream: SSE `data:` chunks, a `finish_reason`, optional final `usage` chunk (only if requested), then `[DONE]`.
4. Tokens are the unit of cost, limits and capacity. Language and format change token counts a lot (Hebrew, code, JSON).
5. TTFT is queue plus prefill; ITL is decode. One average latency hides which one is broken.
6. Gateway state (keys, spend, limits) lives in Postgres/Valkey; spend rows are batch-written, so they lag.
7. Debug top-down and stop at the first layer whose behaviour disagrees with the layer above.
8. In this lab llama.cpp is real and CPU-only; GPU behaviour comes from simulations or from theory. Never extrapolate CPU timings to GPUs.

## Check yourself
1. Place these in layers and say why: Postgres behind LiteLLM, SeaweedFS holding weights, Aider, vLLM, DCGM exporter, an OCI registry.
2. A streaming client prints text correctly but the spend log shows 0 tokens for its requests. Give two possible causes at two different layers.
3. Name three things a gateway gives you that "client → engine directly" does not, and two costs it adds.
4. A client gets `200` with an empty `content` and `finish_reason: "length"`. Which layer's setting do you look at, and what are two candidate causes?
5. Why is `curl` without `-N` misleading when testing a stream, and what else in the path can break streaming?
