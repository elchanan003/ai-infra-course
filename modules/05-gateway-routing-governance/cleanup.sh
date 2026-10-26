#!/usr/bin/env bash
# Module 05 cleanup: remove lab keys/teams, reset mock faults, remove generated files and state, stop the stack. Never touches lab/ sources.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if docker ps --format '{{.Names}}' | grep -qx "$PGC"; then
  if curl -fsS --max-time 3 "$GW/health/liveliness" >/dev/null 2>&1; then
    for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%' or key_alias like 'verify-%'"); do
      admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null 2>&1; done
  fi
  pg "delete from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%' or key_alias like 'verify-%'" >/dev/null
  pg "delete from \"LiteLLM_TeamTable\" where team_alias in ('chat-team','agent-team')" >/dev/null
fi
reset_mocks 2>/dev/null
rm -rf "$STATE" "$LAB/out" "$LAB/PRICES.md" "$LAB/CAPACITY.md"; mkdir -p "$LAB/out"
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
echo "cleanup: keys/teams removed, mock faults reset, generated files removed, stack down"
