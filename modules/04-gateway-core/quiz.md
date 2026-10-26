# 04 — Quiz

1. Draw the request path through LiteLLM from the client's HTTP request to the backend and back. Mark where authentication, limits, routing, spend computation and callbacks happen, and which of them are synchronous.
2. What is the difference between `model_name` and `litellm_params.model` in a `model_list` entry? Give two failures caused by getting each wrong.
3. A client receives 401, another 403, another 429, another 422. For each: what is the cause and what would you look at first?
4. You issue a key with `models: ["chat"]` inside a team whose model list is `["embed"]`. What can the key call? How would you debug a 403 on `chat`?
5. Explain how a virtual key is stored. What do you do when a developer says "I lost my key"? Why is putting keys in `config.yaml` a bad idea even if it works?
6. `rpm_limit: 6`, three replicas, round-robin LB, no Valkey. What is the effective limit? Name the exact config that makes it global, and say why `router_settings.redis_host` alone does not.
7. Compute: a key has `tpm_limit: 1000`. Each response uses 600 tokens. Starting at the beginning of a window, how many requests succeed in that window, and why is the answer not 1?
8. Measured RPM semantics: `rpm_limit: 3`, a client sends one request every 10 s for 3 minutes, starting exactly at a window start. Sketch which requests get 429 if the window is fixed 60 s. Would a token bucket give a different result? Which behaviour does `retry-after: 60` suggest?
9. After `docker restart litellm` all keys return 401. List three possible causes in order of likelihood and how you test each.
10. What is `LITELLM_SALT_KEY` for? What happens if you regenerate it during a redeploy?
11. Your dashboard says key X spent $12.40 in the last day, but the sum of `LiteLLM_SpendLogs` for key X is $3.10. Give two plausible causes (one about the backend, one about the pipeline).
12. Why is `/health` a bad Kubernetes readiness probe for the gateway? What do you use instead?
13. What is wrong with this design, and how would you fix it?
    ```
    clients -> litellm:4000 -> llama:8080
    clients -> llama:8080   (published port, "for debugging")
    ```
14. You must give an autonomous agent platform access without letting it starve chat users. Which three limits do you set on its key, and at which level (key/team) do you put the budget? Why not just give it a small RPM?
15. Production vs lab: name four things in this lab that would be different in a production deployment of the gateway.
