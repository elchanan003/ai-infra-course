#!/usr/bin/env bash
# Module 09 prepare.   ./prepare-lab.sh [A|B|all]      (default: all)
#   A: compose profiles `mock obs` - SIMULATED GPU nodes (mock-dcgm A/B, fake nvidia-smi), real Prometheus using lab/prometheus.
#      Seeds a per-learner variant in .state/ (GPU UUIDs, which GPU is hottest, an active XID fault).
#   B: kind cluster `aiinfra` (3 nodes) with NO GPUs yet and an empty namespace gpu-lab. GPU capacity is SIMULATED by you (task 9.4).
# Idempotent: the variant is created once and kept until cleanup.sh. Never touches lab/ contents, never reveals answers.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
PART="${1:-all}"
case "$PART" in A|B|all) ;; *) echo "usage: $0 [A|B|all]" >&2; exit 2 ;; esac
STATE="$MODULE_DIR/.state"
mkdir -p "$STATE"
PY="$PLATFORM_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3

seed_variant() {
  [ -s "$STATE/variant.env" ] && return 1
  "$PY" - "$STATE" <<'PY'
import os, random, sys, uuid, yaml
state = sys.argv[1]
r = random.SystemRandom()
pairs = [("NVIDIA A100-SXM4-80GB", 81920, 400), ("NVIDIA A100-SXM4-40GB", 40960, 400),
         ("NVIDIA A100-PCIE-40GB", 40960, 250), ("NVIDIA A100-PCIE-80GB", 81920, 300)]
r.shuffle(pairs)
hot = r.randrange(4)
a = []
for i, (model, mem, pw) in enumerate(pairs):
    a.append(dict(model=model, memory_mib=mem, power_limit_w=pw, uuid="GPU-" + str(uuid.UUID(int=r.getrandbits(128), version=4)),
                  util=85 if i == hot else 28 + r.randrange(14)))
b = [dict(model="NVIDIA A100-SXM4-80GB", memory_mib=81920, power_limit_w=400, util=33 + 6 * i,
          uuid="GPU-" + str(uuid.UUID(int=r.getrandbits(128), version=4))) for i in range(2)]
node = r.choice("AB")
code = r.choice([13, 31, 43, 48, 64, 74, 79, 95])
if node == "A":
    code = r.choice([13, 31, 43, 48, 64, 74, 95])          # XID 79 would break nvidia-smi on node A (task 9.1 reads it)
    xidx = r.choice([i for i in range(4) if i != hot])
else:
    xidx = r.randrange(2)
inj = [i for i in range(4) if i != hot and not (node == "A" and i == xidx)][0]   # live-fire target on node A (verify only)
action = "wait" if code in (13, 31, 43) else "drain"
for n, gl, hostname in (("a", a, "gpu-node-a"), ("b", b, "gpu-node-b")):
    d = os.path.join(state, "dcgm-" + n); os.makedirs(d, exist_ok=True)
    yaml.safe_dump(dict(hostname=hostname, gpus=gl), open(os.path.join(d, "gpus.yaml"), "w"), sort_keys=False)
    fp = os.path.join(d, "fault.yaml")
    if node.lower() == n:
        yaml.safe_dump(dict(faults=[dict(gpu=xidx, xid=code)]), open(fp, "w"))
    elif os.path.exists(fp):
        os.remove(fp)
xgl = a if node == "A" else b
env = dict(HOT_IDX=hot, HOT_UUID=a[hot]["uuid"], HOT_MEM=a[hot]["memory_mib"], HOT_POWER=a[hot]["power_limit_w"],
           XID_NODE=node, XID_IDX=xidx, XID_CODE=code, XID_UUID=xgl[xidx]["uuid"], XID_ACTION=action,
           INJ_IDX=inj, INJ_UUID=a[inj]["uuid"], A_UUIDS=" ".join(g["uuid"] for g in a), B_UUIDS=" ".join(g["uuid"] for g in b))
with open(os.path.join(state, "variant.env.tmp"), "w") as f:
    for k, v in env.items():
        f.write(f'{k}="{v}"\n')
os.replace(os.path.join(state, "variant.env.tmp"), os.path.join(state, "variant.env"))
PY
}

part_a() {
  local fresh=0
  seed_variant && fresh=1
  [ -s "$STATE/variant.env" ] || { echo "prepare-lab: could not seed the variant"; return 1; }
  chmod -R a+rX "$MODULE_DIR/lab/prometheus" "$STATE"
  export PROM_CONFIG_DIR="$MODULE_DIR/lab/prometheus" MOCK_DCGM_A_CONFIG_DIR="$STATE/dcgm-a" MOCK_DCGM_B_CONFIG_DIR="$STATE/dcgm-b"
  "$PLATFORM_DIR/stack.sh" up mock obs || { echo "prepare-lab: stack did not come up healthy"; return 1; }
  if [ "$fresh" = 1 ]; then   # config contents changed under the same bind path: compose would not notice
    "$PLATFORM_DIR/stack.sh" compose up -d --force-recreate mock-dcgm-a mock-dcgm-b >/dev/null 2>&1
  fi
  wait_http "http://127.0.0.1:18031/health" 60 && wait_http "http://127.0.0.1:18032/health" 60 && wait_http "$PROM_URL/-/ready" 60 \
    || { echo "prepare-lab: mock-dcgm or Prometheus not ready"; return 1; }
  curl -fsS -o /dev/null -X POST "$PROM_URL/-/reload" 2>/dev/null || true
  cat <<MSG
prepare-lab A: ready.  (SIMULATED GPUs: mock-dcgm containers, fake nvidia-smi; Prometheus and promtool are real)
  fake nvidia-smi   bin/smi A -L        bin/smi B --query-gpu=index,uuid,temperature.gpu --format=csv
  DCGM metrics      curl -s localhost:18031/metrics | grep DCGM_FI_DEV_GPU_TEMP     (node A; node B is :18032)
  Prometheus        http://100.127.87.65:18090   rules: lab/prometheus/rules/dcgm-alerts.yml   reload: ../../platform/stack.sh reload-prometheus
  Tasks 9.1-9.3 in lab.md.
MSG
}

part_b() {
  if docker ps -q --filter label=com.docker.compose.project=aiinfra --filter label=com.docker.compose.service=llama-chat | grep -q .; then
    echo "prepare-lab: profile llm is up (kind and llm never run together); converging the stack down first"
    "$PLATFORM_DIR/stack.sh" down || return 1
  fi
  "$PLATFORM_DIR/k8s.sh" up || { echo "prepare-lab: kind cluster did not come up"; return 1; }
  "$PLATFORM_DIR/k8s.sh" gpu-patch --clear >/dev/null 2>&1
  k delete ns gpu-lab --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
  k create ns gpu-lab >/dev/null && k label ns gpu-lab course=aiinfra --overwrite >/dev/null || { echo "prepare-lab: cannot create namespace gpu-lab"; return 1; }
  cat <<MSG
prepare-lab B: ready.  (kind: real Kubernetes scheduler; GPUs do NOT exist - you simulate the device plugin in task 9.4)
  k = kubectl --context kind-aiinfra      nodes: aiinfra-control-plane, aiinfra-worker, aiinfra-worker2      namespace: gpu-lab
  Tasks 9.4-9.7 and T in lab.md. verify.sh applies and deletes the pods/deployments itself; you may apply yours to experiment.
MSG
}

rc=0
case "$PART" in
  A) part_a || rc=1 ;;
  B) part_b || rc=1 ;;
  all) part_a || rc=1; part_b || rc=1 ;;
esac
exit $rc
