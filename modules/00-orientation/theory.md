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
LiteLLM's Postgres table `LiteLLM_SpendLogs` has one row per request (columns include `request_id`, `call_type`, `api_key` (hashed), `model`, `model_group`, `api_base`, `user` (the key owner), `end_user` (the OpenAI `user` field of the request), `prompt_tokens`, `completion_tokens`, `total_tokens`, `spend`, `startTime`, `endTime`, `status`, `metadata`). The admin API exposes the same data under `/spend/logs`, and the UI has a Logs page. The `request_id` is taken from the backend's response `id` — which is why a backend that returns the same `id` twice breaks spend logging (the lab's mock-vllm returns unique ids for that reason). Rows are **batch-written**: right after a request they are not there yet.

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

## 8. A request, hop by hop, with real commands

Everything below can be reproduced in the lab (`gw llm`). The master key and ports are in `platform/stack/README.md`.

```bash
KEY=sk-aiinfra-master
curl -si http://127.0.0.1:18040/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":8,"temperature":0}' | head -20
```
What you see, and what each part tells you:
- `HTTP/1.1 200 OK` and `content-type: application/json`: the non-streaming form. The body is one JSON object: `id` (the backend's response id, `chatcmpl-...`), `model` (what the gateway reports), `choices[0].message.content`, `choices[0].finish_reason`, `usage`.
- Response headers added by the gateway: a call id (`x-litellm-call-id`), the deployment/model id, response cost, and rate-limit headers when limits exist. They are the fastest way to answer "did this request go through the gateway, and which deployment served it?".
- The same call against the engine directly (`curl http://127.0.0.1:18011/v1/chat/completions ...` with `"model":"chat"`; llama-server accepts any model name unless you configure an alias) skips auth, limits and accounting: use it to separate "engine broken" from "gateway broken".

### 8.1 Timeline of one streamed request (numbers are typical for a GPU deployment, not for this CPU lab)
| t | Event | Layer |
|---|---|---|
| 0 ms | TCP + TLS to the ingress, request body arrives | L4 network |
| 1-5 ms | gateway authenticates the key (cache or DB), checks model allow-list, limits, budget | L2 |
| 1-3 ms | router picks a deployment (shuffle, least-busy, latency-based...) | L2 |
| 2-10 ms | request forwarded; engine tokenises the prompt (about 1 ms per 1k tokens) | L3 |
| 0-N ms | **queue wait**: no free sequence slot or KV block (0 when the engine is idle, seconds when saturated) | L3 |
| 30-3000 ms | **prefill**: 500-token prompt on an H100 with an 8B model about 30-60 ms; 30k-token agent prompt on a 70B model several seconds | L3 |
| first chunk | first token flushed through the gateway to the client: this moment is TTFT | L3→L2→L1 |
| every 10-60 ms | next token (ITL), one SSE chunk per token or small group | L3 |
| last chunk | `finish_reason`, then (if requested) usage, then `[DONE]` | L3 |
| +2-5 s (lab) / tens of s (default) | spend log row is written in a batch | L2 |

### 8.2 What a gateway does not hide
- A 429 can be the gateway's own limit or a pass-through of the engine's/provider's. The response body and headers tell you which.
- A hung request is usually an engine queue, not a network problem. Check `requests_deferred` (llama.cpp) or `vllm:num_requests_waiting`.
- Timeouts stack: client timeout > gateway timeout > engine request timeout is the sane order. If the gateway times out first it cancels the upstream call and the engine wastes work on an abandoned request unless it detects the disconnect.

## 9. The gateway configuration in depth (LiteLLM v1.106.4)

The lab file (`platform/stack/config/litellm/config.yaml`, and your copy in `lab/litellm/`) has four blocks:

```yaml
model_list:                       # the aliases clients can ask for
  - model_name: chat              # alias: what clients put in "model"
    litellm_params:
      model: openai/chat          # "openai/" = speak the OpenAI protocol; "chat" = model name sent to the backend
      api_base: http://llama-chat:8080/v1
      api_key: none
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY     # admin credential; virtual keys are minted with it
  database_url: os.environ/DATABASE_URL         # Postgres: keys, teams, spend logs
  proxy_batch_write_at: 5                       # lab-only, seconds between spend-log batch writes
litellm_settings:
  callbacks: ["prometheus"]                     # exposes /metrics
  cache: true                                   # with supported_call_types: [] only the limit counters use Redis
router_settings:
  redis_host: valkey                            # shared state for cooldowns and counters
```
Facts to keep:
- **`model_name` is the alias**, `litellm_params.model` is `<provider>/<backend model name>`. Several entries with the **same** `model_name` form a group: the router load-balances across them (module 05). One alias can therefore hide ten backends.
- **`api_base` is resolved inside the gateway container.** `http://llama-chat:8080/v1` works because compose gives every service a DNS name on the `aiinfra` network and the engine listens on 8080 *inside* its container. The published host port (`127.0.0.1:18011`) is irrelevant for container-to-container traffic; using it, or a wrong container port, gives "connection refused" in the gateway log and a 500 to the client. This is exactly the planted fault of task 0.5.
- **Config is read at start.** Editing the file does nothing until the process restarts or reloads (LiteLLM can also store models in its database and add them through the API, which then override file edits: a classic "I changed the YAML and nothing happened" cause). The lab restarts the container.
- **Health endpoints**: `/health/liveliness` (process up), `/health/readiness` (up and connected to its DB), `/health` (calls every backend: slow, use sparingly). `GET /v1/models` lists what a key may use; `GET /model/info` shows deployments.
- **Auth model**: the master key can do everything; **virtual keys** (module 04) carry model lists, limits and budgets, belong to users/teams, and are stored hashed. Never hand out the master key; never log keys. Spend logs store the hashed key.
- **Callbacks** run on the request path or in background tasks: `prometheus` is cheap; heavy callbacks (tracing every prompt) add latency under load and should be measured.

## 10. The engines' own surface (what you can ask a llama.cpp server)

| Endpoint | Purpose |
|---|---|
| `GET /health` | 200 when the model is loaded (503 while loading); what the compose healthcheck uses |
| `GET /props` | effective settings: build, context size, number of slots, chat template, default sampling |
| `GET /slots` | per-slot state (context size, whether it is processing, the last task's token counts) |
| `GET /metrics` | Prometheus text (`--metrics`): token counters, busy/deferred requests |
| `POST /v1/chat/completions`, `/v1/completions`, `/v1/embeddings` | the OpenAI-compatible API |
| `POST /tokenize`, `/detokenize`, `/apply-template` | see exactly how text becomes tokens and how the chat template renders messages |
| `POST /infill` | FIM (fill-in-the-middle) for autocomplete models |

vLLM's equivalents: `/health`, `/v1/models`, `/metrics` (much richer: queue, KV usage, latency histograms), `/tokenize`, plus startup logs that print KV capacity. Knowing "how do I ask this engine what it thinks it is doing" is half of operating it.

## 11. Networking facts that decide most lab and production incidents
- **Published vs container ports.** `ports: ["127.0.0.1:18012:8080"]` means host 18012 → container 8080. Clients on the host use 18012; other containers use `llama-coder:8080`. Mixing the two is the most common wiring bug in compose and Kubernetes (`port` vs `targetPort`).
- **Bind addresses.** The course binds published ports to `127.0.0.1` (and the UIs additionally to the Tailscale address). Binding `0.0.0.0` on an internet-facing host exposes an unauthenticated engine. In production the engine's port is reachable only from the gateway (NetworkPolicy / security group); clients never talk to engines.
- **DNS inside the network.** Service names resolve through Docker's embedded DNS (Kubernetes: cluster DNS). A typo in a service name looks like "temporary failure in name resolution" in the gateway log.
- **Internal networks.** A network created with `internal: true` has no route out and cannot publish ports: it is how the lab simulates an air gap (module 02).
- **Streaming through proxies.** Reverse proxies and ingress controllers buffer by default; for SSE set `proxy_buffering off` (nginx) / the equivalent annotation, raise read timeouts beyond the longest generation, and avoid compression that waits for the full body. Symptom of buffering: the UI shows nothing and then the whole answer at once.
- **HTTP/1.1 keep-alive and connection limits** matter: each in-flight generation holds a connection for its whole duration, so connection limits (ingress, gateway workers, the engine's `--max-num-seqs`) act as concurrency limits in practice.

## 12. Failure modes by layer (what pages look like)

| Layer | Typical failure | First look | Typical fix |
|---|---|---|---|
| L1 | agent loops resending a 40k-token history every turn | gateway logs: prompt tokens per request, request rate per key | per-key TPM/RPM, `max_parallel_requests`, prompt caching on the engine |
| L1 | client sets a huge `max_tokens` and holds slots | engine slots busy, long `completion_tokens` | cap `max_tokens` at the gateway/engine |
| L2 | gateway pod OOM or CPU-bound (Python), p99 latency up while GPUs idle | gateway CPU, event-loop lag, callbacks | scale replicas, trim callbacks, shared Redis |
| L2 | DB down: auth and spend fail | `/health/readiness`, Postgres | HA Postgres; gateway keeps serving cached keys for a while only |
| L2 | wrong alias/api_base after a config change | 500 with connection refused, wrong backend counters | fix config; deploy configs through review and a test request |
| L3 | KV cache full: queue grows, TTFT explodes | `num_requests_waiting`, KV usage, preemptions | smaller `max_model_len`, more replicas, quantised KV |
| L3 | engine start-up refused (not enough memory for the context) | engine logs at start | lower `max_model_len`/utilisation, free GPU memory |
| L3 | model quality regression after a "harmless" requantisation | eval set, tool-call success rate | roll back, evaluate before promoting |
| L4 | GPU falls off the bus (XID 79) or ECC errors: engine crashes or returns garbage | DCGM metrics, `dmesg`, node events | drain/replace node (module 09) |
| L4 | cold start takes 20 minutes | image pull + weight transfer time | node-local cache, pre-pull, faster storage (module 02) |
| L4 | model files corrupted/incomplete after a transfer | engine errors at load, hash mismatch | verify manifests at every hop (module 02) |

## 13. Capacity and cost intuition (so numbers do not surprise you)
- A coding assistant for 100 developers: each active developer sends about 1 request per minute while working, each carrying 8-20k prompt tokens (system prompt, files, history) and producing 200-500 tokens. That is roughly 100 × 60 × 8 h ≈ 48,000 requests per day, and **hundreds of millions of prompt tokens per day**; output is 100x smaller but costs far more GPU time per token. Prefix caching therefore decides whether the platform needs 2 GPUs or 10.
- Decode speed is per-sequence and batch-dependent: an 8B model on one H100 gives about 100-150 tok/s per stream at low load and thousands of tokens/s aggregate at high batch. A 70B model on 4 GPUs gives 30-50 tok/s per stream.
- Capacity is measured in **concurrent sequences × context length** (KV memory), not in requests per second. Two users with 100k-token contexts can use more KV than fifty chat users.
- Cost per token is dominated by GPU utilisation: an idle GPU costs the same as a busy one. This is why batching, autoscaling to queue depth and sharing GPUs (MIG, time-slicing) are platform topics.
- Embedding and rerank traffic is high-volume and cheap per request; keep it on separate deployments so it cannot starve chat (module 05).

## 14. Security and governance in one page
- **Identity**: one key per user/app/agent, never shared; teams own budgets. Rotate keys; the gateway stores hashes only.
- **Prompts are sensitive data**: they contain source code, tickets, customer data and sometimes secrets. Decide per environment whether prompts/responses are logged, who can read them, how long they are kept, and whether PII is masked. Tracing tools (Langfuse) make this a first-class decision.
- **Model supply chain**: weights are code-adjacent (pickle can execute code) and behaviour-bearing; provenance, scanning and pinned hashes are mandatory (module 02).
- **Egress**: engines and gateway normally need **no** internet access. In an air-gapped site every outbound call is either a bug or a policy violation (telemetry, update checks, downloads); prove it with network controls, not environment flags.
- **Agents and tools**: anything that lets a model call tools or run code needs sandboxing and least privilege (module 07).
- **Multi-tenancy**: tenants share GPUs; isolation levels differ (separate deployments > MIG > time-slicing). Budgets and rate limits are also a safety control.

## 15. Glossary (the words you will hear in the first week)
| Term | Meaning |
|---|---|
| prefill / decode | processing the prompt in one pass / generating tokens one at a time |
| KV cache | stored attention keys/values of previous tokens; the main consumer of VRAM beyond weights |
| TTFT / ITL / TPS | time to first token / inter-token latency / tokens per second |
| continuous batching | the engine re-forms the batch every step so sequences join and leave freely |
| quantisation | storing weights (or KV) with fewer bits: FP8, INT4, GGUF k-quants |
| tensor parallelism (TP) | splitting each layer across GPUs; needs fast interconnect |
| MoE | mixture of experts: large total parameters, few active per token |
| LoRA / adapter | small fine-tuned weight deltas loaded on top of a base model |
| embedding / RAG | vectors for retrieval; retrieval-augmented generation feeds retrieved text into the prompt |
| FIM | fill-in-the-middle completion used by IDE autocomplete |
| tool calling / function calling | the model emits a structured request for a tool; the client executes it and sends the result back |
| MCP | Model Context Protocol: an open standard for exposing tools and data to model clients |
| agent | a loop of model call → tool execution → model call until done |
| OpenAI-compatible | implements the request/response shapes of the OpenAI REST API (with gaps) |
| XID | NVIDIA driver error code reported in the kernel log (module 09) |
| air gap | a network with no path to the internet |

## 16. Your first-week questions for the team (start a list now; module 11 turns it into a plan)
1. Which engine(s) and versions do we run, and why? Which GPUs, how many per node, which interconnect?
2. What is the gateway, how is it deployed (replicas, Redis, Postgres), and who issues keys?
3. How do weights get in: who approves a model, how is it scanned, where is it stored, how long is a cold start?
4. What are our SLOs (TTFT, ITL, availability) and where are they measured?
5. What is logged about prompts, who may read it, and how is it retained?
6. How do we upgrade an engine or a model without dropping streams?

## 17. Three short incident stories (work through them before the quiz)

**Story 1 — "Chat is down" (it is not).** A developer reports that the coding assistant returns errors since 09:00. The gateway log shows `litellm.APIConnectionError ... Connection refused` for alias `coder` only; alias `chat` works. The `coder` engine container is `Up` and `/health` on its published port answers 200. What changed at 08:50? A config PR changed `api_base` for `coder` from `http://llama-coder:8080/v1` to `http://llama-coder:8081/v1`. The engine never moved; the gateway pointed at a port nobody listens on. Lessons: (1) the ladder located the fault at the L2→L3 wiring, not in either component; (2) the engine being healthy on its *published* port says nothing about the address the gateway uses; (3) configs are deployed through review **and** a smoke request per alias.

**Story 2 — "The bill doesn't match".** Finance sees 40% fewer tokens in the gateway's spend logs than the engine's metrics report. Streaming clients are most of the traffic. The clients never set `stream_options.include_usage`, so the gateway had no `usage` chunk to read and recorded a token estimate for streamed calls. The engine's counters (generated tokens) are the ground truth. Lessons: tokens are counted at the engine; every accounting layer above it is an approximation unless usage is propagated; reconcile with a periodic job (module 08) and make the gateway force `include_usage` for streams.

**Story 3 — "Fast on Friday, slow on Monday".** Time-to-first-token for the agent tool went from 400 ms to 6 s over the weekend while GPU utilisation fell. The only change: a prompt-template update that added `Current time: <ISO timestamp>` at the top of the system prompt. Every request now has a different first token, the engine's prefix cache never hits, and each 20k-token agent prompt is fully re-prefilled. Lessons: cache hit rate is a first-class metric; volatile data goes last in the prompt; "GPU util went down" can mean the GPU is waiting on a queue it is not working through efficiently, or that requests are slower per token but fewer — read TTFT and queue metrics before utilisation.

## 18. How this module's lab maps to the theory
| Task | Concept practised | Where to read |
|---|---|---|
| 0.1 | stack profiles, ports, doctor, labels | 5 |
| 0.2 | SSE structure, `include_usage`, finish reasons | 4.1 |
| 0.3 | spend logs, request ids, batch-written accounting, decoy rows | 4.3, 9 |
| 0.4 | the layer-assignment rule, published ports | 2, 11 |
| 0.5 | gateway wiring (`api_base`), debugging ladder, counters as ground truth | 6, 9, 11 |

Habits to start now: always prove which backend served a request (counters, headers); never conclude from a single layer's health check; write down each incident as "symptom → layer → cause → what would have caught it earlier".

## 19. Messages, roles and the chat template (what the engine really receives)
- The API takes a list of `messages` with roles `system`, `user`, `assistant` (and `tool` for tool results). The **engine converts that list into one flat string** with the model's **chat template** (a Jinja template shipped in the tokenizer config or GGUF metadata), adding special tokens such as `<|im_start|>` / `<|im_end|>` (Qwen/ChatML) or `<|start_header_id|>` (Llama 3). The model sees only that string.
- Consequences: (1) the same messages produce different token counts on different models; (2) a wrong or missing template silently degrades answers (the lab's `/apply-template` shows the rendered prompt); (3) the template decides how tool definitions are presented, which is why tool calling needs engine flags (`--jinja` in llama.cpp; `--enable-auto-tool-choice` plus a `--tool-call-parser` in vLLM); (4) the system prompt is simply the first part of every request, which is why it dominates prompt-token counts for agents and why it is the best candidate for prefix caching.
- `max_tokens` bounds the **completion**, not the prompt. The prompt + completion must fit the context window; engines either reject (HTTP 400, "maximum context length") or silently truncate depending on settings. A gateway cannot fix this: the client or the engine configuration must.
- Sampling parameters (`temperature`, `top_p`, `seed`) shape the output. `temperature: 0` plus a fixed seed makes a request nearly reproducible on the same engine and build, which the lab exploits for graded checks. It is not a cross-engine guarantee: batch composition and kernels change floating-point results.

## 20. "OpenAI-compatible" is a spectrum
| Area | Typical divergence between engines/gateways |
|---|---|
| Streaming usage | needs `stream_options.include_usage`; some servers send usage on every chunk or never |
| Tool calling | arguments formatting (string vs object), parallel tool calls, `tool_choice: required`, parser needed per model family |
| Structured output | `response_format`/JSON schema supported by some engines (guided decoding), ignored by others |
| Parameters | `n>1`, `logprobs`, `seed`, `presence_penalty`, `max_completion_tokens` vs `max_tokens` |
| Model names | some engines ignore `model`, some require the served name, gateways map aliases |
| Errors | different status codes for context overflow (400), overload (429/503), auth (401/403) and different JSON error shapes |
| Embeddings | dimensions, normalisation, `encoding_format=base64` (the openai client default) support |
| Extras | `/v1/completions` suffix/FIM handling, `/v1/responses`, audio, images |
Practical rule: **contract-test the client against the engine behind the gateway** (a handful of requests per feature, run in CI when the engine or model changes), because an upgrade is a compatibility event even when the version number says patch.

## 21. Worked exercise: read this stream
```
data: {"id":"chatcmpl-9","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
data: {"id":"chatcmpl-9","choices":[{"index":0,"delta":{"content":"1"},"finish_reason":null}]}
data: {"id":"chatcmpl-9","choices":[{"index":0,"delta":{"content":" 2"},"finish_reason":null}]}
data: {"id":"chatcmpl-9","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}
data: {"id":"chatcmpl-9","choices":[],"usage":{"prompt_tokens":31,"completion_tokens":2,"total_tokens":33}}
data: [DONE]
```
Questions: how many content chunks? (2: the first chunk's content is the empty string.) Why did generation stop? (`length`: the client's `max_tokens` was 2, not an EOS.) What does `completion_tokens: 2` confirm? (one token per content chunk here; not guaranteed in general.) What would be missing without `include_usage`? (the fifth line; the client and gateway would not know the token counts.) Which line would a proxy that buffers delay? (all of them: the client would see all six lines at once at the end.)

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
