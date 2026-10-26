# 03 — Lab: predict and fix vLLM startup, KV and preemption problems

Time: ~3 h of work. Guidance level: guided at first, then open. Work from `modules/03-vllm-ops/`.

**Honesty first.** There is no GPU on this host. The "vLLM" you operate in this lab is **mock-vllm** (simulated): it reads the same flags you would give `vllm serve`, runs the same memory arithmetic on a *simulated* GPU, fails with the *real* vLLM error text and exports the *real* metric names. Latencies come from a deterministic virtual clock, so results are reproducible but are not GPU measurements. Task 3.7 (optional) runs a real vLLM-CPU for a few minutes.

## Starting state

`prepare-lab.sh` starts profile `mock` (mock-vllm A on :18021, mock-vllm B on :18022; mock-dcgm is not used here), seeds your per-learner **variant** (model, simulated GPU sizes, floors, SLO numbers; stored in `.state/`, never shown) and writes starter files under `lab/`. The mock containers read their flags from `lab/vllm-a/args` and `lab/vllm-b/args`; after editing, restart with:

```bash
./lab/tools/apply.sh a      # or: b   -- restarts that mock with the current args and prints the startup log tail
curl -s localhost:18021/health -o /dev/null -w '%{http_code}\n'
curl -s localhost:18021/metrics | grep -E '^vllm:(kv_cache_usage_perc|num_requests|num_preemptions)'
```

Real vLLM metric names are used; see `cheatsheets/vllm-flags-metrics.md`. VRAM/KV arithmetic: `cheatsheets/vram-kv-math.md`.

## Ownership

| Path | Status |
|---|---|
| `lab/predict/PREDICT.env` | yours — task 3.1 (starter: `REPLACE_ME` values) |
| `lab/predict/cfg-1.args`, `cfg-2.args`, `cfg-3.args` | given (three candidate configs for the variant model/GPU); read-only |
| `lab/vllm-a/args` | yours — tasks 3.2 and 3.8 (starter: broken) |
| `lab/vllm-a/gpu.yaml`, `lab/vllm-a/model/config.json` | given: the simulated GPU and the real model geometry (read them!) |
| `lab/vllm-b/args` | yours — tasks 3.3 and 3.6 (starter: naive defaults) |
| `lab/answers/ttft.env` | yours — task 3.4 (starter: `REPLACE_ME`) |
| `lab/answers/pressure.env` | yours — task 3.5 |
| `lab/slo/SLO.md` | given: SLO table for task 3.6 |
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
1. Start from `lab/vllm-b/args` and look at what the starter does under the load: `python3 lab/tools/load.py --target b --concurrency 8 --preset task3` and watch `num_preemptions_total`.
2. Compute the tokens needed: 8 × (prompt + max_tokens). Compare with the KV pool tokens in the startup log / `cache_config_info`.
3. Change the flags that matter (and only those that matter): seq cap, KV size/dtype, max length.

Success criteria (verify runs its own load)
- `3.3a` all 8 requests complete with 200 (no errors, none rejected).
- `3.3b` peak `num_requests_running` ≥ 8 during the run.
- `3.3c` `num_preemptions_total` delta == 0.

## Task 4 (3.4) — p95 TTFT by hand from raw buckets

**Goal:** compute p95 TTFT from the raw `_bucket` lines — the way `histogram_quantile` does — to know what your alert really measures.

Steps/hints:
1. `./lab/tools/snapshot.sh` saves a frozen snapshot of mock B's `/metrics` to `lab/answers/ttft.snapshot.prom` (deterministic scenario; same for you and verify).
2. Extract `vllm:time_to_first_token_seconds_bucket` lines, find the bucket containing rank 0.95 × count, interpolate linearly.
3. Write `lab/answers/ttft.env`: `P95_TTFT_SECONDS=<value>`, `BUCKET_LOWER=<le below>`, `BUCKET_UPPER=<le above>`.

Success criteria
- `3.4a` `P95_TTFT_SECONDS` within ±10% of verify's `histogram_quantile` on the same snapshot.
- `3.4b` `BUCKET_LOWER`/`BUCKET_UPPER` are the real adjacent `le` values that bracket that quantile.

## Task 5 (3.5) — Watch KV pressure happen

**Goal:** drive the scripted pressure ramp, record what moves and in what order.

Steps/hints:
1. On a config where KV is the limit (your task-2 instance A works: run `python3 lab/tools/load.py --target a --preset ramp`), poll `/metrics` every second (`watch`, or a tiny script) for `kv_cache_usage_perc`, `num_requests_waiting`, `num_preemptions_total`, and the TTFT histogram count/sum.
2. Write `lab/answers/pressure.env`: `KV_PEAK` (max usage observed, fraction 0..1, two decimals), `PREEMPTIONS` (counter delta during the ramp), `ORDER` (comma list of the first-moving signals from `kv,queue,preempt,ttft`, earliest first).

Success criteria
- `3.5a` `KV_PEAK` within ±0.03 of verify's own replay of the same deterministic ramp.
- `3.5b` `PREEMPTIONS` equals verify's counter delta exactly.
- `3.5c` `ORDER` equals the order observed in the replay (evidence is variant-bound: the seq cap differs per learner, so the order differs).

## Task 6 (3.6) — Choose `--max-num-seqs` for an SLO

**Goal:** pick `--max-num-seqs` (and, if needed, `--max-num-batched-tokens`) in `lab/vllm-b/args` to meet the SLO table in `lab/slo/SLO.md` under a hidden deterministic load.

Steps/hints:
1. Compute the KV ceiling in sequences for the load's average size. Start at ~80% of it.
2. Use `load.py --preset sweep` (open-loop, deterministic) and read p95 TTFT, p95 ITL, tokens/s, preemptions. Sweep 3-5 values; plot or tabulate.
3. Too low: queueing (TTFT). Too high: preemption cliff. Pick the knee with margin.

Success criteria (verify replays a hidden load of the same family)
- `3.6a` p95 TTFT under the SLO and p95 ITL under the SLO.
- `3.6b` output tokens/s ≥ the throughput floor.
- `3.6c` preemption delta == 0.

## Task 7 (3.7, optional, unscored) — Real vLLM-CPU

Run the one-box real engine (profile `vllm`, alone; ~6 GB RAM): `platform/stack.sh up vllm`, wait for `/health` on :18023, send a request, read `/metrics` and compare names with mock-vllm. Observe the startup log's KV size and "maximum concurrency", then restart with a `--max-model-len` too large to reproduce the real error. No criteria; do not expect prefix-cache hits (block size 128).

## Task 8 (3.8) — Troubleshooting: dies on one node only

**Scenario.** The platform team promoted `lab/vllm-a/args` to a second GPU node ("node-2"). It starts fine on node-1 but crash-loops on node-2 with a startup error. Same GPU type, same model. Mock A is now configured as node-2 (simulated: another process holds part of its GPU memory — a fault you can see with `GET :18021/admin/fault`, but production would show it in `nvidia-smi`).

Steps/hints:
1. Reproduce with `./lab/tools/apply.sh a --node 2`, read the **first** error, not the last.
2. Find what differs between nodes (free memory), compute the safe utilization.
3. Fix `lab/vllm-a/args` so it starts on **both** nodes without changing `--max-model-len` or model.

Success criteria
- `3.8a` instance starts on node-2 (healthy, completion 200).
- `3.8b` configured utilization ≤ the free fraction of the node-2 GPU minus 0.02 headroom (computed live from `gpu.yaml` + fault state).
- `3.8c` the same args still start on node-1 (verify launches both) and `--max-model-len` is unchanged from the starter.

---

## Reference points

- Real error text, metric names and flag semantics: `theory.md` sections 2-3, 11.
- If a mock container will not come up, `platform/stack.sh logs mock-vllm-a`.
