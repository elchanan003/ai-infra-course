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

### 1.5a Engine Rosetta stone: the same knob under different names

Every engine answers the same five questions: how much memory is claimed, how many requests run together, how big a
prefill step is, how the model is split over GPUs, and what is exported. Flag and metric names below are the
commonly documented ones; **verify them against the deployed version** (`--help`, the docs for that tag).

| Question | vLLM | SGLang | TGI | llama.cpp `llama-server` | Triton + TRT-LLM |
|---|---|---|---|---|---|
| Memory the instance may claim | `--gpu-memory-utilization` (0.92 default in this course's pin) | `--mem-fraction-static` (weights + KV pool; the rest is activations/graphs) | `--cuda-memory-fraction` | none: you choose `-c` (context) and `-ngl` (layers on GPU) | engine build-time `max_batch_size`, `max_seq_len`; KV fraction in the backend config |
| Concurrent sequences | `--max-num-seqs` | `--max-running-requests` | `--max-concurrent-requests` (admission) and batch token budgets | `-np` / `--parallel` slots (context is shared: `-c` divided by slots) | `max_batch_size`, in-flight batching, `dynamic_batching` in `config.pbtxt` |
| Prefill step budget | `--max-num-batched-tokens`, chunked prefill | `--chunked-prefill-size` | `--max-batch-prefill-tokens` | `-b` / `-ub` batch sizes | `max_num_tokens` at engine build |
| Max context | `--max-model-len` | `--context-length` | `--max-total-tokens`, `--max-input-tokens` | `-c` | `max_seq_len` at engine build |
| Tensor parallel | `--tensor-parallel-size` | `--tp-size` (`--tp`) | `--num-shard` | not the model (layer split with `--tensor-split` across GPUs) | `tp_size` at engine build time |
| Prefix reuse | automatic prefix caching (hash of blocks) | RadixAttention (radix tree of prefixes) | prefix caching in newer versions | prompt cache per slot (`--cache-reuse`) | backend dependent |
| Metrics endpoint | `/metrics`, names `vllm:*` | `/metrics` when started with `--enable-metrics`, names `sglang:*` | `/metrics`, names `tgi_*` | `/metrics` only with `--metrics`, names `llamacpp:*` | separate metrics port (8002 by default), names `nv_inference_*`, `nv_gpu_*` |
| Queue signal | `vllm:num_requests_waiting` | `sglang:num_queue_reqs` | `tgi_queue_size` | `llamacpp:requests_deferred` | `nv_inference_pending_request_count`, `nv_inference_queue_duration_us` |
| KV pressure signal | `vllm:kv_cache_usage_perc` | `sglang:token_usage` | batch/queue gauges only; no KV-fraction gauge to rely on | `llamacpp:kv_cache_usage_ratio` | backend specific; often absent, so look at queue and latency |
| Latency signals | `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds` | `sglang:time_to_first_token_seconds`, `sglang:inter_token_latency_seconds` | `tgi_request_mean_time_per_token_duration` | none as histograms; per-request `timings` in the response | `nv_inference_request_duration_us`, TTFT is usually measured by the client or gateway |

Two habits follow from the table:
1. When someone says "KV is full", ask which metric shows it. If the engine has no KV gauge (TGI, Triton), the team
   watches queue and latency instead, and your PromQL from module 08 will not port 1:1.
2. Dashboards copied from vLLM do not work on another engine. A panel that shows "no data" after a migration is the
   most common silent observability regression (module 08: absence is not health).

### 1.5b Parallelism and topology vocabulary

| Term | Meaning | What you will notice operationally |
|---|---|---|
| TP (tensor parallel) | each layer is sharded across GPUs in one node; per-token all-reduce | needs fast interconnect (NVLink); one GPU failure kills the whole replica; pod needs N GPUs on one node |
| PP (pipeline parallel) | layers are split in stages, often across nodes | adds bubbles and latency; used when a model does not fit in one node |
| DP / replicas | independent copies behind a router | the cheap way to scale throughput; each replica has its own KV and prefix cache, hence routing matters |
| EP (expert parallel) | MoE experts spread over GPUs | needs fast all-to-all; wide-EP stacks (llm-d, Dynamo) target this |
| Disaggregated P/D | separate prefill and decode pools, KV moved between them (NIXL, Mooncake-style transfer, LMCache) | helps when long prompts disturb decoding; costs a network fabric and a scheduler that understands both pools |
| KV offload | spill KV blocks to CPU RAM, local NVMe or a remote store | more effective cache at the price of transfer latency; watch the hit rate, not just capacity |
| Speculative decoding | small draft model proposes tokens, big model verifies | better ITL at low load; acceptance rate is the metric; extra memory for the draft |

How to say it in a meeting: "Is that replica TP=4 on one node, and what happens to the pool when one GPU throws an XID?"
That sentence connects modules 01, 03 and 09.

### 1.5c GPU and node stacks (what module 09 simulated)

| Layer | Common choices | Notes for an on-prem, air-gapped team |
|---|---|---|
| Driver + runtime | driver on the host or driver container (GPU Operator), NVIDIA Container Toolkit, CDI | driver upgrades are a node-drain event; pin driver and CUDA together with the engine image |
| Kubernetes integration | NVIDIA GPU Operator (device plugin, feature discovery, DCGM exporter, MIG manager), or hand-installed device plugin | the Operator pulls many images: all of them must be mirrored into the internal registry |
| Sharing | whole GPU, MIG (hardware partitions, real isolation), time-slicing (no memory isolation), MPS | whole GPU for big models; MIG for many small models; time-slicing for dev only |
| Next-gen allocation | Dynamic Resource Allocation (DRA) with a GPU DRA driver | resource claims replace `nvidia.com/gpu: 1` counters; check the Kubernetes version before relying on it |
| Batch/quota | Kueue, Volcano, NVIDIA Run:ai, Slurm in parallel (training-heavy shops) | ask whether inference and training share the same GPU pool |
| Other accelerators | AMD ROCm (vLLM and SGLang run there; AMD device plugin/operator), Intel Gaudi, cloud TPUs/Trainium (not on-prem) | metrics and flags differ; do not assume DCGM exists |
| Health | DCGM exporter (`DCGM_FI_DEV_*`), XID in kernel logs, node problem detector | module 09's XID taint pattern; ask who owns the node-repair process |

Simulated in the lab: mock-dcgm, fake `nvidia-smi`, node patch for `nvidia.com/gpu`. Real in production: driver and
CUDA compatibility, NVLink topology, ECC/XID events, MIG reconfiguration (which can need a node reboot), and
thermal throttling that no mock produces. You have the vocabulary and the failure model, not the hands-on time on
real hardware: say so honestly in week 1 and ask for a supervised first node operation.

### 1.5d Weights, registries and the air-gap pipeline in the wild

| Concern | Common implementations | The question behind it |
|---|---|---|
| Where models land | internal S3/SeaweedFS/Ceph, Artifactory or Nexus "Hugging Face" remote/hosted repos, Harbor OCI artifacts, MLflow registry | what is the source of truth, and can you reproduce a deployment from it? |
| How weights reach pods | init container / storage initializer download, PVC pre-population, modelcar OCI image, node-local cache (hostPath/NVMe), shared RWX filesystem | cold-start time is dominated by this (module 02, 03 cold-start counters) |
| Image supply | Harbor/Artifactory pull-through proxy, `kind`-style preload, offline tarballs (`skopeo copy`, `docker save`) | who mirrors new engine images, and how long does a new vLLM version take to arrive? |
| Integrity | sha256 manifests, safetensors-only policy, Sigstore model-signing, SBOM for images, scanner in the ingest path | scanner pass is not safe (module 02): where is the human approval? |
| Licence/approval | model cards reviewed, allow-list of model families, legal sign-off record | who can say "yes, we may serve Llama/Qwen/Mistral weights"? |
| Fails closed | no route out, DNS to nowhere, tripwire/alert on egress attempts | `HF_HUB_OFFLINE=1` is a hint to a library, not a network control |

### 1.5e Where the smart routing can live (decide with the team, not alone)

| Placement | Examples | Pros | Cons |
|---|---|---|---|
| In the gateway | LiteLLM routing strategies, Portkey configs, Kong/Envoy upstream balancing | one place for keys, limits and routing | load-aware or KV-aware routing is usually weaker than a dedicated picker |
| In a dedicated router | vLLM production-stack router, SGLang router, llm-d inference scheduler | prefix/KV/queue aware, knows engine metrics | another component to run, version and monitor |
| In the mesh/ingress | Envoy + Gateway API Inference Extension endpoint picker | Kubernetes-native resources, standard APIs | needs the Gateway API stack and matching CRDs for your cluster |
| In the client | SDK with retry/fallback lists | simplest | invisible to the platform team; breaks governance |

When a client reports "slow only sometimes", the first question is which of these placements is in the path and
whether it balances by load, by prefix, or randomly.

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

### 1.10 Translation drills (practice before day 1)

Say each sentence out loud, then answer "which module, which metric, which question to ask".

| The team says | Map it to | First thing you ask or look at |
|---|---|---|
| "We run vLLM on KServe with a modelcar." | module 03 engine args in an `InferenceService` runtime; module 02 OCI weights | where are the args (CRD in Git?), how is the modelcar image built and scanned |
| "p95 is fine but users complain." | module 01/08: average and e2e hide TTFT vs ITL | per-model TTFT and ITL percentiles, queue time, which client class complains |
| "We got a lot of 429s from the gateway on Monday." | module 05: which limit (key, team, model, global), per-replica counters | the 429 body (which limit), replica count, shared Redis or not |
| "A node dropped out of the pool." | module 09: XID, taint, drain | `dcgm` XID panels, node events, who owns the repair |
| "Cold start is 14 minutes." | module 02/03: weights fetch + load + graph capture | where weights come from, local cache, image pull |
| "We moved to SGLang and the dashboards are empty." | section 1.5a: other metric prefix, `--enable-metrics` | scrape config, metric names, alert rules that now never fire |
| "We use MIG on the A100 nodes." | module 09: hardware isolation, fixed slice sizes | which profile, who changes it, whether it needs a reboot |
| "The agent platform needs a sandbox." | module 07: no network, no secrets, kill on timeout | what runs the code, network policy, resource limits |
| "Our keys are in a spreadsheet." | module 04/10 incident: no source of truth | propose key templates in Git as the first PR |

### 1.11 What the lab simulated, and what production changes (be honest in week 1)

| Lab piece | Real in the lab? | In production |
|---|---|---|
| llama.cpp, LiteLLM, Open WebUI, Qdrant, SeaweedFS, registry, Prometheus, Grafana, Langfuse | yes, real software on CPU | same software, real load, HA, TLS, SSO, backups |
| mock-vllm, mock-dcgm, fake `nvidia-smi`, node patch, scripted mock-chat | simulated, deterministic counters | real vLLM on GPUs, DCGM-exporter, GPU Operator, MIG, CUDA OOM, driver and fabric faults |
| Timings | noisy CPU | stable but load dependent; use ratios and counters, not single numbers |
| Failure drills | injected by an API | arrive at 3 a.m. with partial information and a human who is unsure |

What you can claim: you understand the mechanisms and have debugged their symptoms in a simulator. What you should not
claim: hands-on experience tuning a production GPU fleet. Teams respect the honest version and mentor accordingly.

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

### 2.1 How to listen to the answers

| Answer you may hear | What it usually means | Follow-up |
|---|---|---|
| "It is in the wiki." | maybe stale | "When was it last used for a real change?" |
| "Ask X, only X knows." | single point of failure (bus factor 1) | ask X to pair on it; note it as a risk |
| "We never had that problem." | no alert exists, or nobody looked | "How would we know?" |
| "The UI is the source of truth." | config drift risk (capstone 1) | "Is there an export, and does it get reviewed?" |
| "We do it by hand, it is quick." | automation candidate, and a hidden runbook | offer to write the runbook, not to automate first |
| "That is under discussion." | a decision is open; your input may matter | "What are the options, and who decides?" |

### 2.2 Ordering: the three that change your first week

1. **Access and ownership**: who owns the platform, what can you touch, what needs approval. Without it every other day stalls.
2. **How a change ships**: repo, CI, review, who deploys, what rollback looks like.
3. **On-call and incidents**: are you expected on the rota, and what were the last three incidents.

Everything else (engine versions, capacity, costs) you can learn by reading the repos in days 2-3.

### 2.3 How to write a question people answer

- Specific and short: "Which Redis does LiteLLM use for rate limits in prod?" beats "How do limits work?".
- Names the thing you already checked: "I saw `router_settings` in the repo; is it the file used in prod?".
- One question per bullet, answerable in a sentence, ends with a question mark.
- Keep a running file with the answer, the date and who gave it. Unanswered ones move to the "parked" list.

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

### 5.1 Day-by-day detail

**Day 1, access and the map.** Checklist: cluster (read-only first), registry, Grafana, Prometheus, gateway admin UI
or API, repos, chat/ticket system, on-call tool (observer), secrets vault. Draw the request path on paper from client
to GPU with the real names (gateway host, service names, namespace, node pool). Ask the top-three questions.

**Day 2, repos.** Find: engine args (Helm values, Kustomize, CRDs), gateway config (`config.yaml`, `router_settings`),
alert rules, dashboards as code, CI pipelines, Dockerfiles with pinned versions, the air-gap import scripts. Output: a
one-page list "what lives where", plus a tiny reviewable PR (doc typo, runbook link).

**Day 3, learn from incidents.** Read the last three postmortems. For each: layer, symptom, detection, time to
mitigate, follow-ups still open. Map them to module 10's incident classes. If you shadow on-call, only observe and
take notes.

**Day 4, first real task.** Candidates: add `owner`/`runbook_url` labels to an alert, add a queue/KV panel, a key
template in Git, a missing runbook. Criteria: small, reviewable, no production behaviour change.

**Day 5, capacity, limits, cost.** Collect GPU allocation vs utilisation (and remember: utilisation is not saturation),
the current limits table per client class, spend per team, and open questions. Present five minutes to your mentor:
what you learned, what is still unclear, what you propose to do next week.

### 5.2 Week-1 rules of engagement

- Read-only first. Never "just test" a flag, limit or restart on a production system.
- Use staging if it exists; if it does not, that is finding number one.
- Do not rename, delete or clean up things you do not own; ask who does.
- Write down every command you run on shared systems.
- When you find a problem, bring the evidence (query, log line, link) and a proposal, in writing.
- Separate "I do not know" from "I think it is wrong": say the first often, the second carefully.

### 5.3 Your risks to name early

Say to your mentor in week 1: no hands-on with real GPU hardware; air-gap practice was on a simulated network;
mock-based drills only. Ask for one supervised exercise on real hardware in your first month (a node drain with
the GPU Operator, or a vLLM rollout with a rollback). Naming the gap makes the team give you the right tasks.

### 5.4 Thirty-sixty-ninety, in one line each

- 30 days: you can trace any request path, read every dashboard, and you shipped three small PRs.
- 60 days: you run a rollout or a key/limit change independently, and have co-owned an incident.
- 90 days: you own one improvement end to end (for example alert coverage, or the model-intake pipeline).

## Key takeaways

- The four-layer map transfers across stacks; names, flags and defaults do not.
- Engines: vLLM, SGLang, TGI (maintenance mode), Triton/TensorRT-LLM, Dynamo; platforms: KServe, Ray Serve, llm-d, GIE; gateways: LiteLLM, Kong, Envoy AI Gateway, Portkey.
- Ask first about ownership, how changes ship, limits and capacity, on-call, air-gap process.
- Read dashboards and alerts critically before trusting them.
- Flag and metric names differ per engine (section 1.5a); a migration silently breaks dashboards and alerts.
- Lab honesty: mocks and the fake GPU taught mechanisms, not hardware experience; say so and ask for supervised real-hardware practice.
- Week 1 is read-only, written down, and ends with a small reviewable PR.

## Check yourself

1. The team runs TGI. What is its status and what would you ask before proposing a change?
2. Where does the "smart router" live in llm-d and in Gateway API Inference Extension?
3. Why are TensorRT-LLM engines a special artifact for an air-gapped pipeline?
4. Name three questions about the gateway that change your first week.
5. A team moved from vLLM to SGLang. Name two things in your monitoring that break without anyone noticing.
6. Where could KV-aware routing live, and what does each placement cost?
7. What do you say if your mentor asks "have you run this on real GPUs?"
8. Which three questions come first on day 1, and why those?
