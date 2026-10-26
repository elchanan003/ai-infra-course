#!/usr/bin/env bash
# Given. ./replicas.sh 2  -> second LiteLLM replica on :18041 (same config dir, DB, Valkey); ./replicas.sh 1 -> only :18040.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LITELLM_CONFIG_DIR="$MODULE_DIR/lab/litellm"; chmod -R a+rX "$LITELLM_CONFIG_DIR"
case "${1:-}" in
  2) exec "$MODULE_DIR/../../platform/stack.sh" up gw gw2 llm mock ;;
  1) exec "$MODULE_DIR/../../platform/stack.sh" up gw llm mock ;;
  *) echo "usage: replicas.sh 1|2"; exit 2 ;;
esac
