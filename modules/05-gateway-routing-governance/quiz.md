# 05 — Quiz

1. Explain the difference between retries, fallbacks and cooldowns. For a request to group `chat` (deployments A, B) while A returns 500 on every call, describe what happens step by step with `num_retries: 2`, `allowed_fails: 3`, `cooldown_time: 5`.
2. Why is `simple-shuffle` the recommended default for GPU replicas, and what goes wrong with `latency-based-routing` for LLM traffic?
3. You want to canary a new vLLM version on 10 % of traffic. Show the config idea (weights) and how you would watch the canary. What is the normal range of canary hits for 500 requests?
4. A user sends a 90 000-token prompt to a group whose deployments accept 32 000. Your config has `fallbacks: [{chat: [chat-big]}]`. What happens, and what do you change? What does `enable_pre_call_checks` do?
5. Fallbacks as a design decision: give three non-technical (or semi-technical) concerns before pointing `chat` at a SaaS group as the last fallback in an air-gapped company. How do you make a silent fallback visible?
6. Compute: prices 3e-6 per prompt token, 6e-6 per completion token; each call reports 50 prompt + 40 completion tokens. (a) cost per call, (b) spend after 120 calls, (c) calls allowed with `max_budget: 0.05` if one overshoot is possible.
7. A key budget is exceeded. Which HTTP status and error type do clients get? Why can't you reliably test budgets with 20 parallel requests?
8. Why does spend for your self-hosted model show 0 and budgets never trigger? Give two ways teams define an internal price.
9. Little's law: an agent key has `rpm_limit: 60`; each generation takes 20 s. What concurrency can the agent reach? What limit actually protects an engine with 8 sequence slots, and what value would you pick if chat needs 6 slots?
10. Name four differences between chat traffic and agent traffic that affect gateway/engine design. Which isolation layer is the only one that really protects KV cache?
11. Where does the router keep cooldown state with 2 gateway replicas, and which Redis settings share it? Why is this different from sharing rate limits (module 04)?
12. What does `stream_timeout` protect against? What happens to retries/fallbacks if the engine dies half-way through a stream?
13. Design: three model groups `chat`, `agent`, `fim` on a 2-node pool. Sketch fallbacks (who may fall back to whom), limits per key type, and one alert per layer.
14. Your fallback counter shows 30 % of requests fell back overnight, users did not complain. What do you conclude and do?
