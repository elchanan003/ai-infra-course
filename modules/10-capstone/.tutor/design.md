# 10 - Design note (author/tutor only)

Status: implemented (content complete, **not yet run**: validation `.build/validate-module.sh 10 N` pending, see "Leftovers").
Binding decisions used: decisions.md 3 (LiteLLM shared state needs `cache: true` + redis `cache_params`, `supported_call_types: []`; RPM = 60 s fixed window; 422 budget),
4 (unique response id), 7, 10 (tripwire = DNS query log), 12 (lab-session lock); metric names from mock/README 3.7 (golden vLLM 0.31).

## Layout
- `prepare-lab.sh N`, `verify.sh [N|--status]`, `cleanup.sh`, `verify-clean.sh`; `lib/common.sh` (helpers, hidden state, per-incident env), `lib/incN.sh` (page, plant, verify_N),
  `lib/checks.sh` (N.3/N.4/N.5), `lib/restart.sh` (+ GIVEN `lab/incident-N/restart.sh`), `lib/{loadgen,mq,cap,pm_check,mkmodel}.py`, `lib/gpu-plugin-sim.sh`.
- Hidden state `.state/` (git-ignored): `current`, `N/variant.env` (hidden variant), `N/truth.env` (evidence recorded at plant), `N/win` (incident window epochs), `result-N`.
- Shipped starters in `lab/`: `answers/N-{rootcause,evidence}.env` (placeholders `<...>`), `postmortem-N.md`. Generated per prepare: `lab/incident-N/` (untracked).
- Environment per incident: `inc_env` sets the documented overrides (`LITELLM_CONFIG_DIR`, `MOCK_VLLM_A/B_CONFIG_DIR`, `MOCK_DCGM_A/B_CONFIG_DIR`, `MOCK_TIME_SCALE`) and `recreate` force-recreates services.
- Output stability for `validate-module.sh` ("identical"): scored lines carry no volatile numbers; numbers go to `~` lines; WARN/PRE are ignored by the comparison.

## Common checks
N.1/N.2 incident-specific (below), both start from a restart/redeploy with the learner's files (+ re-asserted hardware faults); N.2 BLOCKED if N.1 fails. N.3 enum + STATEMENT (>= 6 words, mechanism keyword) with a discrimination
message for a wrong value (never the answer). N.4 evidence: placeholders rejected; values compared with live data (Prometheus window queries with `@ end`, DCGM, truth recorded at plant). N.5 `lib/pm_check.py`
(sections, >= 3 UTC timeline lines, root cause names component + mechanism, mitigation vs fix, >= 3 owned action items incl. detect + prevent). Starter = 0: faults present, placeholders, empty postmortems.

## Incidents (final)
1. gateway / rate-limit-misconfig. Profiles `gw gw2 mock obs`. Two replicas on `lab/incident-1/litellm`, team quota 30/36/42 rpm, keys `chat-<v>` / `agent-<v>` (tokens in `keys.env`, limits via `keys.yaml` + GIVEN `apply-keys.sh` = `POST /key/update`).
   1.1 key with `rpm_limit 3`: 2 requests on replica 1 + 3 on replica 2 -> exactly 3 x 200. 1.2 agent flood (team+2 requests) vs chat (8): chat 8/8, agent 200s in [3, team-12], >= 1 x 429, no 5xx, engine TTFT p95 <= 2.5 s (bucket edge).
2. serving / kv-cache-exhaustion. Profiles `gw mock obs`, `MOCK_TIME_SCALE=2`. Qwen2.5-7B geometry on a 24 GiB A10G with 4/5/6 GiB held by another process (given `gpu.yaml`, restored by verify), release 24 -> 80/96/128 seqs + no prefix caching + decoys.
   2.1 restarts healthy and `/v1/models` max_model_len >= 4096. 2.2 replays the peak (1.35 x the KV fit, ~1,500-token prompts, 80 % shared prefix): all 200, preemptions 0, KV peak < 95 %, TTFT p95 <= 10 s (bucket edge), gateway `mock-a` 6/6. Prefix hit ratio is only a WARN.
3. gpu / hardware-fault (router gap contributing). Profiles `gw mock obs`, scale 1. XID 79|48 + thermal on one GPU of node a|b (`fault.yaml` of mock-dcgm, re-read at each start), the node's mock-vllm `latency_ms 6000`, `error_rate 0.3` (`fault.yaml`). Router starter: retries 0, allowed_fails 1000, cooldown 1.
   3.1 40 sequential requests: sick backend serves <= 10 (mock request counter), and after the fault is cleared it takes traffic again within 80 s (ejection temporary). 3.2 0 x 5xx and slowest request < 5.5 s.
4. artifact / artifact-integrity (air-gap-leak contributing). Profile `store`. Synthetic 2-shard model (random bytes, real safetensors framing, Qwen2.5-0.5B config) in an HF cache layout `lab/incident-4/hf-cache`, published to the registry as `cap4/rollout:release-2026-10` (oras),
   planted: `tokenizer.json` removed, one shard with a flipped byte, `rollout.env` without `HF_HUB_OFFLINE` and with `HF_ENDPOINT=https://models-<v>.corp.internal`. GIVEN `rollout.sh` runs one mock-vllm container on `aiinfra-airgap` with DNS = tripwire.
   4.1 manifest (golden copy in `.state`) matches for every file, rollout healthy, in-network chat probe 200 (probe by container IP). 4.2 tripwire delta 0 over the rollout and a negative control (tokenizer removed on a copy) that fails closed with delta 0.
5. kubernetes / scheduling-config. kind (compose stopped). Node-pool variant (worker or worker2) gets label `gpu-pool=pool-<v>`, taint `pool-<v>=gpu:NoSchedule`, 2 simulated GPUs, `aiinfra.io/sim-plugin=true`; the other node is the legacy pool (1 GPU). Time-slicing ConfigMap names a wrong resource -> the simulated plugin publishes `nvidia.com/gpu = 0`.
   5.1 verify deletes the objects and the published capacity, runs GIVEN `apply.sh` (ConfigMap -> sim sync -> Deployment): pod Ready on the new pool. 5.2 a 1-GPU probe pod runs, a pod asking for capacity+1 stays Pending with `Insufficient nvidia.com/gpu`.

## Reconciliation of the CONFIRM items (vs mock/README.md and platform/stack/README.md)
| Item | Resolution |
|---|---|
| Config dir env names | `LITELLM_CONFIG_DIR`, `MOCK_VLLM_A_CONFIG_DIR`, `MOCK_VLLM_B_CONFIG_DIR`, `MOCK_DCGM_A_CONFIG_DIR`/`B`, `MOCK_TIME_SCALE`: all in compose.yaml (checked). Switching needs force-recreate (`recreate`). |
| Fault API / fault.yaml | `fault.yaml` keys = `/admin/fault` keys (`latency_ms`, `error_rate`, ...); dcgm `faults: [{gpu, xid}]` plus separate `{gpu, thermal}` entries. Used as written in README 2/3.9/4. |
| `/admin/stats` fields | `requests{model:{chat:n}}` (request counter), `engine.{kv_peak_usage,preemptions}` used as README 3.9 lists. |
| Prefix-cache modelling | exists (`--no-enable-prefix-caching`, `vllm:prefix_cache_*`); only a WARN in 2.2 because TTFT/KV already decide. |
| Second replica recipe | profile `gw2` (`litellm-2`, :18041, same config dir, `DISABLE_SCHEMA_UPDATE`), global limits need the config shown in `solution/lab/incident-1/litellm/config.yaml` (base config documents it). |
| Key limit mechanism | `POST /key/update` from `keys.yaml` via GIVEN `apply-keys.sh`; verify recreates keys (planted state) then re-applies. |
| kind helpers | `platform/k8s.sh up`, `gpu-patch FILE|--clear`; taints/labels set by prepare; capacity of the new-pool node published only by `lib/gpu-plugin-sim.sh` (own node-status patches, same technique as module 09). |
| Incident 4 startup checks | README 3.4: tokenizer check, missing/inconsistent shards, sha256 only with a `SHA256SUMS` file or 64-hex blob names -> the lab ships neither, so a flipped payload byte is only caught by the manifest (as in reality). Hub contact comes from `--model cap/rollout` (repo id) resolved with `HF_HUB_CACHE`. |
| Mirror vs registry for the restore | the synthetic model is not in the hf-mirror cache; the connected-side release is an OCI artifact in the registry (oras). |
| Tripwire counter | `GET /hits` -> `{host: n}` per README 6; `tripwire_hits` helper tolerates shapes. verify resets it before measuring. |
| SLO numbers | expressed as histogram bucket edges (TTFT p95 from bucket upper bound): 2.5 s (inc 1), 10 s (inc 2), constants in `lib/common.sh`, overridable via `CAP_*`. |
| kubeconform in 5.2 | dropped (needs schemas offline; module 09 ships only a ConfigMap schema); replaced by applying through the real API server. |

## Leftovers (need a real run; list for the validator)
1. Nothing was executed: `bash -n` only. Run `.build/validate-module.sh 10 N` for N = 1..5 and every planted fault separately.
2. Inc 1: confirm v1.106.4 enforces **team** `rpm_limit` through the shared cache and that the failed-requests metric (name/labels) counts 429s per `api_key_alias` (N.4 `CHAT_429_COUNT` is compared with the loadgen count recorded at plant, +-25 %).
3. Inc 2: calibrate `I2_SEQ_TOK`, fit/peak numbers, `SLO_TTFT_S` and the 95 % rule against real mock output (`plant_2` dies if the planted variant does not preempt).
4. Inc 3: confirm cooldown/allowed_fails semantics for timeouts and 500s on v1.106.4 (reference solution: timeout 2, retries 2, allowed_fails 1, cooldown 30 must yield <= 10 sick hits and no 5xx); the 40 s/80 s waits in verify.
5. Inc 4: confirm `snapshot_download` falls back to the cache on the sink's connection errors (otherwise the first rollout fails earlier, which is still correct), `oras push/pull --plain-http` flags on 1.3.6, that docker `--env-file` + `-e` precedence is as assumed, and that the mock accepts regular files (no blob symlinks) in a snapshot.
6. Inc 5: confirm the kubelet does not reset the patched extended resources between sync and scheduling (module 09 relies on the same), and the FailedScheduling message text for the taint.
7. `lab/incident-*` is generated (untracked); `validate-module.sh` restore removes it. Add `lab.bak-*` is already git-ignored.
