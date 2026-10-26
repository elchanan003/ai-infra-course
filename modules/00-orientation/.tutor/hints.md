# 00 — Hint ladder

## Task 0.2 (0.2.x) read a stream
- H1: run the request from `lab/request.json` with `curl -sN` and just look at the raw lines first.
- H2: concept: SSE `data:` lines; role chunk, content chunks, a chunk with `finish_reason`, an optional usage chunk, `[DONE]`. Usage is only sent in a stream when you ask for it (`stream_options`).
- H3: `jq '. + {stream_options:{include_usage:true}}' lab/request.json | curl -sN ... -d @-`; then `grep '^data: {' | sed 's/^data: //' | jq -s ...` and count the entries whose `choices[0].delta.content` is a non-empty string. `finish_reason` is the one non-null value in `choices[0]`; `usage` is on the last JSON chunk.
- H4: see `.tutor/solve-answers.sh` (section 0.2).

## Task 0.3 (0.3.x) find the ticket
- H1: where does the gateway write what it did per request? (Postgres, `LiteLLM_SpendLogs`; also `/spend/logs` and the UI.)
- H2: the ticket id is in the OpenAI `user` field; there are decoy rows from other tickets. Rows are batch-written, so a fresh request needs a few seconds.
- H3: `docker exec aiinfra-postgres-1 psql -U llm -d litellm -c 'select request_id, model_group, api_base, total_tokens, status from "LiteLLM_SpendLogs" where "user"='"'"'ticket-XXXX'"'"`. Use the `api_base` as logged.
- H4: `.tutor/solve-answers.sh` (section 0.3).

## Task 0.4 (0.4.x) layers
- H1: for each name ask: who calls it, whom does it call, and what does it do for them?
- H2: rule: the layer whose job it performs; a datastore belongs to the layer that owns its state. Postgres/Valkey are not "infra" for this purpose.
- H3: clients=1 (Open WebUI, Aider); litellm, postgres, valkey = 2; llama-* = 3; seaweedfs, registry = 4. Ports: `docker ps --format '{{.Names}} {{.Ports}}'`; take the `127.0.0.1:PORT->` part; `none` for anything not running.
- H4: `.tutor/solve-answers.sh` (section 0.4).

## Task 0.5 (0.5.x) the broken coder alias
- H1: reproduce with `curl -i` through the gateway, then read `platform/stack.sh logs litellm`.
- H2: the gateway log says which URL it tried. Compare with where the coder engine really listens inside the compose network (container port, not the published host port).
- H3: llama.cpp containers listen on 8080 inside the network; the published `18012` is the host side. Edit `api_base` of the `coder` alias, then `lab/bin/reload-gateway.sh`.
- H4: `api_base: "http://llama-coder:8080/v1"` (see `.tutor/solution/litellm/config.yaml`). Do not point `coder` at `llama-chat`: the counters would give it away.
