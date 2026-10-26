# 00 — Lab: run the stack, trace one request, map the layers

Time: ~55 min. Guidance level: guided. Work from `modules/00-orientation/`. Profiles: `gw llm` (real LiteLLM + Postgres + Valkey + llama.cpp). Nothing here is simulated.

## Starting state
`./prepare-lab.sh` converges the stack to `gw llm` with LiteLLM reading **your** `lab/litellm/config.yaml`, seeds a hidden per-learner variant in `.state/` (which request to use, which ticket to find, which components appear in `ARCH.env`), sends one "ticket" request through the gateway, and plants one fault. It never prints answers.

## Ownership
| Path | Status |
|---|---|
| `lab/request.json`, `lab/TICKET.txt` | given (created by prepare-lab; differ per learner) |
| `lab/bin/reload-gateway.sh`, `lab/README.md` | given |
| `lab/answers/stream.json` | yours — task 0.2 (starter: template values) |
| `lab/answers/trace.json` | yours — task 0.3 (starter: template values) |
| `lab/ARCH.env` | yours — task 0.4 (starter: component list, layer values empty) |
| `lab/litellm/config.yaml` | yours — task 0.5 (starter: `coder` alias is broken) |
| `platform/`, `mock/`, module scripts, `.state/` | given — do not modify |

## Task 0.1 — Bring the stack up (precondition, not scored)
**Goal:** a healthy `gw llm` stack and a first look at what is running.
1. `platform/doctor.sh`, then `./prepare-lab.sh` (it calls `platform/stack.sh up gw llm`).
2. `platform/stack.sh status`; `docker ps --filter label=course=aiinfra --format '{{.Names}}\t{{.Ports}}'`.
3. Find the master key and the base URL in `platform/stack/README.md`; `curl -s localhost:18040/v1/models -H "Authorization: Bearer $KEY" | jq`.

Precondition check `0.1` in `verify.sh` prints whether the gateway and the three engines answer. It is **not scored**; if it fails, later checks are BLOCKED.

## Task 0.2 — Read a stream
**Goal:** know exactly what a streamed completion looks like on the wire, and read `usage` from it.

`lab/request.json` is a ready chat request (alias `chat`, temperature 0, fixed seed, small `max_tokens`, prompt differs per learner).
1. Replay it through the gateway as a **stream** with `curl -sN` and save the raw output to a file.
2. Count the chunks that carry non-empty `delta.content`; find the chunk with `finish_reason`; find the final `usage`. (Hint: the request has to ask for usage in the stream.)
3. Fill `lab/answers/stream.json`: `content_chunks`, `prompt_tokens`, `completion_tokens`, `finish_reason`, `usage_chunk_present` (true/false).

Success criteria (verify.sh makes its own identical request through the gateway and compares):
- `0.2.1` `content_chunks` equals the live count (only chunks whose `delta.content` is a non-empty string count).
- `0.2.2` `prompt_tokens` and `completion_tokens` equal the live `usage`.
- `0.2.3` `finish_reason` and `usage_chunk_present` are correct for **this** request (the variant makes `length` vs `stop` differ between learners).

Hints in `.tutor/hints.md`. Concept: theory section 4.1.

## Task 0.3 — Find a request in the gateway's own records
**Goal:** answer "what happened to ticket X?" from LiteLLM's spend log, the way you will on call.

`prepare-lab.sh` sent one request through the gateway with a per-learner `user` value `ticket-<id>` (plus two decoy requests for other tickets); the helpdesk gives you that id in `lab/TICKET.txt`. Spend rows are written in batches, so allow a few seconds.
1. Find the row: Admin API (`/spend/logs`), the UI Logs page, or SQL against the `LiteLLM_SpendLogs` table in the stack's Postgres (credentials in `platform/stack/README.md`).
2. Fill `lab/answers/trace.json`: `request_id`, `model_group`, `api_base` (the backend address the gateway actually called), `total_tokens`, `status`.

Success criteria:
- `0.3.1` `request_id` exists in the spend logs and belongs to the ticket's user.
- `0.3.2` `model_group` and `api_base` match that row (not the alias you *assume*).
- `0.3.3` `total_tokens` and `status` match that row.

Concept: theory section 4.3.

## Task 0.4 — Map the components to the four layers
**Goal:** assign each running component to its layer and know where it listens.

`lab/ARCH.env` lists 8 components (the selection differs per learner; some are not part of this profile, so nothing is published for them: port `none`). Variable names replace `-` by `_` (`LAYER_llama_chat`). For every component set `LAYER_<name>=1|2|3|4` (1 clients, 2 gateway/control incl. its state, 3 engines, 4 hardware/platform) and `PORT_<name>=<host port or "none">` taken from `docker ps`.

Success criteria:
- `0.4.1` every `LAYER_*` is correct (verify reports the first wrong component by name and the rule that decides it — not the answer).
- `0.4.2` every `PORT_*` equals the live published host port (or `none` when nothing is published).

Concept: theory section 2 (assignment rule).

## Task 0.5 — Troubleshooting (planted): the `coder` alias returns 500
**Goal:** find which layer is lying and fix it without breaking `chat`.

Symptom: requests with `"model": "coder"` through the gateway fail while `chat` works.
1. Reproduce with `curl -i`; read the gateway log; call the coder engine directly from inside the network to prove it is healthy.
2. Fix `lab/litellm/config.yaml` and reload the gateway (`lab/bin/reload-gateway.sh` restarts LiteLLM and waits until it is healthy).

Success criteria:
- `0.5.1` a completion through alias `coder` returns 200.
- `0.5.2` the **coder** engine's request counter moved and the **chat** engine's did not (negative control: pointing `coder` at the chat engine is not a fix).
- `0.5.3` alias `chat` still returns 200 and moves only the chat engine's counter.

Concept: theory sections 4 and 6 (debugging ladder).

## Wrap-up
`./verify.sh` prints one line per check and `SCORE: x/y`. `./cleanup.sh` removes runtime state only (it never touches `lab/`); `./verify-clean.sh` proves it.
