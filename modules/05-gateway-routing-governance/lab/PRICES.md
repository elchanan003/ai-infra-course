# Your internal price list (generated for you - do not edit)

| | per token |
|---|---|
| prompt (input) | 1e-5 |
| completion (output) | 1e-5 |

Standard call used by the checks: one user message "price-check", `max_tokens: 20`. The simulated backend reports
**10 prompt tokens + 20 completion tokens** for it (every call, both deployments).

Task 5.4: the key `lab-budget` must have `max_budget: 0.00165`.
Canary share (task 5.1): group `chat` must send **25 %** of its traffic to deployment A and the rest to B.
