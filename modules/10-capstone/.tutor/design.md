# 10 — Design note (tutor/author only, for phase 2 implementation)

Status: phase 1 design. Anything marked **CONFIRM** depends on `mock/README.md`, `platform/stack/README.md` or
modules 04/05/09 being validated; adapt names, keep the semantics. Binding decisions used: decisions.md 3
(LiteLLM shared state needs `cache: true` + redis `cache_params`, `supported_call_types: []`; RPM is a 60 s fixed
window; 429 burst rule; budget 422), 4 (unique response id), 7, 10 (tripwire = DNS query log, probes run inside
`aiinfra-airgap`), 12 (lab-session lock); mock fault API `latency|error_rate|kv_pressure|crash|slow_load|other_gpu_mem`,
mock-dcgm faults `xid|thermal|ecc|vram_leak`; vLLM metric names from `.build/spike/vllm-metrics-golden.txt`
(`vllm:kv_cache_usage_perc`, `vllm:num_requests_waiting`, `vllm:num_preemptions_total`, `vllm:time_to_first_token_seconds`).

## Common machinery
- `prepare-lab.sh N`: `platform/stack.sh up <profiles>` (converge), write the clean baseline of `lab/incident-N/`, health wait,
  replay deterministic "before" load for ~2.5 min (mock deterministic mode, virtual clock), snapshot baseline, plant, replay
  incident load, write `lab/answers/N-*.env` (field names only), print the page. Hidden variant (seed in `.state/10-capstone/N.variant`,
  chosen at random per run) binds evidence values. Never print the variant.
- Profiles: 1-3 `gw mock obs`; 4 `gw mock obs store`; 5 none of compose, `kind` (cluster `aiinfra`, node-patch capacity, plus a
  small given controller script `lib/gpu-plugin-sim.sh` that sets node capacity from the time-slicing ConfigMap). Never with `llm`.
- Common checks (`lib/common.sh`): N.1 durable = restart affected component(s) via `platform/stack.sh` with the learner files
  (config dirs through the documented env overrides, **CONFIRM** names) and re-assert simulated hardware faults; N.2 probe = 40
  sequential requests via gateway (or the incident path), no 5xx, TTFT p95 from deterministic mock stats < SLO (ratio-free, deterministic),
  + incident-specific pair; N.3 enum file (COMPONENT, CAUSE, STATEMENT >= 6 words, template values rejected); N.4 evidence vs live;
  N.5 `lib/pm_check.py` (copy sibling approach: sections with min words, >= 3 timeline lines `HH:MM`, root cause names component AND a mechanism keyword,
  >= 3 action bullets incl. detect keyword and prevent keyword). BLOCKED cascade: N.2 blocked if N.1 fails; N.4/N.5 never blocked.
- N.3 grading: wrong COMPONENT or CAUSE fails with a message naming the discrimination rule (theory section 6), never the answer.
- Evidence tolerances: counters from Prometheus `increase()` over the incident window, +-15%; maxima +-3 points; names/uuids exact;
  sha256 compared on the first 12 hex.
- Starter must score 0: N.1 fails (fault present), N.2 fails, answer files are templates, postmortems are templates.
- Cleanup: remove fault state, stop profiles (`down`, keep volumes), delete kind cluster, `.state/10-capstone`; never touch `lab/` content.

## Incident 1 - gateway: per-replica limits, uncapped agent key
- Layer: L2. COMPONENT=`gateway`, CAUSE=`rate-limit-misconfig`. Distractors that must fail: `runaway-client`, `capacity-overload`.
- Setup (profiles `gw mock obs`): two LiteLLM replicas (**CONFIRM** module 04.5 compose recipe/ports) on one config `lab/incident-1/litellm-config.yaml`
  (GIVEN base + learner-owned parts: `litellm_settings`, per-model `rpm`, general settings). Keys (created by prepare, stored in Postgres, survive
  restart): `chat-<v>` (team chat, rpm cap sized for chat, models chat) and `agent-<v>` (team agents) with **no** `max_parallel_requests`
  and a high/absent rpm. Router has no shared cache (no redis cache_params) so counters are per replica. Backend mock-vllm A/B deterministic.
- Planted traffic: prepare replays an agent flood (many concurrent sequential loops on the agent key, spread over both replicas) while chat key sends
  steady interactive requests. Visible symptoms: chat gets 429s from the model-level/per-replica rpm exhausted by the agent flood and slow TTFT
  (engine slots held by agent calls); engine itself not saturated on KV (so not incident 2).
- Fix space (learner): agent key `max_parallel_requests` + rpm/tpm cap (via `/key/update`, durable in PG, or key template file `lab/incident-1/keys.yaml`
  applied by given `apply-keys.sh` that verify re-runs: **CONFIRM** preferred mechanism after module 04/05 land) AND shared limit state across replicas
  (config: `cache: true`, redis cache_params, `supported_call_types: []`). Either alone is insufficient (check below).
- N.1: restart both replicas with `lab/incident-1/litellm-config.yaml`; key limits persist (`/key/info`); config has working shared cache (behaviour test below).
- N.2 (live, verify's own load): (a) negative: agent flood of 20 requests alternating replicas with the agent key -> >= 1 x 429 and 200s <= limit x 1 (global, not per replica);
  (b) concurrent chat key 40 sequential requests via alternating replicas -> 0 x 429, 0 x 5xx, deterministic TTFT p95 < SLO. Burst rule per decisions 3; recovery poll <= 70 s.
- N.4 evidence (variant-bound): `HEAVY_KEY_ALIAS` (variant alias `agent-<hex>`, from per-key metrics/spend), `CHAT_429_COUNT` (429s seen by the chat key during the incident window,
  from gateway metrics in Prometheus, +-20%), `LIMIT_SCOPE` (enum per-replica|global; must be `per-replica` for the planted state), `REPLICA_SPLIT` (share of agent requests on replica 1, +-10 points).
- Page text: "Chat users report 429 and slow answers since 14:xx; the agents team started a nightly batch." (No mention of limits, replicas or Valkey.)
- Postmortem keywords (root cause): `limit|rpm|parallel|cache|valkey|redis|replica`.

## Incident 2 - serving: KV exhaustion after a release
- Layer: L4. COMPONENT=`serving`, CAUSE=`kv-cache-exhaustion`. Distractors: `capacity-overload` (engine is mis-set, not under-provisioned), `bad-release`.
- Setup (`gw mock obs`): mock-vllm A with `lab/incident-2/mock-vllm-a/args` (via `MOCK_VLLM_A_CONFIG_DIR`); model geometry fixture, `gpu.yaml` fixed so the KV budget
  = known tokens (variant-chosen model/context so the numbers differ per run). Baseline `--max-num-seqs` is sane (sized to fit KV with margin); planted release raises it
  (variant 48/64/96) and disables prefix caching (**CONFIRM** the mock models prefix-cache hits/`--no-enable-prefix-caching`; if not, drop that half and keep the
  KV/seq mismatch). `lab/incident-2/RELEASE-NOTES.md` (GIVEN) lists the release diff with decoys (log level, served-model-name tweak) - the learner must discriminate.
- Planted traffic: deterministic peak replay (virtual clock): concurrency above the new max_num_seqs with long prompts -> `kv_cache_usage_perc` -> 1.0, preemptions, queue.
- Fix space: lower `max_num_seqs` to what the KV budget supports (compute from theory/module 01), and/or enable prefix caching, and/or reduce `max_model_len`/raise `gpu-memory-utilization`
  within the node's free memory; any combination that passes behaviour.
- N.1: restart mock-vllm A with the learner's args dir; engine starts healthy; args file is the source (`/admin/fault` kv_pressure reset counts for nothing).
- N.2: verify replays the deterministic peak: preemption delta == 0, `kv_cache_usage_perc` max < 0.95, TTFT p95 < SLO; negative/throughput floor: generation throughput >= floor (rejects
  `max_num_seqs=1`), requests all 200 through the gateway.
- N.4: `KV_PEAK` (max of `vllm:kv_cache_usage_perc` over the incident window, +-3 points of Prometheus `max_over_time`, queried from history so it survives the restart),
  `PREEMPTIONS` (`increase(vllm:num_preemptions_total)` over the window, +-15%), `PLANTED_MAX_NUM_SEQS` (exact, variant), `PEAK_WAITING` (+-20%).
- Page: "TTFT p95 3x the SLO between 14:30 and 15:10 daily peak since the 2026.10.26 release; GPU utilisation looks fine." Postmortem keywords: `max.num.seqs|kv|cache|preempt|slots|prefix`.

## Incident 3 - gpu + router: sick node still in rotation
- Layers L5+L3. COMPONENT=`gpu`, CAUSE=`hardware-fault` (the router gap is the contributing factor, goes in the postmortem and in N.1). Distractors: `capacity-overload`, `bad-release`.
- Setup (`gw mock obs`): router balances A and B (config `lab/incident-3/litellm-config.yaml`: no `allowed_fails`/`cooldown_time`, no `timeout`, no fallbacks). mock-dcgm node A or B (variant!)
  gets an XID fault (variant 79 or 48) with a variant GPU UUID plus thermal; the corresponding mock-vllm gets fault `latency` (slow) + a partial `error_rate` (re-asserted by verify, because it models
  hardware; learner cannot remove it).
- Fix space: router config: per-request `timeout`, `allowed_fails`, `cooldown_time`, `num_retries`, `fallbacks` to the healthy peer (and optionally set the sick deployment out of rotation).
  Node drain is the *mitigation*; what verify measures is that the router protects users while the node remains sick.
- N.1: restart gateway with the learner config; verify re-asserts the hardware faults on the sick node; config loads and routes.
- N.2: 40 sequential requests via the gateway, 0 x 5xx, deterministic latency p95 < SLO, and the sick backend receives <= K requests (mock `/admin/stats` counter) after the cooldown trigger
  (<= `allowed_fails` + retries); pair: for a control window verify clears the sick node's fault, and after the cooldown expires the backend receives traffic again (ejection is by health, not permanent removal). **CONFIRM** cooldown_time semantics on v1.106.4 (default 5 s).
- N.4: `AFFECTED_NODE` (a|b exact, variant), `XID_CODE` (exact, variant from `DCGM_FI_DEV_XID_ERRORS`), `GPU_UUID` (exact from the metric label, variant), `DRAIN_DECISION` (drain|wait; both XIDs in the pool
  are drain), `TEMP_C` (+-3 of the DCGM temperature at snapshot).
- Page: "p95 of the chat alias doubled at 15:02; roughly half of requests are slow, a few time out; load is normal." Postmortem keywords: `xid|gpu|node|cooldown|timeout|router|eject|drain`.

## Incident 4 - artifact: rollout will not start, and leaves the air gap
- Layer X. COMPONENT=`artifact`, CAUSE=`artifact-integrity`; `air-gap-leak` is the contributing factor (distractor for the enum). 
- Setup (`gw mock obs store`): `lab/incident-4/rollout.sh` (GIVEN) runs the new model on mock-vllm role inside network `aiinfra-airgap` with the learner-owned
  `lab/incident-4/rollout.env` (HF_HUB_OFFLINE etc.; baseline has `HF_ENDPOINT=<variant host>` and **no** `HF_HUB_OFFLINE`) and the model dir `lab/incident-4/model/` (seeded from the mirror
  copy; `MANIFEST.sha256` GIVEN from the "connected side"). Planted: `tokenizer.json` removed, one safetensors shard has a flipped byte (variant file index). Mock must (**CONFIRM / request to WP3**):
  fail startup on missing tokenizer; if `HF_HUB_OFFLINE` unset try to resolve `HF_ENDPOINT` host (DNS lookup -> tripwire query log) before failing; with offline = 1 fail fast with a local-only error;
  optionally refuse start when a safetensors header is inconsistent. A flipped payload byte is only detectable by sha256 (as in reality).
- Fix space: restore `tokenizer.json` and the shard from hf-mirror/registry (via the normal network, with `hf download --include ...`), check `sha256sum -c MANIFEST.sha256`, set `HF_HUB_OFFLINE=1`
  (+ `HF_HUB_CACHE`/local dir) in rollout.env, rerun rollout. 
- N.1: verify runs `rollout.sh` itself: all files match the manifest (computed live), engine healthy, `tripwire_hits` delta == 0.
- N.2: in-network probe (inside `aiinfra-airgap`) nonce completion -> 200; negative control: verify copies the model dir, deletes `tokenizer.json`, runs with the learner's env -> must fail **closed** (non-zero,
  `tripwire` delta == 0); i.e. the offline posture is proven, not the file fix only.
- N.4: `MISSING_FILE` (exact), `BAD_FILE` (exact shard name, variant), `BAD_SHA` (first 12 hex of the corrupt file's sha256 as it was in the planted state; verify stores it in `.state`), `TRIPWIRE_HOST` (exact
  host from the tripwire query log, variant), `TRIPWIRE_HITS` (>= 1, within +-30% of count at snapshot).
- Page: "Rollout of model X to the air-gapped serving pool hangs for several minutes and then fails; finance asks why the network team saw DNS lookups from the serving subnet." Postmortem keywords: `checksum|sha|manifest|tokenizer|shard|offline|integrity|artifact`.

## Incident 5 - kubernetes: Pending after node-pool change
- Layer L5. COMPONENT=`kubernetes`, CAUSE=`scheduling-config`. Distractors: `misconfiguration`, `capacity-overload`, `hardware-fault`.
- Setup (kind `aiinfra`, 1 control plane + 2 workers; node-patch GPU capacity; **CONFIRM** module 09 helper scripts): `lab/incident-5/` has `model.yaml` (Deployment, 1 replica, requests `nvidia.com/gpu: 1`, nodeSelector product label)
  and `time-slicing.yaml` (ConfigMap in ns `gpu-operator`). Planted node-pool change: new worker pool gets taint `pool-<variant>=gpu:NoSchedule` and label; ConfigMap entry has resource name `nvidia.com/gpus` (typo) -> the given
  controller `lib/gpu-plugin-sim.sh` (stand-in for the device plugin, labelled as simulation) computes capacity = physical GPUs x replicas only for the exact resource name `nvidia.com/gpu`, otherwise 0.
  Pod events: first `untolerated taint {pool-<v>: gpu}`, after toleration `Insufficient nvidia.com/gpu`.
- Fix space: add the matching toleration to `model.yaml`; fix the resource name (and `replicas`) in `time-slicing.yaml`; apply both; the controller republishes capacity.
- N.1: live objects equal the lab files (`kubectl diff` clean) AND verify resets node capacity to 0 and re-runs the controller: the pod must schedule (hand-patching the node does not survive).
- N.2: model pod Running on the right node; negative pair: a second replica beyond capacity (verify scales a probe Deployment to capacity+1) stays Pending with `Insufficient nvidia.com/gpu`; kubeconform on both files.
- N.4: `NODE_NAME` (exact, variant), `TAINT_KEY` (exact, variant), `PENDING_REASONS` (comma list, must contain `untolerated-taint` and `insufficient-gpu` in the order seen; verify recorded events at plant time in `.state`),
  `GPU_CAPACITY_AFTER` (integer = physical x replicas of the learner's fixed config, computed live), 
- Page: "After this morning's node-pool change the model-serving pod is Pending; the new pool was supposed to give us more GPUs." Postmortem keywords: `taint|toleration|time.slicing|capacity|resource|device.plugin|pending`.

## Open items for phase 2
1. Confirm mock/README names (fault API payload shape, `/admin/stats` fields, prefix-cache modelling, startup file checks for incident 4).
2. Confirm gateway two-replica recipe and key-limit mechanism from modules 04/05 harness.
3. Confirm kind helpers from module 09 (capacity patch, labels) and reuse for the controller.
4. Choose SLO numbers after measuring deterministic mock TTFT.
5. `.build/validate-module.sh 10` runs prepare/verify per incident; N<->N interference: each prepare converges the stack, so run order independent.
