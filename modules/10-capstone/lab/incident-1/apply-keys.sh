#!/usr/bin/env bash
# GIVEN (do not edit). Applies keys.yaml to the gateway: POST /key/update for every alias listed. Idempotent.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
PY="$D/../../../../platform/.venv/bin/python"; [ -x "$PY" ] || PY=python3
exec "$PY" - "$D" <<'PYEOF'
import json, os, sys, urllib.request, yaml
d = sys.argv[1]
env = dict(l.strip().split("=", 1) for l in open(os.path.join(d, "keys.env")) if "=" in l and not l.startswith("#"))
tok = {env["CHAT_ALIAS"]: env["CHAT_KEY"], env["AGENT_ALIAS"]: env["AGENT_KEY"]}
gw = os.environ.get("LITELLM_URL", "http://127.0.0.1:18040"); master = os.environ.get("LITELLM_KEY", "sk-aiinfra-master")
spec = (yaml.safe_load(open(os.path.join(d, "keys.yaml"))) or {}).get("keys") or {}
rc = 0
for alias, lim in spec.items():
    if alias not in tok:
        print(f"apply-keys: unknown alias {alias}"); rc = 1; continue
    body = {"key": tok[alias]}
    for f in ("rpm_limit", "tpm_limit", "max_parallel_requests"):
        if isinstance(lim, dict) and lim.get(f) is not None:
            body[f] = int(lim[f])
    req = urllib.request.Request(gw + "/key/update", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + master, "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).read(); print(f"apply-keys: {alias} -> " + ", ".join(f"{k}={v}" for k, v in body.items() if k != "key"))
    except Exception as e:
        print(f"apply-keys: {alias} FAILED: {e}"); rc = 1
sys.exit(rc)
PYEOF
