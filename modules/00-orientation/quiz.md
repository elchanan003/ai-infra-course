# 00 — Quiz

1. Place each component in one of the four layers (clients, gateway, engines, hardware/platform) and justify the two that are not obvious: Open WebUI, LiteLLM, the Postgres behind LiteLLM, a llama.cpp container, SeaweedFS holding weights, the NVIDIA device plugin, Aider.
2. Describe the structure of a streamed `/v1/chat/completions` response from the first byte to the last. Which chunk carries `finish_reason`? What must the client request to receive `usage` in a stream, and what happens to spend accounting if it does not?
3. Give three reasons to put a gateway between clients and engines, and two costs it introduces. Which of the costs would you mitigate with a shared Valkey/Redis?
4. A user reports "the chat model answers with an empty message". The gateway log shows `200`. Walk the debugging ladder: what do you check at each layer, and which fields in the response narrow it down?
5. A Hebrew paragraph of 120 words and its English translation (95 words) are sent to the same model. Roughly which one uses more tokens and why? Why do limits and bills use tokens rather than characters or requests?
6. Two clients both use "OpenAI-compatible" servers but one breaks when you swap the engine behind the gateway from llama.cpp to vLLM. Give three kinds of incompatibility that can cause this.
7. You send a request and immediately query the spend log for it: nothing. A minute later the row is there. Explain. Which setting controls the delay and why is lowering it in production a trade-off?
8. In the lab LiteLLM listens on `127.0.0.1:18040`, not `0.0.0.0:18040`. Why, and how do you still reach it from your laptop?
9. A client gets `429`. Name two different layers that can produce it, and how you tell them apart from the response and the logs.
10. This lab runs llama.cpp on a 4-core ARM CPU with a 0.5B model. List two conclusions you may draw from it for production GPU serving and two you may not.
