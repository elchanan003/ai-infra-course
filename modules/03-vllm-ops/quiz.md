# 03 — Quiz

Use pen and paper for the "compute" questions; show your arithmetic. Decimal GB = 10^9 bytes, GiB = 2^30 bytes (say which you use).

1. Explain in two sentences what `--gpu-memory-utilization` controls. Name two things it does **not** control.
2. Llama-3-8B-class model: 32 layers, 8 KV heads, head_dim 128, bf16 KV. (a) KV bytes per token? (b) KV for one 8192-token sequence? (c) The same with `--kv-cache-dtype fp8`?
3. GPU 40 GB, `--gpu-memory-utilization 0.9`, weights 16 GB, activations + non-torch overhead 3 GB, model from question 2. How many tokens fit in the KV pool, and how many sequences of 8192 tokens? What would FP8 KV give?
4. Startup fails with: `To serve at least one request with the model's max seq len (49152), (6.0 GiB KV cache is needed, which is larger than the available KV cache memory (4.5 GiB). Based on the available memory, the estimated maximum model length is N …` for the model in question 2. Compute `N`. Then list three different fixes and one cost for each.
5. The last line of the container log is `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}`. What do you do next, and why is this line useless on its own?
6. A config sets `--gpu-memory-utilization 0.98` and starts fine on a dedicated node but fails on another node of the same GPU type. Give the most likely cause, the shape of the error, and the correct fix.
7. `vllm:kv_cache_usage_perc` shows `0.62` on your dashboard panel configured with unit "percent (0-100)". What does the panel display and what is the fix? Which older metric name do many blog posts use, and why will its panel be empty on the pinned version?
8. What is a preemption in vLLM V1? Why can generation throughput fall while "GPU utilization" is high? Which counter proves it?
9. Under steadily increasing load, put these in the order they typically move: TTFT p95 rises; `kv_cache_usage_perc` approaches 1; `num_preemptions_total` rate > 0; `num_requests_waiting` > 0. Justify the position of the first one you place.
10. Here are cumulative TTFT bucket counts after some load (`le` in seconds): 0.25 → 40, 0.5 → 70, 0.75 → 90, 1.0 → 96, 2.5 → 100, +Inf → 100. Compute p95 by hand the way `histogram_quantile` does. Why is the answer only approximate, and why can't you get it from `_sum / _count`?
11. TTFT p95 is 4 s, `num_requests_running` = `max_num_seqs` = 64, `num_requests_waiting` = 30, `kv_cache_usage_perc` = 0.48, preemptions flat. What is the binding limit and what is your first change? What would you check before making it?
12. Prefix caching is enabled but `rate(prefix_cache_hits_total)/rate(prefix_cache_queries_total)` is ~0 for a chat app with a long shared system prompt. Give three possible reasons.
13. Why must `--tensor-parallel-size` divide the number of KV heads (e.g. 8)? What does TP do to per-GPU weights and KV, and why is TP not a "make it faster" switch?
14. What is simulated in this lab's vLLM, what is real, and what must you not carry over to a production capacity plan?
