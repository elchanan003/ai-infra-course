#!/usr/bin/env bash
# GIVEN. SIMULATED stand-in for the NVIDIA device plugin / GPU Operator reacting to the time-slicing ConfigMap (kind has no GPU).
#   gpu-plugin-sim.sh sync    read ConfigMap gpu-operator/time-slicing-config and publish the extended resources it implies on every
#                             node labelled aiinfra.io/sim-plugin=true (node-status patch, like platform/k8s.sh gpu-patch)
#   gpu-plugin-sim.sh reset   remove everything this script published
# Rules (a simplification of the real plugin): physical GPUs = node label nvidia.com/gpu.count. Without a ConfigMap, nvidia.com/gpu = physical.
# With one, the plugin advertises exactly the resources named in sharing.timeSlicing.resources, each physical x replicas; if nvidia.com/gpu is not
# among them the node advertises nvidia.com/gpu = 0 (the real plugin renames/hides the resource; the details differ per version - read the docs).
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
PLAT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../platform" && pwd)"
PY="$PLAT/.venv/bin/python"; [ -x "$PY" ] || PY=python3
exec "$PY" - "${1:-sync}" <<'PYEOF'
import json, subprocess, sys, yaml
mode = sys.argv[1]
CTX = ["kubectl", "--context", "kind-aiinfra"]
def k(*a, inp=None):
    return subprocess.run(CTX + list(a), capture_output=True, text=True, input=inp)
def esc(n): return n.replace("~", "~0").replace("/", "~1")
nodes = json.loads(k("get", "nodes", "-l", "aiinfra.io/sim-plugin=true", "-o", "json").stdout or '{"items":[]}')["items"]
cm = k("-n", "gpu-operator", "get", "cm", "time-slicing-config", "-o", "json")
resources = None
if cm.returncode == 0 and mode == "sync":
    data = json.loads(cm.stdout).get("data") or {}
    for v in data.values():
        try:
            resources = ((yaml.safe_load(v) or {}).get("sharing") or {}).get("timeSlicing", {}).get("resources") or []
        except Exception as e:
            print(f"gpu-plugin-sim: cannot parse the ConfigMap: {e}"); sys.exit(1)
        break
for n in nodes:
    name = n["metadata"]["name"]
    phys = int((n["metadata"].get("labels") or {}).get("nvidia.com/gpu.count", "0"))
    prev = [x for x in ((n["metadata"].get("annotations") or {}).get("aiinfra.io/sim-extra", "")).split(",") if x]
    adv = {}
    if mode == "sync":
        if resources is None: adv["nvidia.com/gpu"] = phys
        else:
            for r in resources: adv[r["name"]] = phys * int(r.get("replicas", 1))
        adv.setdefault("nvidia.com/gpu", 0)
    ops = []
    for x in prev:
        if x not in adv:
            for sec in ("capacity", "allocatable"): ops.append({"op": "remove", "path": f"/status/{sec}/{esc(x)}"})
    if mode == "reset": adv = {}; ops += [{"op": "remove", "path": f"/status/{s}/nvidia.com~1gpu"} for s in ("capacity", "allocatable")]
    for r, v in adv.items():
        for sec in ("capacity", "allocatable"): ops.append({"op": "add", "path": f"/status/{sec}/{esc(r)}", "value": str(v)})
    for op in ops:                      # one op at a time: a missing key to remove must not abort the rest
        k("patch", "node", name, "--subresource=status", "--type=json", "-p", json.dumps([op]))
    extra = ",".join(sorted(r for r in adv if r != "nvidia.com/gpu"))
    k("annotate", "node", name, "--overwrite", f"aiinfra.io/sim-extra={extra}")
    print(f"gpu-plugin-sim: {name}: " + (", ".join(f"{r}={v}" for r, v in adv.items()) if adv else "reset") + " (simulated)")
PYEOF
