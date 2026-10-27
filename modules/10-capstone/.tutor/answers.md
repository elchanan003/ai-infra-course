# 10 - Tutor answers

Do not show before the learner has a hypothesis. Mechanics of each check: `design.md`; helper layout: `lib/`. All variant values are hidden in `.state/` (never print them).

## Expected lab answers

| # | COMPONENT | CAUSE | Planted | Evidence (variant-bound; tolerance) |
|---|---|---|---|---|
| 1 | gateway | rate-limit-misconfig | agent key without `rpm_limit`/`max_parallel_requests`; replicas without `cache`/`cache_params` so limit counters are per replica; team quota 30/36/42 rpm; chat reserve 12 | `HEAVY_KEY_ALIAS=agent-<hex>`, `TEAM_RPM_LIMIT` exact, `CHAT_429_COUNT` +-25 % (min 3) of what the chat key got in the batch window, `LIMIT_SCOPE=per-replica` |
| 2 | serving | kv-cache-exhaustion | release set `--max-num-seqs` 80/96/128 (was 24), `--no-enable-prefix-caching`, decoys seed/log level/stats; GPU 24 GiB with 4/5/6 GiB held by another process | `KV_PEAK` +-4 points, `PREEMPTIONS` +-20 %, `PEAK_WAITING` +-25 %, `PLANTED_MAX_NUM_SEQS` exact (all but the last from Prometheus over the printed window) |
| 3 | gpu | hardware-fault | XID 79 or 48 + thermal 89-94 C on one GPU of node a/b, its mock-vllm slow (6 s) and 30 % errors, re-asserted at every verify; router `num_retries 0`, `allowed_fails 1000`, `cooldown_time 1` | `AFFECTED_NODE`, `XID_CODE`, `GPU_UUID` exact, `DRAIN_DECISION=drain`, `TEMP_C` +-3 |
| 4 | artifact | artifact-integrity | `tokenizer.json` missing, one of two shards with a flipped byte, `HF_HUB_OFFLINE` unset with an endpoint `https://models-<hex>.corp.internal` | `MISSING_FILE`, `BAD_FILE`, `BAD_SHA` (12 hex of the corrupt file), `TRIPWIRE_HOST` exact, `TRIPWIRE_HITS` 1..3x+3 |
| 5 | kubernetes | scheduling-config | new-pool node tainted `pool-<hex>=gpu:NoSchedule`, pod selects the pool but has no toleration; time-slicing names a wrong resource so `nvidia.com/gpu` allocatable is 0 | `NODE_NAME`, `TAINT_KEY`, `WRONG_RESOURCE` exact, `FIRST_REASON=untolerated-taint`, `SECOND_REASON=insufficient-gpu`, `GPU_CAPACITY_AFTER` = 2 x replicas, read live |

Reference fixes: `.tutor/solution/lab/` (config, keys, args template, model/time-slicing manifests, postmortems). Reference timings: see `.build/evidence/10/`.

## Common mistakes (what verify says, and what to ask)
- Inc 1: only `keys.yaml` capped -> 1.1 fails (per-replica counters give 5 x 200 for a limit of 3): "where does a limiter keep its state?". Only the cache fixed -> 1.2 fails (agent still eats the team quota). Cap set to the whole team quota -> 1.2 "policy leaves it at most team - 12". Choosing `runaway-client`: there was no enforced agreement.
- Inc 2: `max_num_seqs` exactly at the KV fit -> KV peak 96-100 % fails the 95 % rule (margin!). Shrinking `max-model-len` -> 2.1 rejects (contract 4,096). `max_num_seqs 1` -> TTFT SLO fails through the queue. Blaming "capacity" because the GPU is 99 % busy: busy is redoing prefill (preemptions).
- Inc 3: draining the node only (no router change) -> verify re-asserts the fault, 3.1 fails; `allowed_fails` low but `cooldown_time` 600 -> "ejection must be temporary"; timeout 3 with 2 retries -> a user waits 6 s > 5.5 s.
- Inc 4: fixing files but not HF_HUB_OFFLINE -> 4.2 sees DNS lookups; setting offline but leaving the bad shard -> 4.1 manifest mismatch; replacing the shard before taking its sha -> BAD_SHA unrecoverable (re-run prepare); editing MANIFEST.sha256 -> restored by verify. Remember the lesson: a running engine is not proof of integrity.
- Inc 5: removing the nodeSelector (pod lands on the legacy node) -> 5.1 "moving it elsewhere is not a fix"; hand-patching capacity on the node -> removed by the clean redeploy in verify; tolerations with the wrong value -> still untolerated.
- All: runtime fixes (admin API, exec) are undone by the verify restart; postmortem written before evidence is collected; blameful wording trips the checker.

## Quiz
1. Gateway (L2): the engine is idle, so rejections are configured behaviour. Questions: whose limit (key, team, model deployment, global)? which scope/window (RPM is a 60 s fixed window; per replica or shared)? is the limit sized for this client class (agent vs chat), and does a concurrency cap (`max_parallel_requests`) exist?
2. Up to 60 (30 on each replica) because counters are in process memory per replica. Make it global: `litellm_settings.cache: true` with a redis/Valkey `cache_params` (`supported_call_types: []`), or route one key to one replica. Router-level redis alone is not enough.
3. 12,000 / 1,500 = 8 sequences fit, not 32. At peak more than 8 running sequences means KV fills (`vllm:kv_cache_usage_perc` ~ 1.0), the scheduler preempts and recomputes; proof: `increase(vllm:num_preemptions_total[5m]) > 0` with `num_requests_waiting` > 0.
4. Order: `num_requests_running` climbs to 64 -> `kv_cache_usage_perc` -> ~1.0 -> `num_preemptions_total` starts increasing -> prefix cache hit ratio low (no reuse, more KV and compute per request) -> `request_queue_time` and TTFT p95 up -> throughput (generation tokens/s) flat or lower. Off-peak the cache never fills, hence "only at peak".
5. Utilisation measures busy, not useful: preempted sequences are recomputed, so the GPU is busy redoing prefill. `vllm:num_preemptions_total` (and `request_num_preemptions`, repeated prefill tokens).
6. `timeout` (per-request) and `allowed_fails` + `cooldown_time` (eject the deployment after repeated failures/timeouts), optionally fallbacks to the healthy peer. Draining removes this node but the next sick replica will behave the same: mitigation vs a router that ejects by itself.
7. 79 = GPU fell off the bus: drain the node, replace/RMA, no point waiting. 63 (row remap pending) can wait for a reset window; schedule drain at low traffic after verifying the replica is still correct (no 48/94/95).
8. (a) Artifact incomplete/corrupt: tokenizer missing (and a bad shard); (b) loader allowed to use the network: `HF_HUB_OFFLINE` unset on an isolated network, so it queried a remote host until it timed out (tripwire DNS hits). `HF_HUB_OFFLINE=1` converts (b) into a fast local failure; it does not fix (a).
9. The engine does not checksum weights; a flipped byte can load fine and yield wrong outputs. Run `sha256sum -c MANIFEST` against the manifest produced on the connected side (or compare the registry/blob digest), before the rollout.
10. One node has a taint the pod does not tolerate (add the toleration, key/effect as the node shows); another node (or the same after tolerating) has 0 allocatable `nvidia.com/gpu` (device plugin/time-slicing config). Fix the toleration first, re-read the event, then fix capacity. Reasons stack.
11. The scheduler looks for nodes with a resource literally named `nvidia.com/gpus`; none has it: `Insufficient nvidia.com/gpus` (or unknown resource), pod stays Pending. `describe pod` events list it; the fix is the exact resource name `nvidia.com/gpu`.
12. `runaway-client` only if the limits were correct and the client broke the agreement (e.g. a rate agreement exists and is enforced, the client ignores 429 and retries in a storm). `rate-limit-misconfig` when the limit that should have capped the client was missing/mis-scoped/not shared; evidence: key has no cap, replicas differ, counters not shared.
13. "At 14:05 a release changed `--max-num-seqs` from 16 to 64 and disabled prefix caching. No load test of the change at peak concurrency existed, so the KV cache saturated and preemptions began at 14:40."
14. Detect: alert on `vllm:kv_cache_usage_perc > 0.9 for 5m` or `increase(vllm:num_preemptions_total[5m]) > 0`, owner on-call/SRE, testable with a promtool test. Prevent: CI check that `max_num_seqs * mean_seq_tokens <= KV budget` plus a peak-load canary before rolling a flags change, owner platform team.
