#!/usr/bin/env bash
# Lab 05 — keys (yours). IDEMPOTENT. Writes lab/out/keys.env with KEY_BUDGET (5.4), KEY_CHAT_USER and KEY_AGENT (5.5).
# Inputs: lab/PRICES.md (budget) and lab/CAPACITY.md (limits) - generated per learner.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="${MASTER:-sk-aiinfra-master}"; GW="${GATEWAY:-http://127.0.0.1:18040}"
mkdir -p "$HERE/out"; : > "$HERE/out/keys.env"
api() { curl -sS --max-time 30 -X "$1" "$GW$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
# TODO 5.4: key lab-budget (max_budget from PRICES.md, no rate limits)
# TODO 5.5: teams chat-team and agent-team; keys lab-chat-user (rpm only) and lab-agent (parallel + tpm), each in its team
# Append NAME=value lines to $HERE/out/keys.env
