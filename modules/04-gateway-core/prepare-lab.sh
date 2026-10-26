#!/usr/bin/env bash
# Module 04 prepare: profiles gw llm mock; seeds per-learner state (legacy keys, team lab-ds + key); points LiteLLM at lab/litellm;
# starts the client container for task 4.8. Idempotent; never touches lab/ files or answers.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
chmod -R a+rX "$LAB"
# per-learner variant (stable across prepares until cleanup)
if [ ! -f "$STATE/variant.env" ]; then
  { echo "LEGACY_N=$(( RANDOM % 7 + 3 ))"; echo "LAB_TOKEN=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"; } > "$STATE/variant.env"
fi
LEGACY_N=$(env_kv "$STATE/variant.env" LEGACY_N); LAB_TOKEN=$(env_kv "$STATE/variant.env" LAB_TOKEN)

# 1. seed with a database-enabled platform config (never the learner's)
stack_up "$MODULE_DIR/env/seed" gw llm mock >/dev/null || { echo "prepare-lab: stack did not come up (seed config)"; exit 1; }
gw_wait "$GW" 120 || { echo "prepare-lab: gateway not live"; exit 1; }
# clean previous runtime keys/teams
for al in $(pg "select key_alias from \"LiteLLM_VerificationToken\" where key_alias like 'legacy-%' or key_alias like 'lab-%'"); do
  admin POST /key/delete "$(jq -nc --arg a "$al" '{key_aliases:[$a]}')" >/dev/null
done
for t in $(pg "select team_id from \"LiteLLM_TeamTable\" where team_alias like 'lab-%'"); do
  admin POST /team/delete "$(jq -nc --arg t "$t" '{team_ids:[$t]}')" >/dev/null
done
for i in $(seq 1 "$LEGACY_N"); do
  admin POST /key/generate "$(jq -nc --arg a "legacy-$i" '{key_alias:$a,models:["chat"]}')" >/dev/null
done
tid=$(admin POST /team/new '{"team_alias":"lab-ds","models":["chat"]}' | jq -r '.team_id')
dskey=$(admin POST /key/generate "$(jq -nc --arg t "$tid" '{key_alias:"lab-ds-key",team_id:$t}')" | jq -r '.key')
{ echo "KEY_DS=$dskey"; echo "TEAM_DS=$tid"; } > "$STATE/seed.env"

# 2. learner config
stack_up "$LAB/litellm" gw llm mock >/dev/null || { echo "prepare-lab: stack did not come up with lab/litellm (config.yaml invalid? ../../platform/stack.sh logs litellm)"; exit 1; }

# 3. client container + client-only network (task 4.8)
docker rm -f "$CLIENT_C" >/dev/null 2>&1
docker network inspect "$CLIENT_NET" >/dev/null 2>&1 || docker network create --label course=aiinfra --label module=04 "$CLIENT_NET" >/dev/null
docker run -d --name "$CLIENT_C" --label course=aiinfra --label module=04 --network aiinfra -e "LAB_TOKEN=$LAB_TOKEN" \
  --entrypoint sleep "$MOCK_IMAGE" infinity >/dev/null && docker network connect "$CLIENT_NET" "$CLIENT_C"
for p in A B; do mock_fault "$p" DELETE >/dev/null; done
rm -rf "$LAB/out"; mkdir -p "$LAB/out"
cat <<MSG
prepare-lab: ready.
  Gateway   http://127.0.0.1:18040  (config: lab/litellm/config.yaml; restart: ../../platform/stack.sh compose restart litellm)
  Master key in lab/env.sample; client container for 4.8: $CLIENT_C
MSG
