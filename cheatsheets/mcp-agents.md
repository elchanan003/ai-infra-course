# Cheatsheet: tool loops, MCP, sandboxing, RAG

## Tool-calling loop (OpenAI wire format)
```
req : {"model","messages","tools":[{"type":"function","function":{"name","description","parameters":<JSON Schema>}}],"tool_choice":"auto"}
resp: choices[0].message.tool_calls[] = {id, type:"function", function:{name, arguments:"<JSON STRING>"}}  finish_reason="tool_calls"
next: messages += assistant msg (with tool_calls) + one {"role":"tool","tool_call_id":<id>,"content":"<string>"} per call
stop: finish_reason="stop" -> content is the answer
```
- `arguments` is a string: `json.loads` in try/except, return the error text to the model.
- Always: `max_steps` (10-25), per-call timeout, result size cap, loop detection (same tool+args 3x).
- Tokens per run = n*P + d*n(n-1)/2 (P base prompt, d tokens added per step). 16 steps is ~3x the cost of 8.
- No `tool_calls` but tool JSON in `content`: llama.cpp missing `--jinja`; vLLM missing `--enable-auto-tool-choice --tool-call-parser X`.
- Context overflow = 400, retry/fallback does not help (needs `context_window_fallbacks` to a longer model).
- Agents get their own key: `max_parallel_requests`, TPM cap, budget (module 05).

## MCP (spec 2026-07-28; previous 2025-11-25)
| Item | Fact |
|---|---|
| Wire | JSON-RPC 2.0 |
| Transports | stdio (log to stderr only), Streamable HTTP (single endpoint, conventionally `/mcp`); HTTP+SSE legacy |
| Server primitives | tools (`tools/list`, `tools/call`), resources, prompts |
| Client primitives | sampling, roots, elicitation |
| 2026-07-28 | stateless: self-contained requests, `server/discover`; older: `initialize` handshake + `Mcp-Session-Id` (needs sticky LB) |
| Tool result | `{"content":[{"type":"text","text":..}],"isError":bool}`; protocol errors are JSON-RPC errors |
| Auth (remote) | OAuth 2.1, protected-resource metadata (RFC 9728), resource indicators (RFC 8707); lab uses static keys |
| LiteLLM v1.106 | MCP gateway: `mcp_servers:` in config, `/mcp` endpoint, per-key/team access (check docs for exact keys) |
| Python SDK | package `mcp` 2.3.0: high-level `FastMCP`-style server; docstring = description, type hints = schema (confirm imports in the installed version) |

Debug: `tools/list` empty -> wrong path/transport/revision; works with 1 replica only -> session state; weird stdio failures -> stdout pollution.

## Threats
| Threat | Control |
|---|---|
| prompt injection via tool results/RAG docs | least-privilege tools, human confirmation for writes, remove egress |
| lethal trifecta (private data + untrusted content + egress) | remove one leg, usually egress |
| tool poisoning / rug pull / shadowing | pin by digest, review `tools/list` diffs, namespace per server, gateway allow-list |
| command injection / path traversal / SSRF in tools | argv lists (no `shell=True`), realpath jail, IP allow-list, treat the model as untrusted caller |
| confused deputy | per-user tokens, no shared super-token |

## Hardened sandbox (docker)
```bash
docker run --rm --name sbx-$RANDOM --label course=aiinfra \
  --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 64 --memory 128m --memory-swap 128m --cpus 0.5 \
  --ulimit nofile=256 --user 65534:65534 \
  -v "$PWD/job.py:/work/job.py:ro" IMAGE timeout 10 python /work/job.py
```
| Flag | Stops | You see |
|---|---|---|
| `--network none` | exfil, payload download | Network is unreachable |
| `--read-only` + tmpfs | persistence, tampering | Read-only file system |
| `--cap-drop ALL` | raw sockets, mount, chown | Operation not permitted |
| `no-new-privileges` | setuid escalation | NoNewPrivs: 1 in /proc/self/status |
| `--pids-limit` | fork bomb | Resource temporarily unavailable |
| `--memory` + equal `--memory-swap` | memory hog (swap defaults to 2x!) | exit 137, `.State.OOMKilled=true` |
| `--user 65534` | root-only actions | uid=65534 |
| `timeout` inside + `docker kill`/`rm -f` outside | loops, SIGTERM-ignoring jobs | exit 124; no leaked `sbx-*` |

Never: `-v /var/run/docker.sock` (= host root; `:ro` does not help), `--privileged`, `-v /etc` or `-v /` (even `:ro`), `--network host`, `--pid host`, secrets in `-e`.
Check live: `docker inspect -f '{{json .HostConfig.Binds}} {{json .Mounts}} {{.HostConfig.NetworkMode}} {{.HostConfig.Privileged}}' NAME`.
Isolation ladder: hardened container < gVisor (`runsc`, RuntimeClass) < microVM (Firecracker/Kata). Untrusted tenants: gVisor or microVM.
k8s: `securityContext` (runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault), default-deny NetworkPolicy, `emptyDir{medium:Memory,sizeLimit}`, Job `activeDeadlineSeconds` + `ttlSecondsAfterFinished`.

## RAG / Qdrant v1.20.0 (host port 18033)
```
PUT  /collections/C {"vectors":{"size":384,"distance":"Cosine"}}
PUT  /collections/C/points?wait=true {"points":[{"id":"<uuid5>","vector":[..],"payload":{..}}]}
POST /collections/C/points/query {"query":[..],"limit":3,"with_payload":true}
POST /collections/C/points/count {"exact":true}
PUT  /collections/C/index {"field_name":"tenant","field_schema":"keyword"}
POST /collections/aliases {"actions":[{"delete_alias":{"alias_name":"docs"}},{"create_alias":{"collection_name":"C2","alias_name":"docs"}}]}
POST /collections/C/snapshots
```
- Embeddings via gateway: `POST /v1/embeddings {"model":"embed","input":[...]}`; bge-small = 384 dims; batch 16-64; keep chunks under the model max (512 tokens); query prefix for bge/e5 queries.
- Ids = `uuid5(source, chunk_index, content hash)`: idempotent. `wait=true` before searching.
- RAM raw vectors = N x dim x 4 B (1M x 384 = 1.5 GB); real = 1.5-2x; int8 scalar quantisation = 4x smaller.
- One collection per embedding model; multi-tenancy = payload field + index, not one collection per tenant.
- Model change = new collection + full re-embed + alias switch; never repoint the gateway alias alone.
- Dense retrieval misses exact IDs: hybrid/BM25 or reranker. Metrics: recall@k, MRR; prompt cost = k x chunk tokens per question.
