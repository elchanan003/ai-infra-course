#!/usr/bin/env bash
# Lab 04 task 4.8 (yours): make the gateway the ONLY path from the client container to the backends.
# Containers: aiinfra-lab04-client (the "client"), gateway aiinfra-litellm-1 (and -2 if running).
# Networks: aiinfra (backends + gateway + client, as given), aiinfra-lab04-client (client-only network).
# Must be idempotent. verify.sh runs it, then probes from inside the client container.
set -uo pipefail
# TODO 4.8
