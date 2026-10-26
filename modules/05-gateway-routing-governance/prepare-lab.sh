#!/usr/bin/env bash
# Module 05 prepare: profiles gw mock (mock A/B configured by this module), LiteLLM on lab/litellm, per-learner variant
# (lab/PRICES.md, lab/CAPACITY.md generated). Idempotent; never touches your lab/ files.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ ! -f "$STATE/variant.env" ]; then
  pins=(2e-6 3e-6 5e-6 1e-5); pouts=(4e-6 6e-6 1e-5 2e-5)
  i=$((RANDOM % 4)); j=$((RANDOM % 4))
  { echo "CANARY_PCT=$(( (RANDOM % 3) * 5 + 20 ))"; echo "P_IN=${pins[$i]}"; echo "P_OUT=${pouts[$j]}"
    echo "K_ALLOWED=$(( RANDOM % 5 + 5 ))"; echo "R_CHAT=$(( RANDOM % 4 + 2 ))"; echo "NORMAL_CPM=$(( (RANDOM % 4 + 3) * 4 ))"; } > "$STATE/variant.env"
fi
chmod -R a+rX "$LAB"
stack_up >/dev/null || { echo "prepare-lab: stack did not come up (config.yaml invalid? ../../platform/stack.sh logs litellm)"; exit 1; }
reset_mocks
# measure the usage of the standard call directly at mock A (deterministic by the mock's token convention)
std=$(curl -sS --max-time 20 "http://127.0.0.1:18021/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"chat","messages":[{"role":"user","content":"price-check"}],"max_tokens":20}' | jq -c '.usage')
PT=$(echo "$std" | jq -r .prompt_tokens); CT=$(echo "$std" | jq -r .completion_tokens)
[ -n "$PT" ] && [ "$PT" != null ] || { echo "prepare-lab: mock-vllm A did not answer"; exit 1; }
{ echo "PT=$PT"; echo "CT=$CT"; } > "$STATE/usage.env"
P_IN=$(vget P_IN); P_OUT=$(vget P_OUT); K=$(vget K_ALLOWED); R=$(vget R_CHAT); CPM=$(vget NORMAL_CPM); CAN=$(vget CANARY_PCT)
cost=$(python3 -c "print(repr($PT*$P_IN+$CT*$P_OUT))")
budget=$(python3 -c "print('%.10g' % (($K-0.5)*$PT*$P_IN+($K-0.5)*$CT*$P_OUT))")
cat > "$LAB/PRICES.md" <<MD
# Your internal price list (generated for you - do not edit)

| | per token |
|---|---|
| prompt (input) | $P_IN |
| completion (output) | $P_OUT |

Standard call used by the checks: one user message "price-check", \`max_tokens: 20\`. The simulated backend reports
**$PT prompt tokens + $CT completion tokens** for it (every call, both deployments).

Task 5.4: the key \`lab-budget\` must have \`max_budget: $budget\`.
Canary share (task 5.1): group \`chat\` must send **$CAN %** of its traffic to deployment A and the rest to B.
MD
cat > "$LAB/CAPACITY.md" <<MD
# Capacity of the shared pool (generated for you - do not edit)

- Pool "shared" = simulated engine A: **8** concurrent sequence slots.
- Chat users need **$R** of them to stay responsive; the agent may use the rest.
- The agent's normal rate: **$NORMAL_CPM** calls per minute; each call (standard call, see PRICES.md) uses $((PT+CT)) tokens.
- Chat latency target while the agent runs: at most 1.5 x the idle latency plus 0.3 s.
MD
rm -rf "$LAB/out"; mkdir -p "$LAB/out"
for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%'"); do admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null; done
for t in $(pg "select team_id from \"LiteLLM_TeamTable\" where team_alias in ('chat-team','agent-team')"); do admin POST /team/delete "$(jq -nc --arg t "$t" '{team_ids:[$t]}')" >/dev/null; done
echo "prepare-lab: ready. Gateway http://127.0.0.1:18040, mock A :18021, mock B :18022. Read lab/PRICES.md and lab/CAPACITY.md."
