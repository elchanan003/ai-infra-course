# Authoring Conventions (for agents building/maintaining the course)

Read this fully before creating or editing any course file. The learner never needs this file; the tutor rarely does.

## 1. Host facts
- Host is **arm64** (Neoverse-N1: NEON+dotprod, no bf16/i8mm/SVE), 4 vCPU, 23 GB RAM (~15 GB free), **no GPU**, ~133 GB free disk. Every image must be multi-arch. Use only images pinned in `platform/versions.env` (tags + digests; `TBD-WP0` until frozen). Adding an image → `docker manifest inspect <img> | grep arm64` and add it to versions.env.
- Pre-existing, NOT course-owned: `rakazo-*`, `cli-proxy-api`, `workout-mongo`, `kali-cli`, the `observability-course` stack. Never stop, remove, or prune them. Never `docker system prune` / `volume prune` / `docker rm` without a `course=aiinfra` label filter. Never change the Docker daemon config.
- Ports 18000-18199 are reserved for this course; everything else on the host is off limits.
- CLI tools: `kind`, `kubectl`, `helm`, `uv` in `~/.local/bin`; `kubeconform`, `promtool`, `oras` from `platform/setup.sh`. `jq`, `curl`, `python3` available. Python tooling in `platform/.venv` (huggingface_hub `hf`, openai, mcp, safetensors, picklescan, boto3, qdrant-client).
- After `platform/setup.sh` (the "connected side") everything runs offline: compose services use `pull_policy: never`; no `latest` tags.

## 2. Language and style
- All files in **English**. The tutor speaks Hebrew; files do not.
- Theory: dense, precise, practical; internals and pitfalls, "how teams run it". Tables and short code blocks. No fluff, no emojis, no detours.
- Every claim must be correct for the pinned versions (vLLM 0.32.x, LiteLLM v1.106.x, llama.cpp b<N>, Open WebUI 0.12.x, MCP spec 2026-07-28, huggingface_hub 2.x with `hf` CLI; exact tags `TBD-WP0`). Do not teach `huggingface-cli`, `TRANSFORMERS_OFFLINE` or MinIO as current. Re-check defaults (e.g. `--gpu-memory-utilization` 0.92) on the pinned version.
- Honesty: every simulated element is labeled as simulated in theory and lab text, with how production differs. Never imply a real GPU.

## 3. Port map (host side, 127.0.0.1; UIs also on Tailscale 100.127.87.65)
| Service | Port |
|---|---|
| Grafana | 18030 (+Tailscale) |
| LiteLLM | 18040 (+Tailscale) |
| Open WebUI | 18080 (+Tailscale) |
| Prometheus | 18090 (+Tailscale) |
| llama.cpp chat / coder / embed | 18011 / 18012 / 18013 |
| mock-vllm A / B | 18021 / 18022 |
| vllm-cpu (optional) | 18023 |
| mock-dcgm | 18031 / 18032 |
| Qdrant | 18033 |
| Postgres | 18054 |
| Valkey | 18063 |
| registry | 18050 |
| SeaweedFS S3 | 18070 |
| hf-mirror | 18071 |
| Langfuse | 18060 |
| kind NodePorts 30000-30010 | 18100-18110 |
Never bind to 0.0.0.0 (host is internet-facing). `doctor.sh` checks each port is free or course-owned.

## 4. Labels and naming
- Every course container/volume/network carries label `course=aiinfra`. Compose project `aiinfra`. Networks `aiinfra` and `aiinfra-airgap` (`internal: true`, DNS = tripwire).
- kind cluster `aiinfra` (context `kind-aiinfra`); every k8s object carries label `course=aiinfra`.
- Safe cleanup is always label-scoped: `docker ps -aq --filter label=course=aiinfra`.

## 5. Base stack contract
Owned by `platform/stack/` (`platform/stack/README.md`, written by the platform builder). Modules **reuse** it; they do not copy compose files.
- `platform/stack.sh up <profile...>` / `down [--volumes]` / `status` / `logs <svc>` / `build`. Profiles: `gw` (litellm, postgres, valkey), `llm` (3x llama.cpp: chat/coder/embed), `mock` (mock-vllm A/B, mock-dcgm), `obs` (prometheus, grafana), `ui` (open-webui), `rag` (qdrant), `store` (seaweedfs, registry, hf-mirror, tripwire), `lf` (langfuse + clickhouse + deps), `vllm` (real vLLM-CPU, optional).
- **Converge semantics**: `up` converges to exactly the listed profiles (others' containers removed, volumes kept) and waits for health (poll with timeout).
- Config dirs overridable via env vars so a module can point a service at its own `lab/` files (e.g. LiteLLM config, Prometheus rules); full list in `platform/stack/README.md`.
- RAM budget (WP0 measures): peak <= 8 GB; `lf`, `vllm` and kind never together with `llm`; doctor warns if MemAvailable < 6 GB.
- Lab-only settings (e.g. LiteLLM `proxy_batch_write_at: 5`, 5 s Prometheus scrape) are flagged as lab-only in theory.

## 6. Mock contract
`mock/README.md` is the contract (metric names, capacity model, fault API, scripted patterns); modules use those exact names and never re-document them.
- mock-vllm (image `aiinfra-mock:1.0`): OpenAI-compatible + streaming; exact vLLM metric names; capacity model from real `config.json` geometry; real vLLM error strings; deterministic mode with a virtual clock; fixed `usage`; scripted **mock-chat** mode (pattern → `tool_calls`, Aider SEARCH/REPLACE, FIM shape echo).
- Fault API `/admin/fault` (GET read, POST set, DELETE reset): `latency`, `error_rate`, `kv_pressure`, `crash`, `slow_load`, `other_gpu_mem`.
- mock-dcgm + fake `nvidia-smi`: `DCGM_FI_*` for N simulated GPUs; faults `xid`, `thermal`, `ecc`, `vram_leak`.
- hf-mirror (HF-Hub-compatible, served from local cache) and tripwire (dnsmasq sink + HTTP host counter) are real course-owned services.

## 7. Module file contract
```
modules/NN-slug/
  theory.md          numbered sections; "how teams run it", pitfalls; ends with "Key takeaways" + "Check yourself" (3-5 q)
  lab.md             numbered tasks; each: Goal, Steps/hints (not the answer), Success criteria (ids match verify.sh)
  quiz.md            10-15 questions, no answers
  lab/               learner workspace (starter files, TODO markers). Learner edits only here.
  prepare-lab.sh     brings up required profiles + seeds starter state/faults. Idempotent. Does not reveal answers.
  verify.sh          checks LIVE state against Success criteria. One line per check, then SCORE.
  cleanup.sh         removes only runtime state this module created; never touches lab/
  verify-clean.sh    proves cleanup worked
  .tutor/answers.md  quiz answers + expected lab answers + common mistakes
  .tutor/hints.md    per-task hint ladder H1-H4
  .tutor/solution/   reference solution mirroring lab/
  .tutor/apply-solution.sh  copies solution over lab/ (validation only; backs up lab/ to lab.bak-<ts>/ first)
```
Harness rules (non-negotiable; course-harness skill):
1. Starter scores **0**; reference solution **100%** with no manual steps; 5 runs identical. Poll readiness with timeout, never `sleep` blindly.
2. Preconditions (health, targets up) are printed but **not scored**.
3. Positive + negative pairs (works / must-be-denied; fire / quiet; solution / control).
4. Verify generates its own load and nonces. Learner configs/queries are **executed** live, never grepped.
5. Answer files reject shipped template values. Enum answers always come with a variant-bound evidence field (hidden per-learner variant), so guessing cannot pass.
6. Spend checks use `litellm_flush_wait` (bounded poll for batch-written spend logs).
7. 429 checks are burst-based: `rpm_limit: 2`, burst of 5 → >=1 x 429 and <=2 x 200; recovery = poll for 200 within 70 s.
8. `BLOCKED` (not FAIL) when a prerequisite check failed (cascade).
9. Timing policy: real-CPU timing checks use counters where possible; otherwise ratio threshold + median-of-3 + 1 retry; verify calls `wait_idle` and prints WARN (not FAIL) and refuses to score when load is high. Deterministic mock mode for anything graded on latency.
10. `cleanup.sh` idempotent (run twice, same output); never deletes learner files in `lab/`.
11. Quiz/answers/solutions live only under `.tutor/`.
Capstone: `prepare-lab.sh N`, graded N.1-N.5 as in PLAN section 5 (durable fix, live probe, root-cause enum, evidence vs live data, postmortem checker).

## 8. Shared harness library
`platform/lib.sh` (source from every script). Signatures TBD-WP2; frozen after WP2 (changes only via the coordinator).
- Sibling set: `pass ID MSG`, `fail ID MSG`, `blocked ID MSG`, `summary` (prints `SCORE: x/y`, writes `.last-verify` with timestamp+score, exit 0 only if all pass), `wait_http URL TIMEOUT`, `grafana_api PATH`, `prom_query EXPR`, `prom_value EXPR`.
- New: `litellm_api`, `litellm_flush_wait`, `mock_stats`, `env_kv`, `within`, `tripwire_hits`, `sandbox_run`, `wait_idle`, `promtool_test`, `k` (kubectl --context kind-aiinfra).
```
[PASS] 1.2 sizing.py passes hidden case 3
[FAIL] 1.3 kv_gb ignores kv_heads — revisit GQA
[BLOCKED] 1.4 needs 1.3
SCORE: 1/3
```
FAIL messages name the real cause and point to the concept, never give the answer.

## 9. Resource hygiene
- Compose profiles and kind should not run together unless a module needs both; each `prepare-lab.sh` stops what it does not need via `platform/stack.sh` profile selection.
- **Lab lock**: one lock per whole test cycle (prepare → verify → cleanup) via the `lab-session` wrapper: `flock -w 1800 /tmp/aiinfra-course-lab.lock`, owner file `/tmp/aiinfra-course-lab.owner`. Authors write content in parallel; test cycles are serialized.
