# 05 — Hints (H1 nudge, H2 concept, H3 partial, H4 full)

## 5.1 weighted split
- H1: Which setting decides how the router picks among deployments of one group? Read the share in `lab/PRICES.md`.
- H2: `simple-shuffle` is weighted when deployments carry a `weight`; ids come from `model_info.id`. Expect a random result: compute the spread before judging.
- H3: `litellm_params.weight` on each of the two `chat` entries, in the ratio target : (100 - target); `model_info.id: chat-a` / `chat-b`.
- H4: solution `litellm/config.yaml` (weights are substituted per learner).

## 5.2 fallback
- H1: Group `ha` has one deployment. When it fails, what else can the router try?
- H2: Fallbacks map a group name to a list of group names, in `router_settings.fallbacks`.
- H3: `fallbacks: [{"small": ["big"]}, {"ha": ["ha-backup"]}]` - keep the existing entry.
- H4: solution config.

## 5.3 cooldown
- H1: Count how many requests reach A during the 20 sequential calls with the defaults.
- H2: A deployment is cooled down after more than `allowed_fails` failures per minute, for `cooldown_time` seconds; retries make the failure invisible to the client.
- H3: Lower `allowed_fails` (1), raise `cooldown_time` (e.g. 30), keep `num_retries` at 2 or more. These are global `router_settings`.
- H4: solution config.

## 5.4 prices and budget
- H1: Where does LiteLLM take a per-token price for a self-hosted model from?
- H2: `model_info.input_cost_per_token/output_cost_per_token`, on EVERY deployment of the group. Spend = prompt x in + completion x out.
- H3: 20 x (PT x P_IN + CT x P_OUT) with PT/CT/prices from `PRICES.md`; write the decimal into `spend.env`. Budget key: `max_budget` from `PRICES.md`.
- H4: solution `provision.sh` (`gen lab-budget ...`) and config.

## 5.5 separation
- H1: Chat needs R of 8 slots. How many may the agent hold at once?
- H2: `max_parallel_requests` caps in-flight requests (Little's law: concurrency = rate x latency); `tpm_limit` caps tokens; RPM alone does not.
- H3: `MAX_PARALLEL = 8 - R`; `AGENT_TPM` between normal_cpm x tokens_per_call and ten times that; keys in separate teams; chat key RPM only.
- H4: solution `provision.sh`.

## 5.6 context-window fallback
- H1: Send the long prompt to `small` and read the status code and error type.
- H2: A context-length error is a 400 `ContextWindowExceededError`, handled by its own fallback list.
- H3: `router_settings.context_window_fallbacks: [{"small": ["big"]}]`.
- H4: solution config.
