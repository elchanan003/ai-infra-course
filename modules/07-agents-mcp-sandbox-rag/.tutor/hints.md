# 07 — Hint ladder (tutor only)

Log per task, e.g. `7.2 [x] H2`. H3/H4 -> add the concept to Weak areas.

## Task 7.1 tool-calling loop (7.1a-d)
- H1: print the raw first response (`jq`). Which field says "the model wants a tool", and what is `arguments`?
- H2: the API is stateless. What must the *next* request contain so the model knows what happened? Think: assistant message with `tool_calls`, then one `tool` message per call, linked by id.
- H3: loop `for _ in range(max_steps)`: call -> if no `tool_calls` return `content` -> append the assistant message (with its `tool_calls`) -> for each call append `{"role":"tool","tool_call_id":call["id"],"content":result}` -> repeat. After the loop return None; `main` maps None to exit 2. `arguments` -> `json.loads`, errors become the tool result.
- H4: `.tutor/solution/agent/loop.py`.
- If 7.1a fails with "extra lines": something prints to stdout besides the answer (debug prints go to stderr).
- If 7.1c fails: only one tool call answered, or the tool results attached to the wrong id (iterate over ALL `tool_calls`).

## Task 7.2 MCP server (7.2a-d)
- H1: `python -c "import mcp.server.mcpserver as m; help(m.MCPServer)"` and look at `tool`, `run`.
- H2: the server object turns type hints + docstring into `inputSchema`/description. Transport and port are arguments to `run`.
- H3: `from mcp.server.mcpserver import MCPServer; app = MCPServer("x")`, `@app.tool()` on two typed functions with docstrings, `app.run("streamable-http", host="127.0.0.1", port=args.port)`.
- H4: `.tutor/solution/mcp/server.py`.
- Common: importing `FastMCP` (v1 name, gone in 2.x); `print` on stdout; port hard-coded; `ticket_status` reading a path instead of `$TICKETS_JSON` (reuse `lookup_ticket`).

## Task 7.3 sandbox runner (7.3a-i)
- H1: run each probe in `lab/sandbox/probes/` against the starter first. Which five things does hostile code do that you want to stop?
- H2: one flag per attack (theory 4.2 table). Two are easy to forget: `--memory-swap` (equal to `--memory`) and `--security-opt no-new-privileges`. The timeout needs two layers (inside and outside).
- H3: flags: `--network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 --memory 256m --memory-swap 256m --user 65534:65534`, name `sbx-<random>`, label `course=aiinfra`, run `timeout -k 1 N python ...` inside and a watchdog that `docker kill`s the name after N+3 s; map 137/watchdog to exit 124; `trap` -> `docker rm -f`.
- H4: `.tutor/solution/sandbox/run_sandboxed.sh`.
- 7.3f fails with "stopped at ~500 MiB": swap. 7.3h fails on the SIGTERM-ignoring job only: no outer kill. 7.3i is BLOCKED until 7.3b passes: it is the control run.
- Remember `HOME=/tmp` and `PYTHONDONTWRITEBYTECODE=1` for a non-root user on a read-only root.

## Task 7.4 exec tool (7.4a-f)
- H1: what does the model control? `code` and `timeout_s`. What must never reach a shell?
- H2: write the code to a temp file, call the runner with an argv list, clamp the timeout to the runner maximum, truncate the output, return JSON.
- H3: `tempfile.TemporaryDirectory` -> write `job.py` (chmod 644: the container user is not you) -> `subprocess.run([RUNNER, path, str(t)], capture_output=True)` -> `exit_code = returncode`, `timed_out = (returncode == 124)`, slice stdout/stderr to 64 KiB.
- H4: `.tutor/solution/mcp/exec_server.py`.

## Task 7.5 RAG (7.5a-f)
- H1: embed one string and print `len(vector)`. Where does the collection's `size` come from?
- H2: ids must be a pure function of the content position (theory 5.3), embeddings go in batches (the API takes a list), writes use `wait=true`. Chunking is exactly "split on blank lines, strip, drop empty"; a line with only spaces is blank.
- H3: `uuid.uuid5(NS, f"{source}:{chunk_index}")`; `re.split(r"\n\s*\n", text)`; batches of 16; `PUT /collections/{c}` with `{"vectors":{"size":dim,"distance":"Cosine"}}` only if it does not exist; search with `POST /collections/{c}/points/query`.
- H4: `.tutor/solution/rag/`.
- 7.5b off by a few: `.json` ingested, or `split("\n\n")` missed the whitespace-only line. 7.5d fails: random ids.

## Task T the runner that "passed review" (T.1-T.3)
- H1: start a long job through the runner and `docker inspect` the live container. Do not read the script yet.
- H2: look at `Mounts` and `HostConfig.Privileged`. Which of them does a report-generating script need? Which would let it read host secrets or control Docker?
- H3: three things: the socket mount, the host `/etc` mount (`:ro` does not help), `--privileged`. Keep the job-directory mount (read-only) and the benign job must still run.
- H4: `.tutor/solution/sandbox/legacy_runner.sh`.
