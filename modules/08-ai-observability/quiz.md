# 08 — Quiz

1. Why are request rate, error rate and average latency not enough for an LLM service? Name three additional signals and what each tells you.
2. Define TTFT and ITL. Which engine phase dominates each, and which user experience does each map to?
3. Write the PromQL for p95 TTFT per model across several vLLM replicas. Why must `le` appear in the `by` clause, and why is `avg(histogram_quantile(...))` wrong?
4. TTFT bucket counts (cumulative, `le` in seconds): 0.5 → 60, 1.0 → 90, 2.5 → 98, 5.0 → 100, +Inf → 100. Compute the p99 as `histogram_quantile` would. If your SLO is "p99 < 2 s", why is this number weak evidence, and what do you compute instead?
5. For each of these metrics say gauge / counter / histogram and the right way to plot it: `vllm:num_requests_waiting`, `vllm:num_preemptions_total`, `vllm:time_to_first_token_seconds_bucket`, `vllm:kv_cache_usage_perc`.
6. A teammate's dashboard panel `rate(vllm:kv_cache_usage_perc[5m])` is flat zero and another panel for the same metric shows "0.62%" when KV is at 62%. Diagnose both.
7. You scrape with `scrape_interval: 5s`. What is the smallest sensible `rate()` window and why? What breaks with `[10s]`?
8. Design the `QueueGrowing` alert: expression, `for`, severity, one false-positive source and how you avoid it.
9. A `KVCacheNearFull` alert (`kv_cache_usage_perc > 0.9 for 5m`) pages daily at 15:00 although users are fine. Explain why this is expected behaviour of the engine and how to re-scope the alert.
10. An alert on `vllm:gpu_cache_usage_perc > 0.9` has never fired. Give two reasons and a guard that would have caught it.
11. Spend logs (Postgres) show 6% fewer total tokens than `increase(vllm:prompt_tokens_total[1h]) + increase(vllm:generation_tokens_total[1h])` for the last hour, and 0.3% fewer than LiteLLM's token counters. List the causes you would check, in order, and the one you would suspect first from those two numbers.
12. Why must a reconciliation job wait for a flush barrier? What lab-only setting shortens the lag, and what is the production default order of magnitude?
13. What does a recording rule buy you, and what is the trap with recording a quantile?
14. Draw (or list) the Langfuse v3 components and the path of one trace from LiteLLM to the UI. Why does a trace not appear instantly and how should a test wait for it?
15. A security reviewer asks what is stored when Langfuse tracing is on for a coding assistant. Answer and name two controls.
