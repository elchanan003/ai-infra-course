# Authoring Conventions (for agents building/maintaining the course)

Read this fully before creating or editing any course file. The learner never needs this file; the tutor rarely does.

## 1. Host facts
- Host is **arm64** (Neoverse-N1: NEON+dotprod, no bf16/i8mm/SVE), 4 vCPU, 23 GB RAM (~15 GB free), **no GPU**, ~133 GB free disk. Every image must be multi-arch. Use only images pinned in `platform/versions.env` (tags + digests, frozen in WP0/WP2). Adding an image → `docker manifest inspect <img> | grep arm64` and add it to versions.env.
- Pre-existing, NOT course-owned: `rakazo-*`, `cli-proxy-api`, `workout-mongo`, `kali-cli`, the `observability-course` stack. Never stop, remove, or prune them. Never `docker system prune` / `volume prune` / `docker rm` without a `course=aiinfra` label filter. Never change the Docker daemon config.
- Ports 18000-18199 are reserved for this course; everything else on the host is off limits.
- CLI tools: `kind`, `kubectl`, `helm`, `uv` in `~/.local/bin`; `kubeconform`, `promtool`, `oras` from `platform/setup.sh`. `jq`, `curl`, `python3` available. Python tooling in `platform/.venv` (huggingface_hub `hf`, openai, mcp, safetensors, picklescan, boto3, qdrant-client).
- After `platform/setup.sh` (the "connected side") everything runs offline: compose services use `pull_policy: never`; no `latest` tags.

## 2. Language and style
- All files in **English**. The tutor speaks Hebrew; files do not.
- Theory: dense, precise, practical; internals and pitfalls, "how teams run it". Tables and short code blocks. No fluff, no emojis, no detours.
- Every claim must be correct for the pinned versions (vLLM v0.31.0 CPU fp32 for the real-engine option, vLLM 0.31/0.32 semantics for mock; LiteLLM v1.106.4; llama.cpp server-b11889; Open WebUI v0.12.4; Langfuse 3.225.14; Qdrant v1.20.0; SeaweedFS 4.51; registry:3; ORAS 1.3.6; kind v0.29.0 / node v1.33.1; Prometheus v3.5.0; Grafana 12.1.1; MCP spec 2026-07-28; huggingface_hub 2.3.0 with `hf` CLI; exact pins + digests in `platform/versions.env`). Do not teach `huggingface-cli`, `TRANSFORMERS_OFFLINE` or MinIO as current. Re-check defaults (e.g. `--gpu-memory-utilization` 0.92) on the pinned version.
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
`platform/lib.sh` (source from every script; frozen after WP2, changes only via the coordinator). Full header with semantics in the file. Endpoints overridable via env (`PROM_URL`, `GRAFANA_URL`, `LITELLM_URL`, `LITELLM_KEY`, `MOCK_A_URL`, `MOCK_B_URL`, `TRIPWIRE_URL`, ...); base-stack ports as in section 3.
| Signature | Meaning |
|---|---|
| `pass ID MSG` / `fail ID MSG` / `blocked ID MSG` | print scored lines `[PASS]/[FAIL]/[BLOCKED] ID MSG` |
| `passed ID` | status 0 iff check ID passed (cascade to BLOCKED) |
| `warn ID MSG` | unscored `[WARN]` line |
| `precond DESC CMD...` | run CMD, print unscored `[PRE] DESC: ok|NOT OK`, return CMD's status |
| `summary` | print `SCORE: x/y`, write `.last-verify` (timestamp+score) in the module dir, exit 0 only if all passed |
| `wait_http URL [TIMEOUT_S=60]` | poll until 2xx/3xx |
| `within SECS CMD...` | retry CMD every 1 s until success or timeout (no blind sleeps) |
| `wait_idle [MAX_BUSY_PCT=60] [TIMEOUT_S=60]` | wait for low host CPU; 1 on timeout (verify prints WARN, refuses to score) |
| `prom_query EXPR` / `prom_value EXPR` | instant query JSON / first sample value |
| `grafana_api PATH [curl args]` | Grafana API as admin:admin |
| `promtool_test TESTFILE` / `promtool_check FILE...` | promtool from the prometheus image (`PROMTOOL_MOUNT=<dir>` to widen the mounted dir) |
| `litellm_api PATH [curl args]` | gateway API with the master key (or `$LITELLM_KEY`); body out, no `-f` |
| `litellm_code KEY MODEL [PROMPT]` / `litellm_chat KEY MODEL [PROMPT]` | one chat completion with KEY: HTTP status / body |
| `litellm_flush_wait [KEY [N=1 [TIMEOUT_S=30]]]` | bounded poll until >=N SpendLogs rows for KEY (or, without args, row count stable 7 s) |
| `litellm_spend KEY` | spend from `/key/info` |
| `mock_stats [A|B]` / `mock_fault [A|B] [METHOD] [JSON]` | mock-vllm `/admin/stats` and `/admin/fault` |
| `tripwire_hits [HOST_REGEX]` / `tripwire_reset` | tripwire counter (all or matching hosts) / reset |
| `sandbox_run [docker flags] IMAGE [CMD...]` | throwaway container on `aiinfra-airgap` (DNS = tripwire, no route out, caps dropped); needs profile `store` |
| `env_kv FILE KEY` | value of KEY in an env-style file |
| `k ...` | `kubectl --context kind-aiinfra ...` |
Lab lock wrapper: `platform/lab-session.sh <cmd...>` (re-entrant). Module validation: `.build/validate-module.sh NN [args]`.
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
