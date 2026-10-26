# PLAN — "AI Infrastructure & Platform (LLMOps)" onboarding course

## Context
The learner (junior DevOps: Docker/K8s/networking/CI-CD) is joining an AI-platform / LLMOps team, likely air-gapped on-prem. They need a ~2-week (3-4 h/day, ~44 h) practical course built exactly like the finished sibling `/home/student/observability-course` (tutor `CLAUDE.md` + `PROGRESS.md` + modules with validated prepare/verify/cleanup/verify-clean harnesses). Source: `.build/gemini-source-plan.md` (good skeleton, several errors). Host (verified): arm64 **Neoverse-N1** (NEON+dotprod, no bf16/i8mm/SVE), 4 vCPU, 23 GB RAM (~15 GB free; rakazo-* uses ~7 GB), **no GPU**, 133 GB free disk, Docker 29.8 (containerd store), compose v5, kind/kubectl/helm/uv in `~/.local/bin`. Ports 18000-18199 free.
Method: Sonnet subagents did (a) live version/arm64 research (registry manifests, GitHub/PyPI APIs, docs), (b) syllabus + harness design, (c) critic review — all folded in below. Plan mode was read-only, so **RAM/throughput figures are estimates until the WP0 spike measures them**; nothing was pulled or run.
First actions after approval: save this plan as `.build/PLAN.md` and the research + critic reports as `.build/research-notes.md`.

## 1. Scope / non-goals
**In:** serving & inference internals + vLLM ops; weights lifecycle & air-gap; LiteLLM gateway; clients & agent infra (Open WebUI, Continue/Aider, FIM vs chat, function calling, MCP, sandboxing, RAG infra); AI observability & governance (TTFT/ITL/TPS, KV%, DCGM, Langfuse, token accounting); GPUs on Kubernetes; capstone; onboarding prep.
**Out:** NN math, training/fine-tuning, prompt engineering, model-quality evaluation, app frameworks (LangChain etc.), real CUDA/driver installs, multi-region gateway HA beyond concepts, SaaS providers beyond "LiteLLM can front them".

## 2. Verified corrections / additions to the Gemini plan
| Gemini claim | Verdict (checked 2026-10-26) |
|---|---|
| VRAM ≈ params×bytes×1.2; "70B FP16 = 168 GB → 2×80 GB with TP" | Ignores KV cache. Teach weights + KV explicitly: KV/token = `2×layers×kv_heads×head_dim×bytes` (Llama-3-70B FP16: 320 KiB/token ≈ 1.25 GB per 4k sequence). 70B FP16 on 2×80 GB is **marginal** (a handful of sequences); 4×80 GB is practical; FP8 on 2×80 is the common alternative. TP degree must divide attention/KV head counts. |
| `--gpu-memory-utilization` default 0.9 | Current docs: **0.92** (re-check on pinned version in WP0). Fraction of *this GPU's* memory the instance may claim for weights+activations+KV — not a KV-only knob, not a limit on other processes. `--kv-cache-memory-bytes` overrides it. |
| Quantization AWQ/GPTQ/FP8 | Correct, plus: FP8 needs Ada/Hopper+; Marlin kernels; quantization shrinks weights, not KV (separate `--kv-cache-dtype fp8`); GGUF in vLLM is experimental. |
| `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` | HF_HUB_OFFLINE valid; teach `HF_HOME`, `HF_HUB_CACHE`, `HF_ENDPOINT` (internal mirror, how Artifactory/Nexus HF remotes are used), `local_files_only`. TRANSFORMERS_OFFLINE is legacy. Env vars ≠ air-gap — prove with network isolation. |
| `huggingface-cli download` | Current CLI is **`hf`** (`hf download --local-dir`), huggingface_hub 2.3.0. |
| vllm-openai images 10-20 GB | ~10.3 GB compressed (v0.32.0). An official **arm64 CPU image** `vllm/vllm-openai-cpu:v0.32.0` (1.24 GB) exists; N1 support is unproven. |
| MinIO for weights | **MinIO community repo archived 2026-04-25**, no new images → use **SeaweedFS 4.51** (S3 API); mention MinIO as legacy-but-common. |
| LiteLLM TPM in Redis | Partly: keys/teams/budgets need Postgres (`DATABASE_URL` + master key); Redis shares limits/cooldowns across replicas (in-memory otherwise). Spend logs are batch-written (lag). The Prometheus callback is not enterprise-gated in current docs (re-check in WP0). |
| Ollama for local serving | Ollama has **no native Prometheus `/metrics`** (PRs still open). Use **llama.cpp server** (`--metrics`, `/slots`, `/props`, `/v1/*`, `/infill` FIM, `--embeddings`, `--jinja` for tools); Ollama covered in theory. |
| MCP | Open standard; current spec **2026-07-28** (stateless, `server/discover`); previous 2025-11-25. Python SDK `mcp` 2.3.0; LiteLLM has a real MCP gateway. |
| Langfuse + OpenLLMetry | Langfuse v3+ = web + worker + Postgres + ClickHouse + Redis + S3 (~4-5 GB); v4 is latest — WP0 picks. |
| **Missing in Gemini** | KV/prefix-aware routing (llm-d v1.0, vLLM production-stack, Gateway API Inference Extension), capacity planning, cold start/weight-load time, GPU health (XID/ECC/throttling), DCGM semantics (GPU util ≠ saturation), time-slicing vs MIG vs MPS, DRA (k8s 1.34+), models as OCI artifacts (ORAS 1.3.6, KitOps, KServe modelcar), pickle scanning (picklescan 1.0.5, modelscan 0.8.8, fickling), OpenAI-compat gaps between engines, PII in prompt logs, TGI in maintenance mode. |

## 3. Lab environment
### 3.1 Components (all arm64 confirmed by manifest; exact tags + digests frozen in `platform/versions.env` in WP0)
| Component | Pin | Role | Mode |
|---|---|---|---|
| llama.cpp server | `ghcr.io/ggml-org/llama.cpp:server-b<N>` | real engine: chat, coder (FIM), embeddings | real |
| Models (cached in `~/.cache/aiinfra-course/`) | chat Qwen2.5-0.5B-Instruct Q4_K_M (491 MB) + Q8 (size lab); FIM Qwen2.5-Coder-0.5B base GGUF; embed bge-small-en-v1.5 GGUF; HF-layout repo SmolLM2-360M-Instruct safetensors (724 MB) | Apache/MIT | real |
| **mock-vllm** (course-owned FastAPI image `aiinfra-mock:1.0`) | — | OpenAI-compatible + streaming; exact vLLM metric names; capacity model from real `config.json` geometry; real vLLM error strings; **deterministic mode with a virtual clock** (latency = f(concurrency, tokens)); fixed `usage`; **scripted "mock-chat" mode** (pattern → `tool_calls`, Aider SEARCH/REPLACE, FIM shape echo); fault API `/admin/fault` (latency, error_rate, kv_pressure, crash, slow_load, other_gpu_mem) | sim |
| **mock-dcgm** + fake `nvidia-smi` (same image) | — | DCGM_FI_* metrics for N simulated GPUs; faults: xid, thermal, ecc, vram_leak | sim |
| **hf-mirror** (course-owned, ~50 lines FastAPI) | — | HF-Hub-compatible `/api/models/...` + `resolve/` served from the local cache → `HF_ENDPOINT` labs | real (stand-in for Artifactory) |
| tripwire (course-owned) | dnsmasq `address=/#/<sink-ip>` + HTTP sink counting hosts | air-gap leak detector: DNS server of the `internal: true` network; also attached to the normal network for controls | real |
| vLLM CPU | `vllm/vllm-openai-cpu:v0.32.0` `--dtype float16` | optional real-vLLM task, only if WP0 spike passes | optional |
| LiteLLM | `ghcr.io/berriai/litellm-database:<exact v1.106.x tag>`; base config `proxy_batch_write_at: 5` (lab-only, flagged in theory) | gateway | real |
| Postgres + pgvector / Valkey | `pgvector/pgvector:pg17` / `valkey/valkey:9` (LiteLLM compat checked in WP0) | gateway state, pgvector option | real |
| Open WebUI | `ghcr.io/open-webui/open-webui:v0.12.4` — `WEBUI_ADMIN_*` bootstrap, fixed `WEBUI_SECRET_KEY`, `ENABLE_OLLAMA_API=false`, `OFFLINE_MODE=true`, `RAG_EMBEDDING_ENGINE=openai` (via gateway), tiktoken cache pre-seeded, fresh volume per prepare | client | real |
| Qdrant | `qdrant/qdrant:v1.20.0` | vector DB | real |
| SeaweedFS / registry / ORAS | `chrislusf/seaweedfs:4.51` / `registry:3` / ORAS 1.3.6 | internal S3 + OCI registry (images and weights as OCI artifacts) | real |
| Prometheus / Grafana | `prom/prometheus:v3.5.0` (+ `promtool`) / `grafana/grafana:12.1.1` (already cached) | AI observability; 5 s scrape in labs | real |
| Langfuse | v3 `3.225.14` or v4 (WP0) + `clickhouse/clickhouse-server:25.8` | tracing / token accounting, run alone | real, separate gate |
| kind | v0.29.0 / node v1.33.1 (cached), cluster `aiinfra` | GPUs on k8s. **Primary: node-status patch** advertising `nvidia.com/gpu` (+ GFD-style labels); **optional: run-ai fake-gpu-operator v0.2.1** if the spike works | sim |
| Python venv (`uv`, `platform/.venv`) | `huggingface_hub` 2.3.0 (`hf`), `openai`, `mcp` 2.3.0, `safetensors`, `picklescan`, `boto3`, `qdrant-client`, `aider-chat` 0.86.2 (optional extra if install fails) | learner tooling | real |
| kubeconform v0.8.0 | arm64 binary | dry-run/schema validation of time-slicing ConfigMap etc. | real tooling |

Not runnable here (taught as theory + sim, said explicitly to the learner): vLLM on GPU, DCGM-exporter, NVIDIA Container Toolkit/CDI, GPU Operator, MIG, MPS, DRA, gVisor (needs a Docker daemon change, which is forbidden), TEI (amd64-only), VS Code extensions (Cline/Roo/Continue IDE).

### 3.2 Real vs simulated matrix
| Topic | Taught with | Verified by |
|---|---|---|
| OpenAI API, SSE, tokens, embeddings, RAG | real llama.cpp | verify's own nonce requests |
| Prefill/decode, batching, prompt cache, quantization | real llama.cpp | **counters, not wall-clock**: `/slots` (`n_prompt_tokens`, cache hits), `/metrics` token counters, `/props` flags, exact file sizes; timing only as ratio-threshold with median-of-3 + 1 retry |
| VRAM/KV/TP/MIG sizing | calculator | learner's `sizing.py` on hidden per-learner variants (±2%, incl. GQA, fp8 KV, TP-divisibility) |
| vLLM flags, startup OOM, KV%, preemption, queueing, SLO tuning | mock-vllm deterministic mode (+ optional real vLLM-CPU) | live startup outcome, metric deltas under verify-generated load |
| Tool calling, Aider, FIM | **mock-chat scripted mode** (graded: plumbing); real llama.cpp optional exploration | nonces through the loop, request shape, routing, spend rows |
| Weights / air-gap | real SeaweedFS, registry, ORAS, hf-mirror, internal network + tripwire | sha256, digests, tripwire counters (0 for solution, >0 for control) |
| Gateway | real LiteLLM + PG + Valkey, mock backends with fixed `usage` | live 200/403/429, restart durability, backend counters, exact spend |
| AI observability | real Prometheus/Grafana/Langfuse over mock + real metrics | learner rules via `promtool test rules` (deterministic) + 1 bounded live smoke |
| DCGM | mock-dcgm + fake nvidia-smi | promtool tests + live fire/quiet pair |
| GPUs on k8s | kind + node-patch (opt. fake-gpu-operator); time-slicing via dry-run | Running vs Pending (`Insufficient nvidia.com/gpu`) pairs; schema validation |

### 3.3 Isolation, ports, profiles, budget
- Compose project `aiinfra`; networks `aiinfra` and `aiinfra-airgap` (`internal: true`, DNS = tripwire); label `course=aiinfra` on every container/volume/network/k8s object; kind cluster `aiinfra`; all compose services `pull_policy: never` after setup (proves offline). Cleanup is always label-scoped; never prune; never touch rakazo-*, cli-proxy-api, workout-mongo, kali-cli or the obs course.
- Ports (127.0.0.1; UIs also on Tailscale 100.127.87.65): LiteLLM 18040 · Open WebUI 18080 · Grafana 18030 · Prometheus 18090 · llama chat/coder/embed 18011/18012/18013 · mock-vllm A/B 18021/18022 · vllm-cpu 18023 · mock-dcgm 18031/18032 · Qdrant 18033 · Postgres 18054 · Valkey 18063 · registry 18050 · SeaweedFS S3 18070 · hf-mirror 18071 · Langfuse 18060 · kind NodePorts 30000-30010 → 18100-18110. doctor.sh checks each port is free or course-owned.
- Profiles (`platform/stack.sh up <p...>` converges exactly, as in the sibling): `gw` (litellm, postgres, valkey) ~1.2 GB · `llm` (3× llama.cpp) ~2.5-3 · `mock` ~0.4 · `obs` ~0.8 · `ui` ~1.2 · `rag` ~0.3 · `store` (seaweedfs, registry, hf-mirror, tripwire) ~0.5 · `lf` ~4-5 · `vllm` ~3-4 (estimates). Rules: peak ≤ 8 GB; `lf`, `vllm` and kind never together with `llm`; doctor warns if MemAvailable < 6 GB.
- Disk: images ~12 GB, models ~3 GB, volumes < 2 GB (WP0 measures). `platform/setup.sh` = the "connected side": pulls by digest, downloads models + vendored CRD schemas/charts, builds course images, creates the venv; after that everything runs offline.

## 4. Modules (~44 h)
**Harness rules for all modules** (from CONVENTIONS + course-harness skill): starter scores 0; reference solution 100% with no manual steps; 5 runs identical; preconditions (health, targets up) printed but **not scored**; positive+negative pairs; verify generates its own load and nonces; learner configs/queries are **executed** live (never grepped); answer files reject shipped template values; enum answers always come with a variant-bound evidence field (guessing doesn't pass); spend checks use `litellm_flush_wait` (bounded poll); 429 checks are burst-based (`rpm_limit: 2`, burst of 5 → ≥1 × 429, ≤2 × 200; recovery = poll for 200 within 70 s); BLOCKED cascade. New `platform/lib.sh` helpers: `litellm_api`, `litellm_flush_wait`, `mock_stats`, `env_kv`, `within`, `tripwire_hits`, `sandbox_run`, `wait_idle`, `promtool_test`, `k` (kind-aiinfra), plus the sibling's own helpers.

| ID | Module | h | deps | real/sim/theory | Learner can, at the end... |
|---|---|---|---|---|---|
| 00 | orientation | 1.5 | — | 40/20/40 | draw the 4-layer architecture, run the stack, trace one request client→gateway→engine |
| 01 | serving-internals | 5 | 00 | 35/25/40 | explain prefill/decode/KV/batching; size VRAM, KV and TP for any model |
| 02 | weights-airgap | 4.5 | 00 | 65/0/35 | move a model across an air gap with integrity + scanning and serve it provably offline |
| 03 | vllm-ops | 4.5 | 01 | 10/55/35 | predict and fix vLLM startup/KV/preemption problems from flags and metrics |
| 04 | gateway-core | 4 | 00 | 70/10/20 | run LiteLLM with keys, teams, TPM/RPM limits, durable state, shared Redis |
| 05 | gateway-routing-governance | 3.5 | 04 | 55/35/10 | design LB, fallbacks, cooldowns, budgets and chat-vs-agent traffic separation |
| 06 | clients-coding-tools | 3.5 | 04 | 60/25/15 | wire Open WebUI and coding tools to the gateway; tell FIM from chat; read a coding-agent request |
| 07 | agents-mcp-sandbox-rag | 4 | 04 | 65/15/20 | build a tool loop + MCP server, sandbox agent code, run RAG infra |
| 08 | ai-observability | 5 | 03,05 | 40/45/15 | build AI dashboards, recording rules, alerts, token accounting, LLM tracing |
| 09 | gpu-on-k8s | 4 | 03,08 | 10/50/40 | explain the GPU stack driver→pod; read DCGM failures; write correct GPU scheduling manifests |
| 10 | capstone | 5 | all | 30/70/0 | run AI-platform incidents end to end with a postmortem |
| 11 | onboarding-prep | 0.5 | any | theory | arrive with a map of alternatives, sharp questions, a first-week plan |
Hands-on share ≈ 60% (much of it on simulated targets — stated honestly to the learner).

Lab tasks — `[verify method / false-pass defence]`, **T** = planted troubleshooting:
- **00**: 0.1 `stack.sh up gw llm` + doctor [precondition, unscored]; 0.2 streaming curl, count chunks + `usage` [values vs verify's own deterministic request to the mock]; 0.3 find verify's nonce request in LiteLLM logs → request id [id exists in spend logs with the nonce]; 0.4 `ARCH.env` component→layer [enum + per-variant component names]; **T** chat alias points at the wrong port [completion via alias returns 200].
- **01**: 1.1 implement `sizing.py` (`weights_gb`, `kv_gb`, `fits`, `min_tp`) [6 hidden variant cases incl. GQA, fp8 KV, TP divisibility, ±2%]; 1.2 `vram.env` for the variant model; 1.3 `--parallel 1` vs `4`: aggregate throughput [ratio threshold, median-of-3 + retry, from `/metrics` token counters]; 1.4 prompt cache on/off on a long repeated prefix [`/slots` cached-token counts + `/props` flag; deterministic]; 1.5 Q8 vs Q4 [exact file sizes + tensor-type answer; no tok/s ordering]; 1.6 TP/MIG sizing for a 70B variant [hidden variant]; **T** starter `sizing.py` with a MiB/GB mix-up and a missing GQA factor [hidden cases fail until fixed].
- **02**: 2.1 `hf download` through `HF_ENDPOINT=hf-mirror` → local dir + sha256 manifest; read the shard/tensor count from the safetensors header (8-byte LE + JSON) [manifest matches blobs; counts computed live]; 2.2 a static pickle scanner (pickletools opcodes) + picklescan [5 hidden files: 2 malicious flagged, 0 false positives, canary never created → proves no load]; 2.3 weights into SeaweedFS with RO/RW identities [RO GET ok / PUT 403 pair, checksum]; 2.4 serve on `aiinfra-airgap` with offline env + local cache [completion via in-network probe AND tripwire_hits == 0; control without offline config hits the tripwire]; 2.5 mirror the llama.cpp image into `registry:3`, run by digest; push GGUF as an OCI artifact with ORAS [running digest == registry digest; `oras pull` sha matches]; **T** synced model missing `tokenizer.json` + one shard with a flipped byte [learner names file + bad sha; repaired artifact verifies and serves].
- **03**: 3.1 `PREDICT.env` for 3 configs before launching [vs live outcome]; 3.2 fix "max seq len larger than KV cache" without lowering `max_model_len` below a floor [health 200 + floor]; 3.3 8 concurrent seqs with no preemption [preemption delta 0, running peak ≥ 8]; 3.4 p95 TTFT computed by hand from raw `/metrics` buckets [±10% of verify's `histogram_quantile`]; 3.5 KV-pressure symptom order + `KV_PEAK` [vs `max_over_time`]; 3.6 choose `max_num_seqs` for an SLO table [deterministic hidden load: p95 TTFT < SLO and throughput ≥ floor]; 3.7 *(optional, if spike ok, unscored)* real vLLM-CPU; **T** `--gpu-memory-utilization 0.98` dies on a node where another process holds memory [starts + util ≤ free fraction].
- **04**: 4.1 `config.yaml` chat+embed aliases (`openai/` prefix, `api_base`) [`/v1/models`, completion, embedding dimension]; 4.2 key limited to one model [200 vs 401/403 pair]; 4.3 rpm/tpm on a key [burst rule]; 4.4 durability [verify restarts litellm → same key 200]; 4.5 two LiteLLM replicas + Valkey [global limit holds across replicas; control without Redis exceeds it]; 4.6 backends reachable only via the gateway (networks) [direct call from client network fails / via gateway works]; **T** key vs team model-list mismatch [fixing it with `*` fails: the other model must stay denied].
- **05** (mock backends, fixed usage): 5.1 LB [split 40/60 over 100 calls]; 5.2 fallback A→B [A error_rate=1 → 200 + B moves; healthy A → B untouched]; 5.3 cooldown [≤ K hits to A during cooldown]; 5.4 cost map + budget key [spend == hand-computed (exact) after flush; then `budget_exceeded` within bounded poll]; 5.5 teams chat vs agents (`max_parallel_requests`, tpm) [provided looping agent capped while chat stays 200 with deterministic p95 under target]; **T** fallback never fires on a context-length 400 → `context_window_fallbacks` [long prompt succeeds via the fallback model].
- **06**: 6.1 Open WebUI points only at LiteLLM with its own key (connection set via UI/API — teach `PersistentConfig`) [verify signs in via API, sends a nonce chat, nonce arrives at LiteLLM under that key; no direct backend traffic]; 6.2 Aider via the gateway (mock-chat scripted edit) [file changed + aider key spend row]; 6.3 Continue `config.yaml` chat + autocomplete roles; FIM via coder alias [verify replays the configured FIM request; mock echoes shape: prompt/suffix/FIM tokens/model routed to coder]; 6.4 dissect a captured coding-agent request (system prompt size, #tools, prompt tokens) [±5% of logged values]; **T** empty/slow model list (stale Ollama URL in the DB, `ENABLE_OLLAMA_API` on) [model list loads < N s]. (Optional, unscored: real VS Code Continue over Tailscale.)
- **07**: 7.1 tool-calling loop (mock-chat) [nonce from the tool result reaches the final answer]; 7.2 MCP server (python `mcp`, Streamable HTTP, 2 tools) [verify's MCP client lists + calls with a nonce]; 7.3 hardened sandbox runner (`--network none --read-only --cap-drop ALL --pids-limit --memory --user`, tmpfs, `timeout`) [probes: egress / rootfs write / fork bomb / mem hog all blocked AND nonce written to the allowed tmpfs; control with the same resource caps but open network hits the tripwire]; 7.4 code-exec as an MCP tool [end-to-end output, no leaked containers]; 7.5 RAG ingest via gateway embeddings into Qdrant [point count == expected chunks; a known fact ranks 1st]; **T** runner mounts a (decoy) docker socket + host `/etc` [mounts removed; probe sees no docker API]. 7.6 embedding-model change → optional, unscored.
- **08**: 8.1 scrape mock-vllm, llama.cpp, LiteLLM `/metrics` [precondition + metric names present]; 8.2 TTFT p95 recording rule [`promtool test rules` with verify's synthetic series + 1 live value ±10%]; 8.3 Grafana dashboard-as-code (queue, KV%, TTFT/ITL, tok/s, spend/key) [each panel query returns data via the Grafana API]; 8.4 alerts KVCacheNearFull / TTFTHigh / QueueGrowing [promtool fire/quiet tests + one live fire under fault, `for:` ≤ cap]; 8.5 token reconciliation spend logs vs Prometheus [after flush barrier, ±2%]; **T** flat TTFT panel (`rate()` on a gauge / average of `_sum` only) [fixed query matches the reference]. **8.L Langfuse** (separate gate `verify.sh langfuse`, run alone with profile `lf`): trace a nonce user via the LiteLLM callback [trace found via API with model/tokens/user].
- **09**: A (compose `mock obs`): 9.1 answer from fake `nvidia-smi` [variant]; 9.2 DCGM alert rules for XID/thermal/ECC/VRAM leak [promtool + live fire/quiet]; 9.3 drain-vs-wait per XID with evidence (XID code + GPU UUID from the variant) [enum + evidence]. B (kind + node-patch): 9.4 node advertises `nvidia.com/gpu` + product labels [node JSON]; 9.5 GPU pod with requests/tolerations/nodeSelector [Running + over-capacity pod Pending with `Insufficient nvidia.com/gpu` pair]; 9.6 time-slicing ConfigMap [kubeconform + server-side dry-run; explicitly "validated, not exercised"]; 9.7 TP=2 Deployment needs 2 GPUs on one node [scheduled on the 2-GPU node only]; **T** `nvidia.com/gpus` typo + missing toleration [pod Running].
- **11**: questions-for-the-team + first-week plan files [sections filled, minimal checker like the sibling's 11].

Each module also ships: `theory.md` (deep, version-accurate, "how teams run it", pitfalls, Key takeaways, Check yourself), `quiz.md` (10-15 q), `.tutor/{answers.md,hints.md,solution/,apply-solution.sh}`.

## 5. Capstone (10) — `prepare-lab.sh N`, graded N.1-N.5 like the sibling
| N | Page | Planted fault | Layer |
|---|---|---|---|
| 1 | "Chat users get 429s/slow while one team hammers" | agent key without `max_parallel_requests`; replicas not sharing Valkey → per-replica limits | gateway |
| 2 | "Latency spikes at peak after a release" | `max_num_seqs` raised + prefix caching off → KV 100%, preemptions, queue | serving (mock) |
| 3 | "One replica slow, gateway keeps sending traffic" | mock-dcgm node B: XID 79 / thermal throttle; router without cooldown | GPU metrics + routing |
| 4 | "New model rollout won't start" | artifact missing tokenizer + bad shard; `HF_HUB_OFFLINE` unset → tripwire hits | air-gap |
| 5 | "Model pod Pending after node-pool change" | time-slicing config leaves capacity 0 + missing toleration | k8s |
- N.1 durable fix (source-of-truth config; survives a verify-triggered restart; `/admin/fault`/exec doesn't count) · N.2 live probe (40 requests via gateway, no 5xx, deterministic mock TTFT p95 < SLO, incident specifics) · N.3 `N-rootcause.env` COMPONENT + CAUSE enum {bad-release, misconfiguration, rate-limit-misconfig, kv-cache-exhaustion, capacity-overload, hardware-fault, artifact-integrity, air-gap-leak, scheduling-config, dependency-outage, runaway-client} · N.4 evidence vs live data (KV_PEAK, PREEMPTIONS, XID_CODE/GPU_UUID, bad file + sha, TRIPWIRE_HOST, PENDING_REASON, failing REQUEST_ID) — makes enum guessing useless · N.5 postmortem checker (sibling's `pm_check.py` approach).

## 6. Course layout (mirrors the sibling)
```
ai-infra-course/
  CLAUDE.md  AGENTS.md->CLAUDE.md  GEMINI.md->CLAUDE.md  README.md  SYLLABUS.md  PROGRESS.md  CONVENTIONS.md  .gitignore
  platform/  setup.sh doctor.sh stack.sh k8s.sh lib.sh versions.env models.txt stack/{compose.yaml,README.md,config/} k8s/
  mock/      mock-vllm, mock-chat mode, mock-dcgm, fake nvidia-smi, hf-mirror, tripwire; README.md = contract (metric names, capacity model, fault API, scripted patterns)
  modules/00-orientation … 11-onboarding-prep/  theory.md lab.md quiz.md lab/ prepare-lab.sh verify.sh cleanup.sh verify-clean.sh .tutor/
  cheatsheets/ vllm-flags-metrics.md litellm.md vram-kv-math.md hf-airgap.md gpu-k8s-dcgm.md mcp-agents.md
  .build/    PLAN.md research-notes.md author-brief.md finish-prefix.md BUILD-STATUS.md validate-module.sh evidence/
```
`.gitignore`: `lab.bak-*/ .last-verify .state/ __pycache__/ .venv/` (`.build/` is committed, as in the sibling, but no secrets).
- **PROGRESS.md schema** (sibling's): State (current, `next_action` = concrete step plus exact command, onboarding_date, course_started, env `profiles=… kind=absent|up`) · Modules table (id | status | verify | quiz | done_date | notes) · Current module steps ([x] + hints used) · Weak areas · Strengths · Open questions for the team · Session log. Updated and committed after **every** task.
- **CLAUDE.md outline** (sibling's, adapted): session start (read PROGRESS → doctor → Hebrew greeting of 2-4 lines → continue) · language (Hebrew speech, English terms/commands, e.g. "ה-`--gpu-memory-utilization` קובע כמה מה-VRAM ה-vLLM משריין"; files in English; FAIL lines stay English and the tutor explains them) · course map · teaching loop (theory chunks + check q → predict → learner does lab → verify → quiz → close + commit) · hint ladder H1-H4 logged · progress rules · pacing priorities (01, 03, 04, 05, 08, 09, capstone; cut optional tasks if behind) · environment rules (label, ports, RAM rules, never touch other containers) · **honesty rule** (always say what is simulated and how production differs) · domain misconceptions list (VRAM = weights only; gpu-memory-utilization semantics; per-replica limits; offline env vars ≠ air-gap; scanner pass ≠ safe; time-slicing ≠ isolation; GPU util ≠ saturation; average latency on streams; TTFT vs ITL).

## 7. Build plan
| WP | Content | Agent | Gate |
|---|---|---|---|
| WP0 spike (~2 h) | pull pins; measure RAM/disk per profile; llama.cpp metric/`/slots` names on N1; vLLM-CPU on N1 (Qwen-0.5B fp16) → golden `/metrics` (fallback: names from the pinned vLLM source); LiteLLM tag + prometheus + keys/limits/budget/batch-write smoke with Valkey; Open WebUI scripted signin/config/chat offline; Langfuse v3 vs v4 RAM; node-patch + fake-gpu-operator on kind arm64; aider install; freeze pins/digests | 1 Sonnet | report in `research-notes.md`; coordinator resolves decisions |
| WP1 core docs + contracts | README, CLAUDE.md (+symlinks), PROGRESS.md, SYLLABUS.md, CONVENTIONS.md (incl. port map, **mock API contract**, lib.sh API) | coordinator (Opus) | review |
| WP2 platform | versions.env, setup.sh, stack.sh + compose profiles, lib.sh, doctor.sh, k8s.sh | 1 Sonnet | all profiles healthy; doctor OK; down → 0 course containers; lib.sh frozen (changes only via the coordinator) |
| WP3 mock | mock-vllm (deterministic/virtual clock, mock-chat), mock-dcgm, nvidia-smi, hf-mirror, tripwire + tests | 1 Sonnet (parallel with WP2) | metric names == golden; deterministic runs identical |
| WP4 authors | A: 00,01,02 (after WP2) · C: 04,05,06 · B: 03,08 + cheatsheets (after WP3) · D: 07,09 (after WP3) · E: 10,11 (after 03/04/05/09 frozen) | 5 Sonnet, common `author-brief.md` | per module, run by `.build/validate-module.sh NN`: starter 0 → solution 100% ×3 identical → cleanup/verify-clean ×2 identical → lab/ restored; logs in `.build/evidence/NN/` |
| WP5 final | coordinator runs validate-module.sh on all modules itself; setup.sh from an empty cache (clean-machine rule); offline pass (`pull_policy: never`, no `latest`); teardown; commit | 2 Sonnet + coordinator | BUILD-STATUS all green with evidence |
- **Locking**: one lock per whole test cycle (prepare → verify → cleanup), via a `lab-session` wrapper: `flock -w 1800 /tmp/aiinfra-course-lab.lock` + owner file `/tmp/aiinfra-course-lab.owner`. Authors write content in parallel; test cycles are serialized.
- **Resume**: `.build/BUILD-STATUS.md` is updated after each WP/module with evidence paths; `finish-prefix.md` relaunches interrupted authors to audit + finish what is on disk; the coordinator commits after each gate (local only, never push).
- **Effort**: ~15-20 h wall (serialized test queue: ~30-50 cycles × 5-15 min), ~20-25 agent sessions. Top risks: mock fidelity, LiteLLM version semantics, Open WebUI automation, CPU-timing noise.

## 8. Decisions (defaults chosen; flagged) and risks
1. **Decision needed — Langfuse**: default = real Langfuse in 08 as a separate gate (`verify.sh langfuse`), run alone (~5 GB). Alternative: concepts only + LiteLLM spend logs.
2. **Decision needed — graded path for tool-calling/Aider/FIM**: default = deterministic mock-chat (grades plumbing; a 0.5B model is too unreliable); real llama.cpp as unscored exploration.
3. **Decision needed — HF mirror**: default = course-owned hf-mirror (stand-in for Artifactory/Nexus HF remote) so `HF_ENDPOINT` is practiced.
4. **Decision needed — GPU on kind**: default = node-status patch primary, fake-gpu-operator optional.
5. **Decision needed — real vLLM-CPU**: default = optional, unscored 3.7 only if the WP0 spike passes.
6. **Decision needed — IDE clients**: default = Aider + Continue `config.yaml` replay; VS Code over Tailscale optional.
7. Timing policy: real-CPU timing checks are threshold-ratio + median-of-3 + 1 retry; verify calls `wait_idle` and refuses to score when load is high (prints a WARN, not FAIL).
8. Risks: LiteLLM limit/budget semantics drift (pin exact tag, assert behaviour not text); shared host RAM (doctor guard); Open WebUI `PersistentConfig` (fresh volume per prepare); kind on arm64 + fake GPU; WP0 may change pins/images → WP1+ starts only after WP0.

## Verification (of the built course)
For each module, `.build/validate-module.sh NN` runs the following and saves logs:
1. `prepare-lab.sh` → `verify.sh`: 0 PASS.
2. `apply-solution.sh` → `verify.sh`: 100%, three times, identical.
3. `cleanup.sh` → `verify-clean.sh`, twice, identical.

The capstone runs per N. Then:
- `platform/setup.sh` from an empty cache.
- An offline run.
- `platform/doctor.sh` all OK.
- `docker ps -a --filter label=course=aiinfra` empty, no kind cluster `aiinfra`.
- Other containers and `observability-course` untouched.
- Local git committed, nothing pushed.
