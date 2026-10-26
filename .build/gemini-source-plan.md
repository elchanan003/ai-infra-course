# Source plan (from the learner's Gemini consultation) — AI Infrastructure & Platform (LLMOps)

Context: learner is moving from classic DevOps (containers, K8s, networking, CI/CD) into an "AI Infrastructure & Platform" team (a.k.a. LLMOps), probably an air-gapped / on-prem organization. Workloads differ from web services: model weights of tens/hundreds of GB, GPU VRAM bottlenecks, streaming network traffic, budgets measured in tokens (not just RPS).

## 1. Architecture: 4 layers
1. Clients & Agents: Open WebUI, IDE coding tools (Continue.dev / Cline / Roo Code), terminal coding agents (Aider, Claude Code pointed at internal proxy), internal systems.  -> uniform protocol: OpenAI REST API
2. AI Gateway & control (LiteLLM Proxy): virtual keys, routing & load balancing, rate limiting (RPM/TPM), usage/log tracking.
3. Inference & serving: vLLM (production LLM serving), Text Embeddings Inference (TEI), Ollama / llama.cpp (lightweight).
4. Hardware & infra: NVIDIA GPU servers, Kubernetes + GPU Operator / Docker, fast weight storage (NVMe / internal S3 / MinIO / NFS), air-gap.

## 2. Deep-dive topics
A. Model serving / inference
- Weights & formats: Safetensors (safe, vs Pickle), GGUF for local/light. Model = huge binary of matrices.
- Quantization: FP16 -> INT8/INT4; AWQ, GPTQ, FP8. Lets a 140GB-VRAM model fit in 80GB with minimal quality loss.
- vLLM: PagedAttention + KV cache management (paged like OS virtual memory), continuous batching.
- VRAM math rule of thumb: VRAM_GB ~= params(B) x bytes_per_param x 1.2 overhead. Example: 70B FP16 = 70 x 2 x 1.2 = 168 GB -> at least 2x 80GB H100/A100 with Tensor Parallelism.
- Key vLLM args: --tensor-parallel-size, --gpu-memory-utilization (default 0.9), --max-model-len.
B. Air-gapped environment
- Moving weights: 15GB-400GB per model; Hugging Face download -> security scan -> internal storage (MinIO/S3/NFS); needs stable automation.
- Disabling "phone home": HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1, all config paths local (tokenizers etc.).
- Driver & base images: vllm/vllm-openai images are 10-20GB (CUDA + PyTorch). Internal registry/Artifactory analogies.
- Hugging Face repo structure: config.json, tokenizer.json, *.safetensors; `huggingface-cli download` for offline environments.
C. Gateway: LiteLLM Proxy
- Protocol normalization to OpenAI API (/v1/chat/completions) in front of vLLM or external providers.
- Token-based rate limiting (TPM alongside RPM), state in Redis.
- Virtual keys & permissions: PostgreSQL; per-key/team model access and virtual budgets.
- Smart routing: fallbacks & load balancing across GPU servers/models.
D. Clients, dev tooling, agent infrastructure
- Open WebUI: enterprise chat UI (SSO/LDAP, built-in RAG, prompt sharing) pointed ONLY at LiteLLM (OPENAI_API_BASE_URL, OPENAI_API_KEY).
- AI coding assistants in air-gap: Continue.dev, Cline/Roo Code, Aider, Claude Code via internal proxy. Two model types needed: big smart chat/agent model + tiny fast FIM (Fill-In-the-Middle) autocomplete model with ~zero latency.
- Agents: function calling / tool use; MCP (Model Context Protocol) — open standard to connect models/clients to enterprise tools & data; Sandboxing — agent-generated code must run in ephemeral containers/pods, never on the host.
- RAG infra: embedding models + vector DBs (Qdrant, Milvus, pgvector over PostgreSQL).
E. Observability & governance for AI
- DCGM exporter -> Prometheus + Grafana (GPU util, temp, power, VRAM).
- TTFT (Time To First Token), ITL / TPS (tokens per second), KV cache usage % (100% => queueing) via vLLM/LiteLLM built-in metrics.
- Tracing & token accounting (who asked what, tokens consumed, cost): Langfuse (self-hosted) + OpenTelemetry (OpenLLMetry).

## 3. Gemini's suggested hands-on roadmap (local lab, no big GPU required)
Step 1 (days 1-3): Docker Compose base stack. Ollama (or vLLM if NVIDIA GPU) with a tiny model (llama3.2:1b, qwen2.5-coder:1.5b). LiteLLM Proxy with config.yaml (model_list -> local model), + PostgreSQL + Redis. Create Virtual Keys (UI/API), set tpm limit and watch it block. Open WebUI pointed only at LiteLLM.
Step 2 (days 4-5): developer client tooling. VSCode Continue or Cline configured against local LiteLLM; inspect LiteLLM logs to see how coding-tool requests look (huge system prompts, file trees, tool definitions) vs plain chat.
Step 3 (days 6-8): GPU world, vLLM, monitoring. NVIDIA Container Toolkit & GPU Operator concepts, MIG (Multi-Instance GPU). Walk through the key vLLM CLI args. Run Langfuse and connect to LiteLLM with ~2 lines of config; watch traces appear from Open WebUI chats.

## 4. Recommended reading (engineering-focused, not neural-net math)
vLLM blog (PagedAttention post); LiteLLM Proxy docs (Config.yaml, Virtual Keys, Routing/Load Balancing, Logging/Callbacks); Hugging Face Hub docs (model repo structure, CLI); modelcontextprotocol.io Architecture Overview; Langfuse docs (self-hosting + LiteLLM integration).

## 5. Good questions for the first week of onboarding
- How is the weight lifecycle managed in the air-gapped environment: Object Storage (S3/MinIO) loaded on pod start, or fast shared FS (NFS/NVMe)?
- Do models run on Kubernetes (GPU Operator / KServe) or dedicated machines with Docker Compose?
- How is traffic separated in LiteLLM between regular chat (Open WebUI) and heavy agent/coding-tool traffic, so a looping agent doesn't starve the GPUs for everyone?
