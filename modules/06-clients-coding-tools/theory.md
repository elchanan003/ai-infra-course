# 06 — Clients and coding tools: Open WebUI, Aider, Continue, FIM vs chat, reading a coding-agent request

Time: ~1.25 h reading with the tutor. Prerequisites: module 04 (keys, aliases, limits); module 05 helps (separation of traffic). Pinned: Open WebUI `v0.12.4`, LiteLLM `v1.106.4`, aider-chat `0.86.2` (in `platform/.venv-aider`), Continue config schema v1 (`config.yaml`).

Honesty box. Real: Open WebUI (a real container, real API, real UI at `:18080`), Aider (real CLI), LiteLLM, llama.cpp. Simulated: the graded coding behaviour. A 0.5B CPU model cannot produce valid tool calls, SEARCH/REPLACE edits or reliable FIM, so the graded paths use mock-vllm's scripted **mock-chat** mode (pattern -> `tool_calls`, a SEARCH/REPLACE block, a FIM-shape echo). It tests the *plumbing* — routing, keys, request shape, spend — not model quality. Not runnable here: the VS Code Continue extension and Cline/Roo (we replay what they send); in production the same clients talk to a real 7-70B coder model on GPUs, and quality (not plumbing) becomes the main source of tickets.

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

## 2. Open WebUI

### 2.1 What it is
A web chat UI (FastAPI backend + Svelte frontend, port 8080 in the container; `:18080` here) with accounts, chat history, RAG (documents, knowledge bases), tools/functions, model presets. State lives in its data directory (`/app/backend/data`: SQLite DB by default, uploads, vector store for built-in RAG). Production: a Postgres `DATABASE_URL`, Redis (`REDIS_URL`, `WEBSOCKET_MANAGER=redis`) when running more than one replica, and an external vector DB (Qdrant — module 07) instead of the built-in one.

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

### 2.3 PersistentConfig — the "I changed the env var and nothing happened" trap
Many Open WebUI settings (connections, RAG engine, feature flags) are **PersistentConfig**: the environment variable is read **only on first boot**, then stored in the database; later boots use the DB value and the UI/API is the source of truth. Consequences:

- Changing `OPENAI_API_BASE_URLS` in compose and restarting does **nothing** if the data volume already exists. Change it through the admin API/UI, or recreate the volume, or set `ENABLE_PERSISTENT_CONFIG=false` (env always wins; UI changes stop persisting — appropriate for GitOps-managed deployments).
- A *wrong* value saved on first boot (a stale Ollama URL, an old gateway address) survives redeploys until someone fixes it in the DB — lab task 6.5 plants this.
- Treat the data volume as stateful config: back it up, and in lab automation start from a fresh volume.

### 2.4 Hidden traffic: tasks and the task model
Besides your messages Open WebUI sends **background requests** for chat titles, tags, follow-up suggestions, autocomplete in the input box and search/RAG query generation, using a *task model* (default: the same model you chat with). With a big model and many users that is a large, invisible share of tokens and GPU time. Teams point the task model at a small fast alias (`TASK_MODEL_EXTERNAL=chat-small`) and/or disable features (`ENABLE_TITLE_GENERATION`, `ENABLE_TAGS_GENERATION`, `ENABLE_FOLLOW_UP_GENERATION`, `ENABLE_AUTOCOMPLETE_GENERATION`; names per release — check the admin panel `Interface` page for v0.12). Measure: count gateway requests per user message; if it is 3-4 you found it.

### 2.5 Identity: one key for everyone vs per-user attribution
With one shared gateway key, all spend is "owui". Options:
1. Forward the user: `ENABLE_FORWARD_USER_INFO_HEADERS=true` makes Open WebUI add `X-OpenWebUI-User-Name/Id/Email/Role` headers to upstream requests; LiteLLM can read a configured header as the end-user id (`general_settings.user_header_name`) so spend is attributable per person without per-person keys.
2. Per-team keys (separate Open WebUI instances or model access groups) when budgets differ by department.
Choose deliberately; per-human gateway keys do not scale and tempt people to copy keys into scripts.

### 2.6 RAG through the gateway
`RAG_EMBEDDING_ENGINE=openai` with `RAG_OPENAI_API_BASE_URL` (the gateway) and `RAG_EMBEDDING_MODEL=embed` makes document embeddings go through the gateway (spend, limits, one place for the model) instead of downloading a sentence-transformers model inside the UI container — essential offline. Changing the embedding model later invalidates existing vector collections (module 07).

## 3. FIM vs chat

**Chat completion** (`/v1/chat/completions`): a list of role-tagged messages; the engine applies the model's *chat template* and generates an assistant reply. Used for conversation, explanations, edits ("rewrite this function").

**Fill-in-the-middle (FIM)**: the editor sends the text before the cursor (*prefix*) and after it (*suffix*); the model must generate the *middle*. Models trained for FIM know special tokens. For Qwen2.5-Coder: `<|fim_prefix|>…prefix…<|fim_suffix|>…suffix…<|fim_middle|>` and generation continues after the last token (StarCoder uses `<fim_prefix>/<fim_suffix>/<fim_middle>`, CodeLlama `<PRE> <SUF> <MID>` — the token names are **model-specific**; the wrong template gives garbage, not an error). There is no chat template and no system prompt.

| | Chat | FIM / autocomplete |
|---|---|---|
| Endpoint | `/v1/chat/completions` | `/v1/completions` (legacy text completion) with `prompt` (+ `suffix` where supported) — or llama.cpp's native `/infill` |
| Model | instruct/chat model (7-70B) | base coder model, often small (1.5-7B) |
| Latency target | first token < ~1-2 s, then streaming | whole suggestion in ~100-400 ms; late = useless |
| Output | long, streaming | short: `max_tokens` 32-128, `temperature` 0-0.2, `stop` at newline/blank line |
| Request rate | per human message | **per pause in typing** (debounced, ~every few hundred ms, cancelled when you type on) |
| Prompt | conversation | a window of file context around the cursor (hundreds-few thousand tokens) |

Platform consequences:
1. **Separate alias** (`coder`) and **separate key** for FIM: different model, different limits (high RPM, small `max_tokens`, small/no TPM burst allowance), never in the same pool as agents (module 05).
2. Autocomplete is the highest-QPS client you have; cancelled requests (client aborts the connection) must be aborted at the engine, otherwise stale generations waste GPU — check that the gateway and engine propagate disconnects.
3. Latency budget matters more than quality: a 1.5B model with a 150 ms response beats a 32B model at 2 s. Pre-warm, keep the model resident, and make autocomplete a first-class SLO (module 08).
4. Prefix caching helps FIM a lot (consecutive requests share almost the whole prefix) — on GPUs. (Not measurable on the CPU lab.)
5. A chat model used for FIM "works" but produces rambling text; a FIM model used in chat ignores instructions. The alias names enforce the separation (`chat` vs `coder`).

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

## 5. Aider (CLI pair programmer)

Aider edits files in a git repo through chat. What it sends each turn: a system prompt (rules + the **edit format** instructions), a **repo map** (tree-sitter summary of the code base, size set by `--map-tokens`), the contents of files added to the chat, the chat history, and your message. Prompt tokens are therefore large and mostly repeated between turns (prefix caching on the engine helps a lot).

- **Edit formats**: `diff` (SEARCH/REPLACE blocks — default for strong models), `whole` (rewrite whole file — robust but token-hungry; the usual fallback for weak models), `udiff`, `editor-diff/whole` (architect/editor split with two models). A small model that cannot produce exact SEARCH blocks yields "malformed edit" loops — pick the format per model.
- **Using a gateway**: `OPENAI_API_BASE=http://127.0.0.1:18040/v1`, `OPENAI_API_KEY=<key>`, model `openai/<alias>` (the `openai/` prefix tells Aider/LiteLLM-inside-Aider to use the OpenAI protocol with your base URL; the alias after the slash is what the gateway knows).
- Unknown model names produce warnings about context size/cost; describe the model in `.aider.model.metadata.json` (`max_input_tokens`, costs) and settings in `.aider.model.settings.yml` (edit format, `use_repo_map`).
- Auto-commits: by default each applied edit is committed (`--no-auto-commits` to disable); good for review and revert, surprising for newcomers.
- Offline hygiene: `--no-analytics`, `--no-check-update`, `--no-show-release-notes` (or the `AIDER_*` env equivalents) so it does not try to phone home.
- Not a daemon: no keep-alive traffic; spend appears only while you chat. That makes it a good "agent-lite" workload to size.

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
2. **History grows every turn and is resent in full.** If the fixed prefix is P tokens and each turn adds d tokens (model output + tool result), turn k sends P + k·d prompt tokens; a session of n turns processes Σ = nP + d·n(n+1)/2 prompt tokens. Example: P = 12 000, d = 1 500, n = 30 -> 360 000 + 1 500·465 = 1 057 500 prompt tokens for one task, versus ~57 000 *distinct* tokens (P + n·d) of actual information. Without prefix caching the engine prefills ~1 M tokens; with it, roughly the new tokens only. This is the arithmetic behind "agents cost 10-100x chat".
3. `tools`/`tool_choice`/`parallel_tool_calls`: needs a model and serving stack with tool-call parsing (vLLM `--enable-auto-tool-choice --tool-call-parser ...`); a model that emits malformed JSON arguments breaks the loop — gateway logs show repeated near-identical requests.
4. `stream: true` with tool-call deltas: the gateway must pass SSE through without buffering; a proxy that buffers kills agent UX.
5. `max_tokens` large + `temperature`; many agents set a high `max_tokens` "just in case" — it reserves KV in the engine (module 01/03).
6. Context-window management: when history approaches the window the client truncates or summarizes ("condense"). A sudden prompt-size drop in your logs is that event; a hard 400 context error is what module 05's `context_window_fallbacks` handles.
7. Identification: the `User-Agent` header (and any `HTTP-Referer`/`X-Title` the client sets) distinguishes tools; log it and label metrics with it where possible (LiteLLM's Prometheus metrics carry `user_agent`).
8. Parallelism: sub-agents or parallel tool calls fire several requests at once — the reason agent keys need `max_parallel_requests`.

## 7. Gateway policy for clients — what teams actually configure

| Client | Alias | Key/team | Limits |
|---|---|---|---|
| Open WebUI | `chat`, `chat-small` (task model) | team `ui`, key `owui-prod` | RPM sized for users, team budget; forward user headers |
| Continue chat | `chat` | team `ide`, per-team key | RPM |
| Continue autocomplete | `coder` | team `ide`, key `ide-fim` | high RPM, low TPM, `max_tokens` cap enforced client side (the gateway cannot rewrite clients' prompts safely) |
| Aider/agents | `agent` | team `agents`, key per tool/user group | `max_parallel_requests`, TPM, daily budget |
| Embeddings (RAG, code index) | `embed` | team of the owning app | RPM + batch size awareness |

Checklist before onboarding a new tool: which endpoints does it call (`/v1/completions`? `/v1/embeddings`?), which model names does it hard-code, does it support custom headers, does it retry on 429 (and how), does it phone home, what is its worst-case concurrency, can its config be centrally managed?

## 8. Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Open WebUI shows no/slow model list | stale Ollama URL stored in DB (PersistentConfig), `ENABLE_OLLAMA_API` on, DNS blackhole timeouts | fix via admin API/UI, disable Ollama, shorten model-list timeout |
| Env change has no effect in Open WebUI | PersistentConfig, old data volume | change in UI/API or recreate volume |
| Everyone logged out after redeploy | `WEBUI_SECRET_KEY` regenerated | fix it in the secret store |
| Gateway sees 3-4 requests per user message | background title/tag/follow-up tasks | task model on a small alias; disable features |
| Autocomplete suggestions are nonsense | wrong FIM template or chat model on `/completions` | model-family template; `coder` alias on a base coder model |
| Autocomplete feels laggy | big model, no prefix cache, queueing behind agents | small model, dedicated pool, SLO |
| Aider loops on "malformed edit" | model can't do SEARCH/REPLACE | `--edit-format whole` or stronger model |
| Agent bills explode | history resent each turn, no prefix cache, no budgets | prefix caching, budgets, `max_parallel_requests`, context condensing |
| 403 for a tool after you rotated aliases | tool hard-codes a model name | keep old alias as an alias to the new group |
| Tool works directly against the engine but not via the gateway | missing `/v1` prefix, SSE buffering, `tools` unsupported by the group | check base URL, proxy buffering, parser flags |

## 9. What the lab simulates, and how production differs

| Lab | Production |
|---|---|
| mock-chat scripted answers for Aider/agent/FIM | a real coder model; quality, latency, tool-call parsing matter |
| llama.cpp 0.5B coder for optional exploration | 7-32B coder on GPUs, prefix cache, speculative decoding |
| Continue replayed by the verifier from your `config.yaml` | the IDE extension on developer laptops over VPN |
| Open WebUI single container, SQLite | Postgres + Redis, several replicas, SSO, external vector DB |
| one gateway key per client for the exercise | key/team structure per org, user-header attribution |

---

## Key takeaways

- All clients speak OpenAI-compatible HTTP; the platform's job is a key, alias, limit set and model per *workload class*.
- Open WebUI: point at the gateway only, with its own key; PersistentConfig means env vars apply on first boot only; background task requests multiply traffic; forward user headers for attribution; embeddings via the gateway when offline.
- FIM is not chat: base coder model, `/v1/completions` with prefix/suffix, model-specific tokens, short outputs, tiny latency budget, highest QPS. Give it its own alias, key and limits.
- Continue: per-role models in `config.yaml`, each with its own endpoint and key; verify what is on the wire.
- Aider: files + repo map + edit-format prompt; `openai/<alias>`; weak models need `whole`.
- A coding-agent request = big fixed prefix + tool schemas + ever-growing history; prompt tokens grow quadratically over a session -> prefix caching, budgets, parallel limits.

## Check yourself

1. Open WebUI still lists a dead model after you changed `OPENAI_API_BASE_URLS` and restarted. Why, and what are two ways to fix it?
2. Why must the autocomplete key be different from the chat key, and what should it be limited to?
3. A request to `/v1/completions` with a chat model returns fluent but wrong middles. What are two possible reasons?
4. Compute the total prompt tokens of an agent session: P = 8 000, d = 1 000, n = 20 turns. How much does prefix caching change the engine's prefill work (order of magnitude)?
5. A user types one message in Open WebUI and the gateway logs show 4 requests. Name three causes.
