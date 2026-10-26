# 07 — Lab: tool loop, MCP server, hardened sandbox, RAG ingestion

DRAFT (phase 1). Task ids are final; paths, ports and helper names marked (TBC) are confirmed in phase 2 against `platform/` and `mock/README.md`.

Time: ~3 h. Guidance level: guided. Work from `modules/07-agents-mcp-sandbox-rag/`. Profiles: `gw mock llm rag` (gateway + mock-chat backend + embedding model + Qdrant). Only 7.5 needs the real embedding model; tasks 7.1-7.4 use the scripted **mock-chat** backend, so the "LLM" is simulated and deterministic (production: a real model; the loop, MCP server and sandbox are unchanged).

## Starting state

```bash
./prepare-lab.sh            # converges profiles, writes lab/env.sh, plants the troubleshooting fault
source lab/env.sh           # GATEWAY, LAB_KEY, AGENT_MODEL, EMBED_MODEL, QDRANT_URL, SANDBOX_IMAGE (TBC)
curl -s $GATEWAY/v1/models -H "Authorization: Bearer $LAB_KEY" | jq '.data[].id'
```

`LAB_KEY` is a gateway virtual key created by `prepare-lab.sh`, limited to the aliases above. Use the project venv: `../../platform/.venv/bin/python`.

## Ownership

| Path | Status |
|---|---|
| `lab/agent/loop.py` | yours: task 7.1 (starter: function stubs + TODO) |
| `lab/agent/tools.py` | given: `lookup_ticket(ticket_id)`, reads the JSON file named by `$TICKETS_JSON` |
| `lab/mcp/server.py` | yours: task 7.2 (starter: empty skeleton) |
| `lab/sandbox/run_sandboxed.sh` | yours: task 7.3 (starter: runs the job with NO isolation) |
| `lab/mcp/exec_server.py` | yours: task 7.4 (starter: skeleton) |
| `lab/rag/ingest.py`, `lab/rag/search.py` | yours: task 7.5 (starter: skeleton) |
| `lab/rag/docs/` | given: sample corpus (verify ingests its own corpus too) |
| `lab/sandbox/legacy_runner.sh` | the platform team's runner: task T (broken) |
| `lab/env.sh`, `platform/`, `mock/`, module scripts | given: do not modify |

---

## Task 7.1 — A tool-calling loop

**Goal:** implement the agent loop against the gateway using the OpenAI wire format.

Contract: `python lab/agent/loop.py --task "<text>"` prints the model's final answer on stdout (nothing else) and exits 0; it exits 2 if `--max-steps` (default 6) is exhausted without a final answer. Tools are the functions in `tools.py`, advertised as OpenAI `tools` with a JSON Schema derived from the function signature (hand-written schema is fine).

Steps / hints:
1. Call `POST $GATEWAY/v1/chat/completions` with model `$AGENT_MODEL`, `messages`, `tools`. mock-chat is scripted: a task that mentions a ticket id makes it request `lookup_ticket`; after the tool result it answers with text that includes that result (pattern details: `mock/README.md`, scripted mock-chat section).
2. What exactly must be appended to `messages` before the next call? Print the raw first response (`jq`) and look at `finish_reason`, `tool_calls[].id` and `arguments`.
3. `arguments` is a string. A malformed one must not crash the loop: return the error to the model as the tool result.
4. Answer every `tool_call` (there can be several) and enforce `--max-steps`.

Success criteria:
- `7.1a` the final answer contains a fresh nonce that only exists inside the tool result (verify writes its own `$TICKETS_JSON`)
- `7.1b` the gateway saw >= 2 requests for the run, the second containing a `role: tool` message with the matching `tool_call_id`
- `7.1c` with a task that makes the scripted model loop forever, the run stops after `--max-steps` with exit code 2 (negative case)

## Task 7.2 — Your own MCP server (Streamable HTTP)

**Goal:** serve two tools over MCP: `word_count(text) -> int` and `ticket_status(ticket_id) -> str` (reads `$TICKETS_JSON`).

Contract: `python lab/mcp/server.py --port N` listens on `127.0.0.1:N`, Streamable HTTP at `/mcp`. Tools need descriptions and typed parameters so the generated `inputSchema` is meaningful. Log to stderr only.

Steps / hints:
1. Read the installed SDK (`mcp` 2.3.0): `../../platform/.venv/bin/python -c "import mcp.server, pkgutil; print([m.name for m in pkgutil.iter_modules(mcp.server.__path__)])"` and its docstrings. Find the high-level server class and how to choose the transport and the port.
2. Test with the SDK's own client (`mcp.client.streamable_http`) or `curl` with a JSON-RPC body. What does `tools/list` return for your function signatures?
3. Remember theory 2.2: which protocol revision does your server speak, and does the client you test with speak the same?

Success criteria (verify starts your server itself on a free port):
- `7.2a` an MCP client lists exactly the tools `word_count` and `ticket_status`, each with a non-empty description and an object `inputSchema` with the right required parameter
- `7.2b` `tools/call word_count` on a verify-generated sentence (nonce words) returns the right count
- `7.2c` `tools/call ticket_status` returns the nonce status from verify's ticket file
- `7.2d` an unknown tool name is rejected (JSON-RPC error or `isError`), the server stays up (negative case)

## Task 7.3 — A hardened sandbox runner

**Goal:** `lab/sandbox/run_sandboxed.sh SCRIPT.py [TIMEOUT_SECONDS]` runs a Python script in a container such that hostile code cannot reach the network, write outside one tmpfs, fork-bomb, hog memory, or run as root, and always cleans up.

Contract: stdout/stderr of the script go to stdout/stderr; exit code is the script's, or 124 on timeout (default 10 s, maximum 30 s). Image `$SANDBOX_IMAGE`, pre-pulled (no pulling at run time). The script is mounted read-only; `/tmp` is the only writable path. Containers are named `sbx-<random>` and labelled `course=aiinfra`; none may survive the call.

Steps / hints:
1. Start from the starter (no flags) and run the five probes in `lab/sandbox/probes/` (given: `net.py`, `write.py`, `fork.py`, `mem.py`, `id.py`). Predict before running: which should fail once hardened and how will you see it?
2. Add flags one at a time and re-run the probe each flag is supposed to stop. Theory 4.2 has the table. Do not forget the two flags that are easy to omit: one about swap, one about privilege escalation.
3. Two timeout layers: inside the container and outside. Prove the outer one by running a script that traps SIGTERM.

Success criteria (verify runs its own probe scripts with nonces):
- `7.3a` a benign script prints its nonce and writes/reads a nonce file in `/tmp` successfully (the sandbox still works)
- `7.3b` outbound connection attempt fails inside the sandbox
- `7.3c` writing to the root filesystem fails
- `7.3d` fork bomb is contained (host process count of the container stays within the cap, run finishes)
- `7.3e` memory hog is killed at the cap including swap
- `7.3f` the process runs as a non-root uid with no capabilities and `no-new-privileges`
- `7.3g` an infinite loop and a SIGTERM-ignoring script both end within TIMEOUT+grace with exit 124, and no `sbx-*` container is left
- `7.3h` control: the same resource caps but an open network (verify's own variant) DOES reach the tripwire: proves 7.3b measures your `--network` choice, not a broken probe

## Task 7.4 — Code execution as an MCP tool

**Goal:** `lab/mcp/exec_server.py --port N` exposes `run_python(code: str, timeout_s: int = 5) -> str` that executes the code through your runner and returns a JSON string `{"stdout","stderr","exit_code","timed_out"}`.

Steps / hints:
1. Reuse `run_sandboxed.sh`; write the code to a temporary file and pass it by argv, no shell string building.
2. The model controls `code` and `timeout_s`: clamp the timeout to the runner's maximum, truncate output (64 KiB).
3. After errors and timeouts no container may remain.

Success criteria:
- `7.4a` `tools/call run_python` with `print(<nonce arithmetic>)` returns the right stdout and `exit_code` 0 through a real MCP client
- `7.4b` code that raises returns `exit_code` != 0 and the traceback in `stderr` (the server does not crash)
- `7.4c` `while True: pass` returns `timed_out: true` within the clamped time even when the call asks for `timeout_s=600`
- `7.4d` after 7.4a-c no `sbx-*` containers remain
- `7.4e` hostile code through the tool cannot reach the network (tripwire count unchanged)

## Task 7.5 — RAG ingestion into Qdrant

**Goal:** `lab/rag/ingest.py --docs DIR --collection NAME` chunks every `*.md`/`*.txt` file in `DIR`, embeds the chunks through the gateway alias `$EMBED_MODEL` and upserts them into Qdrant (`$QDRANT_URL`). `lab/rag/search.py --collection NAME "question"` prints the top 3 chunks (text first line + score).

Chunking rule (fixed so counts are checkable): one chunk per non-empty paragraph (blocks separated by a blank line), whitespace-stripped. Payload: `source` (file name), `chunk_index`, `text`.

Steps / hints:
1. Embed a short string and look at the vector length; create the collection with the matching size and `Cosine`.
2. Batch the embedding calls (theory 5.1). Point ids must be deterministic so that re-running does not duplicate points (theory 5.3). Use `wait=true`.
3. Run ingest twice on the same directory; what should `points_count` be?

Success criteria (verify ingests its own generated corpus with one unique "nonce fact"):
- `7.5a` collection exists with vector size equal to the embedding model's dimension and Cosine distance
- `7.5b` exact point count == number of non-empty paragraphs
- `7.5c` re-running ingest leaves the count unchanged (idempotent)
- `7.5d` `search.py` for the nonce fact returns the right chunk ranked 1st
- `7.5e` embedding requests were batched: gateway request count for the ingest < number of chunks

## Task T — Troubleshooting: the runner that "passed review"

The platform team's `lab/sandbox/legacy_runner.sh` runs agent code for another team. Their tests are green (it runs scripts and returns output). A reviewer says "it can do far more than run scripts". You are not told what.

**Goal:** make the runner safe **without breaking it** (it must still run the benign probe). Do not delete the file; edit it.

Hints: do not read the script first. Run a long-lived job through the runner and **inspect the live container** (`docker inspect`: Mounts, HostConfig, SecurityOpt). What is visible from inside that should not be?

Success criteria:
- `T.1` a probe inside the runner can no longer see a Docker API socket or any host path outside the job directory
- `T.2` the benign probe still runs and prints its nonce (positive case)
- `T.3` the container's inspected HostConfig has no bind mount of a socket or of `/etc` (checked on a live container, not by grepping the file)

## Optional (unscored)

7.6 Change the embedding model: add a second collection with a different dimension, re-embed, and switch a Qdrant collection alias atomically. Explain what would break if you only repointed the gateway alias.
