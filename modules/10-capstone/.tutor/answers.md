# 10 — Tutor answers

Do not show before the learner has a hypothesis. Incident mechanics, evidence keys and checks: `.tutor/design.md`.
The per-incident expected answers table (variant-dependent values) is added in phase 2 once `prepare-lab.sh` exists.

| # | COMPONENT | CAUSE | Notes |
|---|---|---|---|
| 1 | gateway | rate-limit-misconfig | agent key without `max_parallel_requests`/rpm cap; two replicas not sharing Valkey so limits are per replica |
| 2 | serving | kv-cache-exhaustion | `--max-num-seqs` raised, prefix caching off, KV 100%, preemptions, queue |
| 3 | gpu | hardware-fault | XID (variant 79 or 48) on one node; router has no cooldown/timeout/fallback (contributing) |
| 4 | artifact | artifact-integrity | tokenizer missing + one corrupt shard; `HF_HUB_OFFLINE` unset caused tripwire hits (contributing) |
| 5 | kubernetes | scheduling-config | time-slicing resource entry yields capacity 0 + missing toleration for the new pool taint |

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
