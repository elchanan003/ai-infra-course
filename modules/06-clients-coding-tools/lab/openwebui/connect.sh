#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$HERE/env.sample"
tok=$(curl -sS "$OWUI_URL/api/v1/auths/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$OWUI_ADMIN_EMAIL\",\"password\":\"$OWUI_ADMIN_PASSWORD\"}" | jq -r .token)
[ -n "$tok" ] && [ "$tok" != null ] || { echo "sign-in failed" >&2; exit 1; }
post() { curl -sS -f -o /dev/null -X POST "$OWUI_URL$1" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$2"; }
post /openai/config/update "$(jq -nc --arg u "$GATEWAY_FROM_CONTAINERS" --arg k "$LAB_KEY_OWUI" '{ENABLE_OPENAI_API:true,OPENAI_API_BASE_URLS:[$u],OPENAI_API_KEYS:[$k],OPENAI_API_CONFIGS:{"0":{enable:true}}}')" || exit 1
post /ollama/config/update '{"ENABLE_OLLAMA_API":false,"OLLAMA_BASE_URLS":[],"OLLAMA_API_CONFIGS":{}}' || exit 1
exit 0
