#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution, fill per-learner numbers, restart the gateway.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/_common.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
CAN=$(vget CANARY_PCT); PIN=$(vget P_IN); POUT=$(vget P_OUT); K=$(vget K_ALLOWED); R=$(vget R_CHAT); CPM=$(vget NORMAL_CPM)
PT=$(env_kv "$STATE/usage.env" PT); CT=$(env_kv "$STATE/usage.env" CT)
BUDGET=$(python3 -c "print('%.10g' % (($K-0.5)*($PT*$PIN+$CT*$POUT)))")
SP20=$(python3 -c "print(repr(20*($PT*$PIN+$CT*$POUT)))")
TPM=$(( CPM*(PT+CT)*3 ))
sub() { sed -i "s/__WA__/$CAN/g; s/__WB__/$((100-CAN))/g; s/__PIN__/$PIN/g; s/__POUT__/$POUT/g; s/__BUDGET__/$BUDGET/g; s/__MAXPAR__/$((8-R))/g; s/__TPM__/$TPM/g; s/__SPEND20__/$SP20/g" "$1"; }
for f in litellm/config.yaml provision.sh answers/spend.env answers/agent-limits.env; do sub "$MODULE_DIR/lab/$f"; done
chmod -R a+rX "$MODULE_DIR/lab"
gw_restart || echo "apply-solution: gateway did not come back"
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), gateway restarted"
