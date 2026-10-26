# 05 — Lab: load balancing, fallbacks, cooldowns, budgets, chat-vs-agent separation

Time: ~2 h of work plus ~4 min of waiting for `verify.sh` (it injects faults into mock-vllm, sends sequential traffic and polls for spend). Guidance level: guided-to-open. Work from `modules/05-gateway-routing-governance/`. Prerequisite: module 04 (you reuse its habits: keys via API, restart after config edits, bounded polls).
Profiles: `gw mock`. **Simulated**: mock-vllm A (`:18021`) and B (`:18022`) stand in for two GPU replicas — deterministic, fixed `usage` per call (see `mock/README.md`), unique response ids, fault API `/admin/fault` (`error_rate`, `latency`, ...). Real: LiteLLM router, Postgres spend, Valkey. llama.cpp is not running in this module (the "small model" fallback target is a second mock-served group).

## Starting state

`prepare-lab.sh` converges `gw mock`, resets mock faults/stats, seeds a per-learner **variant** (prices, usage table, capacity numbers in `lab/PRICES.md` and `lab/CAPACITY.md`, generated — read them, do not edit), and points LiteLLM at `lab/litellm/config.yaml`.

```bash
./prepare-lab.sh
curl -s localhost:18040/health/liveliness
curl -s localhost:18021/admin/stats | jq .     # per-backend counters (A); B is :18022
```

## Ownership

| Path | Status |
|---|---|
| `lab/litellm/config.yaml` | yours — tasks 5.1-5.4 (prices), 5.6 (starter: models and one existing fallback entry, default router settings) |
| `lab/provision.sh` | yours — tasks 5.4, 5.5 (idempotent, writes `lab/out/keys.env`) |
| `lab/answers/spend.env` | yours — task 5.4 |
| `lab/answers/agent-limits.env` | yours — task 5.5 |
| `lab/PRICES.md`, `lab/CAPACITY.md` (generated per learner), `lab/out/` (written by your provision.sh), module scripts, `platform/`, `mock/` | given — do not modify |

Groups in the starter config (simulated engines: A has a 32 000-token window, B only 2 000, both 8 sequence slots):

| Group | Deployments | Used in |
|---|---|---|
| `chat` | A and B | 5.1 (weighted split), 5.4 (prices), 5.5 chat users' `chat` alias |
| `pool` | A and B | 5.3 (cooldown) |
| `ha`, `ha-backup` | A / B | 5.2 (fallback) |
| `small`, `big` | B / A | 5.6 (context window) |
| `shared` | A | 5.5 (the pool chat users and the agent share) |

Tips: after each config edit restart the gateway and send a few requests; read response headers (`curl -i`: `x-litellm-model-id`, `x-litellm-attempted-fallbacks` if present) and the mock counters to see *who actually served* a request.

---

## Task 5.1 — Load balancing with weights

**Goal:** send the canary share given in `lab/PRICES.md` (20-30 % depending on your variant) of group `chat` to deployment A (a new engine version) and the rest to B.

1. Decide the routing strategy and the knob that creates a weighted split. Why not `latency-based-routing` for GPU replicas?
2. Set stable `model_info.id`s (`chat-a`, `chat-b`) and the weights in `lab/litellm/config.yaml`.
3. Send 200 requests and count per backend with `/admin/stats`. What range is normal for n=200 at your p? (compute σ before you decide a threshold).

**Success criteria**
- `5.1.1` 200 verify-sent sequential requests on `chat` return 200.
- `5.1.2` Backend A served your canary share of the 200 within 3.2 σ of the binomial expectation (a weighted split, not 50/50 nor all-to-one).
- `5.1.3` The two `chat` deployments have ids `chat-a` (A) and `chat-b` (B) in `/model/info`, and responses carry one of them in `x-litellm-model-id`.

## Task 5.2 — Fallback A -> B

**Goal:** if A fails, clients of group `ha` still get answers from B's group `ha-backup`; if A is healthy, B is untouched.

1. Configure fallbacks from `ha` to `ha-backup` (router settings).
2. Try it yourself: `curl -X POST :18021/admin/fault -d '{"error_rate":1.0}'`, then request `ha`. Look at the headers and at B's counter. Reset with DELETE.
3. Think: what does the client not see? How would you notice the degradation in production?

**Success criteria**
- `5.2.1` With A failing 100 %, 10 sequential requests on `ha` all return 200 and B's counter rises by at least 10.
- `5.2.2` With A healthy (control), 10 requests on `ha` return 200 and B's counter does not move.
- `5.2.3` With both A and B failing (verify injects `error_rate=1.0` on both), the client gets a clean 5xx within 60 s, not a hang.

## Task 5.3 — Cooldown

**Goal:** a broken replica stops receiving traffic quickly, a recovered one comes back.

1. In group `pool` (A and B, no weights) with A failing 100 %, the default settings still send A several requests. Measure: 20 sequential requests, how many hit A?
2. Tune `allowed_fails` and `cooldown_time` (and `num_retries` so users do not see errors) so that at most 3 of 20 sequential requests reach the failing A during the cooldown, while every client request still returns 200.
3. Reset the fault and show that A serves again after the cooldown.

**Success criteria**
- `5.3.1` With A failing, 20 sequential requests on `pool`: all 200, A's counter rose by at most 3.
- `5.3.2` After the fault is removed, A serves requests again within 75 s (bounded poll) — the cooldown must not be too long.
- `5.3.3` Group `ha` still answers 200 when healthy (your tuning did not break another group).

## Task 5.4 — Cost map and budget

**Goal:** per-call prices from your internal price list, exact spend, and a budget that stops a key.

1. `lab/PRICES.md` (generated, per learner) lists prompt/completion prices for group `chat` and the fixed usage the mock returns per call. Put the prices in `model_info` of **both** `chat` deployments.
2. Hand-compute the spend of exactly 20 successful calls and write it in `lab/answers/spend.env` as `SPEND_20=<decimal>`. Template value is rejected.
3. In `provision.sh` create key `lab-budget` with `max_budget` equal to the value in `PRICES.md` (a few calls' worth) and no rate limits; write `KEY_BUDGET`.
4. Send sequential requests with that key. Which status do you get once spend passes the budget, and how many calls were allowed? Check `/key/info` spend after the flush delay.

**Success criteria**
- `5.4.1` After verify sends exactly 20 sequential requests with a fresh key and the flush barrier passes, `/key/info` spend equals the hand-computed value (relative tolerance 1e-7).
- `5.4.2` `SPEND_20` in `spend.env` equals the same number (not the shipped template).
- `5.4.3` `lab-budget` returns 200 until its budget is passed, then HTTP 422 with error type `budget_exceeded` within a bounded number of sequential requests (at most one overshoot call).
- `5.4.4` A control key without budget keeps returning 200 during the same period.

## Task 5.5 — Chat vs agent separation

**Goal:** a looping agent cannot starve chat users.

1. `lab/CAPACITY.md` gives, per learner, the pool's concurrent slots (8), the slots reserved for chat R, the agent's normal calls per minute and tokens per call. Compute the maximum parallel requests the agent key may have and write it in `lab/answers/agent-limits.env`: `MAX_PARALLEL=` and `AGENT_TPM=` (a TPM that allows the agent's normal rate but not 10x).
2. In `provision.sh` create teams `chat-team` and `agent-team` and keys `lab-chat-user` (RPM only) and `lab-agent` (parallel + TPM limits). Write `KEY_CHAT_USER`, `KEY_AGENT`.
3. Think about it as Little's law: why is an RPM limit alone the wrong tool for the agent?

**Success criteria**
- `5.5.1` Verify runs a looping agent (8 parallel workers for about 15 s, with the pool's engine answering after a simulated 1.5 s per request) on group `shared` with `lab-agent` while `lab-chat-user` sends sequential requests on `shared`: all chat requests return 200.
- `5.5.2` Peak concurrency at the backend (sampled from mock stats) never exceeds `MAX_PARALLEL` + 1 chat request, and the agent receives 429s for the excess.
- `5.5.3` `answers/agent-limits.env` matches the key's real limits and the capacity numbers (variant-bound).
- `5.5.4` The slowest chat request while the agent runs is at most 1.5 x the idle latency + 0.3 s.

## Task 5.6 — Troubleshooting: the fallback that never fires

**Goal:** make long prompts succeed through a bigger-window group.

Story: group `small` (context 2 000 tokens) serves cheap chat; a `fallbacks: [{small: [big]}]` entry exists in the starter config ("so overflow goes to the big model") but a 6 000-token prompt returns an error to the user. The colleague who wrote it says "fallbacks are configured". Do not just delete the small model.

1. Reproduce: send a long prompt to `small`. Which HTTP status and error type do you get? Compare with the mock-induced 500 case from task 5.2 — which of the two triggers the existing fallback?
2. Fix the router config so the long prompt is answered by `big` while short prompts still go to `small`.

**Success criteria**
- `5.6.1` A long prompt on `small` returns 200 and is served by `big` (backend counters / model id).
- `5.6.2` A short prompt on `small` is still served by the `small` backend (control: you did not route everything to `big`).
- `5.6.3` The generic 5xx fallback from task 5.2 still works.

## Wrap-up

`./verify.sh` (FAIL messages name the cause and the concept, never the answer); `./cleanup.sh` removes mock faults, keys created by provision and runtime state, never `lab/`.
