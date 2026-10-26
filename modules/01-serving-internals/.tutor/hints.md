# 01 — Hint ladder

## Task 1.1 sizing.py (1.1.x)
- H1: write the two helpers first (`weights_gb`, `kv_bytes_per_token`) and test them on the quiz/theory numbers: Llama-3-8B must give 128 KiB per token.
- H2: concept: weights = params x bytes; KV per token = 2 x layers x **kv_heads** x head_dim x bytes. Per-GPU need = (weights + KV)/TP + overhead. Everything in GiB (2**30).
- H3: `weights_gb = params_b*1e9*bpp/2**30`; `kv_gb = kv_bytes_per_token*seq_len*n_seqs/2**30`; `fits: (w+kv)/tp + overhead <= gpu_gib*util`; `min_tp` loops over (1,2,4,8) and skips values that do not divide both head counts. `head_dim = model.get("head_dim") or hidden_size // num_attention_heads`.
- H4: `.tutor/solution/sizing.py`.

## Task 1.2 vram.env
- H1: read `lab/variant/model.json` and `gpu.json`; is `head_dim` there?
- H2: pool = gpu x util - weights - overhead (TP=1). MAX_SEQS = floor(pool / KV of one sequence of SEQ_LEN).
- H3: use your own sizing.py functions; remember the KV dtype (`kv_bytes`) and the weight dtype (`bytes_per_param`) can differ.
- H4: run the numbers with `.tutor/solution/sizing.py`.

## Task 1.3 slots and batching (1.3.x)
- H1: `curl localhost:18120/slots | jq '.[].n_ctx'` after `lab/bin/run-llama.sh`: what do you see with the starter env?
- H2: concept: in the classic layout `-c` is split between `-np` slots. You need >= 1800 + generated tokens per slot. Aggregate throughput comes from `/metrics` counters, not from your own token counting.
- H3: `CTX = PARALLEL x per-slot context` (8192 for 4 x 2048). In `bench.py`: parse the line that starts with `llamacpp:tokens_predicted_total`; `tokens = after - before`; `tokens_per_s = tokens / wall`. Run it for PARALLEL=1 and 4 with `PARALLEL=1 lab/bin/run-llama.sh`.
- H4: `.tutor/solution/llama.env`, `.tutor/solution/bench.py`. The reason: concurrent sequences share each weight read (continuous batching), not "more cores" or the prompt cache.

## Task 1.4 prompt cache (1.4.x)
- H1: send two requests that differ only by the question and print `usage.prompt_tokens_details.cached_tokens` of the second.
- H2: the cache matches a strict prefix of tokens. What is the very first thing in the starter's system message, and does it change per request?
- H3: put `system` first and unchanged; `doc` next; `question`, `now` and `request_id` after the document. `stable_prefix_tokens`: `curl -s localhost:18120/tokenize -d '{"content": ...}'` on `system + "\n\n" + doc`.
- H4: `.tutor/solution/prompt_template.py`.

## Task 1.5 quantisation (1.5.x)
- H1: `stat -c%s FILE`; start each model with `MODEL=... lab/bin/run-llama.sh` and `docker logs aiinfra-lab01-llama | head -60`.
- H2: look for lines with `file type`, `BPW` and `- type ...: N tensors`. For speed use a long prompt, `cache_prompt=false`, `max_tokens=1`, and divide the increase of `llamacpp:prompt_tokens_total` by the increase of `llamacpp:prompt_seconds_total`.
- H3: Q4_K_M mixes q4_K and q6_K tensors (plus f32 norms); Q8_0 has q8_0 (+ f32). Ratio = Q8 prompt tok/s over Q4 prompt tok/s, median of 3 runs.
- H4: the reason: Q8_0's simple int8 blocks map straight onto the CPU's dot-product kernels; Q4_K needs unpacking and scale handling (theory 5).

## Task 1.6 TP and MIG (1.6.x)
- H1: do the large model with your `sizing.py`: `min_tp(model, gpu_gib, util, seq_len, n_seqs, kv_bytes, overhead_gib)`.
- H2: max sequences at that TP = per-GPU pool (gpu x util - weights/TP - overhead) / per-GPU KV of one sequence (KV/TP).
- H3: MIG: try the profiles of the family in order of memory and take the first where `fits(small, slice_gib, 0.9, 1, ...)` is true. The sentence: TP has to divide both num_attention_heads and num_key_value_heads.
- H4: `.tutor/solve-answers.sh` (first python block).

## Task 1.7 the buggy team calculator (1.7.x)
- H1: run it on the Llama-3-8B example from theory (8k, 16 sequences) and compare with your `sizing.py`.
- H2: three independent defects: which head count is used for KV; which unit divides the weights vs the KV; where TP is applied.
- H3: look at the three lines that compute `weights`, `kv_per_token`, `per_gpu`.
- H4: `diff lab/team_calc.py .tutor/solution/team_calc.py`.
