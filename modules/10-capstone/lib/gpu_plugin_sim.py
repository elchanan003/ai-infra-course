#!/usr/bin/env python3
"""SIMULATION of the NVIDIA device plugin + time-slicing config, for incident 5 (kind has no GPUs and no plugin).
GIVEN - not a learner file.  usage: gpu_plugin_sim.py --once | --loop [SECONDS]
What it models (production: GPU Operator -> device-plugin DaemonSet -> kubelet device-plugin API):
  * a node advertises nvidia.com/gpu only while a Running pod of DaemonSet app=nvidia-device-plugin-sim (ns gpu-operator) is on it;
    capacity = physical GPUs (node annotation aiinfra.course/physical-gpus) x time-slicing replicas, otherwise 0;
  * replicas come from ConfigMap gpu-operator/time-slicing-config key "any" (sharing.timeSlicing.resources[]); only an entry whose
    name is exactly nvidia.com/gpu is applied, any other entry is ignored (replicas 1) - the plugin does not fail on unknown names;
  * GFD-style label nvidia.com/gpu.present=true follows the capacity.
It only patches node status/labels; scheduling is done by the real Kubernetes scheduler."""
import json, subprocess, sys, time
import yaml

CTX = "kind-aiinfra"

def k(*a, check=False):
    r = subprocess.run(["kubectl", "--context", CTX, *a], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""

def jget(*a):
    out = k(*a)
    try: return json.loads(out) if out else {}
    except ValueError: return {}

def replicas():
    cm = jget("-n", "gpu-operator", "get", "cm", "time-slicing-config", "-o", "json")
    try:
        cfg = yaml.safe_load(cm["data"]["any"]) or {}
        for r in cfg["sharing"]["timeSlicing"]["resources"]:
            if r.get("name") == "nvidia.com/gpu":
                return max(1, int(r.get("replicas", 1)))
    except Exception:
        pass
    return 1

def once():
    nodes = jget("get", "nodes", "-o", "json").get("items", [])
    pods = jget("-n", "gpu-operator", "get", "pods", "-l", "app=nvidia-device-plugin-sim", "-o", "json").get("items", [])
    running = set()
    for p in pods:
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in p.get("status", {}).get("conditions", []))
        if p.get("status", {}).get("phase") == "Running" and ready and not p["metadata"].get("deletionTimestamp"):
            running.add(p["spec"].get("nodeName"))
    r = replicas()
    for n in nodes:
        name = n["metadata"]["name"]
        phys = int((n["metadata"].get("annotations") or {}).get("aiinfra.course/physical-gpus", "0") or 0)
        if phys <= 0:
            continue
        cap = phys * r if name in running else 0
        cur = (n["status"].get("capacity") or {}).get("nvidia.com/gpu")
        if cur != str(cap):
            patch = json.dumps([{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value": str(cap)},
                                {"op": "add", "path": "/status/allocatable/nvidia.com~1gpu", "value": str(cap)}])
            k("patch", "node", name, "--subresource=status", "--type=json", "-p", patch)
            print(f"gpu-plugin-sim: {name} nvidia.com/gpu {cur} -> {cap} (plugin pod running: {name in running}, physical {phys}, replicas {r})", flush=True)
        has = (n["metadata"].get("labels") or {}).get("nvidia.com/gpu.present")
        if cap > 0 and has != "true":
            k("label", "node", name, "--overwrite", "nvidia.com/gpu.present=true")
        elif cap == 0 and has:
            k("label", "node", name, "nvidia.com/gpu.present-")

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--once"
    if mode == "--loop":
        iv = float(sys.argv[2]) if len(sys.argv) > 2 else 3
        while True:
            try: once()
            except Exception as e: print("gpu-plugin-sim: error", e, flush=True)
            time.sleep(iv)
    else:
        once()
