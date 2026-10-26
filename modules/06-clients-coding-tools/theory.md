# 06 — Clients and coding tools: Open WebUI, Aider, Continue, FIM vs chat, reading a coding-agent request

Time: ~2 h reading with the tutor. Prerequisites: module 04 (keys, aliases, limits); module 05 helps (separation of traffic). Pinned: Open WebUI `v0.12.4`, LiteLLM `v1.106.4`, aider-chat `0.86.2` (in `platform/.venv-aider`), Continue config schema v1 (`config.yaml`).

Honesty box. Real: Open WebUI (a real container, real API, real UI at `:18080`), Aider (real CLI), LiteLLM, llama.cpp. Simulated: the graded coding behaviour. A 0.5B CPU model cannot produce valid tool calls, SEARCH/REPLACE edits or reliable FIM, so the graded paths use mock-vllm's scripted **mock-chat** mode (pattern -> `tool_calls`, a SEARCH/REPLACE block, a FIM-shape echo; contract in `mock/README.md` 3.5 and 3.8). It tests the *plumbing* — routing, keys, request shape, spend — not model quality. Not runnable here: the VS Code Continue extension and Cline/Roo (we replay what they send); in production the same clients talk to a real 7-70B coder model on GPUs, and quality (not plumbing) becomes the main source of tickets. Every number in the worked examples below (latencies, QPS, token counts) is an **illustrative calculation with stated assumptions**, not a measurement from the lab; replace the assumptions with your own logs.

Where this theory is unsure that a setting name or default holds in Open WebUI 0.12.4, Continue or aider 0.86.2 it says "check the admin panel / docs for your release". Settings move between releases; the *mechanisms* (what travels on the wire, what is persisted, what multiplies traffic) are what you are expected to know.

How the lab tasks map to sections:

| Task | What you do | Theory |
|---|---|---|
| 6.1 | Open WebUI to the gateway with its own key | 2.1-2.11, 10 |
| 6.2 | Aider through the gateway | 5 |
| 6.3 | Continue config: chat + autocomplete (FIM via the `coder` alias) | 3, 4 |
| 6.4 | Dissect a captured coding-agent request | 6, 7 |
| 6.5 | Stale Ollama URL / slow model-list trap | 2.3, 2.9 |

---

## 1. Who calls the gateway

| Client class | Examples | Traffic shape | Endpoints |
|---|---|---|---|
| Chat UI | Open WebUI, LibreChat | human-paced, streaming, plus hidden background calls (titles, tags) | `/v1/chat/completions`, `/v1/models`, `/v1/embeddings` (RAG) |
| IDE assistant | Continue, Copilot-like plugins | chat + **autocomplete (FIM)** + edit/apply + codebase embeddings | chat, **`/v1/completions`**, embeddings |
| CLI pair-programmer | Aider | turn-based, large prompts (files + repo map) | chat |
| Coding agent | Cline, Roo Code, OpenHands, Claude-Code-style tools | autonomous loops, tool calls, huge growing context | chat with `tools` |
| Scripts/services | your own code, notebooks | whatever the author wrote | any |

All speak the OpenAI-compatible protocol, which is why one gateway can serve them. What differs is *what they put in the request* and *how often*. Treat each class as a separate workload with its own key, team, limits and (ideally) model alias — module 05's separation applied to clients.

A useful mental model is three numbers per class: **requests per human action** (Open WebUI: 3-4 per message with background tasks on; autocomplete: dozens per minute; agent: one per tool step), **prompt tokens per request** (tens for a title task, 1-3 k for FIM, 5-100 k for agents) and **tolerated latency** (150 ms for FIM, 1-2 s time to first token for chat, minutes for an unattended agent). Capacity planning and limits follow from these, not from the number of humans.

## 2. Open WebUI

### 2.1 What it is and how it is built
A web chat UI (FastAPI backend + Svelte frontend, port 8080 in the container; `:18080` here) with accounts, chat history, RAG (documents, knowledge bases), tools/functions, model presets. State lives in its data directory (`/app/backend/data`: SQLite DB by default, uploads, vector store for built-in RAG, cache). Components worth knowing when you operate it:

| Part | Role | Production note |
|---|---|---|
| Backend (uvicorn) | auth, chat API, proxying to model backends, RAG pipeline, task requests | stateless *if* DB and secrets are external; one process is fine for tens of users |
| SQL database | users, chats, settings (PersistentConfig), prompts, functions | SQLite file by default; Postgres via `DATABASE_URL` for anything multi-replica or backed-up properly |
| Vector store | built-in RAG collections (Chroma by default; check `VECTOR_DB` for your release) | external Qdrant (module 07) so replicas share it |
| Redis | websocket manager and shared state between replicas | needed from the second replica on (`REDIS_URL`, `WEBSOCKET_MANAGER=redis`) |
| Data dir | uploads, vector files, SQLite, cache | a volume; back it up |

The browser holds a websocket to the backend (live events, streaming status). Chat completions themselves stream over plain HTTP from the backend, which in turn streams from the gateway.

### 2.2 Connecting it to a gateway
Open WebUI can talk to Ollama and to any number of OpenAI-compatible endpoints. Environment variables (documented):

| Variable | Meaning |
|---|---|
| `OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS` | semicolon-separated lists, same order; first boot only (see 2.3) |
| `ENABLE_OPENAI_API` | master switch for the OpenAI connections |
| `ENABLE_OLLAMA_API=false` | stop it probing the default `http://localhost:11434` / `host.docker.internal` |
| `WEBUI_SECRET_KEY` | session signing; must be identical on all replicas and stable across restarts (otherwise everyone is logged out) |
| `WEBUI_ADMIN_EMAIL/PASSWORD/NAME` | bootstrap the first admin (headless install) |
| `ENABLE_SIGNUP=false` | no self-registration |
| `OFFLINE_MODE=true` | don't reach Hugging Face/the internet (no model downloads, no update checks) |

In the admin panel (`Settings -> Connections`) each OpenAI connection has: URL, key, optional **prefix id** (prepended to model ids to disambiguate several gateways), optional **model id allow-list**, enable switch. The same operations exist as an API (used by the lab and by automation): `POST /api/v1/auths/signin` -> JWT; `GET /openai/config`; `POST /openai/config/update` with `OPENAI_API_BASE_URLS`, `OPENAI_API_KEYS`, `OPENAI_API_CONFIGS`; `GET /api/models`; `POST /api/chat/completions`.

Design rules:
- **Point Open WebUI only at the gateway**, with a key of its own (alias `owui-prod`, limits, team). Never at engines; never with the master key.
- Models users see = what that key may call (`/v1/models`). To give different user groups different models, use Open WebUI's own access control on top, not more gateway keys per human (see 2.5).
- Tell users which alias is which (`chat`, `coder`...) through model names/presets, not through URLs.
- The gateway key sits in Open WebUI's database (PersistentConfig, 2.3), readable by anyone with DB access and shown (masked) to admins. Scope it to the aliases the UI should offer and give it a budget; assume it can leak and make leaking it cheap.

### 2.3 PersistentConfig — the "I changed the env var and nothing happened" trap
Many Open WebUI settings (connections, RAG engine, feature flags) are **PersistentConfig**: the environment variable is read **only on first boot**, then stored in the database; later boots use the DB value and the UI/API is the source of truth. Consequences:

- Changing `OPENAI_API_BASE_URLS` in compose and restarting does **nothing** if the data volume already exists. Change it through the admin API/UI, or recreate the volume, or set `ENABLE_PERSISTENT_CONFIG=false` (env always wins; UI changes stop persisting — appropriate for GitOps-managed deployments).
- A *wrong* value saved on first boot (a stale Ollama URL, an old gateway address) survives redeploys until someone fixes it in the DB — lab task 6.5 plants this.
- Treat the data volume as stateful config: back it up, and in lab automation start from a fresh volume.

Rough inventory of what behaves how (check the docs page "environment variable configuration" for your release; each variable is marked PersistentConfig or not there):

| Persisted after first boot (UI/DB wins) | Read from the environment every boot |
|---|---|
| connection lists (`OPENAI_API_BASE_URLS`, `OPENAI_API_KEYS`, `OLLAMA_BASE_URLS`), `ENABLE_OPENAI_API`, `ENABLE_OLLAMA_API` | `WEBUI_SECRET_KEY`, `DATABASE_URL`, `REDIS_URL` |
| signup and default role (`ENABLE_SIGNUP`, `DEFAULT_USER_ROLE`) | `WEBUI_URL`-style infrastructure settings, ports, `UVICORN_WORKERS` |
| RAG engine, embedding model and endpoint, chunk size, top-k | `OFFLINE_MODE`, timeouts for outbound HTTP (`AIOHTTP_CLIENT_TIMEOUT*`) |
| task model and task feature switches (`TASK_MODEL_EXTERNAL`, `ENABLE_TITLE_GENERATION`...) | `ENABLE_PERSISTENT_CONFIG` itself |
| OAuth/OIDC provider settings, LDAP settings | `GLOBAL_LOG_LEVEL`, `CORS_ALLOW_ORIGIN` |

A rule of thumb: *what the admin panel can edit is persisted; what the process needs to start is environment.* The first-boot-only behaviour makes a clean redeploy from compose a lie unless you either use `ENABLE_PERSISTENT_CONFIG=false` or bootstrap by API after start (what the lab harness does).

### 2.4 Hidden traffic: tasks and the task model
Besides your messages Open WebUI sends **background requests** for chat titles, tags, follow-up suggestions, autocomplete in the input box and search/RAG query generation, using a *task model* (default: the same model you chat with). With a big model and many users that is a large, invisible share of tokens and GPU time. Teams point the task model at a small fast alias (`TASK_MODEL_EXTERNAL=chat-small`) and/or disable features (`ENABLE_TITLE_GENERATION`, `ENABLE_TAGS_GENERATION`, `ENABLE_FOLLOW_UP_GENERATION`, `ENABLE_AUTOCOMPLETE_GENERATION`; names per release — check the admin panel `Interface` page for v0.12). Measure: count gateway requests per user message; if it is 3-4 you found it.

Worked example (assumed): 80 active users, 25 messages per user per day, 4 gateway requests per message with the big `chat` alias (1 answer + title + tags + follow-ups). Answer ~700 prompt + 400 output tokens; each background task ~500 prompt + 40 output. Per message: 1 700 tokens on the answer, ~1 600 on the three tasks — almost half of the tokens go to housekeeping, and the three tasks arrive *at the same moment the answer finishes*, competing with the next user's answer for slots. With the task model on `chat-small` the big model sees one request per message and those 1 600 tokens run on a cheap engine.

### 2.5 Identity: one key for everyone vs per-user attribution
With one shared gateway key, all spend is "owui". Options:
1. Forward the user: `ENABLE_FORWARD_USER_INFO_HEADERS=true` makes Open WebUI add `X-OpenWebUI-User-Name/Id/Email/Role` headers to upstream requests; LiteLLM can read a configured header as the end-user id (`general_settings.user_header_name`) so spend is attributable per person without per-person keys.
2. Per-team keys (separate Open WebUI instances or model access groups) when budgets differ by department.
Choose deliberately; per-human gateway keys do not scale and tempt people to copy keys into scripts. Note the privacy side: forwarded headers put name and email into the gateway's logs and spend rows — decide whether you want an opaque user id instead and document the retention (section 12).

### 2.6 Users, groups and model access control
Open WebUI has its own authorization layer, independent of the gateway:
- **Roles**: `admin`, `user`, `pending` (a new account waiting for approval — the default role for self-registration unless changed; check `DEFAULT_USER_ROLE` for your release). Keep `ENABLE_SIGNUP=false` or default `pending`, otherwise anybody who can reach the URL can spend your budget.
- **Groups**: sets of users used for permissions (who may upload files, use web search, create tools, use the code interpreter) and for *access grants* on models, knowledge bases, prompts and tools.
- **Model access**: a model from the connection can be made private, public, or shared with specific users/groups; wrapped *presets* (a base model plus system prompt, parameters, attached knowledge) are the unit of access. Admins can bypass or not depending on settings (`BYPASS_MODEL_ACCESS_CONTROL`, `ENABLE_ADMIN_CHAT_ACCESS` — check names for your release; the second controls whether admins can read other people's chats, a privacy-sensitive switch).
- The effective set a user sees = (models the gateway key may call) AND (what Open WebUI access control grants). The gateway key is the outer boundary; Open WebUI's groups are the inner one. If a model is in the UI but not callable, the key is too narrow; if a user sees a model they should not, fix the UI grant, not the gateway.

### 2.7 SSO / OIDC
For anything beyond a team of five, use the company identity provider: OIDC via `ENABLE_OAUTH_SIGNUP`, `OAUTH_CLIENT_ID/SECRET`, `OPENID_PROVIDER_URL`, `OAUTH_SCOPES`, `OAUTH_PROVIDER_NAME`, with a correct external `WEBUI_URL` so redirect URIs match. Group claims can be mapped to Open WebUI groups (`ENABLE_OAUTH_GROUP_MANAGEMENT`, `OAUTH_GROUPS_CLAIM` — check the SSO page of the docs for your release), which makes "member of `ai-coders` in the IdP" the single place where access is granted. Two pitfalls: (1) the secret key must be stable and the cookie domain consistent, otherwise the login loop; (2) leaving password login on next to SSO keeps a back door whose accounts nobody offboards. Offboarding rule: disable in the IdP *and* check the Open WebUI user list, because accounts and chats persist locally.

### 2.8 Running more than one replica
A single container is simplest and enough for small teams. For availability or load:

| Requirement | Why |
|---|---|
| `DATABASE_URL` pointing at Postgres | SQLite is a file; two replicas on one volume corrupt or lock it |
| `REDIS_URL` + `WEBSOCKET_MANAGER=redis` (and enable websocket support; check `ENABLE_WEBSOCKET_SUPPORT`) | otherwise an event emitted by replica A never reaches a browser connected to replica B; symptoms: chats that never "finish", stuck spinners |
| identical `WEBUI_SECRET_KEY` on all replicas | otherwise sessions signed by A are invalid on B |
| shared vector store (Qdrant) and shared upload storage | RAG collections and files must be visible to every replica |
| load balancer that supports websockets (`Upgrade` headers, long idle timeouts) | many proxies cut idle websockets at 60 s |
| streaming not buffered at any hop | SSE responses are chunked; a buffering ingress shows the whole answer at the end |

Sticky sessions are *not* strictly required once Redis carries websocket state, but they reduce cross-replica traffic and make debugging easier; if you see sporadic disconnects only with N>1, test with stickiness first before blaming the application. Run database migrations from one replica at a time: Open WebUI migrates its schema on startup, so a rolling upgrade where an old and a new version share a database can break the old pods.

### 2.9 Data, backup, upgrade
- **Back up** the Postgres database (or the SQLite file with the container stopped) and the data volume; `WEBUI_SECRET_KEY` and any OIDC secrets live in your secret store, not in the backup. Restoring only the database but not the vector store gives knowledge bases that answer nothing.
- **Upgrade**: pin the image tag (`v0.12.4` — never `main`/`latest`), read the release notes for migration steps, take a backup, upgrade one replica, check the admin panel and a test chat, then the rest. Downgrades after a schema migration are generally not supported: the backup is your rollback.
- **Model-list timeout behaviour**: when you open the UI, the backend asks *every enabled connection* for its model list and merges the answers. A connection that is unreachable (stale Ollama URL, dead IP, DNS that blackholes) does not fail fast: it waits for the HTTP connect/read timeout, so the model list — and sometimes the whole page — is slow or empty although the gateway is healthy. The timeout is governed by an outbound-HTTP model-list timeout setting (look for `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` or similarly named variable in the docs for your release; the default is on the order of seconds, not milliseconds). Defences: disable connections you do not use (`ENABLE_OLLAMA_API=false`), use IPs or resolvable names, lower the timeout, and remember that the model list is cached for a while by the backend (a fixed connection may need a refresh). Lab task 6.5 measures exactly this: the time of `GET /api/models` with and without the dead connection.
- **File upload limits**: documents go through the RAG pipeline; limits exist for size and count (`RAG_FILE_MAX_SIZE`, `RAG_FILE_MAX_COUNT`; check names), and the reverse proxy has its own body-size limit (nginx `client_max_body_size`, default 1 MB) that rejects uploads before Open WebUI sees them.

### 2.10 RAG through the gateway
`RAG_EMBEDDING_ENGINE=openai` with `RAG_OPENAI_API_BASE_URL` (the gateway) and `RAG_EMBEDDING_MODEL=embed` makes document embeddings go through the gateway (spend, limits, one place for the model) instead of downloading a sentence-transformers model inside the UI container — essential offline. Changing the embedding model later invalidates existing vector collections (module 07).

Knobs that determine quality and traffic (names per release; check the Documents settings page): chunk size and overlap (common start: ~1000 characters, 100 overlap), top-k retrieved chunks, relevance threshold, hybrid search/reranker, "full context" mode (stuffs whole documents into the prompt: great for small files, ruinous for token budgets). Every uploaded file triggers a burst of embedding requests (n chunks / batch size); a 300-page PDF is a few hundred chunks, and ten colleagues uploading at 9 am is a small spike on `embed` — give the UI its own embedding key or rate limit with that in mind, and keep batch size consistent with the gateway's per-request input limits.

### 2.11 Functions, pipes and tools: plugins are code running on your server
Open WebUI "functions" (pipes, filters, actions) and "tools" are **Python code stored in the database and executed inside the backend process**. A pipe can add a "model" that calls anything; a filter can see and rewrite every prompt and response; a tool can read files, call the network, and run with the container's privileges and environment (including the gateway key and the secret key). Treat installing a community function exactly like installing a package from an unknown author:

- Creating/importing functions and tools is an **admin (or explicitly granted) permission**; restrict the workspace permissions of normal groups and do not allow arbitrary users to import from URLs.
- Review the code before enabling; keep reviewed functions in git and import from there; pin the Open WebUI version because the plugin interface changes.
- Run the container as non-root with a read-only root file system where possible, no Docker socket, **egress limited** to the gateway and the identity provider, and no production secrets in its environment beyond what it needs.
- Prefer implementing capabilities as MCP servers or sandboxed tool services behind your own controls (module 07) over in-process Python.
- Log: the gateway sees what leaves the UI to models, but not what a plugin does with the network; egress firewall logs do.

## 3. FIM vs chat

**Chat completion** (`/v1/chat/completions`): a list of role-tagged messages; the engine applies the model's *chat template* and generates an assistant reply. Used for conversation, explanations, edits ("rewrite this function").

**Fill-in-the-middle (FIM)**: the editor sends the text before the cursor (*prefix*) and after it (*suffix*); the model must generate the *middle*. Models trained for FIM know special tokens, and the order in which prefix and suffix are presented is part of the training format (usually PSM: prefix, suffix, middle; some use SPM). There is no chat template and no system prompt.

| | Chat | FIM / autocomplete |
|---|---|---|
| Endpoint | `/v1/chat/completions` | `/v1/completions` (legacy text completion) with `prompt` (+ `suffix` where supported) — or llama.cpp's native `/infill` |
| Model | instruct/chat model (7-70B) | base coder model, often small (1.5-7B) |
| Latency target | first token < ~1-2 s, then streaming | whole suggestion in ~100-400 ms; late = useless |
| Output | long, streaming | short: `max_tokens` 32-128, `temperature` 0-0.2, `stop` at newline/blank line |
| Request rate | per human message | **per pause in typing** (debounced, ~every few hundred ms, cancelled when you type on) |
| Prompt | conversation | a window of file context around the cursor (hundreds-few thousand tokens) |

### 3.1 FIM token tables
The token names are **model-specific**; the wrong template gives garbage, not an error.

| Model family | Prefix | Suffix | Middle | End / stop-relevant | Notes |
|---|---|---|---|---|---|
| Qwen2.5-Coder | `<\|fim_prefix\|>` | `<\|fim_suffix\|>` | `<\|fim_middle\|>` | `<\|endoftext\|>`, `<\|fim_pad\|>`, `<\|file_sep\|>` | PSM; repository-level prompts use `<\|repo_name\|>` and `<\|file_sep\|>` between files |
| StarCoder / StarCoder2 | `<fim_prefix>` | `<fim_suffix>` | `<fim_middle>` | `<\|endoftext\|>`, `<file_sep>` | PSM; `<fim_pad>` also exists |
| CodeLlama (7B/13B base, not 34B) | `<PRE>` | `<SUF>` | `<MID>` | `<EOT>` | format `<PRE> {prefix} <SUF>{suffix} <MID>` with *spaces* mattering |
| DeepSeek-Coder | full-width-bar tokens (`<｜fim▁begin｜>`, `<｜fim▁hole｜>`, `<｜fim▁end｜>`) | | | | hole-style: prefix, hole marker, suffix, end marker |

Do not copy these tables blindly into production: read `tokenizer_config.json`/the model card of the exact checkpoint (the lab's `mock/models` fixtures are not real tokenizers).

### 3.2 A worked FIM request on the wire
The editor has this file open; the cursor is at `|`:

```python
def mean(xs):
    if not xs:
        return 0.0
    |
    return total / len(xs)
```

Style 1 — the server applies FIM (`suffix` parameter, OpenAI legacy completions shape; support depends on the engine and model template):

```json
{
  "model": "coder",
  "prompt": "def mean(xs):\n    if not xs:\n        return 0.0\n    ",
  "suffix": "\n    return total / len(xs)\n",
  "max_tokens": 48,
  "temperature": 0.1,
  "stop": ["\n\n", "<|endoftext|>"],
  "stream": true
}
```

Style 2 — the client builds the model's template itself and sends one flat `prompt` (what Continue-like clients do when told the model family, or against engines that do not implement `suffix`):

```json
{
  "model": "coder",
  "prompt": "<|fim_prefix|>def mean(xs):\n    if not xs:\n        return 0.0\n    <|fim_suffix|>\n    return total / len(xs)\n<|fim_middle|>",
  "max_tokens": 48,
  "temperature": 0.1,
  "stop": ["\n\n", "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>"],
  "stream": true
}
```

Style 3 — llama.cpp native `/infill` (the server knows the loaded model's FIM tokens; check the server README of your build for the exact field set):

```json
{
  "input_prefix": "def mean(xs):\n    if not xs:\n        return 0.0\n    ",
  "input_suffix": "\n    return total / len(xs)\n",
  "input_extra": [{"filename": "util.py", "text": "...other-file snippet..."}],
  "n_predict": 48,
  "temperature": 0.1,
  "stream": true
}
```

A good completion here is `total = sum(xs)` and then an end-of-text. The mock answers differently and honestly: it returns `FIM_ECHO prefix_chars=N suffix_chars=M sentinels=...` (mock contract 3.5) and records `fim`, `prompt_chars`, `suffix_chars`, `prefix_tail`, `suffix_head` in `/admin/stats`. That proves the *shape* arrived — a gateway that dropped `suffix`, a client that sent no sentinels — and nothing about suggestion quality.

Why the parameters look like this:
- **`max_tokens` small (32-128)**: a suggestion is a line or a block, and the user will type over it; every extra token costs decode time on the critical path (decode ~2-10 ms/token on a GPU, 50-100 ms/token on a CPU) and tokens beyond the block end are usually wrong. Note that a hard `max_tokens` can cut a suggestion mid-expression, which is why a client trims at the last complete line.
- **`temperature` 0-0.2**: completions should be the likely continuation; diversity is useless when only one suggestion is shown.
- **`stop` sequences**: the model does not know where the "middle" should end except via its end token. Clients add `\n\n` (blank line) or a newline for single-line mode, plus the family's end/pad/file-separator tokens, because a model that runs past the hole starts writing the suffix again or the next file.
- **`stream`**: lets the client cut off at the first stop condition and show early tokens; but cancelling a streamed request matters more than streaming (3.4).

### 3.3 Latency budget for a 150 ms suggestion
The editor waits a *debounce* (typically 150-350 ms, configurable) after the last keystroke *before* sending, and the user perceives latency from the request on. Assume a developer on VPN, a 1.5B-3B coder on a GPU (illustrative figures):

| Stage | Budget (ms) | What eats it |
|---|---|---|
| Client work (build prompt from file context, TLS reuse) | 5-10 | cold TLS handshake adds 2 RTT; keep-alive on the gateway matters |
| Network to the gateway (VPN) | 20-30 | the only stage you cannot buy back; put the gateway close to developers |
| Gateway overhead (auth, key lookup, limit checks, routing, logging callbacks) | 5-15 | synchronous DB or callback work in the request path; module 05 |
| Queue wait at the engine | 0-10 | any queueing at all, especially behind long prefills |
| Prefill (~1 500 prompt tokens) | 40-60 uncached, ~10-15 when ~80% is a prefix-cache hit | the dominant term on busy engines |
| Decode (~25 output tokens at ~2.5 ms) | 60 | `max_tokens`, model size, speculative decoding |
| Return path | 10-20 | |
| **Total** | **~150-200** | |

Reading the table: the budget is gone by network + decode alone, so there is no room for a 50 ms queue wait or a 500 ms agent prefill ahead of you in the same batch. That is why FIM gets its own engine or at least its own priority class, why the gateway must stay thin for this alias (no per-request prompt logging to a slow store, no heavy guardrail callbacks), and why a bigger FIM model almost never wins: doubling parameters roughly doubles decode and prefill, and an answer after 400 ms is discarded because the user already typed the next character.

### 3.4 Autocomplete traffic math
Assumptions (replace with your own telemetry): a developer actively typing/pausing 30 minutes per hour; one request per pause longer than the debounce, on average one every 3 s of active time; 40% of requests cancelled because the user kept typing; 1 500 prompt tokens (prefix + suffix + context snippets), 30 output tokens for completed ones.

| Quantity | Computation | Result |
|---|---|---|
| Requests per developer per hour | 1 800 s / 3 s | 600 |
| ...of which cancelled | 40% | 240 (360 complete) |
| Fleet of 200 developers, 60% active at peak | 120 active | 120 x 600 / 3 600 = 20 QPS |
| Prefill demand without caching | 20 x 1 500 | 30 000 prompt tokens/s |
| Prefill demand with ~80% prefix hit | 20 % of the above | ~6 000 computed tokens/s |
| Decode demand | 20 x 0.6 x 30 + cancelled-partial | ~360-500 tokens/s |
| Requests per day (8 h, 60% duty) | 200 x 600 x 8 x ~0.5 | ~480 000 |

Consequences:
- 20 QPS of 150 ms requests is only ~3 concurrent sequences on average (Little's law: 20 x 0.15), so the engine is **latency-bound, not throughput-bound**: a small model on one GPU copes, but spikes (everyone resumes after the stand-up) multiply concurrency. Size for p99 concurrency and keep the batch small.
- Compare with chat: 200 developers asking one chat question per 5 minutes is 0.7 QPS — a thirtieth of the request rate. FIM dominates request count; chat dominates tokens per request.
- **Cancellation**: a cancelled request that keeps generating wastes decode slots; cancelled requests are 40% of the traffic here, so propagation of client disconnects (client -> gateway -> engine; vLLM aborts a request when the connection closes) is a capacity feature, not a nicety. Test it: start a long streamed completion, kill the client, and watch `vllm:num_requests_running` fall. A gateway that buffers or detaches the upstream call on client disconnect turns every aborted keystroke into a full generation.
- Rate limits: the right limiter for FIM is a high RPM with a tiny TPM per request, plus a low `max_tokens` enforced where possible; a 429 on autocomplete degrades silently (no suggestion) and the client may retry, so look at 429 rates per key rather than waiting for complaints.
- Cost accounting: 480 000 requests/day at 1 500 prompt tokens is 720 M prompt tokens/day. If the gateway records spend per request, the spend table grows by ~0.5 M rows a day — plan retention and the log pipeline for the FIM key (sampling, or no per-request prompt logging for that key).

### 3.5 Prefix caching: what it does for FIM and for agents
Automatic prefix caching (vLLM; llama.cpp has a similar prompt-cache/slot reuse) keeps KV blocks of prompts already computed and reuses them when a new prompt starts with the same token blocks (block-hashed, e.g. 16 tokens per block, chained so one changed token invalidates everything after it). Metrics: `vllm:prefix_cache_queries_total` and `vllm:prefix_cache_hits_total` (hit rate = rate(hits)/rate(queries)), and `vllm:prompt_tokens_cached_total`. Not measurable on the CPU lab — the mock exposes the metric names but no real cache.

For **FIM** the prompt order is prefix, then suffix, then the middle marker. Typing one character changes the *end of the prefix*, so everything after that point — the whole suffix — misses; only the prefix up to the last full block before the edit is reused. With 1 200 prefix tokens and 300 suffix tokens a hit rate of roughly 75-80% is realistic; with a big suffix or other-file snippets placed *before* the prefix and changing between requests, the hit rate collapses. Practical advice: keep the file-context snippets in a stable order, and check the hit rate with a real client before promising numbers.

For **agents** the fixed system prompt + tool schemas are identical across turns and users, and the history is append-only, so each turn reuses nearly all of the previous turn's prompt: hit rates of 85-95% are typical when the engine has enough KV memory to keep the sessions' blocks. The cache is *LRU in finite KV memory*: a burst of other traffic evicts a long session's blocks and the next turn pays a full prefill (a "cache cliff" that appears as a TTFT spike every N turns). Two things break caching on purpose or by accident: (1) the client inserts changing data early in the prompt (a timestamp or "current working directory listing" in the system prompt), (2) the client truncates history from the front (6.2). Cached tokens are usually still billed as prompt tokens by the gateway's `usage`; cache hits save engine time, not the token counter, unless you price cached tokens differently.

## 4. Continue (IDE assistant)

Continue is an open-source VS Code/JetBrains extension (and CLI). Configuration is `~/.continue/config.yaml` (schema v1): a list of models, each with `roles` (`chat`, `edit`, `apply`, `autocomplete`, `embed`, `rerank`), a provider and endpoint:

```yaml
name: team-assistant
version: 1.0.0
schema: v1
models:
  - name: Team chat
    provider: openai
    model: chat                      # a gateway ALIAS
    apiBase: http://gateway.internal:18040/v1
    apiKey: sk-...                   # a key for chat only
    roles: [chat, edit, apply]
  - name: Team autocomplete
    provider: openai
    model: coder                     # FIM alias
    apiBase: http://gateway.internal:18040/v1
    apiKey: sk-...                   # a different key: coder only
    roles: [autocomplete]
    defaultCompletionOptions: {maxTokens: 64, temperature: 0.1}
  - name: Team embed
    provider: openai
    model: embed
    apiBase: http://gateway.internal:18040/v1
    apiKey: sk-...
    roles: [embed]
```

Notes (check the Continue docs for your exact release before rolling out):
- With provider `openai`, autocomplete is sent as a **completions** request; whether the `suffix` field is used or Continue builds the FIM prompt itself from a template depends on model/provider options (e.g. a template for the model family, or the `useLegacyCompletionsEndpoint` option). Verify against the *request on the wire* (gateway log / mock echo), which is what the lab does.
- Separate keys per role are possible because each model entry carries its own `apiKey`: chat key limited to `chat`, autocomplete key limited to `coder`. This is least privilege applied to a client (module 04).
- Air-gap: disable telemetry and external docs/hub fetches in the shared config; distribute the config as a managed file (MDM/dotfiles repo) instead of letting each user hand-edit it.
- Developers on laptops reach the gateway over VPN/Tailscale; engine ports never.

### 4.1 The config.yaml schema, field by field
Top level of schema v1 (names as documented for the v1 schema; check the reference for your release):

| Field | Purpose | Platform relevance |
|---|---|---|
| `name`, `version`, `schema` | identifies the config; `schema: v1` | version your shared file; bump `version` on every change |
| `models[]` | each entry: `name`, `provider`, `model`, `apiBase`, `apiKey`, `roles`, `defaultCompletionOptions` (temperature, maxTokens, topP, stop...), `requestOptions` (timeout, headers, proxy, TLS verification), `promptTemplates`/`template` options, `capabilities` | the per-role endpoint and key; custom headers for client identification (4.5); timeouts |
| `context[]` | context providers: `code`, `docs`, `diff`, `terminal`, `problems`, `folder`, `codebase`, `url` ... with params | each provider decides what extra text lands in the prompt, hence prompt tokens per chat message |
| `rules[]` | strings (or file references) injected as system-level instructions | team coding standards belong here, versioned, instead of in each developer's head |
| `prompts[]` | named slash-command prompt templates | |
| `mcpServers[]` | MCP servers the agent mode may call | security-relevant; see module 07 for the protocol and its risks |
| `data[]` | development-data destinations (usage telemetry sinks) | check and disable; see 4.4 |

`rules` are worth using for platform reasons: a rule that says "answer in English, prefer the standard library, never print secrets" is copied into *every chat request's system prompt*, so it costs prompt tokens on every turn and is a good prefix-caching candidate (it is identical for the team). Keep rules short.

### 4.2 Embeddings and codebase indexing: the first-open spike
The `codebase` context provider (and `@codebase`-style retrieval) requires an index: on first opening a workspace Continue walks the files, splits them into chunks and calls the `embed`-role model for each chunk, storing vectors locally (and re-embedding only changed files afterwards). Traffic implications (assumed figures):

- A 200 000-line repository is roughly 2.4 M tokens; with ~500-token chunks that is ~4 800 embedding inputs, sent in batches. One developer opening it once is a few minutes at ~10 k tokens/s on a small embedding model.
- A team rollout: 100 developers install the extension on Monday morning, each with one or two repositories -> 240 M-480 M embedding tokens in a couple of hours, i.e. a sustained spike that starves the `embed` alias that Open WebUI RAG shares unless it has its own key, limit and ideally its own capacity. Stagger the rollout, give the IDE its own embedding key with an RPM/TPM cap, and expect `429` retries that stretch indexing time.
- Branch switches and mass reformatting re-embed many files at once. A team that vendors dependencies into the repo triples the index; use the ignore settings (check the docs for the index ignore file/globs).
- Changing the embedding model invalidates every developer's local index: it forces a full re-embed on every laptop at once. Treat `embed` as an alias you never silently repoint (section 11).

### 4.3 Timeouts, cancellation and retries
- Each model entry can set request timeouts and headers via `requestOptions`; a chat request with a large selected context can take longer than the default timeout on a busy shared engine and shows up as an editor error, while the gateway log shows a completed request (the client gave up, the engine finished) — compare durations on both sides.
- Autocomplete requests are cancelled as the user types; confirm in a capture that the connection closes (HTTP/1.1 connection reset or HTTP/2 stream reset) rather than being left to drain.
- A 429 from the gateway on autocomplete is generally *not* surfaced to the user; the suggestion simply does not appear. Clients differ in whether they back off. Check `Retry-After` handling in your release; a tight retry loop under a rate limit turns a limit into a retry storm.
- Chat/edit/apply ride the `chat` alias and a different key from autocomplete, so a spend cap or rate limit hit by chat does not silence autocomplete (and the reverse).

### 4.4 Managed distribution and telemetry
- Ship `config.yaml` through MDM, a dotfiles repo, or the Continue hub/organization features (check the docs for your release); users should only supply their personal key, not the model list. Keep a template with the key left empty and a check script that fails if a real key was committed.
- Keys on laptops: see section 12. A common compromise is a per-developer key with a modest budget minted by a provisioning script (section 10.2), stored in the OS keychain or an environment variable the config references, not in the config text.
- Telemetry: the extension has anonymous usage telemetry and the config can have `data` destinations for development data; in an air-gapped or compliance-bound setup turn the telemetry off in the IDE settings and shared config and confirm with the tripwire/DNS logs that nothing leaves (the course's module 08/09 technique). Do not assume a setting works; verify by observing traffic.

### 4.5 Identification
Set a custom header per client class in `requestOptions.headers` (for example `x-client: continue`, `x-team: ide`) so the gateway can label metrics without depending on `User-Agent` parsing (section 11.3).

## 5. Aider (CLI pair programmer)

Aider edits files in a git repo through chat. What it sends each turn: a system prompt (rules + the **edit format** instructions), a **repo map** (tree-sitter summary of the code base, size set by `--map-tokens`), the contents of files added to the chat, the chat history, and your message. Prompt tokens are therefore large and mostly repeated between turns (prefix caching on the engine helps a lot).

- **Edit formats**: `diff` (SEARCH/REPLACE blocks — default for strong models), `whole` (rewrite whole file — robust but token-hungry; the usual fallback for weak models), `udiff`, `editor-diff/whole` (architect/editor split with two models). A small model that cannot produce exact SEARCH blocks yields "malformed edit" loops — pick the format per model.
- **Using a gateway**: `OPENAI_API_BASE=http://127.0.0.1:18040/v1`, `OPENAI_API_KEY=<key>`, model `openai/<alias>` (the `openai/` prefix tells Aider/LiteLLM-inside-Aider to use the OpenAI protocol with your base URL; the alias after the slash is what the gateway knows).
- Unknown model names produce warnings about context size/cost; describe the model in `.aider.model.metadata.json` (`max_input_tokens`, costs) and settings in `.aider.model.settings.yml` (edit format, `use_repo_map`).
- Auto-commits: by default each applied edit is committed (`--no-auto-commits` to disable); good for review and revert, surprising for newcomers.
- Offline hygiene: `--no-analytics`, `--no-check-update`, `--no-show-release-notes` (or the `AIDER_*` env equivalents) so it does not try to phone home.
- Not a daemon: no keep-alive traffic; spend appears only while you chat. That makes it a good "agent-lite" workload to size.

### 5.1 Repo map sizing
The repo map is a ranked list of files with the key class/function signatures, built with tree-sitter and a PageRank-style ranking over references, truncated to a token budget (`--map-tokens`, default around 1 000 tokens for most models; check `aider --help` for 0.86.2). Effects: a bigger map gives the model more awareness of the code base and costs prompt tokens **on every turn**; the map is recomputed when files change (`--map-refresh` controls how eagerly), and a map that changes between turns breaks prefix caching after its first changed line because it sits early in the prompt. Rules of thumb: 1-2 k for small repos and small-context models, 4-8 k only for strong long-context models, `--map-tokens 0` to disable it for a model that gets confused. Per turn prompt = system prompt (~2 k with edit-format examples) + map + added files + history; with 3 files of 600 lines (~7 k tokens), a 2 k map and 6 turns of history (~6 k), a single request is ~17 k tokens — which is why a model served with an 8 k context window fails in Aider with a context-length 400 (see mock error shape, 3.5 of the mock README) and why `max_input_tokens` in the metadata file matters.

### 5.2 Edit format per model (what to put in `.aider.model.settings.yml`)
Edit formats trade token cost against the model's precision. A model that cannot reproduce the SEARCH text exactly makes Aider retry ("The SEARCH block failed to match"); each retry is another full request. Approximate guide: strong instruction-following models -> `diff`; mid-size models -> `diff` with caution or `whole`; small (<=7B) local models -> `whole`; very long files -> `diff` or `udiff` because `whole` re-emits the file. Example file in the project root or home (`.aider.model.settings.yml`; list of entries; field names as documented for aider — check your release):

```yaml
- name: openai/agent
  edit_format: diff
  use_repo_map: true
  weak_model_name: openai/chat-small   # commit messages and history summaries
  extra_params:
    max_tokens: 4096
    extra_headers:
      x-client: aider
      x-team: agents
- name: openai/coder-small
  edit_format: whole
  use_repo_map: false
```

The `weak_model_name` matters for cost: Aider calls a second, cheaper model for commit messages and for summarizing old history, and if you do not set one for an unknown model it uses the main model for those calls too — extra requests that appear in the gateway as separate calls with a different alias.

### 5.3 Architect/editor mode with two aliases
`--architect` splits the work: an *architect* model reasons about the change in prose; an *editor* model turns that into precise edits (`--editor-model`, `--editor-edit-format`). In platform terms that is **two gateway aliases for one user action**: for example `--model openai/agent-big --editor-model openai/agent-fast`. Each user request becomes two sequential requests (the editor's prompt includes the architect's answer), so latency adds, and spend is split across both aliases and both keys' limits — one key must be allowed to call both, or two env settings are needed. It is the typical way to buy quality (strong reasoning) and reliability (a small model that is good at the edit format) at a lower cost than one big model for everything. Verify in the gateway log that the two calls carry the aliases you intended.

### 5.4 Auto-commit hygiene
- Aider commits *before* editing if the working tree has uncommitted changes to files it will touch ("dirty commits"; `--no-dirty-commits` to disable), and after each applied edit with a generated message; it marks them (author/committer name suffix `(aider)` by default; check `--attribute-*` options). `/undo` reverts the last Aider commit; `/diff` shows the change.
- For team use: work on a branch, squash before review, and never run Aider in a repo containing secrets that should not enter prompts (`.aiderignore` works like `.gitignore` for what Aider will read; also `.env` files — see section 12).
- `--no-auto-commits` is the right choice when the human wants to review the diff in the working tree first, or when your commit policy requires signed commits that Aider's commits would not carry.

### 5.5 Scripting Aider in CI (`--message`)
`aider --message "<instruction>" <files>` runs one instruction non-interactively and exits; add `--yes-always` to accept prompts, `--no-stream --no-pretty` for log-friendly output, `--no-auto-commits` and `--dry-run` to inspect without writing (check the help of 0.86.2 for the exact flag set). For CI: pass the key via environment, give it a CI-specific key with a tight budget and `max_parallel_requests` of 1-2, run in a throwaway checkout, treat the result as an *untrusted patch* (tests and review gate it), and fail the job on non-zero exit or empty diff. Because there is no human to notice a loop, a runaway "malformed edit" retry cycle burns tokens silently — the budget cap on that key is the real safety, not the tool.

### 5.6 The token and cost report
After each message Aider prints "Tokens: X sent, Y received" and, if it knows the prices, a cost estimate and a session total; `/tokens` lists what each part of the context (system, map, files, history) currently costs. Use it in the lab to correlate with the gateway's `usage` for the same request: the numbers agree for the same tokenizer family, but Aider's *estimates* before sending use its own tokenizer, and for an unknown model (such as an alias) the cost shows as zero or unknown — spend truth is in the gateway's spend logs, which is one more reason clients should not be your cost accounting.

## 6. Anatomy of a coding-agent request

Autonomous coding agents (Cline, Roo, OpenHands, Claude-Code-style tools) run a loop: model proposes a **tool call** (read file, edit, run command) -> the client executes it -> the **result is appended** -> the **whole conversation is sent again**. A single request looks like:

```json
{
  "model": "agent",
  "stream": true,
  "max_tokens": 8192,
  "tools": [ {"type":"function","function":{"name":"read_file","description":"...","parameters":{ ...JSON schema... }}}, ... ],
  "tool_choice": "auto",
  "messages": [
    {"role":"system","content":"<thousands of tokens: persona, rules, tool usage guide, repo/env info>"},
    {"role":"user","content":"Fix the failing test in utils/"},
    {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"utils/x.py\"}"}}]},
    {"role":"tool","tool_call_id":"call_1","content":"<file contents>"},
    ...
  ]
}
```

What an infra engineer reads from it:

1. **System prompt + tool schemas = a large fixed prefix** per turn: commonly several thousand tokens, often 10k+ with many tools (the lab capture is smaller but same shape). This prefix is identical across turns and users of the same tool: ideal for **prefix caching** — and the reason engines without it are crushed by agents.
2. **History grows every turn and is resent in full.** If the fixed prefix is P tokens and each turn adds d tokens (model output + tool result), turn k sends P + k·d prompt tokens; a session of n turns processes Σ = nP + d·n(n+1)/2 prompt tokens. Example: P = 12 000, d = 1 500, n = 30 -> 360 000 + 1 500·465 = 1 057 500 prompt tokens for one task, versus ~57 000 *distinct* tokens (P + n·d) of actual information. Without prefix caching the engine prefills ~1 M tokens; with it, roughly the new tokens only. This is the arithmetic behind "agents cost 10-100x chat". Section 6.1 works several parameter sets.
3. `tools`/`tool_choice`/`parallel_tool_calls`: needs a model and serving stack with tool-call parsing (vLLM `--enable-auto-tool-choice --tool-call-parser ...`); a model that emits malformed JSON arguments breaks the loop — gateway logs show repeated near-identical requests (section 6.3).
4. `stream: true` with tool-call deltas: the gateway must pass SSE through without buffering; a proxy that buffers kills agent UX.
5. `max_tokens` large + `temperature`; many agents set a high `max_tokens` "just in case" — it reserves KV in the engine (module 01/03).
6. Context-window management: when history approaches the window the client truncates or summarizes ("condense"). A sudden prompt-size drop in your logs is that event; a hard 400 context error is what module 05's `context_window_fallbacks` handles.
7. Identification: the `User-Agent` header (and any `HTTP-Referer`/`X-Title` the client sets) distinguishes tools; log it and label metrics with it where possible (LiteLLM's Prometheus metrics carry `user_agent`).
8. Parallelism: sub-agents or parallel tool calls fire several requests at once — the reason agent keys need `max_parallel_requests`.

### 6.1 Session token arithmetic with several parameter sets
Formula: prompt tokens processed over n turns = n·P + d·n(n+1)/2; distinct information = P + n·d.

| Set | P | d | n | Σ prompt tokens | Distinct | Ratio | Peak prompt (turn n) |
|---|---|---|---|---|---|---|---|
| Small task | 8 000 | 1 000 | 20 | 160 000 + 210 000 = 370 000 | 28 000 | 13x | 28 000 |
| Medium task | 12 000 | 1 500 | 30 | 360 000 + 697 500 = 1 057 500 | 57 000 | 19x | 57 000 |
| Long task | 15 000 | 3 000 | 50 | 750 000 + 3 825 000 = 4 575 000 | 165 000 | 28x | 165 000 |
| Many tools | 25 000 | 1 500 | 30 | 750 000 + 697 500 = 1 447 500 | 70 000 | 21x | 70 000 |

Note the last column: the long task needs a 165 k context; no client policy can avoid either a big window or condensing. With a 32 k window the medium task hits the limit at turn 14 (12 000 + 13.3 x 1 500 = 32 000).

### 6.2 Cost versus context policy
Take the medium task (P = 12 000, d = 1 500, n = 30) with a 32 k window, an engine with a prefix cache, and these policies. Prompt tokens are what the gateway's `usage` and any per-token price see; "computed" is the engine's real prefill work assuming ideal caching (illustrative arithmetic, not a measurement):

| Policy | Prompt tokens sent | Prefill computed | Remarks |
|---|---|---|---|
| Append only, window >= 57 k, no cache | 1 057 500 | 1 057 500 | the baseline; needs a big window |
| Append only, with prefix cache | 1 057 500 | ~57 000 (+ misses) | roughly P + n·d; the cache hit rate is the whole story |
| Truncate oldest to 32 k, no cache | 13 turns grow to 32 k (292 500) + 17 x 32 000 = 836 500 | 836 500 | never exceeds the window; quality loses old context |
| Truncate oldest to 32 k, with cache | 836 500 | ~370 000 | front truncation moves the start of history every turn, so everything after the system prompt misses: 31 500 + 17 x 20 000 |
| Condense at 24 k (summarize to ~3 k, back to ~15 k), no cache | ~670 000 incl. ~4 summarization calls of ~24 k | ~670 000 | prompt shrinks in sawtooth; quality is better than truncating |
| Condense at 24 k, with cache | ~670 000 | ~75 000-100 000 | cache misses only at each condense (summary text is new) |

Takeaways: (1) the cheapest policy for engine work is *append only + cache*, bounded by the window; (2) **truncating from the front is the worst case for caches** and for billing alike; (3) condensing is a sawtooth in your per-request prompt-size graph — you can see a client's policy from the logs; (4) the gateway bills sent tokens, so a team that moves from truncate to condense sees spend drop ~20% even though the engine's work drops 5x — spend and GPU load are different curves. Output tokens (a few hundred per turn) are small next to this and are priced differently.

### 6.3 Tool-call parsing failure modes and how they look in the logs
A tool call travels as text the model generated, parsed by the engine into the `tool_calls` field. Each stage has a failure:

| Failure | Cause | What the gateway shows |
|---|---|---|
| Request returns 400 about `auto` tool choice | vLLM started without `--enable-auto-tool-choice` and `--tool-call-parser <name>`, request has `tool_choice: auto` (exact wording by version; check your release) | 400 on every agent request from the first one; the client may show a generic error |
| Tool call appears as plain text in `content`, `finish_reason: stop` | wrong parser for the model family (e.g. a Hermes-style `<tool_call>{...}</tool_call>` output with a Llama parser), or parser flag present but model not trained for tools | no `tool_calls` in the response; assistant message content contains JSON or XML-ish tags; the agent loop asks again |
| Model never uses tools, answers in prose | chat template has no tools section (template ignores the `tools` argument) so the model never saw the schemas; or `tool_choice: none` | `finish_reason: stop` every time while the request has `tools`; low completion tokens |
| Malformed JSON in `arguments` | small or heavily quantized model, truncated by `max_tokens`, unescaped quotes in code | client logs JSON parse error; gateway shows a response with `finish_reason: length` or a tool call whose `arguments` string is not valid JSON |
| Wrong argument names/types | schema too complex, too many tools | client sends the error back as a `tool` message; the next request is near-identical plus an error line |
| Streaming tool-call deltas mangled | proxy or gateway buffering/rewriting SSE, or a client that expects whole arguments in one chunk | partial or duplicate arguments; works with `stream: false` |

How to see it in the logs: group requests by session (same key, same long prefix hash); a healthy session has `finish_reason` alternating `tool_calls` and, at the end, `stop`. A broken one has a run of 3+ near-identical requests (prompt grows by a few dozen tokens each: just the error message) or a high `stop` rate on requests that carry `tools`. Metrics to alert on: share of agent-alias responses with `finish_reason=tool_calls`, and per-session retries. In the lab the mock's scripted mode returns well-formed calls by construction, so the *parsing* failures are not reproducible there; what you can reproduce is a request with `tools` that matches no rule (plain text back) and read it in the log.

Pointer: tool schemas, MCP servers, the tool-execution sandbox and their security model are module 07's subject. In this module you only need to recognise tools in the request and know their token cost; do not design tool servers here.

## 7. Reading a captured request (task 6.4 method)
A repeatable procedure for any unfamiliar client:
1. Identify endpoint and stream flag: chat vs completions vs embeddings; SSE or not.
2. Count the components of the prompt: system message length, number and size of tool schemas, number of history messages, size of the last user/tool message. Estimate tokens as chars/4 (the mock uses `ceil(bytes/4)` plus 4 per message, 3 priming; a real tokenizer differs).
3. Classify the content that repeats between consecutive requests: that is your prefix-cache candidate; what changes first marks where caching stops.
4. Find the knobs that cost capacity: `max_tokens`, `n`, `parallel_tool_calls`, `stop`, `temperature`.
5. Find identity: `User-Agent`, custom headers, key alias, referer/title fields.
6. Decide the platform consequences: alias, limits, whether the gateway must pass SSE unbuffered, what the failure looks like.
Capture with the gateway's request log, the mock's `/admin/stats` (`last_requests` shows the matched rule, FIM shape fields) or a mitmproxy in front of the client in a lab (never a production laptop).

## 8. Gateway policy for clients — what teams actually configure

| Client | Alias | Key/team | Limits |
|---|---|---|---|
| Open WebUI | `chat`, `chat-small` (task model) | team `ui`, key `owui-prod` | RPM sized for users, team budget; forward user headers |
| Continue chat | `chat` | team `ide`, per-team key | RPM |
| Continue autocomplete | `coder` | team `ide`, key `ide-fim` | high RPM, low TPM, `max_tokens` cap enforced client side (the gateway cannot rewrite clients' prompts safely) |
| Aider/agents | `agent` | team `agents`, key per tool/user group | `max_parallel_requests`, TPM, daily budget |
| Embeddings (RAG, code index) | `embed` | team of the owning app | RPM + batch size awareness |

Checklist before onboarding a new tool: which endpoints does it call (`/v1/completions`? `/v1/embeddings`?), which model names does it hard-code, does it support custom headers, does it retry on 429 (and how), does it phone home, what is its worst-case concurrency, can its config be centrally managed?

## 9. Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Open WebUI shows no/slow model list | stale Ollama URL stored in DB (PersistentConfig), `ENABLE_OLLAMA_API` on, DNS blackhole timeouts | fix via admin API/UI, disable Ollama, shorten model-list timeout |
| Env change has no effect in Open WebUI | PersistentConfig, old data volume | change in UI/API or recreate volume |
| Everyone logged out after redeploy | `WEBUI_SECRET_KEY` regenerated | fix it in the secret store |
| Chats never finish with 2 replicas | no Redis websocket manager, or LB drops websockets | Redis + websocket-capable LB |
| Gateway sees 3-4 requests per user message | background title/tag/follow-up tasks | task model on a small alias; disable features |
| Autocomplete suggestions are nonsense | wrong FIM template or chat model on `/completions` | model-family template; `coder` alias on a base coder model |
| Autocomplete feels laggy | big model, no prefix cache, queueing behind agents | small model, dedicated pool, SLO |
| Aider loops on "malformed edit" | model can't do SEARCH/REPLACE | `--edit-format whole` or stronger model |
| Agent bills explode | history resent each turn, no prefix cache, no budgets | prefix caching, budgets, `max_parallel_requests`, context condensing |
| 403 for a tool after you rotated aliases | tool hard-codes a model name | keep old alias as an alias to the new group |
| Tool works directly against the engine but not via the gateway | missing `/v1` prefix, SSE buffering, `tools` unsupported by the group | check base URL, proxy buffering, parser flags |
| Agent replies in prose, never calls tools | chat template without tools, wrong parser, or `tool_choice` | check template and `--tool-call-parser`; see 6.3 |
| Every developer's index rebuilds at once | embedding alias repointed to another model | keep `embed` stable; new alias for a new model |

## 10. Provisioning per client class

### 10.1 Key naming conventions
Names are how you read logs, budgets and incident timelines; fix a convention before the first key exists: `<class>-<team>-<scope>[-<owner>]`, lowercase, no spaces, stable. Examples: `owui-ui-prod`, `ide-fim-platform`, `ide-chat-platform`, `ide-embed-platform`, `agent-cline-alice`, `agent-ci-docs`, `svc-notebooks-research`. Rules: the class prefix says which limit template applies; one key serves one class (never a chat key reused for autocomplete); human-owned keys carry the owner in the alias *and* in metadata (team, owner, expiry, ticket); service keys name the owning service and an on-call contact in metadata; every key has an expiry (`duration`) so forgotten keys die.

### 10.2 Sample provisioning script outline
A script (shell + `curl`, or Python with `requests` from `platform/.venv`) that the platform team or a self-service form runs. Names of the LiteLLM key fields follow module 04 (`/key/generate`; check your release if a field is rejected):

```text
inputs:   class (ide-fim|ide-chat|owui|agent|ci), team, owner, ticket
1. look up the template for the class (one YAML file in git):
     ide-fim : models [coder]          rpm_limit 1200 tpm_limit 400000 max_parallel_requests 8  budget none  duration 90d
     ide-chat: models [chat]           rpm_limit 60   tpm_limit 120000 max_parallel_requests 4  max_budget 5/day  duration 90d
     agent   : models [agent]          rpm_limit 120  tpm_limit 600000 max_parallel_requests 4  max_budget 20/day duration 30d
     ci      : models [agent,chat-small] ... max_budget per month, max_parallel_requests 2
2. refuse if the team does not exist or the owner already has a live key of this class (idempotency)
3. POST /key/generate  {key_alias: "<class>-<team>-<owner>", models, team_id, rpm_limit, tpm_limit,
                        max_parallel_requests, max_budget, budget_duration, duration,
                        metadata: {owner, ticket, class, created_by}}
4. deliver the key once through the secret channel (vault, password manager share); never email, never chat, never log it
5. record alias, owner, expiry in the inventory; schedule the expiry reminder
6. verify: GET /v1/models with the new key returns exactly the template's aliases; one 1-token request succeeds; a request to a non-listed alias is rejected
```

Rotation is the same script with `--rotate`: create new, deliver, wait for the old key's traffic to reach zero in the logs, delete old. Offboarding: delete keys by `metadata.owner`.

## 11. Compatibility and identification

### 11.1 Hard-coded model names and alias retention
Clients hard-code model names more than anyone admits: Continue configs in developer repos, Aider scripts and CI jobs, Open WebUI presets, agent settings pages, notebooks. When you migrate `coder` from Qwen2.5-Coder-1.5B to a new 7B model, keep the **alias stable** and change what it points to; when the alias itself must change, keep the old alias as a second name for the new group for at least one deprecation window and watch the gateway log for requests still using it (count by key alias and alias requested) before deleting it. Announce the date, publish the list of keys still calling the old name, and only then remove it. Never repoint `embed` to a different embedding model silently (4.2); introduce `embed-v2`, migrate collections, retire `embed`.

### 11.2 Behavioural drift behind a stable alias
A new model behind `coder` may use different FIM tokens, a different default `stop` behaviour or a different tool-call parser. Before switching: replay a captured FIM request and an agent request against the new group (the lab's capture technique), compare shape and finish reasons, then roll out gradually by weight (module 05 routing) and watch autocomplete acceptance rate (if clients report it) and agent retry rates.

### 11.3 Identifying clients from gateway logs
`User-Agent` strings are not a stable contract; the table states what you *generally* see — check your own logs, because versions, proxies and wrappers change them.

| Client | `User-Agent` tends to look like | Better identifier |
|---|---|---|
| Open WebUI backend | a Python HTTP client string (aiohttp/requests style), not the browser's | `X-OpenWebUI-*` headers when forwarding is enabled; the key alias |
| Aider | the OpenAI Python SDK string (`OpenAI/Python x.y`) via LiteLLM | `extra_headers` in `.aider.model.settings.yml` (5.2); the key alias |
| Continue | typically the OpenAI JS/Node SDK string or a Node fetch agent | `requestOptions.headers` (4.5) |
| Cline / Roo / similar | usually the OpenAI JS SDK string, sometimes with `HTTP-Referer`/`X-Title` | custom headers if the client supports them; key per tool |
| curl / scripts | `curl/x.y`, `python-requests/x.y`, `python-httpx/x.y` | key alias, metadata |
| LiteLLM-to-engine hop (in engine logs) | the gateway's HTTP client | engine logs lose the original client; correlate by request id |

Reliable identification order: key alias (you control it) > custom header you configured > endpoint + request shape (a `/v1/completions` call with `suffix` is FIM; a request with 20 tools is an agent) > `User-Agent`. Label metrics on the first two; use the last two for forensics. A header is only as trustworthy as the client: it identifies, it does not authenticate.

## 12. Security for client tooling

- **Keys on developer laptops** are the weakest point of the platform. Mitigations: per-class and per-person keys with small budgets and expiry; models limited to the aliases the client needs; rate limits; key stored in the OS keychain or a secret manager injected into the environment rather than in `config.yaml` or shell history; network reachability only over the VPN so a leaked key is useless off-network; rotation procedure that takes minutes (10.2). Assume a key will be pasted into a screenshot or a public repo some day.
- **Key scope**: a key that can call only `coder` can leak at worst autocomplete spend; a master key leaks the platform. The gateway master/admin key never leaves the platform team, and is never configured in any client, Open WebUI included.
- **Secret scanning**: run a scanner (gitleaks, trufflehog or the Git host's built-in push protection) on every repository and on shared `config.yaml` templates; add a custom rule for your key prefix (`sk-` plus the gateway's format) so an accidentally committed key is caught before merge, and wire a revoke runbook to a detection.
- **Prompt data exfiltration**: coding tools send source code, and agents send whatever files they read — including `.env`, SSH keys in the home directory, cloud credentials — to the model endpoint. With a self-hosted gateway the risk is that your own logs and spend tables now contain secrets; with any external fallback route (module 05) it is that secrets leave the network. Controls: `.aiderignore`/Continue ignore settings/agent allow-lists for sensitive paths; do not route `agent` or `coder` aliases to external providers without an explicit decision; egress firewall on the platform; no secrets in the working directories agents run in.
- **Logging of prompts and PII**: decide per alias whether the gateway stores request and response bodies. For `coder` (FIM) the answer is almost always *no* (volume, and the prompt is a window of proprietary code); for `chat` and `agent` store prompts only where retention, access control and a deletion process exist (Langfuse in module 08 has those controls; the spend table does not need bodies). User attribution headers (2.5) make logs personal data; set a retention period and say who may read them. Prompt-injection through files and web content that an agent reads is module 07's subject; here note only that the request log is evidence of it.
- **Open WebUI plugin code** runs with the server's privileges (2.11); **MCP servers** configured in Continue or agents widen what a model can do (module 07).

## 13. Incident walkthrough: autocomplete got slow after the agents rollout

Setting (illustrative): the platform serves `coder` for FIM (Continue autocomplete) and `agent` for Cline; to save a GPU, both aliases route to the same vLLM group ("coder-pool") on one GPU. Autocomplete p95 total latency was ~180 ms. On Tuesday 10:00 the agents team enables Cline for 40 developers.

Symptoms: developers report "autocomplete is gone / shows up after I've typed the line myself". Dashboard: autocomplete p95 rises from 180 ms to ~900 ms by 10:30; gateway error rate unchanged; no 5xx; a few 429s on `ide-fim` keys.

Investigation, in order:
1. **Is it the network or the gateway?** Gateway latency overhead (total minus upstream) is flat at ~10 ms: not the gateway.
2. **Is it queueing or compute?** Engine metrics: `vllm:num_requests_waiting` went from ~0 to 6-12; the histogram `vllm:request_queue_time_seconds` p95 went from ~5 ms to ~600 ms; `vllm:inter_token_latency_seconds` rose modestly. Queueing, not slow decode.
3. **Who arrived?** Gateway request counts by key alias: `agent-cline-*` keys appear with ~3 requests per second in total, but `vllm:request_prompt_tokens` shows agent prompts of 20-60 k tokens against ~1.5 k for FIM. The prefill of one 40 k-token prompt occupies the engine for seconds; FIM requests queue behind it (head-of-line blocking; chunked prefill softens but does not remove it).
4. **Cache effects:** `vllm:prefix_cache_hits_total / queries_total` dropped from ~80% to ~40%: agent sessions evict the FIM prefixes from KV memory, so FIM prefill itself got slower — a second-order effect.
5. **Confirm:** with the agents' keys paused (or rate limited), p95 returns to ~200 ms within a minute.

Root cause: two workload classes with opposite latency profiles share one engine and one cache. Not a bug; a missing separation, exactly module 05's rule applied to clients.

Fix: (a) immediate — lower `max_parallel_requests` and TPM on the agent keys, so FIM regains headroom; (b) real — separate the aliases into two groups on separate engines (or at minimum separate priority classes if the engine supports them) with the FIM pool sized for p99 concurrency, not average; (c) route `agent` to a model with a bigger window and its own capacity.

Prevention: an SLO on autocomplete p95 (module 08) with an alert; per-alias dashboards (requests, prompt tokens, queue time, cache hit rate); a rollout checklist item "new client class -> own alias, key and capacity before enabling for users" (section 8); capacity estimate of the new class made from the arithmetic in 6.1 *before* the rollout, e.g. 40 developers x 1 active session x 1 request per 20 s = 2 QPS of 30 k-token prompts = 60 k prefill tokens/s demand without cache — more than the FIM pool's whole budget.

Lab connection: the mock's fault API (`latency`, `kv_pressure`) and `/metrics` let you reproduce the *queue* and the *metrics reading* but not the true GPU head-of-line blocking; the walkthrough is a reasoning exercise built on the formulas.

## 14. What the lab simulates, and how production differs

| Lab | Production |
|---|---|
| mock-chat scripted answers for Aider/agent/FIM | a real coder model; quality, latency, tool-call parsing matter |
| llama.cpp 0.5B coder for optional exploration | 7-32B coder on GPUs, prefix cache, speculative decoding |
| Continue replayed by the verifier from your `config.yaml` | the IDE extension on developer laptops over VPN |
| Open WebUI single container, SQLite | Postgres + Redis, several replicas, SSO, external vector DB |
| one gateway key per client for the exercise | key/team structure per org, user-header attribution, provisioning script, expiry |
| token counts by the mock convention (`ceil(bytes/4)`) | real tokenizer counts; cached-token metrics; real prefix-cache hit rates |
| latency and QPS figures in this theory are worked assumptions | measure from your own telemetry |

---

## Key takeaways

- All clients speak OpenAI-compatible HTTP; the platform's job is a key, alias, limit set and model per *workload class*.
- Open WebUI: point at the gateway only, with its own key; PersistentConfig means env vars apply on first boot only; background task requests multiply traffic; forward user headers for attribution; embeddings via the gateway when offline. Multi-replica needs Postgres, Redis websockets, a shared secret key and shared vector store. Plugins are server-side code: govern them like packages. An unreachable connection slows the model list for everyone.
- FIM is not chat: base coder model, `/v1/completions` with prefix/suffix (or llama.cpp `/infill`), model-specific tokens, short outputs, tiny latency budget (network + decode alone use most of 150 ms), highest QPS, mostly cancelled requests. Give it its own alias, key, limits and capacity.
- Prefix caching helps FIM partially (suffix misses) and agents strongly (append-only history), and front truncation of history destroys it.
- Continue: per-role models in `config.yaml`, each with its own endpoint and key; verify what is on the wire; the first-open codebase index is an embedding spike; distribute config centrally.
- Aider: files + repo map + edit-format prompt; `openai/<alias>`; weak models need `whole`; architect/editor mode means two aliases per action; scripted use needs a budget-capped key.
- A coding-agent request = big fixed prefix + tool schemas + ever-growing history; prompt tokens grow quadratically over a session -> prefix caching, context policy (condense beats truncate), budgets, parallel limits. Tool-call failures show up as `stop` instead of `tool_calls` and runs of near-identical requests.
- Name keys by class, give every key an expiry, keep aliases stable across migrations, identify clients by key alias and your own headers before `User-Agent`, and treat keys on laptops and prompts in logs as sensitive.

## Check yourself

1. Open WebUI still lists a dead model after you changed `OPENAI_API_BASE_URLS` and restarted. Why, and what are two ways to fix it?
2. Why must the autocomplete key be different from the chat key, and what should it be limited to?
3. A request to `/v1/completions` with a chat model returns fluent but wrong middles. What are two possible reasons?
4. Compute the total prompt tokens of an agent session: P = 8 000, d = 1 000, n = 20 turns. How much does prefix caching change the engine's prefill work (order of magnitude)?
5. A user types one message in Open WebUI and the gateway logs show 4 requests. Name three causes.
6. A developer types for 30 minutes an hour with one autocomplete request per 3 s and a 40% cancel rate. Estimate requests per hour, and say what happens to GPU work if the gateway does not propagate client disconnects.
7. Why does truncating agent history from the front hurt prefix caching more than condensing, and how would you see each policy in a graph of prompt size per request?
8. Autocomplete p95 jumps from 180 ms to 900 ms the day agents are enabled, with no errors and flat gateway overhead. Which metrics do you read first, what is the likely root cause, and what are an immediate and a lasting fix?
9. An agent's responses carry `finish_reason: stop` while the requests contain `tools`, and the same prompt repeats with small additions. List three causes of this pattern and one check for each.
10. Why is a `User-Agent` header a weak client identifier, and what do you use instead?
11. Give the shape of a FIM request in two styles (`suffix` parameter and a flat prompt with model tokens), and explain why `max_tokens` is small and `stop` includes a blank line.
