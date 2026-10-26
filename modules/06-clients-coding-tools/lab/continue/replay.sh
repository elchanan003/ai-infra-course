#!/usr/bin/env bash
# Given. ./replay.sh  -> JSON of the replayed chat + autocomplete requests.
exec "$(dirname "${BASH_SOURCE[0]}")/../../../../platform/.venv/bin/python" "$(dirname "${BASH_SOURCE[0]}")/replay.py" "${1:-$(dirname "${BASH_SOURCE[0]}")/config.yaml}"
