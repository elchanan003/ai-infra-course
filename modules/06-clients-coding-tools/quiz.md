# 06 — Quiz

1. Open WebUI's `OPENAI_API_BASE_URLS` in compose is correct, but the UI still shows the old connection after a restart. Explain PersistentConfig and give two ways to make the new value effective.
2. List four kinds of requests an Open WebUI deployment sends to the gateway besides the user's chat messages (including hidden ones). How do you reduce their cost?
3. Why should Open WebUI use a dedicated gateway key rather than the master key or a developer's key? What limits and model list would you give it?
4. Compare chat completion and FIM: endpoint, model type, prompt shape, output length, latency target, request rate. Why do teams give FIM its own alias and key?
5. Write (as text) the prompt a Qwen2.5-Coder FIM request would contain for prefix `def add(a, b):\n    ` and suffix `\n\nprint(add(1, 2))`. What happens if you send it to a chat-tuned model through `/v1/chat/completions` instead?
6. Continue autocomplete fires on every typing pause. Give three platform-side consequences (limits, cancellation, model choice, caching).
7. In a Continue `config.yaml`, how do you give the chat role and the autocomplete role different keys and models? Why is that good security practice?
8. What does Aider put in each request? Why are Aider prompts large, and what does `--edit-format whole` trade off compared with `diff`?
9. Aider is configured with `OPENAI_API_BASE` and a model called `chat`, and fails with a provider error. What is the likely fix?
10. A coding agent's request has a 12 000-token system prompt + tool schemas and adds 1 500 tokens per turn. Compute the total prompt tokens processed in a 30-turn session, and the order-of-magnitude saving from prefix caching.
11. In an agent request, what are `tools`, `tool_choice` and `tool` role messages? Name two reasons a gateway/engine pair might fail to serve tool calls even though plain chat works.
12. How can you tell from gateway logs whether traffic is Aider, Continue autocomplete or an agent? Give three signals.
13. Why must the gateway/proxy not buffer SSE for agent clients? What happens to retries/fallbacks once a stream has started?
14. A developer says "autocomplete is slow since the agents started". Diagnose with two hypotheses, what you would check, and two fixes.
15. Open WebUI shows a 20-second delay and an empty model list; the compose env is correct. Name the two most likely stored-config causes and the exact place you would fix them.
