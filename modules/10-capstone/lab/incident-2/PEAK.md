# Daily peak (given)
- ~37 concurrent chat requests at the top of the peak (14:30-15:10), each: ~1,500-token prompt, 96 output tokens.
- Prompts start with the same ~1,200-token system prefix (the assistant's instructions), then a user-specific part.
- SLO: TTFT p95 at or under 10 s (virtual seconds of the simulated engine, read from the histogram buckets; mock/README.md 3.6).
- Model: Qwen2.5-7B geometry (28 layers, 4 KV heads, head_dim 128, bf16 KV) on one 24 GiB GPU shared with another process.
- Operating rule: the KV cache must stay under 95 % at peak (alert KVCacheNearFull fires at 90 %).
