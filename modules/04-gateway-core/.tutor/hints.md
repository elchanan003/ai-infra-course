# 04 — Hints (H1 nudge, H2 concept, H3 partial, H4 full)

## 4.1 aliases + database
- H1: What are the two names in a `model_list` entry, and who uses each? Check the gateway log after restart.
- H2: `model_name` is the client alias; `litellm_params.model` needs the `openai/` prefix for an OpenAI-compatible backend; `api_base` must include `/v1` and use the compose service name.
- H3: `chat` -> `http://llama-chat:8080/v1`, `coder` -> `llama-coder`, `embed` -> `llama-embed`, all `api_key: none`. Keys need `general_settings.database_url: os.environ/DATABASE_URL`.
- H4: see `.tutor/solution/litellm/config.yaml`; restart with `../../platform/stack.sh compose restart litellm`.

## 4.2 limited key
- H1: Which HTTP status do you get for a valid key that may not use a model, versus an unknown key?
- H2: `/key/generate` takes `models` and `key_alias`; deleting by alias makes the script rerunnable.
- H3: `POST /key/delete {"key_aliases":["lab-chat-only"]}` then `POST /key/generate {"key_alias":"lab-chat-only","models":["chat"]}`; append `KEY_CHAT_ONLY=<key>` to `out/keys.env` (jq -r .key).
- H4: see `.tutor/solution/provision.sh`.

## 4.3 limits
- H1: Which limit is checked before the call and which after?
- H2: `rpm_limit` counts admissions in a fixed 60 s window; `tpm_limit` counts real `usage` after the response, so a request can overshoot.
- H3: `rpm_limit: 2`; `tpm_limit` below two responses' tokens (e.g. 50) - observe how many requests pass.
- H4: `gen lab-limited '{"rpm_limit":2}'`, `gen lab-tpm '{"tpm_limit":50}'` in the solution.

## 4.4 durability
- H1: Restart the gateway and call with an old key. What does the log say about the database?
- H2: Without `database_url` keys live in memory. Counters for limits are also in memory unless a shared store exists. Postgres tables: `\dt` in database `litellm`.
- H3: `docker exec -it aiinfra-postgres-1 psql -U llm -d litellm` then `select count(*) from "LiteLLM_VerificationToken" where key_alias like 'legacy-%';` and `\d "LiteLLM_SpendLogs"` (primary key).
- H4: `KEYS_TABLE=LiteLLM_VerificationToken`, `SPENDLOG_PK=request_id`, `LOST_ON_RESTART=rpm_counters`, LEGACY_KEY_ROWS = your count.

## 4.5 replicas + Valkey
- H1: With `./replicas.sh 2`, send to both ports alternately. Then list Valkey keys: `docker exec aiinfra-valkey-1 valkey-cli --scan`.
- H2: The rate limiter reads counters through the cache layer. Router Redis settings share router state only.
- H3: `litellm_settings: cache: true` and `cache_params: {type: redis, host: valkey, port: 6379, ...}`; what should `supported_call_types` be so responses are NOT cached?
- H4: `supported_call_types: []` (see solution config). Restart both replicas.

## 4.6 teams
- H1: Create the team first, keep its id.
- H2: `/team/new` takes `models`; `/key/generate` takes `team_id`. A key with no model list inherits the team's.
- H3: `POST /team/new {"team_alias":"lab-team","models":["chat"]}`; key with `{"team_id": "<id>"}`.
- H4: solution `provision.sh`.

## 4.7 key vs team mismatch
- H1: `GET /team/info?team_id=...` for team `lab-ds` and `GET /key/info` for `lab-ds-key`; whose model list lacks embed?
- H2: Both levels apply; the key has none of its own, so the team list decides. A wildcard on the team also opens `coder`.
- H3: Update the team's `models` to chat + embed (`/team/update`), find the id via `/team/list`.
- H4: last lines of solution `provision.sh`.

## 4.8 network
- H1: `docker inspect aiinfra-lab04-client --format '{{json .NetworkSettings.Networks}}'`; which networks does the gateway have?
- H2: Two containers can talk if they share a network. The client must share one with the gateway but not with the backends.
- H3: `docker network connect aiinfra-lab04-client aiinfra-litellm-1` and `docker network disconnect aiinfra aiinfra-lab04-client` (guard for idempotence). The name `llama-chat` then does not resolve.
- H4: solution `net/apply.sh`; `K8S_CONTROL=NetworkPolicy`; `BYPASS_LOSES=auth,rate_limits,spend,audit,aliases`; `DIRECT_RESULT=unresolvable`.
