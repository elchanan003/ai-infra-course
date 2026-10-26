#!/usr/bin/env bash
# VALIDATION ONLY: back up lab/, copy the reference solution, compute the per-learner dissect values the way the lab defines them,
# then run the solution's provision.sh and connect.sh (solution-side apply steps).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/_common.sh"
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MODULE_DIR/lab" "$MODULE_DIR/lab.bak-$ts"
cp -a "$TUTOR/solution/." "$MODULE_DIR/lab/"
J="$LAB/captured/agent-request.json"; rid=$(cat "$STATE/captured.id")
LOGGED=$(pg "select prompt_tokens from \"LiteLLM_SpendLogs\" where request_id='$rid'")
vals=$("$PY" - "$J" "$LOGGED" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); L=float(sys.argv[2]); m=r["messages"]; t=r.get("tools",[])
sc=len(m[0]["content"]); tch=len(json.dumps(t,separators=(",",":"))); rest=sum(len(x.get("content") or "") for x in m[1:]); tot=sc+tch+rest
a=sum(1 for x in m if x["role"]=="assistant"); P=L*(sc+tch)/tot; d=(L-P)/a
print(sc,len(t),tch,len(m),sum(1 for x in m if x["role"]=="tool"),int(L),round(25*P+d*25*26/2))
PY
)
read -r SC TC TCH MS TR LOG S25 <<<"$vals"
sed -i "s/__SC__/$SC/; s/__TC__/$TC/; s/__TCH__/$TCH/; s/__MS__/$MS/; s/__TR__/$TR/; s/__LOG__/$LOG/; s/__S25__/$S25/" "$LAB/answers/dissect.env"
chmod -R a+rX "$LAB"; chmod +x "$LAB"/provision.sh "$LAB"/openwebui/connect.sh "$LAB"/aider/run.sh
( cd "$LAB" && bash ./provision.sh ) && ( cd "$LAB/openwebui" && bash ./connect.sh ) || echo "apply-solution: provision/connect failed"
echo "apply-solution: lab/ replaced (backup: lab.bak-$ts), keys provisioned, Open WebUI connected"
