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

---

## Key takeaways

- The gateway is where identity, limits, spend and aliases live; it is useless as policy if engines are reachable around it.
- `model_name` = client contract (alias), `litellm_params.model` = backend contract; `openai/` + `api_base` (with `/v1`) for any OpenAI-compatible engine.
- Virtual keys are hashed in Postgres; teams carry model lists and budgets; keys carry rate limits; check both levels for 403s. 401 / 403 / 429 / 422 each mean something different.
- RPM = fixed 60 s window; TPM is counted after the response; budget exceeded = HTTP 422; spend lags by `proxy_batch_write_at`; use bounded polls, never sleeps.
- No `database_url` → no durability. Salt key and master key are set once and kept.
- Global limits across replicas need Valkey through `litellm_settings.cache` + `cache_params` (with `supported_call_types: []`); `router_settings.redis_*` alone shares nothing the rate limiter uses.
- Backend response ids must be unique or spend-log rows disappear.

## Check yourself

1. A key has `rpm_limit: 20`; you run 3 replicas without Valkey behind a round-robin LB. What is the effective limit, and which two config keys fix it?
2. A client gets 403, another 401, another 422, another 429. Name the cause of each in one phrase.
3. After `docker restart litellm` every key returns 401. What is the first thing you check, and which two secrets must never change?
4. Why does `tpm_limit: 50` let two 30-token requests through? What would you add to bound a single request?
5. `SpendLogs` has 1 row but the key's spend shows 40 requests' worth. What is the most likely cause?
