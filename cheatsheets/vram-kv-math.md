# VRAM / KV cache math cheatsheet

Decimal GB = 10^9 B; GiB = 2^30 B (1 GiB = 1.0737 GB). State your unit.

## Formulas
```
weights_bytes   = params × bytes_per_param          # bf16/fp16 2, fp8/int8 1, int4 ~0.5 (+ scales ~5-10%)
kv_bytes/token  = 2 × layers × kv_heads × head_dim × kv_bytes     # 2 = K and V; kv_bytes: bf16 2, fp8 1, fp32 4
kv_bytes/seq    = kv_bytes/token × tokens
head_dim        = hidden_size / num_attention_heads   (or config.head_dim)
budget          = gpu_memory_utilization × total_gpu_memory          # per instance, per GPU
kv_pool         = budget − weights − activations(profiled peak) − overhead(CUDA ctx, graphs, NCCL)
kv_pool_tokens  = kv_pool / kv_bytes/token           (÷ TP: both weights and KV are sharded across GPUs)
max_concurrency (at full length) = kv_pool_tokens / max_model_len
startup check   : kv_bytes/token × max_model_len  ≤  kv_pool         else "max seq len larger than KV cache"
estimated max len printed by vLLM = kv_pool / kv_bytes/token
```
Tensor parallel: per-GPU `weights/TP`, per-GPU KV per token = `kv_bytes/token / TP`; **TP must divide attention heads and KV heads** (8 KV heads → TP ∈ {1,2,4,8}; with TP > kv_heads vLLM replicates KV heads).
Quantization shrinks **weights**, not KV (`--kv-cache-dtype fp8` is separate). GQA (few KV heads) and MLA shrink KV.

## Reference models (verify against the model's `config.json`)
| Model | layers | KV heads | head_dim | KV/token bf16 | per 4k seq | per 32k seq |
|---|---|---|---|---|---|---|
| Qwen2.5-0.5B | 24 | 2 | 64 | 12,288 B (12 KiB) | 48 MiB | 384 MiB |
| Qwen2.5-7B | 28 | 4 | 128 | 57,344 B (56 KiB) | 224 MiB | 1.75 GiB |
| Llama-3-8B | 32 | 8 | 128 | 131,072 B (128 KiB) | 512 MiB | 4 GiB |
| Llama-3-70B | 80 | 8 | 128 | 327,680 B (320 KiB) | 1.25 GiB | 10 GiB |
fp32 (CPU lab, Qwen2.5-0.5B): 24,576 B/token; 1 GiB = 43,520 tokens (vLLM-CPU spike).

## Weights (params × bytes)
| Model | bf16 | fp8/int8 | int4 (~4.5 b) |
|---|---|---|---|
| 7-8B | 14-16 GB | 7-8 GB | ~4.5 GB |
| 70B | 140 GB | 70 GB | ~40 GB |

## Worked examples
- Llama-3-8B, 40 GB GPU, util 0.9: budget 36 GB − (16 weights + 3 act/overhead) = 17 GB → 17e9/131,072 ≈ 129,700 tokens ≈ 15.8 × 8k seqs. fp8 KV → 259,400 tokens.
- Max-len error: needs 6.0 GiB (49,152 × 128 KiB) vs available 4.5 GiB → estimated max len = 4.5 GiB / 131,072 = 36,864.
- Llama-3-70B bf16 on 2×80 GB, util 0.9: budget 144 GB − 140 weights = 4 GB − overhead → almost no KV (marginal). 4×80: TP=4 gives ~(288−140−~12)≈ 136 GB KV ≈ 415k tokens. FP8 weights on 2×80: 144 − 70 − ~8 ≈ 66 GB → 200k tokens.
- Sequences that fit ≈ kv_pool_tokens / (avg_prompt + avg_output); set `--max-num-seqs` at ~70-90% of that.

## Sanity rules
- Prefix cache and chunk sizes work in **blocks** (16 tokens GPU; 128 in the CPU build): a prompt shorter than a block never hits.
- `kv_cache_usage_perc` is 0..1.
- 1 GiB / (128 KiB/token) = 8192 tokens exactly (Llama-3-8B bf16).
- Don't forget: activations scale with `--max-num-batched-tokens`; CUDA graphs cost memory; leave ≥5-8% headroom (util ≤ 0.95).
