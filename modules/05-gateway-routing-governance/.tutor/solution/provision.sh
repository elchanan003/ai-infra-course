#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="${MASTER:-sk-aiinfra-master}"; GW="${GATEWAY:-http://127.0.0.1:18040}"
mkdir -p "$HERE/out"; : > "$HERE/out/keys.env"
api() { curl -sS --max-time 30 -X "$1" "$GW$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
gen() { api POST /key/delete "{\"key_aliases\":[\"$1\"]}" >/dev/null; api POST /key/generate "$(jq -nc --arg a "$1" --argjson e "$2" '{key_alias:$a}+$e')" | jq -r '.key'; }
team() { old=$(api GET /team/list | jq -r --arg a "$1" '.[]?|select(.team_alias==$a)|.team_id'); [ -n "$old" ] && api POST /team/delete "{\"team_ids\":[\"$old\"]}" >/dev/null
  api POST /team/new "$(jq -nc --arg a "$1" --argjson e "$2" '{team_alias:$a}+$e')" | jq -r '.team_id'; }
echo "KEY_BUDGET=$(gen lab-budget '{"max_budget":__BUDGET__}')" >> "$HERE/out/keys.env"
ct=$(team chat-team '{"models":["chat","shared"]}'); at=$(team agent-team '{"models":["shared"]}')
echo "KEY_CHAT_USER=$(gen lab-chat-user "{\"team_id\":\"$ct\",\"rpm_limit\":600}")" >> "$HERE/out/keys.env"
echo "KEY_AGENT=$(gen lab-agent "{\"team_id\":\"$at\",\"max_parallel_requests\":__MAXPAR__,\"tpm_limit\":__TPM__,\"rpm_limit\":600}")" >> "$HERE/out/keys.env"
exit 0
