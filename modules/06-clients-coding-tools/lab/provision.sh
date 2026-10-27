#!/usr/bin/env bash
# Lab 06 — gateway keys for the clients (yours). IDEMPOTENT. Key VALUES are fixed in env.sample (use the "key" field of /key/generate),
# so the files that embed them (Open WebUI connection, Aider env, Continue config) stay valid when this script runs again.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/env.sample"
api() { curl -sS --max-time 30 -X "$1" "$GATEWAY$2" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
# TODO 6.1: lab-owui   (models chat, embed; a sane rpm_limit)           value $LAB_KEY_OWUI
# TODO 6.2: lab-aider  (model agent; small max_parallel_requests)       value $LAB_KEY_AIDER
# TODO 6.3: lab-continue-chat (model chat) and lab-continue-fim (model coder; high rpm, low tpm)
