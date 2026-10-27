#!/usr/bin/env bash
# Incident 5 - Kubernetes: the model pod is Pending after a node-pool change.  Sourced by prepare-lab.sh / verify.sh.
# Real: kind cluster (kube-apiserver, scheduler, kubelet), taints, tolerations, nodeSelector, extended-resource scheduling, kubectl.
# SIMULATED: the GPUs (node-status patch, platform/k8s.sh gpu-patch) and the device plugin / GPU Operator (lib/gpu-plugin-sim.sh reads the time-slicing ConfigMap).
# Production differs: the GPU Operator's device plugin and GFD publish capacity, MIG/time-slicing semantics are per operator version, real drivers can fail.

NS=serving

page_5() {
  cat <<MSG
PAGE 5 - $(date -u +%H:%M) UTC  "The model pod is Pending after the node-pool change"
  After this morning's node-pool change the model-serving pod (namespace $NS) is Pending; the new pool was supposed to give us more GPUs.
  Cluster: kubectl --context kind-aiinfra (3 nodes, GPUs are SIMULATED). Your files: lab/incident-5/model.yaml and lab/incident-5/time-slicing.yaml.
  Deploy them with the given lab/incident-5/apply.sh (it applies the ConfigMap, lets the simulated device plugin republish capacity, then applies the model).
MSG
}

i5_write_files() {  # V NEWNODE REPL WRONG
  local V="$1" NEW="$2" REPL="$3" WRONG="$4" d="$LAB/incident-5"
  mkdir -p "$d"
  cat > "$d/model.yaml" <<YAML
# The model server (yours). Namespace $NS. SIMULATED workload: python http.server stands in for the engine; the GPU request is real scheduling input.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model
  namespace: $NS
  labels: {app: model, course: aiinfra}
spec:
  replicas: 1
  selector:
    matchLabels: {app: model}
  template:
    metadata:
      labels: {app: model, course: aiinfra}
    spec:
      nodeSelector:
        gpu-pool: pool-$V            # the release moves the model to the new pool
      containers:
        - name: server
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          command: ["python", "-m", "http.server", "8000"]
          ports: [{containerPort: 8000}]
          readinessProbe: {tcpSocket: {port: 8000}, periodSeconds: 2}
          resources:
            requests: {nvidia.com/gpu: 1}
            limits: {nvidia.com/gpu: 1}
YAML
  cat > "$d/time-slicing.yaml" <<YAML
# GPU time-slicing configuration (yours), consumed by the (simulated) device plugin. Time-slicing shares a GPU between pods; it is NOT isolation.
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
  labels: {course: aiinfra}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
          - name: $WRONG
            replicas: $REPL
YAML
  cat > "$d/apply.sh" <<'SH'
#!/usr/bin/env bash
# GIVEN (do not edit). Deploys your two files the way the pipeline does:
#   1. kubectl apply -f time-slicing.yaml          (the GPU Operator would roll the device plugin on a ConfigMap change)
#   2. lib/gpu-plugin-sim.sh sync                  (SIMULATION of that step: republish node capacity from the ConfigMap)
#   3. kubectl apply -f model.yaml
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
D="$(cd "$(dirname "$0")" && pwd)"; K="kubectl --context kind-aiinfra"
$K apply -f "$D/time-slicing.yaml" || exit 1
"$D/../../lib/gpu-plugin-sim.sh" sync || exit 1
$K apply -f "$D/model.yaml" || exit 1
SH
  chmod +x "$d/apply.sh"
  cat > "$d/README.md" <<MD
# Incident 5 files
- \`model.yaml\`, \`time-slicing.yaml\`: YOURS. \`apply.sh\`: GIVEN (the deploy step; run it after every edit).
- Nodes: \`kubectl --context kind-aiinfra get nodes -L gpu-pool\`; capacity: \`kubectl describe node <node>\` (Capacity / Allocatable / Taints).
MD
  chmod_pub "$d"
}

i5_events() { k -n "$NS" get events --field-selector reason=FailedScheduling -o json 2>/dev/null | jq -r '.items[] | .message'; }

plant_5() {
  local V NEW OLD REPL WRONG
  V=$(rhex 3); NEW=$(pick aiinfra-worker aiinfra-worker2); REPL=$(pick 2 3 4)
  WRONG=$(pick nvidia.com/gpus nvidia.com/gpu.shared nvidia.com/Gpu nvidia/gpu)
  [ "$NEW" = aiinfra-worker ] && OLD=aiinfra-worker2 || OLD=aiinfra-worker
  rm -rf "$STATE/5"; mkdir -p "$STATE/5"
  state_write "$STATE/5/variant.env" V="$V" NEW="$NEW" OLD="$OLD" REPL="$REPL" WRONG="$WRONG"
  echo "prepare-lab: stopping compose profiles (kind and the stack share the CPU), bringing up the kind cluster (cold start takes minutes)"
  "$P/stack.sh" down >/dev/null 2>&1
  "$P/k8s.sh" up || die "k8s.sh up failed"
  cat > "$STATE/5/topology.yaml" <<YAML
nodes:
  $NEW: {gpus: 2, product: NVIDIA-A100-SXM4-80GB, memory_mib: 81920, mig_capable: true, taint: false}
  $OLD: {gpus: 1, product: NVIDIA-L4, memory_mib: 23034, mig_capable: false, taint: false}
YAML
  "$P/k8s.sh" gpu-patch --clear >/dev/null 2>&1
  local n t   # taints of earlier variants
  for n in aiinfra-worker aiinfra-worker2; do
    for t in $(k get node "$n" -o json | jq -r '.spec.taints[]? | select(.key | startswith("pool-")) | .key'); do k taint node "$n" "$t-" >/dev/null 2>&1; done
  done
  "$P/k8s.sh" gpu-patch "$STATE/5/topology.yaml" || die "gpu-patch failed"
  k label node "$NEW" --overwrite "gpu-pool=pool-$V" aiinfra.io/sim-plugin=true >/dev/null || die "label"
  k label node "$OLD" --overwrite gpu-pool=legacy aiinfra.io/sim-plugin- >/dev/null
  k taint node "$NEW" "pool-$V=gpu:NoSchedule" --overwrite >/dev/null || die "taint"
  for ns in "$NS" gpu-operator; do
    k get ns "$ns" >/dev/null 2>&1 || k create ns "$ns" >/dev/null
    k label ns "$ns" course=aiinfra --overwrite >/dev/null
  done
  k -n "$NS" delete deploy --all --wait=false >/dev/null 2>&1; k -n "$NS" delete pod --all --wait=false >/dev/null 2>&1
  k -n "$NS" delete events --all >/dev/null 2>&1
  i5_write_files "$V" "$NEW" "$REPL" "$WRONG"
  local W0; W0=$(date +%s)
  "$LAB/incident-5/apply.sh" > "$STATE/5/apply.log" 2>&1 || die "apply.sh failed: $(tail -3 "$STATE/5/apply.log")"
  within 60 bash -c "kubectl --context kind-aiinfra -n $NS get events --field-selector reason=FailedScheduling -o name | grep -q ." || die "the pod did not report a scheduling failure"
  local ev; ev=$(i5_events | head -1)
  echo "$ev" | grep -q "untolerated taint" || die "unexpected first scheduler message: $ev"
  [ "$(k get node "$NEW" -o json | jq -r '.status.allocatable["nvidia.com/gpu"]')" = 0 ] || die "planted capacity is not 0 on $NEW"
  win_set 5 "$W0" "$(date +%s)"
  state_write "$STATE/5/truth.env" NODE_NAME="$NEW" TAINT_KEY="pool-$V" WRONG_RESOURCE="$WRONG" FIRST_REASON=untolerated-taint SECOND_REASON=insufficient-gpu
  page_5
}

i5_pod_node() { k -n "$NS" get pod -l app=model -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null; }
i5_pod_phase() { k -n "$NS" get pod -l app=model -o jsonpath='{.items[0].status.phase}' 2>/dev/null; }
i5_pod_ready() { [ "$(k -n "$NS" get pod -l app=model -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; }

verify_5() {
  local V NEW; V=$(vget 5 V); NEW=$(vget 5 NEW)
  # reset to a state where only the files can make the pod run: no objects, no published capacity, then deploy exactly like the pipeline
  k -n "$NS" delete deploy,pod --all --grace-period=1 --wait=true --timeout=60s >/dev/null 2>&1
  k -n gpu-operator delete cm time-slicing-config --ignore-not-found >/dev/null 2>&1
  "$LIB/gpu-plugin-sim.sh" reset >/dev/null 2>&1
  k -n "$NS" delete events --all >/dev/null 2>&1
  local out rc; out=$("$LAB/incident-5/apply.sh" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    fail 5.1 "apply.sh failed: $(printf '%s' "$out" | grep -iE 'error|invalid|unknown' | head -2 | tr '\n' ' ' | cut -c1-260)"
    blocked 5.2 "needs 5.1"; return
  fi
  within 120 i5_pod_ready
  if ! i5_pod_ready; then
    fail 5.1 "after a clean deploy the model pod is not Ready (phase $(i5_pod_phase)); scheduler says: $(i5_events | tail -1 | cut -c1-300)"
    blocked 5.2 "needs 5.1"; return
  fi
  local node; node=$(i5_pod_node)
  if [ "$node" != "$NEW" ]; then
    fail 5.1 "the pod runs, but on $node: the release places the model on the new pool, so moving it elsewhere is not a fix"
    blocked 5.2 "needs 5.1"; return
  fi
  pass 5.1 "after a clean deploy from your two files (no hand-patched node, no leftover objects) the model pod is Ready on the new pool"
  # 5.2: capacity is real and bounded: one more GPU pod fits, a pod asking for more GPUs than the node advertises stays Pending with the scheduler's reason
  local cap msg=""; cap=$(k get node "$NEW" -o json | jq -r '.status.allocatable["nvidia.com/gpu"] // "0"')
  cat > "$STATE/5/probes.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata: {name: probe-fits, namespace: $NS, labels: {app: probe, course: aiinfra}}
spec:
  nodeSelector: {gpu-pool: pool-$V}
  tolerations: [{operator: Exists}]
  terminationGracePeriodSeconds: 0
  containers:
    - {name: c, image: python:3.12-slim, imagePullPolicy: IfNotPresent, command: ["sleep", "600"], resources: {limits: {nvidia.com/gpu: 1}}}
---
apiVersion: v1
kind: Pod
metadata: {name: probe-toobig, namespace: $NS, labels: {app: probe, course: aiinfra}}
spec:
  nodeSelector: {gpu-pool: pool-$V}
  tolerations: [{operator: Exists}]
  terminationGracePeriodSeconds: 0
  containers:
    - {name: c, image: python:3.12-slim, imagePullPolicy: IfNotPresent, command: ["sleep", "600"], resources: {limits: {nvidia.com/gpu: $((cap + 1))}}}
YAML
  k apply -f "$STATE/5/probes.yaml" >/dev/null 2>&1
  within 60 bash -c "[ \"\$(kubectl --context kind-aiinfra -n $NS get pod probe-fits -o jsonpath='{.status.phase}')\" = Running ]"
  local fits big_reason
  fits=$(k -n "$NS" get pod probe-fits -o jsonpath='{.status.phase}' 2>/dev/null)
  within 30 bash -c "kubectl --context kind-aiinfra -n $NS get events --field-selector involvedObject.name=probe-toobig,reason=FailedScheduling -o name | grep -q ."
  big_reason=$(k -n "$NS" get events --field-selector involvedObject.name=probe-toobig,reason=FailedScheduling -o json 2>/dev/null | jq -r '.items[0].message // ""')
  k -n "$NS" delete pod -l app=probe --grace-period=0 --force --wait=false >/dev/null 2>&1
  echo "~ node allocatable nvidia.com/gpu = $cap"
  [ "$cap" -ge 2 ] 2>/dev/null || msg+="the node advertises nvidia.com/gpu=$cap: sharing is supposed to give MORE schedulable GPU slots than physical GPUs; "
  [ "$fits" = Running ] || msg+="a second pod asking for 1 GPU does not run (phase ${fits:-none}) although capacity is $cap; "
  case "$big_reason" in *"Insufficient nvidia.com/gpu"*) : ;; *) msg+="a pod asking for $((cap + 1)) GPUs was not rejected with 'Insufficient nvidia.com/gpu' (scheduler said: ${big_reason:-nothing}): capacity must be real and bounded; " ;; esac
  if [ -z "$msg" ]; then pass 5.2 "the node exposes shared GPU slots; one more GPU pod runs and a pod asking for more than the capacity stays Pending with Insufficient nvidia.com/gpu"
  else fail 5.2 "${msg%; }"; fi
}
