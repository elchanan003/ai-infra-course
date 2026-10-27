# 11 - Tutor answers

The lab has no hidden answers. `verify.sh` checks structure only: 11.1 (14 named skills rated, >= 2 distinct ratings, own next step >= 4 words for ratings 1-3), 11.2 (>= 10 distinct questions of >= 6 words ending in `?`, >= 4 sections, no verbatim theory bullets, no placeholders), 11.3 (5 days with focus and output), 11.4 (outputs are artefacts and distinct), T.1 (the planted Day 2 "tune/restart production" must go).
Review content with the learner: are the questions ordered by impact, do the self-ratings match module scores, is each plan day an output (not "learn X")? Questions about the real team go into "Open questions for the team" in PROGRESS.md.

Honesty: there is nothing to simulate in this module. Remind the learner that the whole course ran on mocks for GPU behaviour and that week 1 should name that gap (theory 1.11, 5.3).

Common mistakes: all skills rated 4 (suspiciously uniform), next steps like "study more", questions that are really statements, plans whose outputs are "understanding", keeping the colleague's Day 2.

## Quiz
1. The compiled TensorRT-LLM **engine** (built per GPU architecture, TensorRT-LLM version, TP degree) plus the model repository layout. The air-gap pipeline must carry the built engines (or the toolchain and a build node with the same GPU type), pin versions, and checksum them; weights alone are not enough.
2. `InferenceService` = Deployment + Service + autoscaling + canary in one CRD; runtime = engine image and args (what `--max-num-seqs` etc. configure); modelcar = the weights delivered as an OCI image (module 02) instead of fetched at start. Storage initializer = the "download weights" step; source of truth = the CRD in Git.
3. Queue depth, KV-cache utilisation, prefix-cache affinity, LoRA adapter presence, per-pod criticality; it picks by load and cache state, whereas `simple-shuffle` is load-blind random weighting (only cooldowns eject).
4. TGI is in maintenance mode (fixes, no features): fine for existing deployments; for new work ask why not vLLM/SGLang, which models and features are needed, upgrade/migration plan, metrics parity.
5. Where limits live (key/team/route/global), whether counters are shared across gateway replicas (and how: Redis, Envoy rate-limit service, DB), whether concurrency caps exist per client class, how keys are provisioned.
6. Running prefill and decode on separate pools with a KV transfer; helps when long prompts stall decoding: high TTFT with a long queue vs steady ITL, prefill-heavy traffic (`request_prefill_time_seconds`, `time_to_first_token_seconds` vs `inter_token_latency_seconds`), preemption/queue metrics.
7. Queue (`num_requests_waiting`), KV usage, preemptions, TTFT/ITL percentiles, per-key/team breakdown, GPU temp/XID/FB used, error ratio by status.
8. Find who fires and who got paged (history), read the expression and its `for`, ask the team who owns it, write the runbook draft from module 10 theory 3.4, open a PR adding owner/runbook labels; do not delete it.
9. Typically: where the platform runs and who owns it (access), how changes ship (repo/CI), limits/capacity and on-call. Any justified answer that changes week 1.
10. Keys edited by hand in a UI or `curl` history with no repo trail; no template for the agent vs chat key; limits differ between replicas or environments; causes drift and uncapped keys (the planted state of capstone 1).
11. Request queue/concurrency-based autoscaling = replicas and `max_num_seqs`/queue signals; Ray-specific: actors, deployments, `RayService` CRD, cluster autoscaler, placement groups for TP.
12. Docs/runbook fix, alert labels, a dashboard panel, or a key template: small, reviewable, teaches the change workflow and builds trust without touching production behaviour.
13. Metric prefix (`sglang:*`, enable with `--enable-metrics`) and names (`sglang:num_queue_reqs`, `sglang:token_usage`) differ, so vLLM dashboards show no data and alert rules on `vllm:*` never fire (absence looks like health). Also: flag names (`--mem-fraction-static`, `--max-running-requests`), scrape config/ServiceMonitor, runbooks.
14. Honest version: mechanisms and failure symptoms practised in a simulator (mock-vllm, mock-dcgm, fake nvidia-smi, node patch), real software for gateway/observability/registry on CPU, but no hands-on with real GPUs, drivers, MIG reconfiguration or XID in hardware; ask for a supervised first operation (node drain, rollout with rollback) in the first month.
