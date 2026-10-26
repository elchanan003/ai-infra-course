#!/usr/bin/env bash
set -uo pipefail
C=aiinfra-lab04-client
# gateway joins the client-only network; the client leaves the backend network
for g in aiinfra-litellm-1 aiinfra-litellm-2-1; do
  docker inspect "$g" >/dev/null 2>&1 && ! docker inspect "$g" --format '{{json .NetworkSettings.Networks}}' | grep -q aiinfra-lab04-client && docker network connect aiinfra-lab04-client "$g"
done
docker inspect "$C" --format '{{json .NetworkSettings.Networks}}' | grep -q '"aiinfra"' && docker network disconnect aiinfra "$C"
exit 0
