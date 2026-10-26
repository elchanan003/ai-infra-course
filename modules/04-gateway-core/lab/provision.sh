#!/usr/bin/env bash
# Lab 04 — issue the gateway keys and teams (yours). Must be IDEMPOTENT: a second run must exit 0.
# Writes lab/out/keys.env with:
#   KEY_CHAT_ONLY  (4.2)   KEY_LIMITED, KEY_TPM  (4.3)   KEY_TEAM  (4.6)
# Task 4.7 (team lab-ds) is fixed here too, with an admin call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="${MASTER:-sk-aiinfra-master}"; GW="${GATEWAY:-http://127.0.0.1:18040}"
mkdir -p "$HERE/out"; : > "$HERE/out/keys.env"

api() {  # api POST /key/generate '{"key_alias":"x"}'  -> JSON body
  curl -sS --max-time 30 -X "$1" "$GW$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}
}

# TODO 4.2: key lab-chat-only (models: chat only). Delete an existing key with that alias first, so reruns do not fail.
# TODO 4.3: key lab-limited (rpm_limit 2) and key lab-tpm (low tpm_limit)
# TODO 4.6: team lab-team (models: chat) and key lab-team-key that belongs to it (no models on the key)
# TODO 4.7: fix team lab-ds (see lab.md)
# Then append each key to $HERE/out/keys.env as NAME=value
