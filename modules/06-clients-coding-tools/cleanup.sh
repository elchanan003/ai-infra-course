#!/usr/bin/env bash
# Module 06 cleanup: remove lab keys, Open WebUI container + volume, generated files, state; stop the stack. Never touches lab/ sources.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if docker ps --format '{{.Names}}' | grep -qx "$PGC"; then
  curl -fsS --max-time 3 "$GW/health/liveliness" >/dev/null 2>&1 && for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%'"); do
    admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null 2>&1; done
  pg "delete from \"LiteLLM_VerificationToken\" where key_alias like 'lab-%'" >/dev/null
fi
reset_mocks 2>/dev/null
"$PLATFORM_DIR/stack.sh" reset-openwebui >/dev/null 2>&1
rm -rf "$STATE" "$LAB/captured/agent-request.json" "$LAB/captured/README.txt" "$LAB/aider/repo"
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
echo "cleanup: keys removed, Open WebUI container+volume removed, generated files removed, stack down"
