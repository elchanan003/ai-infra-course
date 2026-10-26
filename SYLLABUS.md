# Syllabus — AI Infrastructure & Platform (LLMOps) Onboarding Course

Budget: ~45 h over ~2 weeks (3-4 h/day). ~60% hands-on, much of it on simulated targets (no GPU on the lab host; stated explicitly in every module).
Stack: llama.cpp (real engine), mock-vllm / mock-dcgm (simulated), LiteLLM, Open WebUI, Qdrant, SeaweedFS, OCI registry + ORAS, Prometheus, Grafana, Langfuse, kind.
Reuses one lab platform in every module; air-gap work uses the `aiinfra-airgap` network with a tripwire.

## Modules
| ID | Module | Hours | Depends on | real/sim/theory % | Profiles (kind) | Learner can, at the end... |
|---|---|---|---|---|---|---|
| 00 | `00-orientation` — 4-layer architecture, stack tour, request trace | 1.5 | — | 40/20/40 | gw llm | draw the 4-layer architecture, run the stack, trace one request client→gateway→engine |
| 01 | `01-serving-internals` — prefill/decode, KV cache, batching, prompt cache, quantization, VRAM/KV/TP sizing | 5 | 00 | 35/25/40 | llm mock | explain prefill/decode/KV/batching; size VRAM, KV and TP for any model |
| 02 | `02-weights-airgap` — HF cache/mirror, safetensors, pickle scanning, S3, OCI artifacts, offline serving | 4.5 | 00 | 65/0/35 | store llm | move a model across an air gap with integrity + scanning and serve it provably offline |
| 03 | `03-vllm-ops` — vLLM flags, startup OOM, KV%, preemption, queueing, SLO tuning | 4.5 | 01 | 10/55/35 | mock (vllm optional) | predict and fix vLLM startup/KV/preemption problems from flags and metrics |
| 04 | `04-gateway-core` — LiteLLM keys, teams, TPM/RPM, Postgres durability, shared Valkey | 4 | 00 | 70/10/20 | gw llm mock | run LiteLLM with keys, teams, limits, durable state, shared Redis |
| 05 | `05-gateway-routing-governance` — LB, fallbacks, cooldowns, budgets, chat-vs-agent separation | 3.5 | 04 | 55/35/10 | gw mock | design LB, fallbacks, cooldowns, budgets and traffic separation |
| 06 | `06-clients-coding-tools` — Open WebUI, Aider, Continue, FIM vs chat, coding-agent requests | 3.5 | 04 | 60/25/15 | gw ui mock llm | wire Open WebUI and coding tools to the gateway; tell FIM from chat; read an agent request |
| 07 | `07-agents-mcp-sandbox-rag` — tool loops, MCP, sandboxing, RAG infra | 4 | 04 | 65/15/20 | gw mock llm rag | build a tool loop + MCP server, sandbox agent code, run RAG infra |
| 08 | `08-ai-observability` — scrape, TTFT/ITL/KV% rules, dashboards, alerts, token accounting, Langfuse | 5 | 03, 05 | 40/45/15 | gw llm mock obs (+ lf alone, with gw mock) | build AI dashboards, recording rules, alerts, token accounting, LLM tracing |
| 09 | `09-gpu-on-k8s` — driver→pod stack, DCGM, XID, time-slicing/MIG/DRA, GPU manifests | 4 | 03, 08 | 10/50/40 | mock obs; kind part B | explain the GPU stack; read DCGM failures; write correct GPU scheduling manifests |
| 10 | `10-capstone` — 5 incident scenarios, root cause, postmortem | 5 | all | 30/70/0 | per scenario | run AI-platform incidents end to end with a postmortem |
| 11 | `11-onboarding-prep` — alternatives map, questions for the team, first-week plan | 0.5 | any | theory | none | arrive with a map, sharp questions and a first-week plan |

Profiles: `gw llm mock obs ui rag store lf vllm`. `lf`, `vllm` and kind never run together with `llm`; peak <= 8 GB. kind (cluster `aiinfra`) is used in 09 part B only.

## Suggested 2-week schedule (adjust to onboarding date in PROGRESS.md)
| Day | Work |
|---|---|
| 1 | 00, 01 (start) |
| 2 | 01 (finish), 02 (start) |
| 3 | 02 (finish), 03 (start) |
| 4 | 03 (finish), 04 (start) |
| 5 | 04 (finish), 05 |
| 6 | 06, 07 (start) |
| 7 | 07 (finish), 08 (start) |
| 8 | 08 (finish) |
| 9 | 09 |
| 10 | 10 (scenarios 1-2) |
| 11 | 10 (scenarios 3-5) |
| 12 | 10 postmortem, 11, review weak areas |

## Reference reading (optional, outside the course)
- vLLM: PagedAttention blog post and paper (Kwon et al., SOSP 2023); docs: `serve` engine args, Metrics (production metrics).
- LiteLLM Proxy docs: virtual keys, routing/fallbacks, rate limits, budgets, Prometheus.
- Hugging Face Hub docs: cache management, `hf` CLI, environment variables (offline, endpoint).
- Model Context Protocol specification (modelcontextprotocol.io).
- Langfuse docs: self-hosting (Docker Compose / Kubernetes).
- NVIDIA GPU Operator docs: overview, time-slicing, MIG, air-gapped install.
