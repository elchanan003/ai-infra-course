#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution over it, fill the live per-learner answers, restart the gateway with the solution config.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/_common.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
chmod -R a+rX "$MODULE_DIR/lab"
live=$(pg "select count(*) from \"LiteLLM_VerificationToken\" where key_alias like 'legacy-%'")
tok=$(env_kv "$STATE/variant.env" LAB_TOKEN)
sed -i "s/__LEGACY__/${live:-0}/" "$LAB/answers/durability.env"
sed -i "s/__TOKEN__/$tok/" "$LAB/answers/network.env"
gw_restart || echo "apply-solution: gateway did not come back"
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), gateway restarted with the solution config"
