# 11 — Tutor answers

The lab has no hidden answers; `verify.sh` checks only structure (14 skills rated, >= 10 questions in >= 4 sections, 5 days planned).
Review content with the learner: are the questions ordered by impact, do the self-ratings match module scores, is each plan day an output (not "learn X")?

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
