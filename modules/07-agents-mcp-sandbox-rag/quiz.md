# 07 — Quiz

1. An agent run makes 8 sequential chat calls. The base prompt (system + tool schemas + task) is 5,000 tokens and every step appends 1,200 tokens (assistant tool call + tool result). Compute the total prompt tokens billed for the run. Then compute it for 16 steps and state what the ratio tells you about step limits.
2. List the exact message sequence (roles and the fields that link them) the client must send for the second request of a loop in which the model asked for two tools in one response. What does a strict server do if one `tool_call_id` is missing?
3. A model "calls" a tool by printing `{"name": "lookup_ticket", ...}` into `content`; `tool_calls` is `null` and `finish_reason` is `stop`. Give two serving-side causes, and say how the same symptom would differ if the cause were a weak model.
4. What is the difference between a JSON-RPC error and `isError: true` in an MCP `tools/call` result? Which one should be shown to the model, and why?
5. Name the MCP transports. Why must an stdio MCP server never `print()` debug text to stdout? Why does a stateful Streamable-HTTP server break behind a round-robin load balancer, and what property of the 2026-07-28 revision removes that problem?
6. Here is an MCP tool. Find two security problems and say how you would fix each.
   ```python
   @app.tool()
   def grep_logs(pattern: str, path: str = "/var/log") -> str:
       """grep"""
       return subprocess.run(f"grep -r {pattern} {path}", shell=True, capture_output=True, text=True).stdout
   ```
7. Explain "tool poisoning" and "rug pull" for MCP servers. Which control addresses both, and where in the platform would you enforce it?
8. The "lethal trifecta" for an agent is private data + untrusted content + a way to exfiltrate. Your coding agent reads GitHub issues (untrusted), has repo credentials (private) and a `fetch_url` tool. Which leg do you remove first in an air-gapped company and how?
9. Annotate this sandbox command: for each flag say which attack it blocks and what you would observe when the attack is attempted. Then name two things that are still missing for a production-grade runner.
   ```bash
   docker run --rm --network none --read-only --tmpfs /tmp:size=16m --cap-drop ALL \
     --pids-limit 64 --memory 128m --user 65534 python:3.12-slim python /job.py
   ```
10. A teammate's runner uses `--memory 256m` and a fork bomb test passes, but a memory hog loop on a host with swap enabled uses about 512 MB before dying. Why, and what is the fix? What exit code and `docker inspect` field confirm an OOM kill?
11. The agent host crashes while a sandbox job is running with `docker run --rm`. What is left behind and how does a well-designed runner prevent a slow leak of such containers? Give the two timeout layers.
12. What does mounting `/var/run/docker.sock` into a sandbox give the code inside it? Why is `:ro` on that mount not a mitigation? Write the one-line command that proves it from inside the container, without running it.
13. Your ingestion job runs `uuid.uuid4()` as the point id and the job fails on chunk 900 of 1,000 and is retried. What is `points_count` after the retry, and how do you make the job idempotent? What one request proves the result is right?
14. Compute the RAM for the raw vectors of 2.5 million chunks with a 768-dimension float32 embedding model, and the effect of scalar int8 quantisation. Why is the real requirement higher?
15. The gateway team repoints alias `embed` from a 384-dim model to a 768-dim one. List the symptoms on the ingest side and on the query side, and give the safe migration procedure including the Qdrant feature that makes cutover atomic.
