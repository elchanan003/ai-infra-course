# 10 — Quiz: incident response on an AI platform

1. Chat users get 429s while an idle engine shows `num_requests_waiting = 0`. At which layer is the problem, and which three questions about the limit do you ask?
2. Two gateway replicas, no shared cache, a key limit of `rpm_limit: 30`. What is the largest number of 200 responses you can see in one fixed minute when you spread requests evenly, and why? What changes it?
3. Compute: KV budget is 12,000 tokens, the mean sequence is 1,500 tokens (prompt + output). `max_num_seqs` is 32. How many sequences actually fit, what happens at peak, and which counter proves it?
4. A release changed `--max-num-seqs 16` to `64` and turned prefix caching off. TTFT p95 doubled only at peak. Give the signal chain you expect in the metrics, in the order it appears.
5. Why can "GPU utilisation 99%" and "TTFT 8 s" be true at the same time? Name the metric that shows work being redone.
6. A backend returns correct answers but 6 s slower than its peer, and DCGM shows temperature at the limit. Which two router settings should have limited the damage, and why is draining the node only a mitigation?
7. `DCGM_FI_DEV_XID_ERRORS` shows 79 on one GPU. Drain or wait? What would change your answer for XID 63?
8. The model rollout fails with "cannot load tokenizer" and the tripwire counted DNS queries for a hub host. Give two root problems and say which one the `HF_HUB_OFFLINE` variable would have turned from a slow failure into a fast one.
9. One shard has a flipped byte, the engine still starts. Why is "the pod is Running and answers" not proof of integrity, and what check do you run instead?
10. A pod is Pending: `0/2 nodes are available: 1 node(s) had untolerated taint, 1 Insufficient nvidia.com/gpu`. Explain each half and the order in which you fix them.
11. The Deployment asks for `nvidia.com/gpus: 1`. What does the scheduler do, and what does `describe pod` show?
12. When is `runaway-client` the correct cause and when is `rate-limit-misconfig`? Give one sentence of evidence for each.
13. Rewrite blamelessly: "Dana raised max-num-seqs without testing, so prod fell over again."
14. Name one detect-sooner and one prevent-recurrence action item for the KV-exhaustion incident, each with an owner-and-test phrasing.
