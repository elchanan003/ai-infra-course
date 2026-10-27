# 03 — Lab: predict and fix vLLM startup, KV and preemption problems

Time: ~3 h of work. Guidance level: guided at first, then open. Work from `modules/03-vllm-ops/`.

**Honesty first.** There is no GPU on this host. The "vLLM" you operate in this lab is **mock-vllm** (simulated): it reads the same flags you would give `vllm serve`, runs the same memory arithmetic on a *simulated* GPU, fails with the *real* vLLM error text and exports the *real* metric names. Latencies come from a deterministic virtual clock, so results are reproducible but are not GPU measurements. Task 3.7 (optional) runs a real vLLM-CPU for a few minutes.

## Starting state

`prepare-lab.sh` starts profile `mock` (mock-vllm A on :18021 reads `lab/vllm-a/`, mock-vllm B on :18022 reads `lab/vllm-b/`; mock-dcgm is not used here), seeds your per-learner **variant** (floors, load sizes, node numbers; stored in `.state/`, never shown) and writes the starter and given files under `lab/`. Instance A starts **broken on purpose** (task 3.2). After editing flags, restart with:

```bash
./lab/tools/apply.sh a      # or: b -- restarts that instance with the current args and prints the result/log tail
./lab/tools/apply.sh x --args FILE [--gpu FILE]   # throwaway scratch instance on :18160 (time scale 20) for experiments
curl -s localhost:18021/health -o /dev/null -w '%{http_code}\n'
curl -s localhost:18021/metrics | grep -E '^vllm:(kv_cache_usage_perc|num_requests|num_preemptions)'
```

Real vLLM metric names are used; see `cheatsheets/vllm-flags-metrics.md`. VRAM/KV arithmetic: `cheatsheets/vram-kv-math.md`.

## Ownership

| Path | Status |
|---|---|
| `lab/predict/PREDICT.env` | yours — task 3.1 (starter: `REPLACE_ME`) |
| `lab/predict/cfg-1..3.args`, `gpu.yaml`, `model/config.json` | given: the three candidates, the node, the model geometry; read-only |
| `lab/vllm-a/args` | yours — task 3.2 (starter: broken); `gpu.yaml`, `model/config.json` given |
| `lab/vllm-b/args` | yours — task 3.3; `gpu.yaml`, `model/config.json` given |
| `lab/pressure/` | given — fixed config for task 3.5 (run on the scratch instance) |
| `lab/slo/args` | yours — task 3.6; `gpu.yaml`, `SLO.md`, `load.json` given |
| `lab/vllm-t/args` | yours — task 3.8; `gpu.node1.yaml`, `gpu.node2.yaml` given |
| `lab/answers/ttft.env`, `lab/answers/pressure.env` | yours — tasks 3.4, 3.5 |
| `lab/tools/` (`apply.sh`, `load.py`, `snapshot.sh`) | given — do not modify |

---

## Task 1 (3.1) — Predict before you launch

**Goal:** from flags and the GPU/model geometry alone, predict what three candidate configs will do.

Steps/hints:
1. Read `lab/vllm-a/gpu.yaml` and `lab/vllm-a/model/config.json`; derive KV bytes/token (cheatsheet).
2. For each `lab/predict/cfg-N.args`, work out weights + activations + overhead (the mock uses the estimates listed in `mock/README.md`), then the KV pool and whether one `max_model_len` sequence fits.
3. Fill `lab/predict/PREDICT.env`: `OUTCOME_N` ∈ `start | fail-kv | fail-gpu-free`, `KV_TOKENS_N` (tokens in the KV pool, for configs that start), `MAX_LEN_FIT_N` (the "estimated maximum model length" the engine would print, for `fail-kv` configs; `0` otherwise).
4. Only **after** writing your predictions: launch each config on mock B with `./lab/tools/apply.sh b --args lab/predict/cfg-N.args` and compare with the startup log. Do not change your file afterwards — verify launches them itself.

Success criteria
- `3.1a` the three `OUTCOME_N` values match the live startup outcome of each config.
- `3.1b` `KV_TOKENS_N` / `MAX_LEN_FIT_N` match the live values within 5%.

## Task 2 (3.2) — Fix "max seq len larger than KV cache"

**Goal:** `lab/vllm-a/args` starts and serves, **without** dropping `--max-model-len` below the floor in `lab/slo/SLO.md` (the product needs that context).

Steps/hints:
1. `./lab/tools/apply.sh a` and read the failing log. Find the root cause line (not the last line).
2. Do the division yourself first. Which levers (utilization, KV dtype, activations budget, length) get you above the floor? Which are free, which cost?
3. Keep `--gpu-memory-utilization` ≤ 0.95 — this simulated node also runs a monitoring agent.

Success criteria
- `3.2a` mock A is healthy and a chat completion returns 200.
- `3.2b` the running instance's `--max-model-len` (from `/v1/models` / `cache_config_info`) is ≥ the floor, and utilization ≤ 0.95.

## Task 3 (3.3) — Eight concurrent sequences, zero preemptions

**Goal:** configure mock B so that **8 concurrent requests** of the size given in `lab/slo/SLO.md` all run together with **no preemption**.

Steps/hints:
1. Start from `lab/vllm-b/args` and look at what the starter does under the load: `python3 lab/tools/load.py --target b --preset task3` and watch `num_preemptions_total`.
2. Compute the tokens needed: 8 × (prompt + max_tokens). Compare with the KV pool tokens in the startup log / `cache_config_info`.
3. Change the flags that matter (and only those that matter): seq cap, KV size/dtype, max length.

Success criteria (verify runs its own load)
- `3.3a` all 8 requests return 200 and run at the same time (peak `num_requests_running` >= 8).
- `3.3b` `num_preemptions_total` delta == 0 while they run together.

## Task 4 (3.4) — p95 TTFT by hand from raw buckets

**Goal:** compute p95 TTFT from the raw `_bucket` lines — the way `histogram_quantile` does — to know what your alert really measures.

Steps/hints:
1. `./lab/tools/snapshot.sh` saves a frozen snapshot of a deterministic scenario's `/metrics` (40 sequential requests of varied prompt sizes on a scratch instance, no time pacing) to `lab/answers/ttft.snapshot.prom` — the same scenario verify replays.
2. Extract `vllm:time_to_first_token_seconds_bucket` lines, find the bucket containing rank 0.95 × count, interpolate linearly.
3. Write `lab/answers/ttft.env`: `P95_TTFT_SECONDS=<value>`, `BUCKET_LOWER=<le below>`, `BUCKET_UPPER=<le above>`.

Success criteria
- `3.4a` `P95_TTFT_SECONDS` within ±10% of verify's `histogram_quantile` on the same snapshot.
- `3.4b` `BUCKET_LOWER`/`BUCKET_UPPER` are the real adjacent `le` values that bracket that quantile.

## Task 5 (3.5) — Watch KV pressure happen

**Goal:** drive the scripted burst against the given config in `lab/pressure/`, record what bounded it.

Steps/hints:
1. `./lab/tools/apply.sh x --args lab/pressure/args --gpu lab/pressure/gpu.yaml`, then `python3 lab/tools/load.py --target x --preset pressure`.
2. While it runs (or after), read `vllm:kv_cache_usage_perc`, `num_requests_running/waiting`, `num_preemptions_total` — via `/metrics` polling, or `/admin/stats` (`engine.kv_peak_usage`, `engine.preemptions`; mock-only; in production use `max_over_time(vllm:kv_cache_usage_perc[...])` in Prometheus).
3. Decide which budget limited the burst: the sequence cap (`running == max_num_seqs`, queue grows, KV not full) or the KV blocks (KV ~1.0, preemptions).
4. Write `lab/answers/pressure.env`: `KV_PEAK` (0..1, two decimals), `PREEMPTIONS` (counter delta during the burst), `LIMITER` = `seq-cap` | `kv`. Restart the scratch instance before each run so counters start at zero.

Success criteria (verify replays the same burst on a fresh instance)
- `3.5a` `KV_PEAK` within ±0.05 of the replay.
- `3.5b` `PREEMPTIONS` equals the replay's counter delta (0 exactly if none; otherwise within ±30%).
- `3.5c` `LIMITER` equals what bounded the burst (evidence is variant-bound: the sequence cap differs per learner).

## Task 6 (3.6) — Choose `--max-num-seqs` for an SLO

**Goal:** in `lab/slo/args` tune `--max-num-seqs` (and `--max-num-batched-tokens` if you want) to meet the SLO table in `lab/slo/SLO.md` under a burst of 96 requests. Utilization (0.30, a shared GPU) and max length are fixed by the platform team.

Steps/hints:
1. Compute the KV ceiling in sequences for the load's average final length. Start at ~80% of it.
2. `./lab/tools/apply.sh x --args lab/slo/args --gpu lab/slo/gpu.yaml`, then `python3 lab/tools/load.py --target x --preset sweep --json`. Sweep 3-5 values; tabulate throughput (generation tokens / virtual seconds), ITL attainment (`itl_buckets`: `le="0.1"` over `+Inf`), preemptions.
3. Too low: throughput floor missed. Too high: preemption cliff and slower decode steps. Pick the knee with margin.

Success criteria (verify replays the same load family with another seed, three runs, median)
- `3.6a` output throughput ≥ 1450 tokens per virtual second (median of 3 runs).
- `3.6b` at least 95% of inter-token gaps are ≤ 0.1 s.
- `3.6c` preemptions == 0.
- `3.6d` utilization and max length unchanged (0.30 / 4096).

## Task 7 (3.7, optional, unscored) — Real vLLM-CPU

Run the one-box real engine (profile `vllm`, alone; ~6 GB RAM): `platform/stack.sh up vllm`, wait for `/health` on :18023, send a request, read `/metrics` and compare names with mock-vllm. Observe the startup log's KV size and "maximum concurrency", then restart with a `--max-model-len` too large to reproduce the real error. No criteria; do not expect prefix-cache hits (block size 128).

## Task 8 (3.8) — Troubleshooting: dies on one node only

**Scenario.** The platform team promoted `lab/vllm-t/args` to a second GPU node ("node-2"). It starts fine on node-1 but crash-loops on node-2 with a startup error. Same GPU type, same model. In this lab the difference is the node's simulated GPU file (`gpu.node1.yaml` vs `gpu.node2.yaml`: another process holds part of the memory; production would show it in `nvidia-smi`).

Steps/hints:
1. Reproduce with `./lab/tools/apply.sh x --node 2` (and `--node 1` for the other node), read the **first** error, not the last.
2. Find what differs between nodes (free memory), compute the safe utilization.
3. Fix `lab/vllm-t/args` so it starts on **both** nodes without changing `--max-model-len` or the model.

Success criteria
- `3.8a` instance starts on node-2 (healthy, completion 200).
- `3.8b` configured utilization ≤ the free fraction of the node-2 GPU minus 0.02 headroom (computed from the node-2 GPU file).
- `3.8c` the same args still start on node-1 (verify launches both) and `--max-model-len` is still 8192.

---

## Reference points

- Real error text, metric names and flag semantics: `theory.md` sections 2-3, 11.
- If a mock container will not come up, `platform/stack.sh logs mock-vllm-a`.
