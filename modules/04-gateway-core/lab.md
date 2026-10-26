# 04 — Lab: run LiteLLM with keys, teams, limits, durable state, shared Valkey

DRAFT (phase 1). Task ids are final; paths/ports of platform pieces marked (TBD-WP2) are confirmed in phase 2.

Time: ~2 h of work plus ~5 min of waiting for `verify.sh` (it restarts the gateway, bursts requests and waits out a 60 s rate-limit window). Guidance level: guided. Work from `modules/04-gateway-core/`.
Profiles: `gw llm mock` (LiteLLM, Postgres, Valkey, llama.cpp chat+embed, mock-vllm). Simulated: mock-vllm backends (fixed `usage`, unique response ids). Real: LiteLLM, Postgres, Valkey, llama.cpp.

## Starting state

`prepare-lab.sh` converges the stack and points LiteLLM at `lab/litellm/config.yaml` (env override, see `platform/stack/README.md`). The starter config has a placeholder `model_list`, no database, no Valkey. The master key and salt key are given (`lab/env.sample`, copied to `.state/` by prepare; never change them).

```bash
./prepare-lab.sh
curl -s localhost:18040/health/liveliness
```

Admin calls use the master key from `lab/env.sample` (`MASTER=...`). Gateway: `http://127.0.0.1:18040` (Tailscale `100.127.87.65:18040`).

## Ownership

| Path | Status |
|---|---|
| `lab/litellm/config.yaml` | yours — tasks 4.1, 4.4, 4.5 (starter: TODO markers) |
| `lab/provision.sh` | yours — tasks 4.2, 4.3, 4.6, 4.7 (starter: empty skeleton; must be idempotent, writes `lab/out/keys.env`) |
| `lab/answers/durability.env` | yours — task 4.4 |
| `lab/answers/network.env` | yours — task 4.8 |
| `lab/replicas.sh`, `lab/env.sample`, `lab/litellm/team-seed.json`, `platform/`, `mock/`, module scripts | given — do not modify |

Useful commands:

```bash
# admin API
curl -s localhost:18040/v1/models -H "Authorization: Bearer $KEY" | jq '.data[].id'
curl -s localhost:18040/key/info?key=$KEY -H "Authorization: Bearer $MASTER" | jq .
curl -s localhost:18040/key/list -H "Authorization: Bearer $MASTER" | jq .
# restart only the gateway (config edits need it)
../../platform/stack.sh restart litellm        # (TBD-WP2: exact verb)
# logs
../../platform/stack.sh logs litellm | tail -50
# postgres
docker exec -it $(docker ps -qf label=course=aiinfra -f name=postgres) psql -U llm -d litellm
```

`verify.sh` restarts the gateway itself and runs `lab/provision.sh` itself — do not rely on state you created by hand.

---

## Task 4.1 — Aliases: `chat`, `embed`, `coder` through the gateway

**Goal:** clients use stable aliases; the backends are the llama.cpp chat, embedding and coder servers.

1. Edit `lab/litellm/config.yaml`: `model_list` with alias `chat` (llama.cpp chat), `embed` (llama.cpp embedding) and `coder` (llama.cpp coder), `openai/` provider prefix, container-DNS `api_base` (ports/hosts are in `platform/stack/README.md`), stable `model_info.id`s.
2. Add `general_settings.master_key` / `database_url` from environment variables (names in `lab/env.sample`) — keys cannot be generated without a database.
3. Restart the gateway and read `/v1/models`. Predict first: which names will appear? Then call chat and embed with the master key.
4. Give the aliases prices in `model_info` (any small non-zero `input_cost_per_token`/`output_cost_per_token`) so spend is non-zero later.

**Success criteria**
- `4.1.1` `/v1/models` lists `chat`, `embed` and `coder`.
- `4.1.2` A chat completion on alias `chat` returns 200 with non-empty content (verify's nonce prompt).
- `4.1.3` An embedding on alias `embed` returns 200 with the vector dimension of the backend model.
- `4.1.4` `/key/generate` works (database connected).

## Task 4.2 — A key that may use only `chat`

**Goal:** least-privilege key.

1. In `lab/provision.sh` create (via `/key/generate`) a key with alias `lab-chat-only` allowed only `chat`, and write `KEY_CHAT_ONLY=<key>` into `lab/out/keys.env`. The script must be idempotent: a second run must not fail on the duplicate alias.
2. Test the key on `chat` and on `embed`. Note the two HTTP status codes and compare with a wrong/garbage key.

**Success criteria**
- `4.2.1` `lab-chat-only` gets 200 on `chat`.
- `4.2.2` The same key is denied on `embed` with 403 (not 401, not 200).
- `4.2.3` A key that does not exist gets 401 (control: proves 4.2.2 is authorization, not authentication).
- `4.2.4` `provision.sh` runs twice with exit code 0.

## Task 4.3 — Rate limits on a key

**Goal:** protect the shared GPUs from one client.

1. In `provision.sh` add a key `lab-limited` (any model) with `rpm_limit: 2` and write `KEY_LIMITED` to `keys.env`.
2. Fire a burst yourself and look at the 429 body and headers (`curl -i`). Which window semantics do you infer? Poll until it recovers and note how long it took.
3. Add a second key `lab-tpm` with a `tpm_limit` low enough that the second request is refused (backends report fixed usage; see `mock/README.md`). Why does the *second* request pass?

**Success criteria**
- `4.3.1` Burst of 5 sequential-ish requests on `lab-limited`: at most 2 return 200 and at least 1 returns 429.
- `4.3.2` The 429 identifies the request limit (`Limit type: requests`).
- `4.3.3` After the window, `lab-limited` returns 200 again within 70 s.
- `4.3.4` `lab-tpm` is refused with 429 `Limit type: tokens` after exceeding its token budget, while `lab-chat-only` (control) is unaffected.

## Task 4.4 — Durability

**Goal:** the gateway survives a restart with its keys, and you can say precisely what is stored where.

1. If keys vanish after a restart, find out why (hint: Task 4.1 step 2, and `docker logs`). Fix it in `config.yaml`.
2. Query Postgres: count key rows in `LiteLLM_VerificationToken` (prepare seeded a hidden number of extra keys; report **what you see**, not a guess).
3. Fill `lab/answers/durability.env`:
   - `KEYS_TABLE=` table that holds key records, `KEY_ROWS=` the count you read,
   - `SPENDLOG_PK=` the column that is the primary key of the per-request spend log,
   - `LOST_ON_RESTART=` comma list from `{keys,spend_logs,rpm_counters,model_list}` that are lost on a restart with no Valkey.
4. Predict, then measure: how long after a request does its row appear in `LiteLLM_SpendLogs` (`proxy_batch_write_at` is 5 in this lab)? Why is `sleep 1` in a test script wrong?

**Success criteria**
- `4.4.1` After a gateway restart (done by verify), `lab-chat-only` still returns 200.
- `4.4.2` `KEYS_TABLE` and `SPENDLOG_PK` are correct; `KEY_ROWS` equals the live count of the variant (differs per learner).
- `4.4.3` `LOST_ON_RESTART` is exactly right.
- `4.4.4` A verify-sent request (nonce user) appears in the spend log within the bounded poll.

## Task 4.5 — Two replicas and shared Valkey

**Goal:** a limit of 2 RPM means 2 RPM for the whole gateway, not per replica.

1. `./replicas.sh 2` starts a second LiteLLM replica (port 18041) on the same config, DB and Valkey. Create/verify `lab-limited` and send requests alternately to 18040 and 18041. Observe how many pass. Look in Valkey (`valkey-cli --scan`): is anything stored?
2. Make the limit global. The obvious place for Redis settings is not enough — check Valkey keys after each attempt instead of guessing.
3. Restart both replicas and re-test.

**Success criteria**
- `4.5.1` With the learner config: 2 x 200 on replica A then 429 on replica B within the same minute (global limit).
- `4.5.2` Counter keys for the limited key exist in Valkey.
- `4.5.3` Control (verify temporarily runs the starter-style config without Redis): more than 2 requests pass — proves 4.5.1 is caused by your config, not by chance.
- `4.5.4` No response caching: two identical requests are both executed by the backend (backend counters +2).

## Task 4.6 — Teams

**Goal:** policy on the team, protection on the key.

1. In `provision.sh` create team `lab-team` allowed only `chat`, then a key `lab-team-key` belonging to it (no `models` on the key). Write `KEY_TEAM`.
2. Check `/team/info` and `/key/info`. Which object answers "may this key call `embed`"?

**Success criteria**
- `4.6.1` `lab-team-key` gets 200 on `chat`, 403 on `embed`.
- `4.6.2` `/key/info` shows `team_id` of `lab-team` and spend attribution to the team after a request (bounded poll).

## Task 4.7 — Troubleshooting: the key that cannot reach `embed`

**Goal:** fix a mismatch without breaking isolation.

Story: the data-science team's key `lab-ds-key` (belongs to team `lab-ds`) gets 403 on `embed`, although its own model list contains `chat` and `embed`. `prepare-lab.sh` created the team and key (see `lab/litellm/team-seed.json` for what the platform team said they wanted). A colleague suggests setting `models: ["*"]` on the key.

1. Find which level denies `embed` (compare `/key/info` and `/team/info`).
2. Fix it on the **right** object with the narrowest change (an admin call scripted in `provision.sh`).
3. The data-science team must NOT get the `coder` alias. It must still be denied afterwards.

**Success criteria**
- `4.7.1` `lab-ds-key` gets 200 on `embed` and on `chat`.
- `4.7.2` `lab-ds-key` still gets 403 on `coder` (a wildcard fix fails here).
- `4.7.3` Another team's key (`lab-team-key`) is unchanged: 403 on `embed`.

## Task 4.8 — Backends only through the gateway

**Goal:** prove the gateway is the only path for a client, and say why that matters.

1. A client container (`platform/` helper, TBD-WP2) is attached to the client network only. From it, call a backend directly and via the gateway.
2. Production reasoning: write in `lab/answers/network.env`: `DIRECT_RESULT=` what the direct call returned (`refused|timeout|200`), `GATEWAY_RESULT=` status via the gateway, `K8S_CONTROL=` the Kubernetes object that enforces the same (`NetworkPolicy|Ingress|ServiceAccount|PodSecurity`), and `BYPASS_LOSES=` comma list from `{auth,rate_limits,spend,audit,aliases}` that a direct call skips (all that apply).

**Success criteria**
- `4.8.1` From the client network: backend direct call fails, gateway call with a valid key succeeds (verify probes live).
- `4.8.2` `network.env` values match the live probe result and are internally consistent.
- `4.8.3` `BYPASS_LOSES` is exactly right.

(Phase 2 finalizes how the client network is provided; if the stack gives no separable network the learner edits a given compose override in `lab/net/` instead.)

## Wrap-up

Run `./verify.sh`; each FAIL names the cause and the concept, never the answer. When done: `./cleanup.sh` (removes runtime state, never `lab/`).
