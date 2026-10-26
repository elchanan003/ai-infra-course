# 01 — Quiz

1. Explain why decode is memory-bandwidth-bound and prefill compute-bound. Which latency metric does each dominate? Why does batching help decode far more than prefill?
2. Compute the KV cache per token and for 16 concurrent 8192-token sequences, FP16, for Llama-3-8B (32 layers, 32 attention heads, 8 KV heads, head_dim 128). Give GiB.
3. The same model with 32 KV heads (MHA) instead of 8: how much per token? If you also store KV in FP8?
4. A 7B model (Qwen2.5-7B: 28 layers, 28 attention heads, 4 KV heads, head_dim 128, 7.62B parameters) in BF16 on one GPU with 24 GiB. Use `--gpu-memory-utilization 0.9` and 2 GiB of overhead. How many tokens of KV fit, and how many 4096-token sequences?
5. vLLM refuses to start: "To serve at least one request with the model's max seq len (65536), (1.5 GiB KV cache is needed, which is larger than the available KV cache memory (1.0 GiB)". Explain the arithmetic behind the message and give three different fixes.
6. A teammate says "we quantised the 70B model to INT4, so KV cache pressure is solved". What is wrong? What would actually reduce KV memory?
7. Contrast static and continuous batching using a batch with one 2000-token generation and three 50-token generations. What does chunked prefill add?
8. `llama-server -c 4096 -np 8` and a client sends a 1500-token prompt. What happens, why, and what are two ways to fix it (with the flags)?
9. Three requests hit the same engine: A = [system S][document D][question q1], B = [S][D][q2], C = [timestamp t][S][D][q3] where t differs per request. Which of B, C benefit from the cache after A, and what is the design rule?
10. Four replicas of an engine sit behind round-robin load balancing; every request starts with the same 8k-token system prompt, prefix caching is on, yet the cache hit rate is ~25%. Explain and name two fixes.
11. Llama-3-70B: attention heads 64, KV heads 8, 80 layers. Which TP sizes are valid on an 8-GPU node, why is TP=3 invalid, and what happens with TP=16?
12. 70B parameters in FP16 on 2 x 80 GiB GPUs, TP=2, utilisation 0.92, 2 GiB overhead per GPU, KV 320 KiB/token. How many 8192-token sequences fit? What changes if weights are FP8?
13. The user complains "it starts slowly" while the dashboard shows an average request latency of 6 s that looks fine. Which two metrics do you look at first and what are the typical causes of each being high?
14. Single-stream decode upper bound: weights 16 GB, memory bandwidth 3.35 TB/s. What is the tokens/s ceiling? What does batch 32 do to the *aggregate* ceiling and to each stream's speed, qualitatively?
15. On this Neoverse-N1 host Q8_0 processed prompts about 3x faster than Q4_K_M even though it is 40% bigger. Give the reason and the general lesson for choosing a quantisation format.
