#!/usr/bin/env bash
# Module 04 cleanup: remove lab keys/teams, client container + network, runtime state, stop the stack. Never touches lab/ sources.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if docker ps --format '{{.Names}}' | grep -qx "$PGC"; then
  if curl -fsS --max-time 3 "$GW/health/liveliness" >/dev/null 2>&1; then
    for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'legacy-%' or key_alias like 'lab-%'"); do
      admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null 2>&1
    done
  fi
  pg "delete from \"LiteLLM_VerificationToken\" where key_alias like 'legacy-%' or key_alias like 'lab-%'" >/dev/null
  pg "delete from \"LiteLLM_TeamTable\" where team_alias like 'lab-%'" >/dev/null
fi
for p in A B; do mock_fault "$p" DELETE >/dev/null 2>&1; done
docker rm -f "$CLIENT_C" >/dev/null 2>&1
docker network rm "$CLIENT_NET" >/dev/null 2>&1
rm -rf "$STATE" "$LAB/out"
mkdir -p "$LAB/out"
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
echo "cleanup: lab keys/teams removed, client container+network removed, stack down"
