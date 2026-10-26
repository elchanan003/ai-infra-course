# Base stack (`platform/stack/`)

Docker Compose stack shared by all modules: project `aiinfra`, networks `aiinfra` and `aiinfra-airgap`
(`internal: true`, DNS = tripwire), every container/volume/network labelled `course=aiinfra`. Images from
`platform/versions.env`, all `pull_policy: never` (run `platform/setup.sh` once with internet). Modules **reuse** this
stack via `platform/stack.sh` and env overrides; they never copy `compose.yaml`. Host binds are 127.0.0.1 only; UIs
(Grafana, LiteLLM, Open WebUI, Prometheus, Langfuse) are also on the Tailscale IP (`TAILSCALE_IP`, default
100.127.87.65; if absent `stack.sh` warns and uses 127.0.0.2). Wrap every prepare/verify/cleanup in `platform/lab-session.sh`.

## 1. Profiles and services (container `aiinfra-<svc>-1`)
| Profile | Service | Host port | In-network | Notes |
|---|---|---|---|---|
| `gw` | `litellm` | 18040 (+TS) | `litellm:4000` | key `sk-aiinfra-master`; config dir `LITELLM_CONFIG_DIR` |
| `gw` | `postgres` (pgvector pg17) | 18054 | `postgres:5432` | db/user/pw `litellm`/`llm`/`llm`; volume `postgres-data` |
| `gw` | `valkey` 9 | 18063 | `valkey:6379` | no persistence |
| `gw2` | `litellm-2` (use with `gw`) | 18041 | `litellm-2:4000` | second replica for global-limit labs (same config, same master key) |
| `llm` | `llama-chat` Q4 (`--jinja --metrics`, alias `chat`) | 18011 | `llama-chat:8080` | 2 slots, ctx 4096 |
| `llm` | `llama-coder` Q8 (FIM `/infill`, alias `coder`) | 18012 | `llama-coder:8080` | |
| `llm` | `llama-embed` bge-small Q8 (`--embeddings --pooling cls`, 384 dims) | 18013 | `llama-embed:8080` | |
| `mock` | `mock-vllm-a` / `mock-vllm-b` | 18021 / 18022 | `mock-vllm-a:8000` | `/config` ro; no restart policy (startup refusal exits 1) |
| `mock` | `mock-dcgm-a` / `mock-dcgm-b` | 18031 / 18032 | `mock-dcgm-a:8000` | hostnames `gpu-node-a/b` |
| `obs` | `prometheus` (5 s scrape) | 18090 (+TS) | `prometheus:9090` | DNS-SD targets: litellm(-2), llama-*, mock-*, vllm-cpu |
| `obs` | `grafana` | 18030 (+TS) | `grafana:3000` | admin/admin; datasource uid `prometheus`; folder "Course" |
| `ui` | `open-webui` | 18080 (+TS) | `open-webui:8080` | offline, admin bootstrap, RAG embeddings via gateway (`embed`); DNS = tripwire |
| `rag` | `qdrant` | 18033 | `qdrant:6333` | |
| `store` | `seaweedfs` S3 | 18070 | `seaweedfs:8333` | identities in `config/seaweedfs/s3.json` |
| `store` | `registry` (registry:3, delete enabled) | 18050 | `registry:5000` | plain HTTP |
| `store` | `hf-mirror` (mock image, role `hf-mirror`) | 18071 | `hf-mirror:8000` | serves `~/.cache/aiinfra-course/hf` read-only |
| `store` | `tripwire` | 18072 (hits API) | `172.29.230.2` (aiinfra), `172.29.231.2` (airgap) | answers every DNS name with 172.29.231.2 |
| `lf` | `langfuse-web` (+TS), `langfuse-worker`, `langfuse-clickhouse`, `langfuse-postgres`, `langfuse-redis`, `langfuse-s3` (+ one-shot `langfuse-s3-init`) | 18060 | `langfuse-web:3000` | v3; ~2.75 GB; own S3, never needs `store` |
| `vllm` | `vllm-cpu` v0.31.0 fp32, non-root | 18023 | `vllm-cpu:8000` | alone on the host; model `chat` = Qwen2.5-0.5B-Instruct; ~6.5 GB; healthy in 3-4 min |

RAM guard in `stack.sh up`: `llm` with `lf`/`vllm`, and `vllm` with `lf`, are refused (exit 2); `k8s.sh up` refuses while `llm` is up.
Memory limits are set per container; whole stack stays under 8 GB for every allowed combination.

## 2. `platform/stack.sh`
| Command | Effect |
|---|---|
| `up <profile...>` | Converges to **exactly** these profiles: starts them, removes containers of other profiles (volumes kept), checks images exist, waits until all containers with a healthcheck are healthy (`STACK_UP_TIMEOUT`, default 240 s, 600 s with `vllm`). Exit 1 if unhealthy or a container exited non-zero (`STACK_ALLOW_EXITED=1` tolerates it, e.g. a mock-vllm deliberately started with a broken config). Restarts Prometheus when components were removed. |
| `down [--volumes]` | Remove all course containers and both networks (volumes kept unless `--volumes`). |
| `status` | `compose ps -a` with ports. |
| `logs <svc> [args]` | `docker compose logs`. |
| `build` | Build `aiinfra-mock:1.0` (`mock/`) and `aiinfra-tripwire:1.0` (`mock/tripwire/`). |
| `reload-prometheus` | `POST /-/reload`. |
| `reset-openwebui` | Remove the Open WebUI container and data volume (fresh admin bootstrap on next `up ui`). |
| `compose <args>` | Raw `docker compose` (all profiles enabled). |

## 3. Environment overrides
Directories (absolute or relative to the caller's cwd; the whole directory replaces the default):
| Variable | Default (under `platform/stack/config/`) | Mounted at | Must contain |
|---|---|---|---|
| `LITELLM_CONFIG_DIR` | `litellm` | `/app/config` | `config.yaml` (+ any callback `.py`) |
| `PROM_CONFIG_DIR` | `prometheus` | `/etc/prometheus` | `prometheus.yml`, rules in `rules/*.yml` |
| `GRAFANA_PROVISIONING_DIR` | `grafana/provisioning` | `/etc/grafana/provisioning` | `datasources/` (keep uid `prometheus`), `dashboards/` |
| `GRAFANA_DASHBOARDS_DIR` | `grafana/dashboards` | `/var/lib/grafana/dashboards` | dashboard JSON |
| `SEAWEEDFS_CONFIG_DIR` | `seaweedfs` | `/etc/seaweedfs` | `s3.json` (RW `rwkey/rwsecret123`, RO `rokey/rosecret123`) |
| `MOCK_VLLM_A_CONFIG_DIR`, `MOCK_VLLM_B_CONFIG_DIR` | `mock-vllm-a`, `mock-vllm-b` | `/config` (ro) | `args`, `gpu.yaml`, optional `script.yaml`, `fault.yaml` (mock/README.md) |
| `MOCK_DCGM_CONFIG_DIR` (both nodes) or `MOCK_DCGM_A_CONFIG_DIR` / `MOCK_DCGM_B_CONFIG_DIR` | `mock-dcgm-a`, `mock-dcgm-b` | `/config` (ro) | `gpus.yaml`, optional `fault.yaml` |
Scalars: `LLAMA_CHAT_MODEL` / `LLAMA_CODER_MODEL` / `LLAMA_EMBED_MODEL` (GGUF file names in `~/.cache/aiinfra-course/models`),
`MOCK_TIME_SCALE` (default 1; 0 = unpaced), `MOCK_HF_OFFLINE` (0/1), `MOCK_HF_ENDPOINT` (mock-vllm's `HF_ENDPOINT`),
`TRIPWIRE_FORWARD` (domains still forwarded to Docker DNS), `PROM_RETENTION` (3d), `AIINFRA_CACHE` (`~/.cache/aiinfra-course`),
`TAILSCALE_IP`, `STACK_UP_TIMEOUT`, `STACK_ALLOW_EXITED`.
Switching a config dir needs `stack.sh up <profiles>` again (compose recreates changed services). Prometheus: edit + `reload-prometheus`.

## 4. Credentials and URLs
| What | Value |
|---|---|
| LiteLLM master key | `sk-aiinfra-master` (`http://127.0.0.1:18040`, UI `/ui`) |
| Postgres | `postgresql://llm:llm@127.0.0.1:18054/litellm` |
| Open WebUI admin | `admin@aiinfra.local` / `Admin-pass-1` (`http://127.0.0.1:18080`; API `POST /api/v1/auths/signin`) |
| Grafana | `admin` / `admin` (`http://127.0.0.1:18030`) |
| Langfuse | `admin@aiinfra.local` / `Admin-pass-1`; project keys `pk-lf-aiinfra` / `sk-lf-aiinfra` (`http://127.0.0.1:18060`); LiteLLM already has `LANGFUSE_PUBLIC_KEY/SECRET_KEY/HOST` in its env: enable with `litellm_settings.success_callback: ["langfuse"]` in a module config |
| S3 (SeaweedFS) | `http://127.0.0.1:18070`, RW `rwkey`/`rwsecret123`, RO `rokey`/`rosecret123`, region `us-east-1`, path-style |
| Registry | `127.0.0.1:18050` (`--plain-http` for oras; docker treats localhost as insecure) |
| Tripwire | `GET http://127.0.0.1:18072/hits` -> `{host: n}` (DNS A-queries); `DELETE /hits` resets |

## 5. Base LiteLLM config (lab-only settings)
Models `chat`, `coder`, `embed` (llama.cpp), `mock-a`, `mock-b` (mock-vllm, served name `chat`); `proxy_batch_write_at: 5` (spend lag 2-5 s; production 60 s);
`callbacks: [prometheus]`, `require_auth_for_metrics_endpoint: false` (scrape path `/metrics/`); `cache: true` + redis `cache_params` with
`supported_call_types: []` so rate limits are global across replicas (router redis alone is not enough). RPM is a 60 s fixed window; budget exceeded = HTTP 422.

## 6. Air-gap
`aiinfra-airgap` is `internal: true` (no route out). Probes run inside it: `sandbox_run IMAGE CMD` (lib.sh) uses DNS = tripwire, so any lookup is counted.
Containers on an internal network cannot publish ports. Open WebUI sits on `aiinfra` with the tripwire as DNS upstream: names outside compose resolve to the sink and are counted.

## 7. Kubernetes (`platform/k8s.sh`)
kind cluster `aiinfra` (context `kind-aiinfra`, node v1.33.1, control-plane + `aiinfra-worker` + `aiinfra-worker2`), NodePorts 30000-30010 -> 127.0.0.1:18100-18110.
`up`/`down`/`status`/`load IMAGE...` (docker save --platform | kind load image-archive)/`gpu-patch [topology.yaml|--clear]` (SIMULATED `nvidia.com/gpu`, GFD-style labels, optional taint; default `platform/k8s/gpu-topology.yaml`: worker 2x A100 tainted, worker2 1x L4)/`fake-gpu [--remove]` (optional run-ai fake-gpu-operator 0.2.1 on worker2; needs internet, not part of the gate).
Never run kind together with `llm`.

## 8. Persistence
Volumes (label `course=aiinfra`): `postgres-data`, `prometheus-data`, `grafana-data`, `openwebui-data`, `qdrant-data`, `seaweedfs-data`, `registry-data`, `langfuse-*`.
`down` keeps them; `down --volumes` wipes them (also `reset-openwebui` for the UI alone). Never prune; clean up with label filters only.
