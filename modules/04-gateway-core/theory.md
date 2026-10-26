# 04 — Gateway core: LiteLLM keys, teams, limits, durable state, shared Valkey

Time: ~1.5 h reading with the tutor. Prerequisites: module 00 (the 4-layer picture, one request traced). Pinned versions: LiteLLM proxy `v1.106.4` (image `litellm-database`), Postgres 17 (pgvector image), Valkey 9. Everything here that says "measured" was observed on exactly this version in the course lab (WP0 spike); everything else is documented LiteLLM behaviour that you should re-check with `curl -i` before relying on it in production.

Honesty box. Real in this module: LiteLLM, Postgres, Valkey, the llama.cpp backends. Simulated: the "big GPU fleet" behind the gateway is mock-vllm (OpenAI-compatible, fixed `usage`, deterministic) — it lets us compute spend and count backend hits exactly. In production the backends are vLLM/TGI/SaaS endpoints on GPUs, there is TLS, an ingress, SSO, and several gateway replicas on Kubernetes; the lab runs 1-2 replicas on one host with plain HTTP.

---

## 1. Why a gateway at all

Without a gateway every client (IDE plugin, chat UI, agent, notebook) holds a URL and credentials of an inference engine. Consequences you will meet in the first month on an AI platform team:

| Problem without a gateway | What the gateway gives |
|---|---|
| Engines have no auth, or one shared token | per-user / per-team / per-service **virtual keys**, revocable individually |
| One runaway agent loop saturates the GPU; chat users time out | **rate limits** (RPM/TPM/parallel) per key/team, **traffic separation** (module 05) |
| Nobody knows who spent what | **spend tracking** per key/team/user/model, budgets |
| Renaming/migrating a model breaks every client | **aliases**: clients ask for `chat`, you decide what serves it |
| Engine restarts and failures leak to users | retries, fallbacks, cooldowns (module 05) |
| Each client speaks a different dialect | one OpenAI-compatible surface (`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`) |
| No audit/metrics | one place for logs, Prometheus metrics, Langfuse traces (module 08) |

What a gateway is **not**: it does not make inference faster (it adds a few ms of overhead per request), it does not batch across clients (the engine does — module 01), and it is not a security perimeter by itself: the engines must be unreachable except through it (section 8).

LiteLLM is the gateway used in this course. Alternatives you will hear about (module 11): Envoy AI Gateway, Kong/APISIX AI plugins, Portkey, OpenRouter-like SaaS, vLLM's own router (prefix-aware routing for vLLM fleets), cloud gateways. They solve the same layer; the concepts transfer.

## 2. LiteLLM anatomy

```
client ──HTTP──▶ LiteLLM proxy (FastAPI, uvicorn)
                   │ 1. auth: master key or virtual key  (DB/cache lookup, key hash)
                   │ 2. pre-call checks: model access, budgets, rpm/tpm/parallel limits
                   │ 3. Router: pick a deployment for the requested model_name
                   │ 4. litellm SDK: translate OpenAI request ──▶ provider request (openai/ = pass-through)
                   │ 5. call backend (retries, timeouts, fallbacks, cooldown bookkeeping)
                   │ 6. response ──▶ client; callbacks run async (spend, Prometheus, Langfuse)
                   ▼
        Postgres (keys, teams, spend, config)        Valkey/Redis (shared counters, cache)
```

Components worth naming correctly:

- **Proxy** = the HTTP server with auth, management API (`/key/*`, `/team/*`, `/user/*`, `/spend/*`, `/model/*`) and an admin UI (`/ui`).
- **Router** = the part that owns the `model_list` and decides which deployment serves a request (module 05). Several `model_list` entries with the same `model_name` form a *model group*.
- **SDK** = the `litellm` Python library that translates between providers. For OpenAI-compatible backends (llama.cpp, vLLM, mock-vllm) you use the `openai/` provider prefix and `api_base`.
- **Callbacks** = success/failure hooks (spend writer, `prometheus`, `langfuse`, custom).
- **State** = Postgres for everything durable; Valkey/Redis for state shared between replicas.

Overhead: single-digit milliseconds per request on top of the backend latency when the DB is healthy (auth is cached in memory). It is CPU-bound Python: one container uses roughly 0.5-0.8 GB RAM here (measured 0.56-0.77 GB) and scales by adding replicas (and `--num_workers`), not by bigger boxes.

The image: `ghcr.io/berriai/litellm-database:v1.106.4`. The `-database` variant bundles Prisma and runs migrations at start (213 migrations here; startup ≈ 25-40 s). Pin an exact tag; `main-latest`/`stable` tags move under you and database migrations are one-way.

## 3. `config.yaml` — the part you own in Git

```yaml
model_list:
  - model_name: chat                       # the alias clients use
    litellm_params:
      model: openai/qwen2.5-0.5b-instruct  # provider prefix + the name the BACKEND knows
      api_base: http://llama-chat:8080/v1  # container DNS name on the compose network
      api_key: os.environ/BACKEND_KEY      # os.environ/ reads an env var; never inline secrets
    model_info:
      id: chat-llama                       # stable deployment id (appears in metrics, headers)
  - model_name: embed
    litellm_params: {model: openai/bge-small, api_base: http://llama-embed:8080/v1, api_key: none}

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  proxy_batch_write_at: 5                  # LAB-ONLY: default is 10 s; see section 6

litellm_settings:
  callbacks: ["prometheus"]
  require_auth_for_metrics_endpoint: false # LAB-ONLY (module 08 scrapes /metrics/)

router_settings:
  num_retries: 2
```

Rules and traps:

1. **`model_name` is the contract with clients; `litellm_params.model` is the contract with the backend.** The first is yours to keep stable; the second must match what the backend serves (llama.cpp ignores the name; vLLM requires `--served-model-name` or the HF id).
2. **The `openai/` prefix means "speak the OpenAI protocol to `api_base`"**, not "call OpenAI". Forgetting it makes LiteLLM try to guess a provider from the name and fail with `LLM Provider NOT provided` (400/500 depending on path).
3. `api_base` includes `/v1`. A missing `/v1` gives 404 from the backend, which LiteLLM reports as a 404/`NotFoundError` from the *gateway* — confusing, because the client sees a 404 on a URL that exists.
4. `os.environ/NAME` is the only secret-injection syntax in the file; keep the file in Git and secrets in env/Secret objects.
5. Wildcards (`model_name: "*"` or `openai/*`) forward anything: handy for SaaS, dangerous on-prem (clients can request models you did not intend).
6. `GET /v1/models` lists model *groups visible to the calling key* (see section 4); it is what UIs use to populate dropdowns — if a backend is slow this call can still be fast (it reads config), but a broken `api_base` only shows up at request time.
7. Config is read at start. Editing the file requires a restart (or `/config/update`-style API with DB-stored config, which splits the source of truth; avoid mixing). Models added through the UI/API with `store_model_in_db: true` live in Postgres and are *not* in Git — pick one source of truth per environment.
8. `model_info` carries prices (`input_cost_per_token`, `output_cost_per_token`) used for spend; unknown self-hosted models have **cost 0** by default unless you set them (module 05 shows why you do it even for on-prem: showback/chargeback).

## 4. Identity and access: master key, virtual keys, teams, users

| Object | What it is | Typical use |
|---|---|---|
| **Master key** (`LITELLM_MASTER_KEY`) | root admin credential; also works for inference | admin tooling only; never given to clients; rotate by redeploy |
| **Virtual key** (`sk-…`) | credential issued by `/key/generate`; the DB stores only a **hash** (SHA-256 of the key), the plaintext is shown once | one per application/service/user/tool |
| **Team** | group with shared model list, budget, limits; keys can belong to a team | "chat-platform", "agents", "data-science" |
| **User** (internal user) | a human identity, can own keys and belong to teams | SSO-backed accounts |
| **Organization** | umbrella above teams (multi-tenant) | big deployments; mostly enterprise features |
| **End user** | the free-form `user` field in a request body, spend tracked per value | per-customer showback inside an app |

Creating a key (everything is a REST call with the master key):

```bash
curl -s localhost:18040/key/generate -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' -d '{
  "key_alias": "svc-search-prod",
  "models": ["chat","embed"],
  "rpm_limit": 60, "tpm_limit": 100000, "max_parallel_requests": 8,
  "max_budget": 50, "budget_duration": "30d",
  "duration": "90d",
  "team_id": "...",
  "metadata": {"owner": "search-team", "ticket": "PLAT-123"}
}'
```

Useful fields: `key_alias` (human name — use it, hashes are unreadable in dashboards), `models`, `rpm_limit`, `tpm_limit`, `max_parallel_requests`, `max_budget` + `budget_duration`, `duration` (expiry), `team_id`, `user_id`, `metadata`, `model_max_budget` / `model_rpm_limit` / `model_tpm_limit` (per-model sub-limits), `tags` (spend attribution), `permissions`. Introspection: `GET /key/info?key=<key-or-hash>`, `GET /key/list`; lifecycle: `/key/update`, `/key/delete`, `/key/block`, `/key/regenerate` (rotation; check availability on your build).

**Model access resolution.** A key with `models: []` (empty) means "all models the proxy knows" (subject to its team). A key in a team is constrained by the team's `models` too: effective access is the intersection in practice, and a model denied at either level is denied. The error for a denied model is HTTP **403** with `key_model_access_denied` (measured) — **not** 404; a key that does not exist or is wrong returns **401**. Keep these straight in dashboards: 401 = authentication, 403 = authorization, 429 = limits, 422 = budget (section 5), 5xx = backend/gateway.

Pitfalls:

- Setting a **wildcard** `models: ["*"]`/`all-proxy-models` on a key "to make it work" silently removes the isolation you built with teams. Fix the team list instead (lab task 4.7 plants exactly this trap).
- A team-scoped key whose team lacks the model fails even though the key lists it: check **both** levels.
- Keys are created by API/UI at runtime and live **in Postgres**, not in `config.yaml`. Your Git repo holds *how keys are issued* (a script/Terraform/operator calling the API), not the keys.
- The plaintext key exists only in the `/key/generate` response. Store it in a secret manager immediately; if lost, issue a new one (hash is not reversible).
- Give every key an alias and an owner in `metadata`. "Which key is `sk-…a3f`?" at 3 a.m. is a bad question.

## 5. Limits: RPM, TPM, parallel requests, budgets

Three independent ceilings, enforceable per key, team, user, and per model:

| Limit | Meaning | Counted | Failure |
|---|---|---|---|
| `rpm_limit` | requests per minute | on admission | **429** `Limit type: requests` |
| `tpm_limit` | tokens per minute (prompt + completion) | **after** the response (real `usage`), so one big request can overshoot; the *next* ones are refused | **429** `Limit type: tokens` |
| `max_parallel_requests` | concurrent in-flight requests | in-flight counter | 429 |
| `max_budget` | money (USD-like units from `model_info` costs) within `budget_duration` | from spend | **422** `budget_exceeded` (measured: HTTP 422, error type `budget_exceeded` — not 429) |

Measured on v1.106.4:

- **RPM is a fixed window of 60 s**, not a sliding window or token bucket. `rpm_limit: 2` + a burst of 200 requests (8 threads) → `{200: 2, 429: 198}`. The 429 carries `retry-after: 60`, `x-ratelimit-api_key-{limit,remaining}-{requests,tokens}` headers, and a body like `Rate limit exceeded for api_key: <hash>. Limit type: requests. Current limit: 2, Remaining: 0. Limit resets at: <ts>`. Recovery is at the window boundary (up to 60 s), so test it as "poll for 200 for up to 70 s", never as "wait exactly 60 s".
- **TPM is post-hoc.** With `tpm_limit: 50` and 30-token responses, two requests pass (30 + 30 = 60 > 50 only after the second completes), then `Limit type: tokens`. Capacity planning consequence: TPM caps *sustained* usage but cannot stop a single huge request; combine with `max_tokens` caps and context limits.
- **Budget exceeded is HTTP 422**, one request can overshoot (the check happens against spend-so-far). Under parallel bursts the spend counter is racy; only reason about budgets with sequential traffic.
- Failed requests (429/422/5xx) are also written to the spend log (status `failure`, spend 0).

Where limits live in the layering: key → user → team (→ team member) → model-specific sub-limits → global. A request must pass all that apply. Design rule used by teams in production:

1. Team gets the **budget and model list** (organizational policy).
2. Keys get **rate limits** (technical protection of the shared GPUs) and are issued per workload.
3. Agents/automation keys *always* get `max_parallel_requests` and a TPM cap; human chat keys get RPM only. (This is the lesson of module 05 and capstone scenario 1.)

429 etiquette for clients: honour `retry-after`, use exponential backoff with jitter, and never retry 401/403/422. A client that retries 429 immediately turns a limit into a retry storm and makes the *gateway* the bottleneck.

## 6. State, durability and the spend pipeline

What lives where:

| State | Home | Lost on gateway restart? |
|---|---|---|
| Virtual keys, teams, users, budgets (definitions) | Postgres `LiteLLM_VerificationToken`, `LiteLLM_TeamTable`, `LiteLLM_UserTable`, `LiteLLM_BudgetTable` | no |
| Per-request spend log | Postgres `LiteLLM_SpendLogs` (PK = **request id**) | no (once flushed) |
| Aggregated daily spend (UI reports) | Postgres `LiteLLM_Daily*Spend` tables | no |
| Running spend counters per key/team | memory, flushed to PG in batches (and Valkey when configured) | up to one flush interval of un-flushed spend |
| RPM/TPM/parallel counters | memory by default; **shared** only via Valkey (section 7) | **yes** (counters reset; fixed windows make this harmless but real) |
| `model_list`, `router_settings`, callbacks | `config.yaml` (Git) | re-read at start |
| Stored credentials for DB-defined models | Postgres, encrypted with **`LITELLM_SALT_KEY`** | no — but unreadable if the salt changes |

The two secrets that must be stable forever: **`LITELLM_MASTER_KEY`** (admin; changing it just changes the admin credential) and **`LITELLM_SALT_KEY`** (encrypts stored provider credentials; *changing it after data exists breaks decryption of everything encrypted before*). Generate once, keep in the secret store, never regenerate on redeploy.

**Spend pipeline.** A request finishes → a success callback computes cost from `usage` × `model_info` prices → the spend update is queued in memory → a background writer flushes queued updates to Postgres every `general_settings.proxy_batch_write_at` seconds (default 10; the lab uses **5**, lab-only). Measured with 5 s: a `SpendLogs` row became visible 2.1-5.4 s after the response. Consequences:

- A check "spend == expected" immediately after the request is a race. Poll with a bound (the course helper `litellm_flush_wait` polls ≤ 30 s). Budget *enforcement* uses in-memory spend and is immediate on one replica; the *database* lags.
- **Request id = backend response `id`.** LiteLLM uses the `id` returned by the backend as the `SpendLogs` primary key. A backend that returns a constant id (some fakes/mocks do) makes every row after the first silently vanish while key spend still increments. Symptom: totals right, per-request log empty. mock-vllm returns unique ids for this reason.
- With several replicas each flushes its own queue; for correct global budgets at scale LiteLLM supports a Redis-buffered spend path — an operations topic to read about before you run >2 replicas.
- `LiteLLM_SpendLogs` grows without bound (one row per request, optionally with prompts/responses). Production practice: `maximum_spend_logs_retention_period`, do not store prompt bodies unless required (privacy + size), and watch table size/vacuum. Prometheus counters and Langfuse (module 08) are the long-term analytics path.
- **Postgres down.** The proxy keeps serving cached keys for a while but cannot validate new keys or write spend; depending on `allow_requests_on_db_unavailable` it either fails closed or serves. Decide deliberately: availability vs. "free tokens while the DB is down". Back up Postgres like any state store (`pg_dump`, WAL archiving, a managed instance).
- Migrations run at container start. With N replicas starting together, run migrations once (init job / one replica with `DISABLE_SCHEMA_UPDATE=false`, others `true`) — otherwise lock contention at upgrade time.

Key durability test (what the lab verifier does): create a key, restart the gateway container, call with the same key → must still be 200. If it is 401, the key lived only in memory (no `database_url`) — a classic first-deploy mistake that is invisible until the first restart.

## 7. Two replicas and shared Valkey — why counters are per-replica by default

A single LiteLLM process is a SPOF and a CPU ceiling, so production runs ≥ 2 replicas behind a load balancer (k8s Service, nginx). By default each replica keeps RPM/TPM/parallel counters **in its own memory**. With `rpm_limit: 10` and two replicas behind a round-robin balancer, a client really gets about 20 RPM; with N replicas, N×. That is not a bug — it is what in-memory counters mean — and it is exactly how an "agent limited to 10 RPM" took down a GPU in many first deployments.

Valkey (Redis-compatible, BSD-licensed fork; LiteLLM talks the Redis protocol, compatibility with Valkey 9 verified here) provides the shared counter store. **Measured on v1.106.4 — this is the key lesson of the module:**

| Config | Result with `rpm_limit: 2` across two replicas |
|---|---|
| no Redis | 4 requests pass (2 per replica), Valkey stays empty |
| `router_settings: redis_host/redis_port` only | **still** per-replica: 4 pass, Valkey empty |
| `litellm_settings: cache: true` + `cache_params: {type: redis, host: valkey, port: 6379, supported_call_types: []}` | replica A: 200, 200, then replica B: **429 ×3** — global limit holds; keys visible in Valkey (`{api_key:<hash>}:requests`, `:tokens`, `:window`, `spend:key:<hash>`) |

Why: the rate limiter reads and writes its counters through LiteLLM's *cache layer*, so the cache must be configured with Redis. `supported_call_types: []` means "do not cache any responses" — you want the shared store without response caching (caching LLM responses is a separate feature with correctness implications: it would return the same answer to different users at temperature > 0). `router_settings.redis_*` shares *router* state (cooldowns, usage-based routing) — useful (module 05) but not what the rate limiter uses.

Operational notes:

- Valkey holds ephemeral counters; it does **not** need persistence for correctness (counters reset = a new window). Do give it memory limits and run it near the gateway (same node pool/zone): each limited request makes network round-trips — put Valkey latency on your dashboards.
- If Valkey is unreachable the gateway must degrade, not die: LiteLLM exposes a Redis circuit-breaker metric (`litellm_redis_circuit_breaker_state`) — alert on it (module 08). While it is open you are back to per-replica limits.
- Fixed-window + shared counters still means a burst at a window boundary can briefly pass 2× the limit across the boundary. Fine for protection, not for billing — billing comes from spend logs.
- No sticky sessions needed: all replicas see the same Postgres and Valkey.
- Replicas must share the **same** `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, and `config.yaml` (deploy from one ConfigMap/image), else routing/auth differ per replica.

## 8. Network, exposure and secrets

- **Backends must be reachable only from the gateway.** If a client can hit `llama-chat:8080` (or mock-vllm, or vLLM `:8000`) directly, keys, limits, budgets and audit are decoration. In Kubernetes: `ClusterIP` services + `NetworkPolicy` allowing ingress to engine pods only from the gateway pods. In Docker: engines on an internal network the clients are not attached to, no host-published ports. (The lab publishes engine ports on 127.0.0.1 for your convenience and says so; task 4.8 makes you reason about the production arrangement and prove the gateway path is the only one that works for a client container.)
- TLS terminates at the ingress/load balancer; inside the cluster HTTP is common but mTLS/mesh is a policy choice. Never bind the proxy on `0.0.0.0` on an internet-facing host (this course binds 127.0.0.1 + Tailscale).
- Never expose `/key/*`, `/team/*`, `/user/*`, `/model/*`, `/spend/*` or `/ui` to ordinary clients: they are admin APIs protected only by the master key (or admin-role keys). Put admin paths on a separate internal ingress or block them at the edge; clients need only `/v1/*` (and `/health/liveliness` for probes).
- `/metrics` is open only because the lab sets `require_auth_for_metrics_endpoint: false`; by default it needs a key. Scrape traffic that is unauthenticated shows up as *failed requests* on route `/metrics` — a nice way to pollute your error-rate alert. Scrape path is `/metrics/` (the bare path 307-redirects).
- Do not return the master key anywhere (`disable_master_key_return`), do not put keys in URLs or logs, rotate on staff changes. Keys for tools are usually delivered via env var or a secret-injected file, e.g. `OPENAI_API_KEY`.
- SSO/RBAC, audit logs and guardrails per team are mostly **enterprise-licensed** features in LiteLLM; the OSS image is fully capable of keys/teams/limits/budgets/Prometheus/Langfuse. Know the boundary before you design an org-wide rollout.

## 9. How teams run it in production

1. **Config as code**: `config.yaml` (models, routing, callbacks) in Git; applied by rolling restart; reviewed like any infra change. Key issuance as code too: a small script/operator/Terraform provider that `POST /key/generate`s with alias + team + limits and writes the secret to the secret manager.
2. **One key per workload**, named `<team>-<app>-<env>`, with expiry (`duration`) and rotation runbook. Humans get keys through the UI/SSO; services through the pipeline.
3. **Defaults that protect the fleet**: every key has `rpm_limit`; every non-human key has `max_parallel_requests`; every team has `max_budget`; the model list is explicit.
4. **Replicas**: ≥ 2, anti-affinity, readiness probe `/health/readiness` (cheap; checks DB/cache connectivity), liveness `/health/liveliness`. **Do not** use `/health` as a probe: it calls every backend (costly, slow, and one sick backend takes the gateway out of rotation).
5. **Postgres**: managed or HA, connection limit sized for replicas × pool (`database_connection_pool_limit`), backups, retention for spend logs.
6. **Observability**: Prometheus callback + alerts on 429/5xx ratio per key, `litellm_redis_circuit_breaker_state`, spend vs budget, request latency vs backend latency (the difference is gateway overhead).
7. **Upgrades**: pin the tag; read release notes (Prisma migrations are one-way); roll one replica, watch, continue; keep Postgres backup before the upgrade.
8. **Capacity**: gateway CPU is rarely the bottleneck in an LLM stack (GPUs are), but streaming responses hold connections open: size workers/file descriptors for *concurrent streams*, not requests per second.

## 10. Pitfall table

| Symptom | Likely cause | Check |
|---|---|---|
| 401 after a restart for keys that worked | no `database_url`, keys only in memory; or DB wiped | `psql … 'select count(*) from "LiteLLM_VerificationToken"'` |
| 403 `key_model_access_denied` | model not in key's (or team's) list | `GET /key/info`, `GET /team/info` |
| 429 only sometimes, "limit 10 but I got 20" | N replicas, per-replica counters | Valkey keys exist? `cache_params` set? |
| rate limit works for 1 replica, not 2, despite `router_settings.redis_*` | wrong place for Redis config | `litellm_settings.cache` + `cache_params` |
| per-request spend log empty, key spend increments | backend returns constant response `id` | compare ids in backend responses |
| spend "wrong" right after a test | batch-write lag | wait `proxy_batch_write_at` + margin |
| 404 for a model that is in the list | `api_base` missing `/v1`, or backend name mismatch | `curl` the backend directly (from the gateway network) |
| UI shows empty model list | models stored in DB vs file confusion; key's `models` restrict | `/v1/models` with that key |
| all spend is 0 on self-hosted models | no `input/output_cost_per_token` in `model_info` | `/model/info` |
| clients bypass limits | engines reachable directly | `curl` the engine from a client container |
| scrape errors counted as 5xx/401 | Prometheus scraping `/metrics` without auth | `require_auth_for_metrics_endpoint` or give Prometheus a key |

## 11. What the lab simulates, and how production differs

| Lab | Production |
|---|---|
| backends: real llama.cpp (tiny CPU models) + mock-vllm with fixed `usage` and unique ids | vLLM/TGI on GPU nodes, SaaS endpoints; real, variable `usage` |
| 1-2 LiteLLM replicas on one Docker host, plain HTTP, 127.0.0.1 ports | k8s Deployment ≥ 2 replicas, ingress + TLS, NetworkPolicy, HPA |
| Postgres/Valkey containers, no backups, no HA | managed Postgres/HA Redis, backups, monitoring |
| `proxy_batch_write_at: 5`, open `/metrics/` | defaults or tuned values; authenticated scrape |
| one master key in an env file | secret manager, key rotation, SSO |

## 12. Worked examples with numbers

These are arithmetic exercises, not measurements. Where a figure depends on your data (row size, token counts) it is labelled an estimate: measure it on your own system before you size anything.

**12.1 Replica limit arithmetic.** A key has `rpm_limit: 60`, three replicas, round-robin LB, no Valkey.

- Each replica counts its own fixed 60 s window, so up to 3 x 60 = **180 RPM** are admitted. If the LB is least-connections or the client keeps connections alive (HTTP keep-alive pins a client to one replica for a long time), the split is uneven and the *observed* ceiling lies between 60 and 180. "It sometimes limits at 60" is therefore not evidence that the limit works.
- With shared counters (section 7) the ceiling is 60 per window. Fixed windows still allow a boundary burst: 60 requests in the last second of window k and 60 in the first second of window k+1 means 120 requests in about 2 s. If your GPU cannot absorb 2x for 2 s, add `max_parallel_requests` (a concurrency cap does not have a boundary effect) rather than lowering RPM.
- A per-replica fallback budget: when Valkey is down you are back to N x limit. If the protected backend tolerates 100 RPM and you run 3 replicas, set `rpm_limit` so that N x limit stays within tolerance (here at most 33), or accept that Valkey is a hard dependency of your protection and alert on it accordingly.

**12.2 TPM overshoot bound.** `tpm_limit: 100000`, `max_parallel_requests: 8`, model context 32768, client allowed `max_tokens` 2048.

- TPM is added after the response, so admission never looks at the size of the request in flight. Worst case per window: 8 parallel requests, each up to about 32768 + 2048 = 34816 tokens, all admitted while the counter is still low: about 278,528 tokens, 2.8x the limit, before the first refusal.
- Bounding levers, in order of strength: lower `max_tokens` (cap output), enforce a smaller context at the engine (`--max-model-len`), lower `max_parallel_requests`. With `max_parallel_requests: 2` and `max_tokens: 512` on 8k contexts the bound is 2 x 8704 = 17,408 tokens.
- After an overshoot the counter is above the limit, so *all* further requests in that window get 429 `Limit type: tokens`, including tiny ones. That is the visible symptom: a user sends one huge paste and then is locked out for the rest of the window.

**12.3 Spend arithmetic from prices x usage.** Set `input_cost_per_token: 0.0000005` (USD 0.50 per 1M) and `output_cost_per_token: 0.0000015` (USD 1.50 per 1M) in `model_info`. One request with `usage` of 1200 prompt and 300 completion tokens:

```
1200 x 0.0000005 = 0.00060
 300 x 0.0000015 = 0.00045
spend            = 0.00105
```

- A key with `max_budget: 50` lasts about 50 / 0.00105 = 47,600 such requests. At 2 requests per second that is about 6.6 hours, so a "monthly" budget on a looping agent is gone before lunch. This is why agent keys get `max_parallel_requests` and a short `budget_duration` (for example `1d`) in addition to a monthly team budget.
- Because the check compares spend-so-far with the budget, the last request can overshoot by one request's cost (here 0.00105). For big prompts (100k tokens at the prices above is USD 0.05) the overshoot is visible; under parallel traffic it is multiplied by the in-flight count.
- Mock-vllm returns a fixed `usage`, so in the lab the expected spend is `n x fixed_cost` exactly. Real engines return variable `usage`; cost is also only as accurate as the `model_info` price you typed (module 05 discusses internal chargeback prices, such as GPU-hour cost divided by sustained tokens per hour).

**12.4 Postgres sizing of `LiteLLM_SpendLogs`.** One row per request, including failures (section 5).

- Estimate without prompt/response bodies: roughly 1-2 KB per row including indexes (metadata, key hash, model, tokens, spend, timestamps, request tags). 1M requests therefore add on the order of **1-2 GB**. With bodies stored and average 6 KB prompt + 2 KB response, rows are 8-10 KB: about **8-10 GB per million**.
- At a sustained 50 requests/s that is 4.3M requests/day: 4-9 GB/day without bodies, 35-43 GB/day with them. Thirty days of retention without bodies is therefore 130-260 GB at that rate; with bodies you are into terabytes and into a privacy problem (section 16).
- Measure instead of trusting the estimate: `select pg_size_pretty(pg_total_relation_size('"LiteLLM_SpendLogs"')), count(*) from "LiteLLM_SpendLogs";` at two points in time, divide.
- Deleting old rows creates bloat; autovacuum must keep up, and the delete itself should run in bounded batches. Use LiteLLM's retention setting (`maximum_spend_logs_retention_period`, documented, confirm in your config reference) or range-partitioning outside LiteLLM if you need long history. Long-term analytics belong in Prometheus/Langfuse/a warehouse, not in the operational table.

**12.5 Connection pool sizing.** Every gateway process holds Postgres connections through Prisma. Total = replicas x workers per replica x pool size per process (the knob is `database_connection_pool_limit`; documented, confirm the default and whether it is per process on your build).

```
4 replicas x 2 workers x 10 connections = 80
+ migrations job, psql sessions, exporters  ~ 10
Postgres default max_connections = 100, 3 reserved  -> 7 spare
```

That fits, but one more replica (100+) does not. Options: lower the pool (the gateway mostly does short batched writes, a pool of 3-5 per process is often enough), raise `max_connections` (each connection costs backend memory, a few MB), or front Postgres with a transaction-mode pooler such as PgBouncer (check that Prisma's pooler mode flag is set, `pgbouncer=true` in the connection string, and that migrations use a direct connection). Rolling upgrades temporarily run old and new pods together, so size for `replicas + maxSurge`.

## 13. A full request lifecycle with failure branches

One `POST /v1/chat/completions` with a virtual key, annotated with where it can end and what the client sees. Statuses marked "confirm" are documented behaviour that you should verify with `curl -i` on v1.106.4 before wiring alerts to them; the others were measured in the lab.

| Step | What happens | Failure branch | Client sees |
|---|---|---|---|
| 0 | TLS/ingress/LB forwards to a ready replica | no ready replica / LB timeout | 502/503/504 from the LB, never reaches LiteLLM (confirm in LB logs, not gateway logs) |
| 1 | Parse body, size and JSON checks | malformed JSON, unknown route | 400 / 404 / 422 (validation; do not confuse with budget 422, read the error type) |
| 2 | Auth: `Authorization: Bearer sk-...`, hash, look up in memory cache, then DB | wrong/unknown key | **401** |
| 2b | Key expired (`duration`), blocked, or team blocked | expired/blocked | 401 (expired) or 403 (blocked), confirm with `curl -i` |
| 2c | Cache miss and Postgres unreachable | depends on `allow_requests_on_db_unavailable` | 5xx (fail closed) or served (fail open), see 14 |
| 3 | Model access: key `models`, team `models`, alias resolution | model not allowed | **403** `key_model_access_denied`; unknown model name: 400 `Invalid model name` (confirm) |
| 4 | Budgets: key, user, team, end user, model budgets | spend >= max_budget | **422** `budget_exceeded` |
| 5 | Rate limits: RPM (admission), TPM (counter so far), parallel | over limit | **429**, `retry-after`, `x-ratelimit-*` |
| 6 | Router picks a deployment of the model group; cooldown-aware | all deployments in cooldown | 429/503 style `No deployments available` (confirm); module 05 |
| 7 | SDK builds the backend request, calls `api_base` | connect refused / timeout | retried up to `num_retries`, then 5xx (typically 500, or 503/504 mapped from the backend error; confirm) |
| 8 | Backend returns 4xx (context too long, bad param) | client error | passed through as 400-class (not retried; retrying a 400 is pointless) |
| 9 | Backend returns 5xx or stream breaks | engine error | retry on another deployment/fallback; if exhausted, error to client. A stream that breaks *after* the first byte cannot be retried transparently: the client sees a truncated stream |
| 10 | Response returned, `usage` read | no `usage` in backend response | spend 0 for that request; cost falls back to token counting only where LiteLLM can (confirm) |
| 11 | Async: spend queued, Prometheus incremented, callbacks | callback exception | does not fail the request; look in the gateway log |

Things that surprise people:

- Limits are checked **before** the backend call, but TPM and spend are updated **after** it. Between the two, the admission decision uses stale information. That is the whole reason overshoot exists.
- A 429 can originate from three places: LiteLLM's own limit (has `x-ratelimit-api_key-*` headers and `Limit type`), the router saying every deployment is cooling down, or the **backend** passing its own 429/overload through. Look at the body and headers before blaming the key limit.
- A client timeout shorter than the gateway timeout produces an aborted request: the gateway may still finish, bill, and write the spend row for a response nobody read. Align timeouts: client > gateway request timeout > engine timeout, with `retry x timeout` fitting inside the client's deadline.
- Streaming: the status line is sent with the first chunk, so an error in the middle of a stream is a broken stream, not a 5xx. Count "stream ended without `[DONE]`" on the client side.

## 14. HA and failure-mode table

What breaks when a dependency is gone. "Documented" means from the LiteLLM docs, not measured in this lab.

| Failure | Immediate effect | Degraded behaviour | What to do |
|---|---|---|---|
| Postgres down | cannot validate keys not in memory cache, cannot write spend | cached keys keep working for a while (cache TTL); spend queue grows in memory; behaviour for uncached keys follows `allow_requests_on_db_unavailable` (documented) | alert on DB connectivity; choose fail-closed for money-spending models and accept the outage; restore from backup/replica; spend queued in memory is lost if the replica restarts meanwhile |
| Postgres failover (managed HA) | 10-60 s of connection errors | Prisma reconnects; some spend flushes fail and retry (confirm) | use the cluster endpoint, not an instance IP; test with a forced failover |
| Valkey down | shared counters unreachable | limits fall back to per-replica (N x); circuit-breaker metric opens | alert on `litellm_redis_circuit_breaker_state`; keep Valkey on the same zone |
| One backend down | requests to that deployment fail | retries and cooldown move traffic to the other deployments of the group; with one deployment the group fails | module 05 (fallbacks, cooldown); alert on cooldown count |
| All backends of a group down | 5xx / no deployments available | fallback group if configured, otherwise errors | fallback to a smaller/other model deliberately, tell users via a response header or doc |
| One gateway replica down | in-flight requests on it fail (streams break) | LB removes it after readiness fails; other replicas take over; in-memory per-replica counters for it are lost (harmless) | `preStop` sleep + `terminationGracePeriodSeconds` >= longest stream so rollouts do not cut streams |
| Valkey flushed or restarted | counters reset | a fresh window; spend counters in Valkey are rebuilt from Postgres (confirm) | not an incident by itself |
| DB migration during upgrade | new image applies Prisma migrations at start; old replicas still run against the changed schema | old pods can error on dropped/renamed columns; migrations are one-way, rollback of the image does not roll back the schema | backup first, run the migration as a one-shot job (section 6), read release notes for destructive migrations, roll one replica |
| Salt key changed | stored provider credentials undecryptable | DB-defined models fail with auth errors to backends | restore the old salt from the secret store; never regenerate |
| Master key lost | no admin API | inference with existing virtual keys continues | redeploy with a new master key (changing it only changes the admin credential) |
| Clock skew between replicas | fixed-window boundaries differ per replica | shared counters use window timestamps, skew shifts reset times by seconds | NTP on nodes |

Lab honesty: in the lab you can reproduce backend-down (stop a container, or `/admin/fault` crash on mock-vllm), gateway-restart durability, and Valkey stop/start with two replicas. Postgres failover and a real destructive migration are described here but not simulated.

## 15. Key lifecycle and rotation runbook

Rotation must be boring. The rule: **a new credential works before the old one stops**, and every step is an API call you can script.

1. **Issue.** `POST /key/generate` with `key_alias` (`<team>-<app>-<env>`), `team_id`, `models`, limits, `duration`, and `metadata` (`owner`, `ticket`, `rotation_due`). Capture the plaintext from the response and write it directly to the secret manager; never to chat, tickets or CI logs.
2. **Deliver.** The workload reads the key from an env var or mounted secret, not from the image. Use the alias in dashboards; record the hash prefix returned in `/key/info` next to it so you can correlate logs.
3. **Rotate with overlap.** Preferred pattern, independent of any single endpoint: generate key B with the same alias suffix (`-v2`), same team and limits; deploy it to the workload; watch `/key/info` spend/last-used for A fall to zero; then revoke A. Two keys share the team budget during the overlap, which is fine. LiteLLM also documents `POST /key/{key}/regenerate` (new plaintext, old one invalid; check availability and whether it needs enterprise or has a grace-period option on v1.106.4 with `curl -i`). Regenerate has no overlap by default, so it suits emergencies better than planned rotation.
4. **Revoke.** Immediate: `POST /key/block` (reversible, keeps spend history, good for "stop it now, investigate later") or `POST /key/delete` (final). After revocation confirm with a `curl -i` using the old key: expect 401 (blocked keys may give 403; confirm). Revocation takes effect in the replica's key cache after its TTL at worst, so verify on every replica, not only the one behind your port-forward.
5. **Expiry.** `duration: "90d"` makes expiry the default; a key without expiry is a decision, not an oversight. A weekly job lists `GET /key/list` and flags keys expiring in 14 days, keys with no spend in 60 days (orphans), and keys with no `metadata.owner`.
6. **Leak response.** Treat as compromise: block the key, read its SpendLogs for the leak window (who, which model, which IP in metadata if you log it), rotate, tell the owner. Reducing blast radius beforehand is cheaper: per-key `max_budget`, model lists, short `duration`.
7. **Master key.** Not for daily use. Rotate by redeploying with a new `LITELLM_MASTER_KEY` on all replicas at once; admin tooling then picks it up from the secret store. Never rotate `LITELLM_SALT_KEY` (section 6).

Scripting note: issuance and revocation run from CI with the master key in a CI secret, or better, with an admin-role key limited to `/key/*`, so the master key itself is touched only in emergencies.

## 16. Security threat model for a gateway

| Threat | How it happens | Mitigation |
|---|---|---|
| Key leakage | key committed to Git, pasted in chat, logged by a client, sent in a URL | secret manager, short `duration`, per-key budgets, secret scanning in CI, alias/owner for fast revocation, rotation runbook (15) |
| Admin API exposure | `/key/*`, `/user/*`, `/model/*`, `/ui` reachable from the internet or from the client network; master key brute force or reuse | separate internal ingress for admin paths, block at the edge, long random master key, no master key in clients, rate-limit the edge |
| Privilege escalation via team/user roles | key issued with `permissions` or admin role by mistake; a user can create keys with higher limits than their own | review who holds admin roles, use team admins carefully, test with `/key/generate` under a non-admin key and expect refusal (confirm on your build) |
| Prompt and PII logging | `store_prompts_in_spend_logs`-style settings, Langfuse traces, debug logs, error bodies containing user text | default to not storing bodies; if required, limit retention, restrict DB access to a few roles, redact (guardrails, enterprise or a custom callback), encrypt at rest; remember that backups copy the data too |
| SSRF via `api_base` | an attacker who can create models or pass `api_base`/`base_url` per request makes the gateway call internal URLs (cloud metadata `169.254.169.254`, the Postgres port, admin endpoints) | keep model creation admin-only; do not enable client-supplied `api_base` overrides (documented as a per-request option, leave it off); egress NetworkPolicy from the gateway only to known engines and the internet if SaaS is needed; block link-local ranges; DB-defined models via UI are an attack surface, prefer Git-defined |
| Model/wildcard overreach | `model_name: "*"` forwards any model, including expensive ones | explicit model list, team model lists, budgets |
| Direct engine access | engines reachable from client network | NetworkPolicy (section 18), no host-published ports |
| Denial of wallet | leaked or looping key burns SaaS budget | budgets with short `budget_duration`, parallel and TPM caps, anomaly alert on spend rate |
| Denial of service on the gateway | many slow streams exhaust file descriptors or workers | `max_parallel_requests`, edge connection limits, capacity plan (19) |
| Supply chain | `main-latest` image, unreviewed config change | pinned tag by digest, image scanning, config review in Git |
| Metrics leakage | `/metrics` open exposes key hashes, aliases, model names | authenticated scrape or an internal-only listener outside the lab |

Lab honesty: the lab has one trust domain, no TLS and an open `/metrics/`. It demonstrates mismatch traps (4.7) and bypass (4.8) but not network attackers; do not treat "works in the lab" as a security review.

## 17. Config as code and GitOps flow

What is source-controlled, what is not:

| Object | Source of truth | Applied by |
|---|---|---|
| `model_list`, `router_settings`, `litellm_settings`, `general_settings` | `config.yaml` in Git | ConfigMap + rolling restart |
| Teams (name, models, budget, limits) | a declarative file (`teams.yaml`) in Git | a reconcile script calling `/team/new` or `/team/update` (idempotent: look up by alias first) |
| Keys | not in Git; issuance recipe is | pipeline job calling `/key/generate`, writing plaintext to the secret manager |
| Secrets (master, salt, DB URL, backend keys) | secret manager | ExternalSecret / sealed secret into a k8s Secret |
| Spend, usage | Postgres | never edited by hand |

Flow:

1. Pull request changes `config.yaml` or `teams.yaml`. CI lints YAML, runs a **dry start** (`litellm --config config.yaml` against a throwaway DB, or the lab's compose stack) and a smoke test: `/health/readiness`, `/v1/models` with a test key, one completion per alias through the mock backend.
2. A policy check rejects dangerous diffs: wildcard models, `rpm_limit` removal, `master_key` literals, `api_base` outside an allowlist (SSRF guard).
3. Merge builds a ConfigMap with a content hash in its name (or an annotation on the pod template) so a config change rolls the Deployment. Without that a changed ConfigMap does not restart pods and replicas run different configs.
4. Rolling update, one replica at a time, readiness gating; watch 5xx ratio and latency for a few minutes; roll back by reverting the commit.
5. A drift job compares `GET /team/list` and `/model/info` with Git. If `store_model_in_db: true` is on, drift is expected and the job is the only thing keeping a single source of truth; if it is off, drift means someone used the UI, which should be disabled for writes in production.

Rule: pick one source of truth per object type and write it down. Mixed ownership (some models in Git, some in the UI) is the commonest cause of "it worked in staging".

## 18. Kubernetes deployment sketch

A sketch, not a tested chart. Pin versions, add resource sizing from your own measurements (the lab saw 0.56-0.77 GB RSS per container at idle load).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: litellm, labels: {app: litellm}}
spec:
  replicas: 3
  strategy: {rollingUpdate: {maxSurge: 1, maxUnavailable: 0}}
  selector: {matchLabels: {app: litellm}}
  template:
    metadata:
      labels: {app: litellm}
      annotations: {config-hash: "<sha256 of config.yaml>"}   # forces a roll on change
    spec:
      terminationGracePeriodSeconds: 120        # >= longest stream you accept
      topologySpreadConstraints:
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway,
           labelSelector: {matchLabels: {app: litellm}}}
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm-database:v1.106.4   # pin; prefer @sha256 digest
          args: ["--config", "/etc/litellm/config.yaml", "--port", "4000", "--num_workers", "2"]
          env:
            - {name: DISABLE_SCHEMA_UPDATE, value: "true"}   # migrations run in a Job (section 6)
            - {name: LITELLM_MASTER_KEY, valueFrom: {secretKeyRef: {name: litellm-secrets, key: master}}}
            - {name: LITELLM_SALT_KEY,   valueFrom: {secretKeyRef: {name: litellm-secrets, key: salt}}}
            - {name: DATABASE_URL,       valueFrom: {secretKeyRef: {name: litellm-secrets, key: database-url}}}
          ports: [{containerPort: 4000}]
          volumeMounts: [{name: cfg, mountPath: /etc/litellm}]
          resources:
            requests: {cpu: "1", memory: 1Gi}
            limits: {memory: 2Gi}
          readinessProbe: {httpGet: {path: /health/readiness, port: 4000}, periodSeconds: 5, failureThreshold: 3}
          livenessProbe:  {httpGet: {path: /health/liveliness, port: 4000}, periodSeconds: 10, failureThreshold: 6}
          startupProbe:   {httpGet: {path: /health/liveliness, port: 4000}, periodSeconds: 5, failureThreshold: 24}
          lifecycle: {preStop: {exec: {command: ["sleep", "15"]}}}
      volumes: [{name: cfg, configMap: {name: litellm-config}}]
---
apiVersion: v1
kind: Service
metadata: {name: litellm}
spec: {selector: {app: litellm}, ports: [{port: 80, targetPort: 4000}]}
```

Notes: the startup probe covers the 25-40 s start measured here (more when a migration runs); the liveness probe must not depend on the database or a backend, otherwise a DB blip restarts every replica at once; `/health` is never a probe (section 9). `ClusterIP` is deliberate: the ingress exposes only `/v1/*`, while admin paths go through a second, internal ingress (section 8).

Backend isolation: engines accept ingress only from gateway pods, and the gateway may egress only to engines, Postgres, Valkey and DNS.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: engines-only-from-gateway}
spec:
  podSelector: {matchLabels: {tier: engine}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {app: litellm}}}]
      ports: [{protocol: TCP, port: 8000}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: gateway-egress}
spec:
  podSelector: {matchLabels: {app: litellm}}
  policyTypes: [Egress]
  egress:
    - to: [{podSelector: {matchLabels: {tier: engine}}}]
      ports: [{protocol: TCP, port: 8000}]
    - to: [{podSelector: {matchLabels: {app: postgres}}}]
      ports: [{protocol: TCP, port: 5432}]
    - to: [{podSelector: {matchLabels: {app: valkey}}}]
      ports: [{protocol: TCP, port: 6379}]
    - to: [{namespaceSelector: {}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
      ports: [{protocol: UDP, port: 53}]
```

A NetworkPolicy is enforced only if the CNI supports it (kind's default CNI does not, a common false sense of security in labs). Test it the way task 4.8 does: `curl` the engine from a client pod and expect a timeout, not a refusal.

## 19. Observability signals and capacity planning

Signals to watch (metric names from the `prometheus` callback; check exact names on `/metrics/` of your build):

| Signal | Why | Alert shape |
|---|---|---|
| 5xx ratio per model group and per route | backend or gateway failure | ratio > 2% for 5 min |
| 429 ratio per key | limit misconfiguration or a runaway client | sustained > 20% on one key: tell the owner |
| 422 / 403 / 401 counts | budget exhaustion, access errors, leaked or expired keys | spike in 401 from one source = scanning |
| Latency p50/p95/p99 (total vs backend) | difference is gateway overhead; growth means CPU saturation | gateway overhead > 50 ms p95 |
| In-flight requests per replica | concurrent streams, the real capacity unit | > 70% of the capacity estimate below |
| Spend rate vs budget | denial-of-wallet, forecasting | burn rate projecting exhaustion before period end |
| Redis circuit breaker state, Valkey latency | shared limits silently degrading | any open state |
| Postgres connections, replication lag, `SpendLogs` size | pool exhaustion, bloat | > 80% of `max_connections` |
| Replica restarts, OOMKills | memory leak or oversized logs | any OOMKill |
| Deployment cooldowns (module 05) | backend flapping | cooldown > 2 min |

Capacity planning, by Little's law (concurrency = arrival rate x duration):

- 20 requests/s with a mean 15 s streamed completion = **300 concurrent streams**. Each stream holds a client socket and a backend socket, so about 600 file descriptors, plus DB/Valkey/log descriptors. The common default `ulimit -n 1024` is too tight; set 65536 (container runtime or `securityContext`/systemd limits).
- Workers: one uvicorn worker is one Python event loop; async I/O handles hundreds of streams, but JSON parsing, token counting and logging are CPU work. Start with `--num_workers` = CPU cores requested (2 in the sketch), measure CPU per 100 req/s, and scale replicas when a replica's CPU exceeds about 60%. More workers multiply DB pools (12.5) and memory (0.56-0.77 GB each was measured idle-to-light in the lab).
- Timeouts and slow clients: a client that reads slowly keeps a stream and its buffers alive. Cap request duration at the gateway and at the ingress (ingress read timeouts shorter than a long generation are a classic cause of truncated answers).
- Headroom rule: size so that losing one replica (or one zone) leaves the remaining replicas under 70% of the concurrency each can carry.
- The GPU is almost always the real bottleneck: at module 01 numbers, an engine decodes tens of concurrent sequences, so the gateway should queue or refuse (429 with `retry-after`) rather than forward 300 streams to a backend that can batch 64.

Lab honesty: the lab runs a handful of requests per second at most against tiny CPU models and a mock; it validates the *logic* of limits and spend, not throughput numbers. Do not reuse its latency or RSS figures for sizing.

## 20. Enterprise, SSO and RBAC boundary

Stated carefully, because licensing changes between releases:

- Open-source image, no license key: virtual keys, teams, users, budgets, RPM/TPM/parallel limits, model access lists, spend logs, Prometheus metrics, Langfuse callback, the admin UI with master-key login. This is what the course relies on, and `/metrics` is not enterprise-gated on v1.106.4 (measured).
- Documented as enterprise-licensed at the time of writing, confirm against the current docs and your license before designing around them: SSO for the admin UI beyond basic provider login, fine-grained RBAC roles and audit logs, per-team guardrail and logging controls, secret-manager integrations, some team-based logging and tag-based routing features, and JWT-based auth mappings.
- Design consequence: with only OSS features, "who may issue keys" is a function of who holds the master key or an admin key. Wrap issuance in your own service behind your own SSO (a small internal portal or pipeline calling `/key/generate`), which keeps you independent of the licensing boundary at the cost of owning that service.
- Verify, do not assume: for any feature you plan to depend on, test the exact call with `curl -i` on the pinned version and read the response; an enterprise-gated endpoint answers with an explicit error rather than silently doing nothing.

## 21. Incident walkthrough: "chat is slow and some users get 429"

Timeline from an on-call point of view; every step is something you can do with the tools of this module.

1. **Page**: 429 ratio on model group `chat` at 35% for 10 minutes; p95 latency 4x normal. Check the 429 body on a failing request (`curl -i`). The body says `Limit type: requests` for `api_key: <hash>`: it is the gateway limit, not the backend.
2. **Whose key?** Look the hash up (`GET /key/info?key=<hash>`) or filter the metric by `key_alias`: it is `agents-batch-prod`, with `rpm_limit: 600` and no `max_parallel_requests`. The same key has 280 in-flight requests on the in-flight panel.
3. **Why is the limit not protecting the GPU?** Three replicas, and the Valkey circuit-breaker metric has been open for 25 minutes (a Valkey node was rescheduled). Counters are per replica: 3 x 600 = 1800 RPM effective. Cross-check: Valkey keys `{api_key:<hash>}:requests` are absent or stale.
4. **Mitigate first**: `POST /key/update` for the agent key with `max_parallel_requests: 8` (works without Valkey because it is a per-replica in-flight counter, so the effective cap is 3 x 8 = 24, confirm the counter scope with `curl -i`); chat users recover within seconds as the engine queue drains. Do not block the key if the batch job is business-critical; throttle it.
5. **Repair**: restore Valkey; confirm the circuit breaker closes and Valkey keys reappear; send a burst against a test key with `rpm_limit: 2` and check `{200: 2, 429: n}` across both replicas (the lab 4.5 test).
6. **Follow-up** (blameless, in Git): add `max_parallel_requests` and TPM caps to the key-issuance recipe for non-human keys; alert on the circuit-breaker metric at warning level (it was present but unrouted); add a per-replica fallback calculation to the runbook (12.1); add the "no limits without Valkey" row to the HA table review.

The lesson mirrors the module: a limit is only as real as the store behind it, a concurrency cap is the protection that survives losing that store, and the first action is to throttle by identity rather than to restart things.

---

## Key takeaways

- The gateway is where identity, limits, spend and aliases live; it is useless as policy if engines are reachable around it.
- `model_name` = client contract (alias), `litellm_params.model` = backend contract; `openai/` + `api_base` (with `/v1`) for any OpenAI-compatible engine.
- Virtual keys are hashed in Postgres; teams carry model lists and budgets; keys carry rate limits; check both levels for 403s. 401 / 403 / 429 / 422 each mean something different.
- RPM = fixed 60 s window; TPM is counted after the response; budget exceeded = HTTP 422; spend lags by `proxy_batch_write_at`; use bounded polls, never sleeps.
- No `database_url` → no durability. Salt key and master key are set once and kept.
- Global limits across replicas need Valkey through `litellm_settings.cache` + `cache_params` (with `supported_call_types: []`); `router_settings.redis_*` alone shares nothing the rate limiter uses.
- Backend response ids must be unique or spend-log rows disappear.
- Sections 12-21 turn this into practice: size limits, logs and pools with arithmetic, know the failure branch and status of every request step, rotate keys with overlap, isolate engines with NetworkPolicy, and treat the lab as a simulation of logic, not of scale or attackers.

## Check yourself

1. A key has `rpm_limit: 20`; you run 3 replicas without Valkey behind a round-robin LB. What is the effective limit, and which two config keys fix it?
2. A client gets 403, another 401, another 422, another 429. Name the cause of each in one phrase.
3. After `docker restart litellm` every key returns 401. What is the first thing you check, and which two secrets must never change?
4. Why does `tpm_limit: 50` let two 30-token requests through? What would you add to bound a single request?
5. `SpendLogs` has 1 row but the key's spend shows 40 requests' worth. What is the most likely cause?
6. A key has `max_parallel_requests: 8`, `tpm_limit: 100000`, context 32768 and `max_tokens` 2048. What is the worst-case token volume admitted in one window, and which lever lowers it most?
7. Valkey becomes unreachable at 3 a.m. with 3 replicas and `rpm_limit: 60`. What is the effective limit now, which metric tells you, and which limit still protects the GPU?
8. Why must the preStop sleep and `terminationGracePeriodSeconds` exceed your longest stream, and why must the liveness probe not touch the database?
