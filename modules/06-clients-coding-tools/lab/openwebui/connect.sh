#!/usr/bin/env bash
# Lab 06 (yours) — configure Open WebUI through its admin API. IDEMPOTENT.
# Open WebUI: $OWUI_URL (host), the gateway as seen FROM the Open WebUI container: $GATEWAY_FROM_CONTAINERS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$HERE/env.sample"
# TODO 6.1: sign in as admin (POST /api/v1/auths/signin -> token), set the OpenAI connection (POST /openai/config/update), Ollama off
# TODO 6.5: the stored configuration may hold more than you set: read it back (GET /openai/config, GET /ollama/config)
