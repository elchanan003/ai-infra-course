#!/usr/bin/env bash
# Course Kubernetes driver: kind cluster "aiinfra" (context kind-aiinfra), 1 control-plane + 2 workers,
# node image kindest/node (KIND_NODE_IMAGE), NodePorts 30000-30010 -> http://127.0.0.1:18100-18110.
#
#   k8s.sh up                   create/converge the cluster (idempotent), label nodes course=aiinfra,
#                               side-load platform/k8s/images.txt (docker save | kind load image-archive)
#   k8s.sh down                 delete the kind cluster (nothing else is touched)
#   k8s.sh status               nodes, GPU capacity/labels/taints, pods
#   k8s.sh load IMAGE...        side-load host images into every node (kind load docker-image is broken on
#                               the Docker 29 containerd store: this uses save --platform | load image-archive)
#   k8s.sh gpu-patch [FILE|--clear]   SIMULATED GPUs: node-status patch of nvidia.com/gpu capacity/allocatable +
#                               GFD-style labels + optional taint, per platform/k8s/gpu-topology.yaml (or FILE)
#   k8s.sh fake-gpu [--remove]  optional: run-ai fake-gpu-operator 0.2.1 (helm, OCI chart; needs internet unless
#                               cached) on node aiinfra-worker2; do not combine with gpu-patch on the same node
#
# Refuses to run with the `llm` profile up (RAM; ALLOW_RAM_RISK=1 overrides). Never touches the docker network "kind".
# Env: K8S_PRELOAD=0 disables side-loading; K8S_UP_TIMEOUT (default 300 s).
set -uo pipefail

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$PLATFORM_DIR/k8s"
set -a; source "$PLATFORM_DIR/versions.env"; set +a
export PATH="$HOME/.local/bin:$PATH"
CLUSTER=aiinfra
CTX=kind-aiinfra
TIMEOUT="${K8S_UP_TIMEOUT:-300}"

k()   { kubectl --context "$CTX" "$@"; }
log() { echo "k8s.sh: $*"; }
die() { echo "k8s.sh: ERROR $*" >&2; exit 1; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
arm() { case "$(uname -m)" in aarch64|arm64) echo linux/arm64 ;; *) echo linux/amd64 ;; esac; }
pyyaml() { local py="$PLATFORM_DIR/.venv/bin/python"; [ -x "$py" ] || py=python3; "$py" "$@"; }

preflight() {
  command -v kind >/dev/null && command -v kubectl >/dev/null || die "kind/kubectl missing: run platform/setup.sh"
  [ "$(nproc)" -ge 4 ] || die "need >= 4 CPUs"
  if docker ps -q --filter label=com.docker.compose.project=aiinfra --filter label=com.docker.compose.service=llama-chat | grep -q . \
     && [ "${ALLOW_RAM_RISK:-0}" != 1 ]; then
    die "profile 'llm' is up: kind and llm never run together (stack.sh up <others> first, or ALLOW_RAM_RISK=1)"
  fi
  docker ps -q --filter label=com.docker.compose.project=aiinfra --filter label=com.docker.compose.service=vllm-cpu | grep -q . \
    && log "WARN vllm profile is up (6 GB); kind will be tight"
  local inst; inst=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  [ "$inst" -ge 512 ] || log "WARN fs.inotify.max_user_instances=$inst (<512); if pods fail with 'too many open files': sudo sysctl fs.inotify.max_user_instances=512"
}

load_images() {
  local imgs=() i tmp plat; plat=$(arm)
  for i in "$@"; do
    if docker image inspect "$i" >/dev/null 2>&1; then imgs+=("$i"); else log "skip $i (not in the host cache)"; fi
  done
  [ ${#imgs[@]} -gt 0 ] || return 0
  tmp=$(mktemp -d); log "loading ${imgs[*]} into kind"
  if docker save --platform "$plat" -o "$tmp/images.tar" "${imgs[@]}" 2>/dev/null \
     && kind load image-archive "$tmp/images.tar" --name "$CLUSTER" >/dev/null 2>&1; then rm -rf "$tmp"; return 0; fi
  rm -rf "$tmp"; log "WARN image load failed; nodes will try to pull"; return 1
}

preload() {
  [ "${K8S_PRELOAD:-1}" = 1 ] || return 0
  local l imgs=()
  while read -r l; do [ -n "$l" ] && [ "${l#\#}" = "$l" ] && imgs+=("$l"); done < "$K8S_DIR/images.txt"
  [ ${#imgs[@]} -gt 0 ] && load_images "${imgs[@]}"
  return 0
}

gpu_patch() {
  local arg="${1:-$K8S_DIR/gpu-topology.yaml}" clear=0
  [ "$arg" = --clear ] && { clear=1; arg="$K8S_DIR/gpu-topology.yaml"; }
  [ -r "$arg" ] || die "topology file $arg not found"
  local lines; lines=$(pyyaml - "$arg" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for n, c in (d.get("nodes") or {}).items():
    print("|".join(str(x) for x in (n, c.get("gpus", 0), c.get("product", "NVIDIA-GPU"), c.get("memory_mib", 0),
          str(c.get("mig_capable", False)).lower(), str(c.get("taint", False)).lower())))
PY
) || die "cannot parse $arg (PyYAML missing? run platform/setup.sh)"
  local n g prod mem mig taint
  while IFS='|' read -r n g prod mem mig taint; do
    [ -n "$n" ] || continue
    k get node "$n" >/dev/null 2>&1 || { log "WARN node $n not in the cluster; skipped"; continue; }
    if [ "$clear" = 1 ]; then
      k patch node "$n" --subresource=status --type=json \
        -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"},{"op":"remove","path":"/status/allocatable/nvidia.com~1gpu"}]' >/dev/null 2>&1
      k label node "$n" nvidia.com/gpu.present- nvidia.com/gpu.product- nvidia.com/gpu.count- nvidia.com/gpu.memory- nvidia.com/mig.capable- >/dev/null 2>&1
      k taint node "$n" nvidia.com/gpu- >/dev/null 2>&1
      log "$n: GPU simulation cleared"; continue
    fi
    k patch node "$n" --subresource=status --type=json -p "[
      {\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"$g\"},
      {\"op\":\"add\",\"path\":\"/status/allocatable/nvidia.com~1gpu\",\"value\":\"$g\"}]" >/dev/null || die "status patch of $n failed"
    k label node "$n" --overwrite nvidia.com/gpu.present=true "nvidia.com/gpu.product=$prod" "nvidia.com/gpu.count=$g" \
      "nvidia.com/gpu.memory=$mem" "nvidia.com/mig.capable=$mig" course=aiinfra >/dev/null
    if [ "$taint" = true ]; then k taint node "$n" --overwrite nvidia.com/gpu=present:NoSchedule >/dev/null
    else k taint node "$n" nvidia.com/gpu- >/dev/null 2>&1; fi
    log "$n: nvidia.com/gpu=$g product=$prod taint=$taint (simulated)"
  done <<< "$lines"
}

fake_gpu() {
  cluster_exists || die "cluster absent: k8s.sh up first"
  command -v helm >/dev/null || die "helm missing"
  if [ "${1:-}" = --remove ]; then
    helm --kube-context "$CTX" uninstall gpu-operator -n gpu-operator --wait >/dev/null 2>&1
    k label node aiinfra-worker2 run.ai/simulated-gpu-node-pool- >/dev/null 2>&1
    k delete ns gpu-operator --ignore-not-found --wait=false >/dev/null 2>&1
    log "fake-gpu-operator removed"; return 0
  fi
  k label node aiinfra-worker2 run.ai/simulated-gpu-node-pool=default --overwrite >/dev/null
  log "installing fake-gpu-operator $FAKE_GPU_OPERATOR_VERSION (needs internet or a cached chart/images)"
  helm --kube-context "$CTX" upgrade --install gpu-operator "$FAKE_GPU_OPERATOR_CHART" --version "$FAKE_GPU_OPERATOR_VERSION" \
    -n gpu-operator --create-namespace --wait --timeout "${TIMEOUT}s" >/dev/null || die "helm install failed"
  k label ns gpu-operator course=aiinfra --overwrite >/dev/null
  log "fake-gpu-operator ready (its dcgm-exporter has only FB_USED/FB_FREE/GPU_UTIL; mock-dcgm covers the rest)"
}

status() {
  if ! cluster_exists; then echo "kind cluster '$CLUSTER': absent"; return 0; fi
  echo "kind cluster '$CLUSTER': present (context $CTX); NodePorts 30000-30010 -> 127.0.0.1:18100-18110"
  k get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.capacity.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,TAINTS:.spec.taints[*].key' 2>/dev/null
  echo; k get pods -A -o wide 2>/dev/null | cut -c1-140
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    preflight
    if cluster_exists; then log "cluster '$CLUSTER' exists"
    else
      for p in $(seq 18100 18110); do
        ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && die "host port $p is in use (NodePort mapping)"
      done
      log "creating kind cluster '$CLUSTER' ($KIND_NODE_IMAGE, 1 control-plane + 2 workers)"
      kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config "$K8S_DIR/kind-config.yaml" --wait "${TIMEOUT}s" \
        || die "kind create cluster failed"
    fi
    k wait --for=condition=Ready node --all --timeout="${TIMEOUT}s" >/dev/null || die "nodes not Ready"
    k label node --all course=aiinfra --overwrite >/dev/null
    preload
    log "ready: $(k get nodes --no-headers | awk '{print $1"="$2}' | tr '\n' ' ')"
    ;;
  down)
    if cluster_exists; then log "deleting kind cluster '$CLUSTER'"; kind delete cluster --name "$CLUSTER"
    else log "kind cluster '$CLUSTER' absent"; fi
    ;;
  status) status ;;
  load)
    [ $# -ge 1 ] || die "usage: k8s.sh load IMAGE..."
    cluster_exists || die "cluster absent: k8s.sh up first"
    load_images "$@" ;;
  gpu-patch)
    cluster_exists || die "cluster absent: k8s.sh up first"
    gpu_patch "${1:-}" ;;
  fake-gpu) fake_gpu "${1:-}" ;;
  *)
    sed -n '2,/^set -uo/p' "$0" | grep -v '^set' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
