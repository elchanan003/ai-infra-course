# 01 — Lab: size a model, watch batching and caching, compare quantisations

Time: ~3.5 h. Guidance level: moderate (formulas are in theory sections 2 and 6; you do the work). Profiles: `llm mock`. **Real:** llama.cpp on CPU. **Simulated:** mock-vllm (used for an optional look at vLLM metrics). **Calculated:** all GPU, VRAM, TP and MIG results — there is no GPU on this host. Units are GiB (2^30) everywhere.

Lab containers you start yourself must be labelled `course=aiinfra` and named `aiinfra-lab01-*`; the given `lab/bin/run-llama.sh` does that and publishes on `127.0.0.1:18120` (module 01 owns 18120-18124). Timing is noisy on this shared 4-core host: tasks use token counters, cache counters and file sizes, and timing only as a ratio.

## Starting state
`./prepare-lab.sh` converges to `llm mock`, creates a hidden per-learner variant in `.state/` (which model geometry and GPU in 1.2/1.6, which model pair in 1.5, which long document in 1.4), and writes the variant inputs into `lab/variant/` (model `config.json` files, GPU table). It never prints answers.

## Ownership
| Path | Status |
|---|---|
| `lab/sizing.py` | yours — tasks 1.1 (starter: functions raise `NotImplementedError`) |
| `lab/answers/vram.env` | yours — task 1.2 |
| `lab/llama.env` | yours — task 1.3 (starter: `CTX=4096 PARALLEL=4`) |
| `lab/bench.py` | yours — task 1.3 (starter: skeleton with TODO) |
| `lab/answers/batching.json` | yours — task 1.3 |
| `lab/prompt_template.py` | yours — task 1.4 (starter: volatile text first) |
| `lab/answers/cache.json` | yours — task 1.4 |
| `lab/answers/quant.json` | yours — task 1.5 |
| `lab/answers/tp.json` | yours — task 1.6 |
| `lab/team_calc.py` | yours — task 1.7 (planted: a colleague's buggy calculator) |
| `lab/variant/*`, `lab/bin/*`, `platform/`, `mock/`, module scripts | given — do not modify |

## Task 1.1 — Write the sizing calculator
**Goal:** a library you trust for the rest of your career: `sizing.py` with these functions (all sizes in GiB):

| Function | Meaning |
|---|---|
| `weights_gb(params_b, bytes_per_param)` | weight memory; `params_b` in billions |
| `kv_bytes_per_token(layers, kv_heads, head_dim, kv_bytes)` | exact bytes per token |
| `kv_gb(layers, kv_heads, head_dim, kv_bytes, seq_len, n_seqs)` | KV memory for `n_seqs` sequences of `seq_len` tokens |
| `fits(model, gpu_gib, util, tp, seq_len, n_seqs, kv_bytes, overhead_gib=2.0)` | `(weights + KV)/tp + overhead <= gpu_gib*util` |
| `min_tp(model, gpu_gib, util, seq_len, n_seqs, kv_bytes, overhead_gib=2.0)` | smallest TP in (1, 2, 4, 8) that divides both `num_attention_heads` and `num_key_value_heads` and fits; `None` if none |

`model` is a dict like `{"params_b", "bytes_per_param", "layers", "num_attention_heads", "num_key_value_heads", "head_dim"}` (`lab/variant/*.json` show the exact keys). `head_dim` may be absent in a real `config.json`: derive it (`hidden_size / num_attention_heads`).

Steps/hints: start from the formula in theory 2; check by hand against the worked-examples table (Llama-3-8B: 128 KiB per token). Test with the numbers from the quiz.

Success criteria (verify imports your module and runs 6 hidden cases per learner: GQA, FP8 KV, MHA, TP divisibility, a model that needs TP=8, one that fits nowhere; tolerance 2%):
- `1.1.1` `weights_gb` and `kv_bytes_per_token` are exact on the hidden cases.
- `1.1.2` `kv_gb` correct (including FP8 KV and n_seqs scaling).
- `1.1.3` `fits` correct on both sides of the boundary (a case just under and just over).
- `1.1.4` `min_tp` correct, including divisibility (never returns 3, 5, 6, 7) and `None`.

## Task 1.2 — VRAM budget for your model
**Goal:** apply the calculator to the learner-specific model in `lab/variant/model.json` on the GPU in `lab/variant/gpu.json` (utilisation 0.9, FP16 weights, FP16 KV unless the variant says otherwise).

Fill `lab/answers/vram.env`: `WEIGHTS_GIB`, `KV_BYTES_PER_TOKEN`, `KV_POOL_GIB` (what is left for KV on one GPU at TP=1, overhead 2 GiB; negative means "does not fit"), `MAX_SEQS` (concurrent sequences of the variant's `SEQ_LEN` that fit in the pool, floor).

Success criteria (reference computed by verify from the same variant, ±2%):
- `1.2.1` `WEIGHTS_GIB`; `1.2.2` `KV_BYTES_PER_TOKEN` (exact); `1.2.3` `KV_POOL_GIB` and `MAX_SEQS`.

## Task 1.3 — Slots, batching and what `-np` does to context
**Goal:** see continuous batching on a real engine and learn that slots share the context.

`lab/bin/run-llama.sh` starts a llama-server (container `aiinfra-lab01-llama`) with the settings in `lab/llama.env` (`CTX` = total context, `PARALLEL`, `THREADS`, `MODEL`) on `127.0.0.1:18120`, with `--metrics` on. You can override a setting for one run: `PARALLEL=1 lab/bin/run-llama.sh`; `lab/bin/run-llama.sh stop` removes it.
1. Starter settings give each slot too little context for the variant's prompts. Look at `GET /slots` and `GET /props`, change `lab/llama.env` so **4 slots can each take a ~1800-token prompt plus 64 generated tokens**.
2. Complete `lab/bench.py` (usage `bench.py --url http://127.0.0.1:18120 --concurrency 4 --max-tokens 32`, prints JSON with `tokens_per_s`): it sends N concurrent generations, and report **aggregate generation throughput = Δ`llamacpp:tokens_predicted_total` / Δwall time** read from `/metrics` (not from your own token estimates).
3. Run it against `PARALLEL=1` and `PARALLEL=4` servers (same N, same `max_tokens`) and record both numbers and the ratio in `lab/answers/batching.json` with a one-line `why` chosen from the enum in the template.

Success criteria:
- `1.3.1` verify starts a server with **your** `llama.env` (model, CTX, PARALLEL, THREADS), sends 4 concurrent ~1800-token prompts: all 200 and the prompts are not truncated (`usage.prompt_tokens` close to the sent length).
- `1.3.2` your `bench.py`, run by verify against its own two servers, reports a throughput within a factor 1.5 of verify's own counter-based measurement (median of 3, one retry).
- `1.3.3` the ratio you recorded is within 0.6-1.6x of verify's measured ratio, and the ratio is above 1.2; `why` is the right enum value.

Concept: theory 3, 3.1. Timing rule: ratios only.

## Task 1.4 — Prompt cache: make a prefix cache-friendly
**Goal:** see `cached_tokens`, then fix a prompt layout that defeats the cache.

`lab/prompt_template.py::build_messages(system, doc, question, now, request_id)` returns the chat messages a hypothetical document-QA assistant sends (`lab/variant/system.txt` and `doc.txt` are your system prompt and shared document). The starter puts `Current time` and the request id **before** the shared system prompt and document.
1. Send two requests that differ only in `question` through your builder to the cache-enabled lab server and read `usage.prompt_tokens_details.cached_tokens` (and `/metrics` `prompt_tokens_cached_total`).
2. Fix the builder so the stable prefix is cached and volatile fields come last.
3. Use `POST /tokenize` on `system + "\n\n" + doc` (the variant files) to count the stable-prefix tokens and record `stable_prefix_tokens` and your two observed `cached_tokens` values (before and after the fix) in `lab/answers/cache.json`.

Success criteria:
- `1.4.1` verify calls **your** `build_messages` with fresh nonces for two requests and the second reports `cached_tokens` ≥ 80% of the stable-prefix tokens (live counters).
- `1.4.2` the builder output is deterministic for the stable part (two calls with different volatile values share the same leading messages byte for byte up to the question).
- `1.4.3` `stable_prefix_tokens` within 3% of verify's `/tokenize` count; `cached_tokens_before` is ≤ 10% of it and `cached_tokens_after` ≥ 80%.

Concept: theory 4.

## Task 1.5 — Quantisation: sizes, tensor types, speed
**Goal:** measure what Q4_K_M versus Q8_0 really means on this CPU.

`lab/variant/models.txt` names the GGUF pair for your variant (`Q4=` and `Q8=` file names in `~/.cache/aiinfra-course/models/`; chat or coder 0.5B).
1. Exact file sizes in bytes (`stat`).
2. Start each with `run-llama.sh` and read the load log (`docker logs`; the per-tensor `llama_model_loader`/`print_info` lines need `-lv 4`, which `run-llama.sh` already passes): file type (`ftype`), the tensor type counts (which of q4_K / q6_K / q8_0 / f32), and the reported bits per weight.
3. Measure prompt-processing speed for both with a long prompt and `cache_prompt: false` (use `llamacpp:prompt_tokens_seconds` or Δ`prompt_tokens_total`/Δ`prompt_seconds_total`), and note resident memory (`docker stats --no-stream`).
4. Fill `lab/answers/quant.json` (template has all keys) including `why_q8_prompt_faster` (enum) and `evidence_bpw_q4`, `evidence_bpw_q8` from your own logs.

Success criteria:
- `1.5.1` both file sizes exact; `1.5.2` tensor type sets and `ftype` strings match verify's own load of the files; BPW within 1% of the log.
- `1.5.3` `prompt_eval_ratio_q8_over_q4` is above 1.5 and within a factor 1.6 of verify's median-of-3 ratio (generation speed is deliberately **not** graded: it is noise-dominated here).
- `1.5.4` the enum is right **and** the evidence BPW values match the variant's files (a guessed enum without evidence fails).

Concept: theory 5. Expectation management: the "smaller is faster" intuition is wrong for prompt processing on this ISA.

## Task 1.6 — TP and MIG sizing for a large model
**Goal:** the answer you would give in a capacity-planning meeting.

`lab/variant/large.json` is a 70B-class model (FP16 or FP8, variant) and a GPU type (40 GiB or 80 GiB class); `lab/variant/small.json` is an 8B-class model.
Fill `lab/answers/tp.json`: `min_tp_large` (utilisation 0.92, `SEQ_LEN` and `N_SEQS` from the variant, overhead 2 GiB/GPU), `max_seqs_at_min_tp`, `mig_profile_small` (smallest MIG profile from theory 6.4 for the GPU family that holds `small.json` at `SMALL_SEQS` sequences; util 0.9, same overhead), and `explain_no_tp3` (one sentence that mentions head divisibility).

Success criteria (±2% on counts):
- `1.6.1` `min_tp_large` (and `null` where nothing in 1/2/4/8 fits); `1.6.2` `max_seqs_at_min_tp`; `1.6.3` `mig_profile_small` exactly one of the profile names; `1.6.4` the explanation mentions both `num_attention_heads` and `num_key_value_heads` divisibility.

## Task 1.7 — Troubleshooting (planted): the team calculator that is "always a bit off"
**Goal:** debug a calculator with several independent defects.

`lab/team_calc.py` is a colleague's script (`python3 lab/team_calc.py lab/variant/large.json --gpu 80 --tp 2 --seq 8192 --seqs 16 --kv-bytes 2`; it prints a JSON object). It disagrees with your `sizing.py` and with the hand-computed Llama-3-8B example in theory. Find out why, **fix it in place**, and keep its CLI and output format. (There is more than one defect.)

Success criteria:
- `1.7.1` verify runs your fixed `team_calc.py` on 6 hidden cases (GQA model, FP8 KV, TP 2/4, a model that does not fit) and the numbers agree with the reference within 2%.
- `1.7.2` the CLI contract still holds (same flags and the same keys in the JSON it prints).

## Optional 1.8 — vLLM metrics on the simulator (unscored)
Point `curl` at mock-vllm A (`/metrics`), send a few concurrent requests, and find `vllm:num_requests_running`, `vllm:kv_cache_usage_perc`, `vllm:num_preemptions_total`. Compare the KV capacity it reports (`GET /admin/stats` -> `capacity`, and `vllm:cache_config_info`) with what `sizing.py` says for the same `config.json` (fixtures in `mock/models/`). Contract: `mock/README.md` section 3.2. Module 03 builds on this.

## Wrap-up
`./verify.sh` (about 6-8 minutes: it starts and stops its own llama-server instances), `./cleanup.sh`, `./verify-clean.sh`.
