# 07 — Lab: tool loop, MCP server, hardened sandbox, RAG ingestion

Time: ~3 h. Guidance level: guided. Work from `modules/07-agents-mcp-sandbox-rag/`. Profiles: `gw mock llm rag store` (gateway, scripted mock-chat backend, real embedding model, Qdrant, tripwire for the air-gap control).

**What is simulated.** The "LLM" behind gateway alias `mock-a` is **mock-vllm in scripted mock-chat mode** (`mock/README.md` section 3.8): a rule table turns a task like "status of ticket T-1001" into a `tool_calls` response and, after the tool result, into a templated answer. It is deterministic and does not understand anything. Production: a real model (vLLM with `--enable-auto-tool-choice --tool-call-parser`, or llama.cpp `--jinja`) decides; a weak model adds wrong-tool and bad-argument failures that this lab cannot show. Everything else is real: the gateway (LiteLLM), the embedding model (llama.cpp bge-small via alias `embed`), Qdrant, Docker, your MCP servers, the tripwire. Timing is not graded except generous upper bounds.

## Starting state

```bash
./prepare-lab.sh            # converges profiles, writes lab/env.sh, creates the lab key, plants the troubleshooting fault
source lab/env.sh           # GATEWAY LAB_KEY AGENT_MODEL EMBED_MODEL QDRANT_URL SANDBOX_IMAGE TICKETS_JSON
curl -s $GATEWAY/v1/models -H "Authorization: Bearer $LAB_KEY" | jq '.data[].id'
```

`LAB_KEY` is a gateway virtual key limited to the aliases `mock-a` and `embed`. Use the project venv: `../../platform/.venv/bin/python` (activate it or call it by path). Peak RAM of this profile set is within the course budget (< 8 GB); do not start `lf`, `vllm` or kind in this module.

**Ports.** Your own dev servers use **18133** and **18134** (the only ports of this module's range 18130-18134 that verify leaves alone). `verify.sh` starts your servers itself on 18131/18132 and a logging proxy on 18130, so stop yours before verifying. Servers bind `127.0.0.1` only.

## Ownership

| Path | Status |
|---|---|
| `lab/agent/loop.py` | yours: task 7.1 (starter: stubs + TODO; CLI and exit-code handling given) |
| `lab/agent/tools.py`, `lab/agent/tickets.json` | given: `lookup_ticket(ticket_id)` reads the JSON file named by `$TICKETS_JSON` |
| `lab/mcp/server.py` | yours: task 7.2 (starter: skeleton that exits) |
| `lab/sandbox/run_sandboxed.sh` | yours: task 7.3 (starter: runs the job with NO isolation) |
| `lab/sandbox/probes/` | given: five practice probes (`net.py write.py fork.py mem.py id.py`) |
| `lab/mcp/exec_server.py` | yours: task 7.4 (starter: skeleton that exits) |
| `lab/rag/ingest.py`, `lab/rag/search.py` | yours: task 7.5 (starter: skeleton that exits) |
| `lab/rag/docs/` | given: tiny sample corpus (verify ingests its own generated corpus) |
| `lab/sandbox/legacy_runner.sh` | the platform team's runner: task T (edit it, do not delete it) |
| `lab/env.sh`, `platform/`, `mock/`, module scripts, `.state/`, `.verify/` | given: do not modify |

---

## Task 7.1 — A tool-calling loop

**Goal:** implement the agent loop against the gateway in the OpenAI wire format.

Contract: `python lab/agent/loop.py --task "<text>" [--max-steps N]` (default 6) prints the model's final answer on stdout (nothing else) and exits 0; it exits 2 if the step limit is exhausted without a final answer. Tools are the functions in `tools.py`, advertised as OpenAI `tools` with a JSON Schema (hand-written is fine). Use `requests` or the `openai` SDK.

Steps / hints:
1. Predict: what will the first response contain when the task mentions a ticket id? Then call `POST $GATEWAY/v1/chat/completions` with model `$AGENT_MODEL`, `messages` and `tools`, and print the raw response (`jq`): look at `finish_reason`, `tool_calls[].id`, and `arguments`.
2. mock-chat only requests `lookup_ticket` when the tool is in your `tools` array and the task mentions "ticket T-1234". After the tool result it answers with text that includes the result. Try "compare T-1001 and T-1002": the scripted model asks for **two** tools in one message.
3. What exactly must be appended to `messages` before the next call, and in which order?
4. `arguments` is a string. A malformed one must not crash the loop: return the error to the model as the tool result. (Unscored here: the scripted model never produces one; a real one does.)
5. Enforce `--max-steps`; a task containing `NEVERENDING` makes the scripted model ask for the tool forever.

Success criteria:
- `7.1a` the final answer contains a fresh nonce that only exists inside the tool result (verify writes its own `$TICKETS_JSON`), and stdout holds only the answer
- `7.1b` verify's logging proxy saw the second request end with the assistant message holding the `tool_calls` and a `role: tool` message with the matching `tool_call_id`
- `7.1c` for the two-tool task, both calls are answered and each result is attached to its own `tool_call_id`
- `7.1d` for the never-ending task with `--max-steps 3`, the run makes exactly 3 model calls, prints nothing and exits 2 (negative case)

## Task 7.2 — Your own MCP server (Streamable HTTP)

**Goal:** serve two tools over MCP: `word_count(text) -> int` and `ticket_status(ticket_id) -> str` (the record of the ticket in `$TICKETS_JSON`; reusing `lookup_ticket` is fine).

Contract: `python lab/mcp/server.py --port N` listens on `127.0.0.1:N`, Streamable HTTP at `/mcp`. Tools have descriptions and typed parameters so the generated `inputSchema` is meaningful. Log to stderr only.

Steps / hints:
1. Read the installed SDK (`mcp` 2.3.0, note that v1 code you may remember imports `FastMCP`, which no longer exists): `../../platform/.venv/bin/python -c "import mcp.server.mcpserver as m; help(m.MCPServer)"`. Find how tools are registered and how the transport and port are chosen.
2. Test with the SDK's client (`from mcp import Client`; `async with Client("http://127.0.0.1:18133/mcp") as c: await c.list_tools()`) or `curl` with a JSON-RPC body. What does `tools/list` return for your signatures?
3. What does this SDK return for an unknown tool name: a protocol error or a result with `is_error`? Which one should the model see (theory 2.1)?

Success criteria (verify starts your server itself):
- `7.2a` an MCP client lists exactly `word_count` and `ticket_status`, each with a non-empty description and an object `inputSchema` whose required parameter is `text` / `ticket_id`
- `7.2b` `tools/call word_count` on a verify-generated sentence (nonce words, random length) returns the right count
- `7.2c` `tools/call ticket_status` returns the record containing the nonce from verify's ticket file
- `7.2d` an unknown tool name is rejected (JSON-RPC error or `is_error`) and the server keeps serving afterwards (negative case)

## Task 7.3 — A hardened sandbox runner

**Goal:** `lab/sandbox/run_sandboxed.sh SCRIPT.py [TIMEOUT_SECONDS]` runs a Python script in a container so that hostile code cannot reach the network, write outside one capped tmpfs, fork-bomb, hog memory, or run as root, and always cleans up.

Contract: stdout/stderr of the script go to stdout/stderr; the exit code is the script's, or **124** on timeout (default 10 s, maximum 30 s; larger values are clamped). Image `$SANDBOX_IMAGE`, already pulled (`--pull never`). The script is mounted read-only; `/tmp` is the only writable path and holds at most 32 MiB. Memory limit at most 256 MiB. Containers are named `sbx-<random>` and labelled `course=aiinfra`; none may survive the call.

Steps / hints:
1. Run the five probes in `lab/sandbox/probes/` through the starter. Predict first: which should fail once hardened and how will you see it?
2. Add flags one at a time and re-run the probe each flag is supposed to stop (theory 4.2 table). Two are easy to omit: one about swap, one about privilege escalation. A non-root user on a writable rootfs can still write `/var/tmp`.
3. Two timeout layers: inside the container (`timeout`) and outside (a watchdog that kills the container by name). Prove the outer one with a script that ignores SIGTERM. Map both cases to exit 124.
4. `--rm` does not fire when the Docker client is killed: add a `trap` that removes the container by name.

Success criteria (verify runs its own probe scripts with nonces; the first Docker run of each is slow):
- `7.3a` a benign script prints its nonce and writes/reads a nonce file in `/tmp` (the sandbox still works; counted only together with 7.3b)
- `7.3b` no network interface besides `lo`; an outbound connect and a DNS lookup fail
- `7.3c` writing to the root filesystem (`/var/tmp`, `/etc`, `/usr`, `/`) fails
- `7.3d` `/tmp` is writable but capped: 48 MiB of writes stop with ENOSPC at <= 32 MiB
- `7.3e` a fork bomb is contained below 150 processes and the run finishes
- `7.3f` a memory hog is killed below 400 MiB (so the cap holds including swap) and the container's swap equals its memory limit
- `7.3g` the job runs as non-root with an empty effective capability set and `NoNewPrivs=1`
- `7.3h` a spin loop and a SIGTERM-ignoring script both end with exit 124 within timeout+grace; the live container is named `sbx-*` with label `course=aiinfra`; no `sbx-*` container is left
- `7.3i` control: verify's own run with the same caps but an open network (the air-gap network whose DNS is the tripwire) DOES make the tripwire see the probe: it proves 7.3b measures your `--network` choice (BLOCKED until 7.3b passes)

## Task 7.4 — Code execution as an MCP tool

**Goal:** `lab/mcp/exec_server.py --port N` exposes `run_python(code: str, timeout_s: int = 5) -> str` that executes the code through your runner and returns a JSON **string** `{"stdout","stderr","exit_code","timed_out"}`.

Steps / hints:
1. Reuse `run_sandboxed.sh`. Write the code to a temporary file and pass its path by argv. No shell string building; what happens to a model-written snippet with quotes and `$(...)` otherwise?
2. The model controls `code` and `timeout_s`: clamp the timeout to the runner's maximum and truncate each output stream to 64 KiB before it goes back into the model's context.
3. The container user is not you: check the temp file's mode. After errors and timeouts no container may remain.

Success criteria (verify starts your server; needs 7.3a):
- `7.4a` `tools/call run_python` with code printing shell metacharacters and a nonce product returns exactly that stdout and `exit_code` 0 through a real MCP client
- `7.4b` code that raises returns `exit_code` != 0 and the traceback in `stderr`; the server survives
- `7.4c` an endless loop with `timeout_s=600` returns `timed_out: true` within ~33 s (the clamp works; this check takes about half a minute)
- `7.4d` no `sbx-*` containers remain after 7.4a-c
- `7.4e` hostile network code through the tool finds no interface and no connectivity
- `7.4f` 300000 bytes of output come back truncated (<= ~64 KiB)

## Task 7.5 — RAG ingestion into Qdrant

**Goal:** `lab/rag/ingest.py --docs DIR --collection NAME` chunks every `*.md`/`*.txt` file in `DIR`, embeds the chunks through gateway alias `$EMBED_MODEL` (real bge-small via llama.cpp) and upserts them into Qdrant (`$QDRANT_URL`). `lab/rag/search.py --collection NAME "question"` prints the top 3 hits, one per line: `<score>TAB<source>#<chunk_index>TAB<first line of the text>`.

Chunking rule (fixed so counts are checkable): one chunk per non-empty paragraph (blocks separated by a blank line; a line containing only spaces is a blank line), whitespace-stripped; other file types are ignored. Payload: `source` (file name), `chunk_index` (0-based within the file), `text`.

Steps / hints:
1. Embed a short string and look at the vector length; create the collection with that size and `Cosine` (one unnamed vector).
2. Batch the embedding calls (theory 5.1). Point ids must be deterministic so re-running does not duplicate points (theory 5.3). Use `wait=true`.
3. Run ingest twice on `lab/rag/docs`; what should `points_count` be? Query with the same alias you ingested with.

Success criteria (verify ingests its own generated corpus with two unique "nonce facts"):
- `7.5a` collection exists with vector size equal to the embedding model's dimension and Cosine distance
- `7.5b` exact point count == number of non-empty paragraphs
- `7.5c` payloads (`source`, `chunk_index`, `text`) match the paragraphs exactly
- `7.5d` re-running ingest leaves the count unchanged (idempotent)
- `7.5e` `search.py` returns 3 lines in the stated format and ranks the right chunk first for both nonce facts
- `7.5f` embeddings were batched: the logging proxy saw all chunks embedded in at most half as many requests as chunks

## Task T — Troubleshooting: the runner that "passed review"

The platform team's `lab/sandbox/legacy_runner.sh` runs agent code for another team. Their tests are green (it runs scripts and returns output). A reviewer says "it can do far more than run scripts". You are not told what.

**Goal:** make the runner safe **without breaking it** (it must still run a benign job). Do not delete the file; edit it.

Hints: do not read the script first. Run a long-lived job through the runner and **inspect the live container** (`docker inspect`: Mounts, HostConfig). What is visible from inside that should not be? (The "Docker socket" involved here is a harmless decoy file; in production it would be the real thing.)

Success criteria:
- `T.1` a probe inside the runner sees no Docker API socket and no mount of a host path outside its job directory
- `T.2` the benign job still runs and prints its nonce (positive case; BLOCKED until T.1 and T.3 pass, so an empty runner cannot score)
- `T.3` the live container's inspected `Mounts` have no docker socket and no host `/etc`, and `HostConfig.Privileged` is false (checked on a running container, not by reading the file)

## Optional (unscored)

7.6 Change the embedding model: add a second collection with a different dimension, re-embed, and switch a Qdrant collection alias atomically (`POST /collections/aliases`). Explain what would break if you only repointed the gateway alias.

## Finish

```bash
./verify.sh     # ~3-5 min; one line per check, BLOCKED when a prerequisite check failed
./cleanup.sh    # removes sandbox containers, helper processes, runtime state, the lab key; stack down
```
