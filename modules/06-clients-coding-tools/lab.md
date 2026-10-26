# 06 — Lab: wire Open WebUI and coding tools to the gateway; FIM vs chat; read an agent request

DRAFT (phase 1). Task ids are final; details marked (TBD-WP2/3) are confirmed in phase 2.

Time: ~2 h of work plus ~3 min of waiting for `verify.sh` (it restarts Open WebUI once, drives Aider and replays Continue). Guidance level: guided. Work from `modules/06-clients-coding-tools/`. Prerequisite: module 04 (keys/aliases/limits via API) — the gateway config from the platform default is used (aliases `chat`, `coder`, `embed`, `agent`), you do not edit it here.
Profiles: `gw ui mock llm`. **Simulated:** the graded coding behaviour: mock-vllm "mock-chat" scripted mode answers Aider (SEARCH/REPLACE), tool calls and echoes the FIM request shape (`mock/README.md`). **Real:** Open WebUI v0.12.4, Aider 0.86.2 CLI (`platform/.venv-aider`), LiteLLM, llama.cpp chat/coder/embed (optional exploration; a 0.5B model is not reliable for edits or FIM quality). Not run: the VS Code Continue extension (the verifier replays what it would send).

## Starting state

`prepare-lab.sh` converges the stack with a **fresh Open WebUI volume**, seeds the per-learner variant (a captured agent request, see 6.4), and plants the 6.5 fault in Open WebUI's stored configuration (a stale connection in its DB). Open WebUI: `http://127.0.0.1:18080` (Tailscale `100.127.87.65:18080`); admin credentials in `lab/env.sample`.

```bash
./prepare-lab.sh
curl -s localhost:18080/health
```

## Ownership

| Path | Status |
|---|---|
| `lab/provision.sh` | yours — creates the gateway keys for this module, writes `lab/out/keys.env` (idempotent): `KEY_OWUI`, `KEY_AIDER`, `KEY_CONTINUE_CHAT`, `KEY_CONTINUE_FIM` |
| `lab/openwebui/connect.sh` | yours — tasks 6.1, 6.5 (admin API calls, idempotent) |
| `lab/aider/aider.env`, `lab/aider/run.sh` | yours — task 6.2 |
| `lab/continue/config.yaml` | yours — task 6.3 |
| `lab/answers/dissect.env` | yours — task 6.4 |
| `lab/captured/agent-request.json` (generated per learner), `lab/aider/repo/` (scratch git repo, generated), `lab/continue/replay.sh`, `lab/env.sample`, module scripts, `platform/`, `mock/` | given — do not modify |

---

## Task 6.1 — Open WebUI talks only to the gateway, with its own key

**Goal:** Open WebUI's one and only upstream is LiteLLM, authenticated with a dedicated limited key.

1. In `provision.sh` create key `lab-owui` (models `chat` and `embed` only, a sane `rpm_limit`) and write `KEY_OWUI`.
2. Write `openwebui/connect.sh`: sign in as admin via the API, then set the OpenAI connection (gateway URL **as seen from the Open WebUI container**, not `localhost`) with that key, and make sure the Ollama connection is off. Use the API, not the browser (you may look at the admin UI to see the result).
3. Think: why did changing the compose env var not change anything on this volume? (PersistentConfig.)

**Success criteria**
- `6.1.1` Verify signs in to Open WebUI, `GET /api/models` lists `chat` (and not models the key may not use).
- `6.1.2` A verify-sent chat with a nonce through Open WebUI (`/api/chat/completions`) returns 200 and the nonce arrives at the gateway under key alias `lab-owui` (spend log / key info, bounded poll).
- `6.1.3` No path around the gateway: Open WebUI's configured OpenAI URLs are exactly the gateway, and backend counters equal gateway counters (nothing reached an engine directly).
- `6.1.4` `connect.sh` is idempotent (second run exit 0, same end state).

## Task 6.2 — Aider through the gateway

**Goal:** a real Aider process edits a file using the gateway; the spend is attributed to Aider's own key.

1. Create key `lab-aider` in `provision.sh` (alias `agent`, `max_parallel_requests` small) — write `KEY_AIDER`.
2. Fill `aider/aider.env` (`OPENAI_API_BASE`, `OPENAI_API_KEY`, model name with the right prefix, offline-hygiene flags) and `aider/run.sh` which runs Aider headless (`--message`, `--yes-always`, no auto-update/analytics) against the scratch repo `lab/aider/repo/` with the file named in the task text there. Aider is from `platform/.venv-aider`.
3. mock-chat answers a specific instruction with a SEARCH/REPLACE block. Read the model's answer in Aider's output: identify the edit format it used.

**Success criteria**
- `6.2.1` After `run.sh` (executed by verify with a nonce instruction), the target file in the scratch repo contains the expected change.
- `6.2.2` The gateway recorded the request(s) under key alias `lab-aider` with model `agent` (spend log, bounded poll).
- `6.2.3` Aider did not try the network outside the gateway (tripwire/DNS and `--no-analytics` hygiene: verify checks no extra hosts were contacted in the module's run).
- `6.2.4` Control: the same run with a bogus key fails cleanly (non-zero exit, file unchanged).

## Task 6.3 — Continue config: chat + autocomplete, FIM via the coder alias

**Goal:** a Continue `config.yaml` with two roles, each with its own key and alias.

1. In `provision.sh` add `lab-continue-chat` (models `chat`) and `lab-continue-fim` (models `coder`, high RPM, low TPM) — write `KEY_CONTINUE_CHAT`, `KEY_CONTINUE_FIM`.
2. Write `continue/config.yaml`: a chat model (roles chat, edit, apply) and an autocomplete model, each with `apiBase` to the gateway, its own key, correct alias, and a small `maxTokens` for autocomplete. Use the real key values from `keys.env` (it is a lab file; production would use secrets).
3. Replay it yourself with `continue/replay.sh` (given: reads your YAML like the extension would and sends one chat request and one FIM request). Look at the mock's echo of the FIM request: which fields did the autocomplete request contain (`prompt`, `suffix`, FIM tokens)?
4. Why must the autocomplete key not work on `chat`?

**Success criteria**
- `6.3.1` Verify parses your YAML and finds one model with role `chat` and one with role `autocomplete`, both pointing at the gateway.
- `6.3.2` The replayed chat request returns 200 under `lab-continue-chat` and is routed to the chat backend.
- `6.3.3` The replayed FIM request returns 200 under `lab-continue-fim`, is routed to the `coder` backend, and the backend saw a FIM-shaped request (prefix and suffix present).
- `6.3.4` Control: the FIM key on `chat` returns 403, the chat key on `coder` returns 403.

## Task 6.4 — Dissect a captured coding-agent request

**Goal:** read what a coding agent sends, in numbers.

`lab/captured/agent-request.json` is one request an agent sent through the gateway (it was really sent during `prepare-lab.sh`; the gateway logged its real token counts, the file is the request body).

1. Measure the system prompt (characters), the number of tools, the number of messages, how many are tool results, and the largest tool-result size.
2. Find the request in the gateway's spend log (hint: `request_id`/time/key alias in `captured/README.txt`) and read the **logged prompt tokens**. Write them down.
3. Compute with the formula from the theory: this agent's fixed prefix P (system + tools, in tokens, estimate with the observed chars/token ratio from your measurement) and per-turn growth d; then the total prompt tokens of a 25-turn session and how much of it a prefix cache would save.
4. Fill `answers/dissect.env`: `SYSTEM_CHARS`, `TOOLS_COUNT`, `MESSAGES`, `TOOL_RESULTS`, `LOGGED_PROMPT_TOKENS`, `SESSION_25_PROMPT_TOKENS` (integer, ±5 %).

**Success criteria**
- `6.4.1` `SYSTEM_CHARS`, `TOOLS_COUNT`, `MESSAGES`, `TOOL_RESULTS` match the captured file (exact; per-learner variant).
- `6.4.2` `LOGGED_PROMPT_TOKENS` is within 5 % of the gateway's logged value for that request.
- `6.4.3` `SESSION_25_PROMPT_TOKENS` is within 5 % of verify's own computation from the file and the logged tokens.
- `6.4.4` Template placeholder values are rejected (answers must differ from the shipped `0`/`TODO`).

## Task 6.5 — Troubleshooting: the empty, slow model list

**Goal:** make Open WebUI list models fast again, durably.

Story: after a migration users report that Open WebUI's model dropdown takes ~20 s and then shows nothing (or only partially). The container's compose env looks right. Starting state: Open WebUI's stored configuration still contains an old Ollama URL (a non-routable address) with the Ollama API enabled, and the gateway connection is missing.

1. Time `GET /api/models` as admin. Check the container logs for connection timeouts. What is the process doing during those 20 s?
2. Look at the stored config via the admin API (`/ollama/config`, `/openai/config`). Fix it **in the application's stored configuration** (not only the environment), so it survives a restart.
3. Restart Open WebUI (verify does it too) and re-time.

**Success criteria**
- `6.5.1` `GET /api/models` as admin returns `chat` in under 5 s.
- `6.5.2` After a restart of Open WebUI (done by verify) the model list is still fast and still correct (the fix is persisted).
- `6.5.3` The Ollama API is disabled in the stored config, and no request to the stale address is attempted (DNS/tripwire counter or stored config check).
- `6.5.4` The fix did not weaken 6.1: still exactly the gateway as upstream, with the `lab-owui` key.

Optional (unscored, tutor-led): point real VS Code Continue at `http://100.127.87.65:18040/v1` over Tailscale with your keys and watch the requests in the LiteLLM logs.

## Wrap-up

`./verify.sh` (FAIL lines name the cause and the concept); `./cleanup.sh` removes keys, Open WebUI volume and runtime state, never `lab/`.
