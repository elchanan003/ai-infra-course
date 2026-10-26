# 11 — Onboarding prep: translate, ask, plan

Module time: ~30 min. No lab stack needed.

Goal: arrive on day 1 able to map whatever the team runs onto what you learned, with a list of sharp
questions and a concrete plan for the first week.

Caveat: this landscape moves quickly. Everything below describes the state as of late 2026 as best known at
authoring time; treat versions and project status as **things to confirm with the team** (section 1.9 lists
how to check quickly). The concepts (layers, KV, routing, limits, GPU scheduling, artifacts) are stable;
product names are not.

---

## 1. Concept map: what you learned vs what the team may run

Your lab: LiteLLM (gateway) -> mock-vllm / llama.cpp (engines) on simulated GPUs, Prometheus/Grafana, a registry
and mirror for artifacts, `kind` for GPU scheduling. Real teams assemble the same four layers from different parts.

```
clients -> [gateway / AI gateway] -> [router / inference scheduler] -> [serving engine + runtime] -> [GPU nodes / k8s]
                          \_ model registry / artifact store / air-gap pipeline   \_ observability + governance
```

### 1.1 Serving engines and model servers

| Project | What it is | Maps to what you know | Watch out for |
|---|---|---|---|
| vLLM | the most common open LLM engine (PagedAttention, continuous batching, prefix cache) | your whole modules 01 and 03 | flags and metric names change between minor versions; check the version's docs |
| SGLang | high-throughput LLM engine with RadixAttention (tree-structured prefix cache) and a structured-output/runtime focus | same concepts: KV, batching, prefix reuse | different flags (`--tp`, `--mem-fraction-static`), different metrics names, own router |
| TGI (Hugging Face Text Generation Inference) | earlier standard server (Rust router + Python/CUDA shards) | same concepts, `--max-batch-prefill-tokens`, `--max-total-tokens` | **maintenance mode** at authoring time: bug fixes, no new features; legacy deployments exist, new ones usually choose vLLM or SGLang. Confirm what the team actually runs |
| Triton Inference Server (NVIDIA) + TensorRT-LLM | general inference server with model repository, ensembles, dynamic batching; TensorRT-LLM backend for LLMs (engines compiled per GPU type) | model repository = your weights store; dynamic batching = batching; engine build step = an extra artifact stage | engines are **GPU-architecture-specific artifacts**: air-gap pipeline must carry the build or the build toolchain; ports 8000/8001/8002 (HTTP/gRPC/metrics) |
| NVIDIA Dynamo | distributed inference framework (disaggregated prefill/decode, KV-aware routing, KV offload) that can run vLLM/SGLang/TensorRT-LLM as workers | disaggregation = splitting the two phases of module 01 onto different pools | young; check version and which backend workers the team uses |
| llama.cpp / Ollama | local, CPU/small-GPU serving, GGUF | your llama.cpp containers | Ollama has no native Prometheus metrics; mostly dev/edge |
| TEI (Text Embeddings Inference) | embeddings/rerank server | your embed alias | often amd64/GPU-specific images |

Common Q: "what is the OpenAI-compatible endpoint?" Almost all expose `/v1/chat/completions`, but details (tool-call
formats, `usage` fields, streaming options, structured outputs) differ. The gateway normalises some of it.

### 1.2 Kubernetes serving layers

| Project | Role | Mapping |
|---|---|---|
| KServe | CRD-based model serving: `InferenceService`, runtimes (vLLM, Triton, etc.), autoscaling (Knative or raw Deployment mode), canary, model storage via storage initializer / modelcar (OCI image with the model) | your Deployment + Service + scale + artifact fetch, packaged as one CRD; modelcar = "models as OCI artifacts" (module 02) |
| Ray Serve (KubeRay) | Python serving framework on Ray clusters; `serve.llm` wraps vLLM, autoscaling by queue/request load, multi-model composition | a programmable router+replica manager; operators run `RayService` CRDs |
| llm-d | Kubernetes-native distributed inference stack on top of vLLM: inference scheduler (KV/prefix- and load-aware), disaggregated prefill/decode, wide expert parallelism, built with the Gateway API Inference Extension | your "router with KV awareness" idea (module 05 notes) |
| vLLM production-stack | reference Helm deployment of vLLM with a router, LMCache/KV offload options, Prometheus/Grafana | a turnkey version of your lab |
| Gateway API Inference Extension (GIE) | Kubernetes SIG project: `InferencePool` + `InferenceModel`/objective resources and an **endpoint picker** that an Envoy-based Gateway calls (ext-proc) to choose a replica using queue depth, KV usage, LoRA adapters, prefix hits | the router layer, expressed as Gateway API resources instead of LiteLLM config |
| GPU Operator, device plugin, DCGM, DRA | driver, runtime, plugin, labels, metrics, (newer) Dynamic Resource Allocation | module 09 |
| Kueue / Volcano / schedulers | quota and gang scheduling for batch/training GPUs | module 09 scheduling discussion; relevant for multi-team GPU quotas |

How teams run it: most on-prem teams pick **one** of {raw Deployments + Helm, KServe, Ray Serve, a vendor platform}.
Ask which; it determines where config lives and what "restart" means (module 10 N.1 idea: source of truth).

### 1.3 Gateways (the layer you know best)

| Product | Notes | Mapping |
|---|---|---|
| LiteLLM proxy | Python; keys, teams, budgets, routing, fallbacks, MCP gateway; Postgres + optional Redis/Valkey | your modules 04-05 |
| Kong AI Gateway | Kong plugins (AI Proxy, AI Rate Limiting Advanced, prompt guard, semantic cache) over Kong Gateway (nginx/Lua, optionally with a database or DB-less config) | key auth, rate limits, routes/services map to your keys/limits/models; declarative config (decK) |
| Envoy AI Gateway | Envoy Gateway + Gateway API based AI layer: routing by model header, token-based rate limiting, provider translation, upstream auth | token rate limit = TPM; `AIGatewayRoute` + backends = model list |
| Portkey (gateway) | open-source AI gateway and commercial control plane: config-driven routing, fallbacks, retries, guardrails, caching, budgets | "configs" = router settings; check whether the self-hosted gateway is used or the SaaS (air-gapped teams usually can only use self-hosted) |
| Cloud gateways (Azure APIM, AWS, Cloudflare) | for hosted-model access | rarely on-prem air-gapped |
| Open WebUI, coding tools | clients (module 06) | |

Questions that distinguish them: where do limits live (key vs team vs route), are counters shared across replicas
(module 10 incident 1), how are keys provisioned (UI, API, GitOps), are spend logs and metrics exported.

### 1.4 Observability for AI

| You learned | Alternatives you may meet |
|---|---|
| Prometheus + Grafana, vLLM/LiteLLM/DCGM metrics | VictoriaMetrics, Datadog (vLLM and NVIDIA integrations), Grafana Cloud, NVIDIA's DCGM dashboards |
| Langfuse (tracing, tokens) | LangSmith, Arize Phoenix, OpenLIT, Helicone, OpenTelemetry GenAI semantic conventions (`gen_ai.*`) |
| Spend logs | gateway usage APIs, cost allocation by team/key |

### 1.5 Weights, registry, air gap

| You learned | Alternatives |
|---|---|
| hf-mirror + HF_ENDPOINT, local cache | Artifactory/Nexus HF remote repositories, Harbor, a model registry (MLflow, Hugging Face Enterprise Hub, internal S3) |
| OCI artifacts (ORAS), registry:3 | Harbor, KitOps ModelKits, KServe modelcar images |
| sha256 manifests, picklescan | signed models (Sigstore model-signing), safetensors-only policy |

### 1.6 Quick glossary swaps
- "Replica" in KServe = a revision's pod; "predictor"/"runtime" = engine container + args.
- "Endpoint picker" (GIE) = the smart router; "InferencePool" = the set of engine pods.
- "Disaggregated serving" = prefill pool and decode pool exchanging KV; adds a KV transfer layer (NIXL, etc.).
- "LoRA adapters" served on one base model: the router must know which pod has which adapter loaded.

### 1.7 What mostly transfers
- Four layers + artifacts + governance is the same map everywhere.
- KV cache, queue, preemption, TTFT/ITL, `max_num_seqs`: every engine has equivalents.
- 429/limit scope, cooldown, fallbacks, timeouts: every gateway.
- XID/ECC/thermal, device plugin, taints: every GPU cluster.
- sha256/manifest/offline-fails-closed: every air-gap pipeline.

### 1.8 What does not transfer
- Flag names, metric names, config file shapes, and defaults.
- Which component owns "restart" and "source of truth" (Helm values vs CRD vs UI-click config).
- Product limits and licences (some features are enterprise-only: confirm before promising them).

### 1.9 Confirming the state of an unfamiliar project in five minutes
Repo activity (last release, open issues about your use case), release notes of the **deployed** version (not latest), the
team's pinned versions in their IaC, and whether the feature you need is documented for that version.

## 2. Questions to ask the team in week 1

Ask early, write the answers down; the ones that change your first week come first.

**Stack and architecture**
- Which engines serve production traffic (vLLM, SGLang, TGI, Triton/TRT-LLM, Dynamo), which versions, and on which GPUs?
- Is serving on Kubernetes (raw Deployments, KServe, Ray Serve, llm-d) or on dedicated hosts? Which GPU Operator version, and MIG/time-slicing/whole GPUs?
- Which gateway (LiteLLM, Kong, Envoy AI Gateway, Portkey, custom)? How many replicas, shared Redis/Valkey, Postgres HA?
- Is there a router/scheduler beyond round-robin (prefix/KV-aware, Gateway API Inference Extension)?

**Models and artifacts**
- Where do models come from (mirror, Artifactory/Nexus, registry), who approves them, and how are integrity and pickle scanning enforced?
- How is a new model rolled out and rolled back, and how long does a cold start take?
- Which models/aliases exist, who owns each, and what are the SLOs?

**Access, limits and cost**
- Who gets keys, how are teams/budgets/limits defined (GitOps or UI), and what are today's limits per client class (chat vs agents)?
- How is GPU capacity planned and billed (showback/chargeback)? What is the utilisation today?

**Operations and on-call**
- On-call rotation for the platform, severity levels, runbooks, last three incidents (and their postmortems)?
- Which alerts exist for KV pressure, queue growth, XID/thermal, 429 ratio, pending GPU pods, tripwire hits?
- Is there a staging cluster where I can break things?

**Security and data**
- What happens to prompt and completion logs (PII, retention, tracing in Langfuse or similar)?
- How is the air gap enforced (network, DNS, proxy), how are images and weights brought in, and who audits it?

**Access and environment**
- Accounts and tools I need (cluster access, registry, Grafana, gateway admin, repos, vault).

## 3. Reading an unknown AI platform dashboard

1. **Which layer and which instance?** Gateway, engine, GPU? Variables (`model`, `instance`, `node`) and time range.
2. **Units and queries:** percentile from histogram buckets? TTFT vs end-to-end latency? tokens vs requests?
3. **Saturation signals present?** Queue, KV%, preemptions, GPU temp/XID. A dashboard with only GPU utilisation is incomplete.
4. **Per-client breakdown?** By key/team/model. Without it, incident 1 is invisible.
5. **Baseline and peak:** change the range to 7 days; look at the peak hours.
6. **Freshness and provisioning:** from Git or hand-edited?

## 4. Reading an unknown alert

Expression and window, `for`, labels and routing, runbook link, history of firings in 30 days, and what happens
when the metric disappears (a dead exporter must not look like health).

## 5. First-week plan (template)

| Day | Focus | Output |
|---|---|---|
| 1 | Access, people, architecture walkthrough | access checklist, hand-drawn request path (client to GPU) with real component names |
| 2 | Read the repos: configs, Helm/CRDs, CI, runbooks | list of repos and how a change ships; one tiny PR (typo, missing runbook link) |
| 3 | Shadow on-call or incident review; read the last postmortems | notes: top recurring failure classes mapped to the layer model |
| 4 | Starter task with a mentor (alert, dashboard panel, key template, doc fix) | PR in review |
| 5 | Capacity/cost/limits tour, open questions | GPU utilisation vs allocation numbers, current limits table, answers or parked questions |

Habits that build trust: write down what you learn in the team wiki, ask in writing, close loops, and never
change production config "just to test" on day 2.

## Key takeaways

- The four-layer map transfers across stacks; names, flags and defaults do not.
- Engines: vLLM, SGLang, TGI (maintenance mode), Triton/TensorRT-LLM, Dynamo; platforms: KServe, Ray Serve, llm-d, GIE; gateways: LiteLLM, Kong, Envoy AI Gateway, Portkey.
- Ask first about ownership, how changes ship, limits and capacity, on-call, air-gap process.
- Read dashboards and alerts critically before trusting them.

## Check yourself

1. The team runs TGI. What is its status and what would you ask before proposing a change?
2. Where does the "smart router" live in llm-d and in Gateway API Inference Extension?
3. Why are TensorRT-LLM engines a special artifact for an air-gapped pipeline?
4. Name three questions about the gateway that change your first week.
