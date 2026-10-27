#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="${MASTER:-sk-aiinfra-master}"; GW="${GATEWAY:-http://127.0.0.1:18040}"
mkdir -p "$HERE/out"; : > "$HERE/out/keys.env"
api() { curl -sS --max-time 30 -X "$1" "$GW$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
gen() {  # gen ALIAS JSON-extra -> key ; replaces an existing key with that alias
  api POST /key/delete "{\"key_aliases\":[\"$1\"]}" >/dev/null
  api POST /key/generate "$(jq -nc --arg a "$1" --argjson e "$2" '{key_alias:$a}+$e')" | jq -r '.key'
}
echo "KEY_CHAT_ONLY=$(gen lab-chat-only '{"models":["chat"]}')" >> "$HERE/out/keys.env"
echo "KEY_LIMITED=$(gen lab-limited '{"rpm_limit":2}')" >> "$HERE/out/keys.env"
echo "KEY_TPM=$(gen lab-tpm '{"tpm_limit":50}')" >> "$HERE/out/keys.env"
# team lab-team (chat only) + key without own models
old=$(api GET "/team/list" | jq -r '.[]? | select(.team_alias=="lab-team") | .team_id')
[ -n "$old" ] && api POST /team/delete "{\"team_ids\":[\"$old\"]}" >/dev/null
tid=$(api POST /team/new '{"team_alias":"lab-team","models":["chat"]}' | jq -r '.team_id')
echo "KEY_TEAM=$(gen lab-team-key "{\"team_id\":\"$tid\"}")" >> "$HERE/out/keys.env"
# 4.7: the data-science team lacks embed -> add it to the TEAM (narrowest fix; key keeps working)
ds=$(api GET "/team/list" | jq -r '.[]? | select(.team_alias=="lab-ds") | .team_id')
api POST /team/update "{\"team_id\":\"$ds\",\"models\":[\"chat\",\"embed\"]}" >/dev/null
exit 0
