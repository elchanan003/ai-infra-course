#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/env.sample"
api() { curl -sS --max-time 30 -X "$1" "$GATEWAY$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
gen() {  # gen ALIAS KEYVALUE JSON-extra
  api POST /key/delete "{\"key_aliases\":[\"$1\"]}" >/dev/null
  api POST /key/generate "$(jq -nc --arg a "$1" --arg k "$2" --argjson e "$3" '{key_alias:$a,key:$k}+$e')" >/dev/null
}
gen lab-owui          "$LAB_KEY_OWUI"          '{"models":["chat","embed"],"rpm_limit":120}'
gen lab-aider         "$LAB_KEY_AIDER"         '{"models":["agent"],"max_parallel_requests":2}'
gen lab-continue-chat "$LAB_KEY_CONTINUE_CHAT" '{"models":["chat"],"rpm_limit":60}'
gen lab-continue-fim  "$LAB_KEY_CONTINUE_FIM"  '{"models":["coder"],"rpm_limit":600,"tpm_limit":20000}'
exit 0
