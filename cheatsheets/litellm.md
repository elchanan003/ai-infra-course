# LiteLLM cheatsheet (proxy v1.106.4, course lab: gateway on :18040)

Facts marked (m) were measured in the course lab on this exact version; others are documented behaviour — confirm with `curl -i` before relying on them.

## Admin API (master key in `Authorization: Bearer`)
```bash
M=sk-...; G=http://127.0.0.1:18040; H=(-H "Authorization: Bearer $M" -H 'Content-Type: application/json')
curl -s $G/health/liveliness ; curl -s $G/health/readiness       # probes (NOT /health: it calls every backend)
curl -s $G/v1/models "${H[@]}" | jq '.data[].id'                  # groups visible to that key
curl -s $G/model/info "${H[@]}" | jq '.data[]|{model_name,id:.model_info.id}'
curl -s $G/key/generate "${H[@]}" -d '{"key_alias":"svc-x","models":["chat"],"rpm_limit":60,"tpm_limit":100000,"max_parallel_requests":4,"max_budget":10,"budget_duration":"30d","duration":"90d","team_id":"<id>","metadata":{"owner":"x"}}'
curl -s "$G/key/info?key=sk-..." "${H[@]}" | jq .                 # models, limits, spend, team_id
curl -s $G/key/list "${H[@]}" | jq . ; curl -s $G/key/delete "${H[@]}" -d '{"key_aliases":["svc-x"]}'
curl -s $G/team/new "${H[@]}" -d '{"team_alias":"t","models":["chat"],"max_budget":100,"rpm_limit":600}'
curl -s $G/team/update "${H[@]}" -d '{"team_id":"<id>","models":["chat","embed"]}'
curl -s "$G/team/info?team_id=<id>" "${H[@]}" | jq .
curl -s "$G/spend/logs?start_date=2026-10-26&end_date=2026-10-27" "${H[@]}" | jq 'length'   # (m) ?request_id= returned [] once; use dates or psql
```

## Status codes (m)
| Code | Meaning | Look at |
|---|---|---|
| 401 | key missing/invalid/expired | key exists? header? expiry |
| 403 `key_model_access_denied` | model not allowed (key AND team both apply) | `/key/info`, `/team/info` |
| 422 `budget_exceeded` | budget spent (one request may overshoot) | `max_budget`, `budget_duration`, spend |
| 429 `Limit type: requests/tokens` | RPM/TPM/parallel; headers `retry-after`, `x-ratelimit-*` | fixed 60 s window (m) |
| 400 ContextWindowExceeded | prompt too long | needs `context_window_fallbacks` |
| 404 from backend | `api_base` without `/v1` / wrong model name | curl backend from gateway network |

## config.yaml skeleton
```yaml
model_list:
  - model_name: chat                      # client alias; same name on several entries = balanced group
    litellm_params: {model: openai/<backend-name>, api_base: http://svc:8000/v1, api_key: os.environ/K, weight: 4, timeout: 60}
    model_info: {id: chat-a, input_cost_per_token: 2e-6, output_cost_per_token: 4e-6}
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  proxy_batch_write_at: 5                 # LAB-ONLY (default 10)
litellm_settings:
  callbacks: ["prometheus"]
  require_auth_for_metrics_endpoint: false   # LAB-ONLY; scrape /metrics/ (bare /metrics -> 307)
  cache: true                             # (m) REQUIRED for global rpm/tpm across replicas
  cache_params: {type: redis, host: valkey, port: 6379, supported_call_types: []}   # [] = no response caching
router_settings:
  routing_strategy: simple-shuffle        # default; weights via litellm_params.weight
  num_retries: 2
  allowed_fails: 3                        # failures/min before cooldown (documented default)
  cooldown_time: 5                        # seconds (documented default)
  fallbacks: [{"chat": ["chat-small"]}]   # group -> group; 5xx/exhausted retries
  context_window_fallbacks: [{"small": ["big"]}]   # context-length 400 needs THIS
  enable_pre_call_checks: true
  redis_host: valkey                      # shares router state (cooldowns), NOT rate limits (m)
  redis_port: 6379
```

## Numbers to remember
- RPM = fixed 60 s window (m): rpm 2 + burst of 200 -> 2 x 200, 198 x 429; recovery within 70 s.
- TPM counted after the response (m): overshoot by up to one request.
- Spend lag with `proxy_batch_write_at: 5`: 2-5 s (m); poll, never sleep. Failed requests logged with spend 0.
- spend/call = prompt x in_price + completion x out_price; no `model_info` price -> 0 -> budgets never fire.
- Backend response `id` must be unique (m): it is the SpendLogs primary key.
- Replicas without Valkey: effective limit = N x configured. Weighted split n=100, p=0.4: sigma 4.9.
- Startup 25-40 s (213 migrations); ~0.6-0.8 GB RAM per replica.

## Debugging recipes
```bash
curl -i $G/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"chat","messages":[{"role":"user","content":"ping"}]}'     # headers: x-litellm-model-id, x-litellm-call-id
docker logs <litellm> 2>&1 | tail -50                                       # via platform/stack.sh logs litellm
valkey-cli -p 18063 --scan --pattern '*api_key*'                            # are shared counters being written?
psql ... -c 'select count(*) from "LiteLLM_VerificationToken"'              # keys durable?
psql ... -c 'select request_id,"user",spend,status from "LiteLLM_SpendLogs" order by "startTime" desc limit 5'
curl -s $G/metrics/ | grep -E 'litellm_(deployment_state|proxy_failed|spend|remaining_api_key)'
```
| Symptom | First check |
|---|---|
| keys 401 after restart | `database_url` set? DB volume intact? salt/master key unchanged? |
| limit "x2" | replicas without `cache` + `cache_params` |
| fallback never fires | error class: context length needs `context_window_fallbacks` |
| spend rows missing, key spend ok | duplicate backend response ids |
| dead replica still hit | `allowed_fails`/`cooldown_time`, retries hide it, `litellm_deployment_state` |
| client bypasses limits | engine reachable directly (network policy) |

## Production reminders
Pin exact image tag; keys by API/IaC not in Git; master + salt keys set once; >= 2 replicas + shared Valkey; probes `/health/readiness` + `/health/liveliness`; admin paths not exposed to clients; alerts on 429/5xx per key, fallback ratio, `litellm_redis_circuit_breaker_state`, budget %; spend-log retention; fallback to SaaS = privacy decision.
