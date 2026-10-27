# 10 - Hint ladder (tutor only)

Rules: H1 nudge -> H2 concept -> H3 partial -> H4 full, only if asked or stuck after H3. Log per task (e.g. `inc3 fix [x] H2`); H3/H4 -> concept into Weak areas.
Task ids: `incN-find` (cause), `incN-fix` (N.1/N.2), `incN-evid` (N.4), `pm` (N.5, shared).

## Incident 1 - gateway
### inc1-find
- H1: Is the engine busy while chat gets 429? Which layer says "no" and why would it say no to one client only?
- H2: 429 from the gateway is configured behaviour. Ask whose limit (key, team, model), which scope (per replica or shared), and who is the biggest sender in the same team.
- H3: The chat and agent keys belong to one team with one rpm quota; the agent key has no rpm or concurrency cap. Send a few requests alternately to :18040 and :18041 with a small test key limit - how many 200s do you get?
- H4: Agent key: no `rpm_limit`/`max_parallel_requests`, so the batch eats the team quota; the replicas' `config.yaml` has no `cache`/`cache_params`, so limit counters are in process memory per replica. Cause rate-limit-misconfig, component gateway.
### inc1-fix
- H1: Two independent gaps; one fix alone leaves one of the two checks red.
- H2: Per-key caps (rpm, max_parallel_requests) in `keys.yaml`; shared counters need the Valkey cache in `litellm_settings` - "router redis" alone is not enough.
- H3: Look at the base stack's config (`platform/stack/config/litellm/config.yaml`) for how the global limit is wired; the agent cap must be at most team quota minus the chat reserve printed on the page.
- H4: `litellm_settings: {cache: true, cache_params: {type: redis, host: valkey, port: 6379, supported_call_types: []}}`, `router_settings: {redis_host: valkey, redis_port: 6379}`; in keys.yaml `agent-<id>: {rpm_limit: <team-14>, max_parallel_requests: 2}`; `restart.sh`, then `apply-keys.sh`.
### inc1-evid
- H1: Alias and quota are in the gateway's own API; the 429 count is a metric of the chat key.
- H2: `/key/list`, `/team/info`; the failed-requests series of the LiteLLM prometheus callback, filtered by key alias, over the incident window.
- H3: `increase(<failed requests series>{api_key_alias="chat-..."}[window])` evaluated at the window end; scope is what you proved with the replica test.
- H4: Heavy key = the `agent-` alias; scope `per-replica`; quota from `/team/info` (rpm_limit).

## Incident 2 - serving
### inc2-find
- H1: Off-peak fine, peak bad, after a release: what did the release change that only matters when many requests overlap?
- H2: Concurrency limit vs KV budget: slots x sequence length against the number of KV tokens. Which gauge hits its ceiling, and which counter proves recomputation?
- H3: Compare `max_num_seqs` to the KV token capacity printed at engine start (`cache_config_info`, `/admin/stats` capacity); the other release changes (seed, log level, stats logging) cannot change capacity.
- H4: KV budget holds roughly N sequences of ~1,600 tokens; the release allows 80-128, so at peak KV hits 100 %, the scheduler preempts and recomputes, the queue grows, TTFT explodes while GPU stays busy. serving / kv-cache-exhaustion.
### inc2-fix
- H1: Compute first, then edit. What is your target and your margin (the rule says 95 %)?
- H2: `max_num_seqs` <= about 85 % of (KV tokens / tokens per sequence); prefix caching helps a workload with a shared prefix; do not shrink `max-model-len` (the contract is 4,096).
- H3: Get the KV token number from the engine log or `cap`-style maths (module 01), divide by ~1,603; restart with `restart.sh` and replay the peak with a handful of parallel requests of 6,000 characters.
- H4: e.g. `--max-num-seqs <0.85 x fit>`, remove `--no-enable-prefix-caching`; keep util and window.
### inc2-evid
- H1: These are windowed Prometheus queries, not live reads.
- H2: `max_over_time(vllm:kv_cache_usage_perc{instance="mock-vllm-a"}[W] @ end)`, `increase(vllm:num_preemptions_total...)`, `max_over_time(vllm:num_requests_waiting...)` for the printed window.
- H3: KV is a fraction: report percent. The planted value of max-num-seqs is in RELEASE-NOTES.md.
- H4: Use the exact window printed by prepare (start/end epoch) in the `@ end` form.

## Incident 3 - gpu + router
### inc3-find
- H1: Which backend is slow, and what does its hardware say that the other's does not?
- H2: DCGM per GPU: `XID_ERRORS`, `GPU_TEMP`, clocks; `nvidia-smi` inside the exporter container. A hardware fault explains slowness; the missing guard explains why users felt it.
- H3: Two separate fixes: node (drain/replace, by XID class) and router (`timeout`, `num_retries`, `allowed_fails`, `cooldown_time`). The existing "tuned for the load test" values are the guard that is switched off.
- H4: gpu / hardware-fault; the router gap is a contributing factor for the postmortem.
### inc3-fix
- H1: What happens to a request that lands on the sick node today: how long does it wait and how often is the node tried again?
- H2: Bound the wait below the sick stall, retry on the peer, eject after few failures, and let it back after a cooldown (ejection must be temporary).
- H3: Mind the arithmetic: timeout x attempts must stay below what a user may wait; allowed_fails 1000 means never eject.
- H4: `router_settings: {timeout: 2, num_retries: 3, allowed_fails: 0, cooldown_time: 30}`; `restart.sh`.
### inc3-evid
- H1: Node, XID, UUID, temperature are in the DCGM exporters.
- H2: Find the GPU whose `DCGM_FI_DEV_XID_ERRORS` is non-zero; labels carry `UUID`.
- H3: XID 79 and 48 are both drain; the temperature is the throttle value.
- H4: Read the series on both nodes (:18031 / :18032) and copy the labels exactly.

## Incident 4 - artifact
### inc4-find
- H1: Never trust "it starts"; what is the authoritative statement of what the files should be?
- H2: `sha256sum -c MANIFEST.sha256` inside the snapshot directory; and read what the loader tried on the network (tripwire `/hits`).
- H3: One file is missing, one differs; independent of that, the rollout environment lets the loader reach for its hub endpoint.
- H4: tokenizer.json missing, one shard flipped byte; `HF_HUB_OFFLINE` unset. artifact / artifact-integrity; the lookups are the contributing air-gap factor.
### inc4-fix
- H1: Fix both: the files and the posture. Then prove the posture with an incomplete artifact.
- H2: The connected side's copy is served by the course HF mirror (`http://127.0.0.1:18071`, HF `resolve` API). Offline mode is a policy; the tripwire proves it.
- H3: Download the two files from the mirror, put them into the snapshot, re-run the manifest check; add `HF_HUB_OFFLINE=1` to `rollout.env`; re-run `rollout.sh`, then test with a tokenizer removed on a copy.
- H4: `curl -fsS http://127.0.0.1:18071/aiinfra/capstone-tiny/resolve/main/<file> -o <snapshot>/<file>` (remove the old file/symlink first); `echo HF_HUB_OFFLINE=1 >> rollout.env`.
### inc4-evid
- H1: Capture the corrupt file's checksum before replacing it.
- H2: `sha256sum` of the failing shard (first 12 hex); `GET /hits` lists the name and the count.
- H3: Names exactly as in the directory listing and the hits JSON.
- H4: If you overwrote the file before taking its checksum, re-run `./prepare-lab.sh 4`.

## Incident 5 - kubernetes
### inc5-find
- H1: Read the scheduler's sentence word by word; each clause is about one node.
- H2: Taint vs toleration vs nodeSelector; then extended-resource capacity on the node.
- H3: After the toleration the reason changes; then compare `describe node` Capacity with what the ConfigMap advertises.
- H4: Toleration for `pool-<id>=gpu:NoSchedule` missing on the model Deployment AND on the device-plugin DaemonSet (no plugin pod on the node, so no GPU capacity); time-slicing entry names `nvidia.com/gpus`, which the plugin ignores. kubernetes / scheduling-config.
### inc5-fix
- H1: Fix, re-apply with `kubectl apply -f`, read again.
- H2: Both files are the source of truth; a node patched by hand is gone at the next clean redeploy.
- H3: `tolerations` entry with key, operator, value, effect matching the node, in both workloads that must run on that node; exact resource name in the ConfigMap.
- H4: `tolerations: [{key: pool-<id>, operator: Equal, value: gpu, effect: NoSchedule}]`; `- name: nvidia.com/gpu`; the same toleration under the DaemonSet's pod spec.
### inc5-evid
- H1: All six values are visible with kubectl.
- H2: `describe node`: Taints, Allocatable (the odd extended resource); `get events`: the two FailedScheduling messages in order.
- H3: Capacity after = physical GPUs x replicas of your fixed config, read live.
- H4: reasons: `untolerated-taint` then `insufficient-gpu`.

## pm (postmortem, all incidents)
- H1: Which sentence would a stranger need to understand what failed and why users noticed?
- H2: Blameless chain: trigger, missing guard, late detection. Mitigation (stops pain) is not the fix (source of truth).
- H3: Timeline in UTC from your notes (3+ lines); root cause names the component and the mechanism keywords; action items: one detect (alert/dashboard with the PromQL), one prevent (CI/gate/limit), each with an owner.
- H4: See `.tutor/solution/lab/postmortem-N.md` for the shape (do not copy).
