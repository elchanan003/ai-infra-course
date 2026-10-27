#!/usr/bin/env bash
# Incident 5 - Kubernetes: model pods Pending after a node-pool change.  Sourced by prepare-lab.sh / verify.sh.
# Real: kind cluster (real API server, scheduler, kubelet, taints, tolerations, DaemonSet, events).
# SIMULATED: the GPUs and the NVIDIA device plugin / time-slicing config (lib/gpu_plugin_sim.py patches node capacity from the plugin DaemonSet's presence and the
# ConfigMap). Production differs: GPU Operator, real device-plugin pods, GFD labels, MIG/time-slicing semantics, a driver; and an unknown time-slicing resource name
# is ignored by the real plugin (the sim does the same: replicas stay 1).

I5_CTX=kind-aiinfra

page_5() {
  cat <<MSG
PAGE 5 - $(date -u +%H:%M) UTC  "The model pod is Pending after the node-pool change"
  After this morning's node-pool change the model-serving pods are Pending; the new GPU pool was supposed to give us MORE GPUs than before.
  Cluster: kubectl --context kind-aiinfra ...   Namespaces: serving (model), gpu-operator (device plugin + time-slicing config).
  Your files in lab/incident-5/: model.yaml, device-plugin.yaml, time-slicing.yaml. Apply them yourself to experiment (verify applies them too).
  Capacity is published by the simulated device plugin about every 3 s (lib/gpu_plugin_sim.py, given). Read what the scheduler says, fix, read it again.
MSG
}

i5_write_files() {  # V NODE PHYS REPL
  local V="$1" NODE="$2" PHYS="$3" REPL="$4" d="$LAB/incident-5"
  mkdir -p "$d"
  cat > "$d/model.yaml" <<YAML
# Model-serving Deployment (yours). SIMULATED workload: a sleeping container stands in for the engine.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-serve
  namespace: serving
  labels: {course: aiinfra, app: model-serve}
spec:
  replicas: $REPL                 # product requirement: all replicas serve, one GPU slice each
  selector: {matchLabels: {app: model-serve}}
  template:
    metadata:
      labels: {course: aiinfra, app: model-serve}
    spec:
      terminationGracePeriodSeconds: 1
      nodeSelector:
        pool: gpu-b-$V               # the new GPU pool
      containers:
        - name: engine
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          command: ["sleep", "3600"]
          resources:
            limits:
              nvidia.com/gpu: 1
YAML
  cat > "$d/device-plugin.yaml" <<YAML
# Stand-in for the NVIDIA device-plugin DaemonSet of the GPU Operator (yours). SIMULATED: a sleeping container; the sim publishes capacity
# for nodes where one of these pods is Running.
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-sim
  namespace: gpu-operator
  labels: {course: aiinfra, app: nvidia-device-plugin-sim}
spec:
  selector: {matchLabels: {app: nvidia-device-plugin-sim}}
  template:
    metadata:
      labels: {course: aiinfra, app: nvidia-device-plugin-sim}
    spec:
      terminationGracePeriodSeconds: 1
      nodeSelector:
        nvidia.com/gpu.deploy.device-plugin: "true"
      containers:
        - name: plugin
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          command: ["sleep", "3600"]
YAML
  cat > "$d/time-slicing.yaml" <<YAML
# Time-slicing config of the device plugin (yours): each physical GPU is meant to be shared by 2 pods.
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
          - name: nvidia.com/gpus
            replicas: 2
YAML
  cat > "$d/README.md" <<MD
# Incident 5 workspace
Your files: model.yaml, device-plugin.yaml, time-slicing.yaml. The node-pool change (taint + labels on one worker, 2-3 physical GPUs) was done by someone else
and is not in a file you own. The simulated plugin (lib/gpu_plugin_sim.py) is given.
MD
  chmod_pub "$d"
}

i5_sim_start() {
  i5_sim_stop
  mkdir -p "$STATE/5"
  # close the lab-lock fd (9) so the daemon does not keep the lock held after the session ends
  setsid nohup "$PY" "$LIB/gpu_plugin_sim.py" --loop 3 > "$STATE/5/sim.log" 2>&1 9>&- < /dev/null &
  echo $! > "$STATE/5/sim.pid"
}
i5_sim_stop() {
  local p; p=$(cat "$STATE/5/sim.pid" 2>/dev/null)
  if [ -n "$p" ] && grep -q gpu_plugin_sim "/proc/$p/cmdline" 2>/dev/null; then kill "$p" 2>/dev/null; fi
  rm -f "$STATE/5/sim.pid"
}
i5_sim_alive() { local p; p=$(cat "$STATE/5/sim.pid" 2>/dev/null); [ -n "$p" ] && grep -q gpu_plugin_sim "/proc/$p/cmdline" 2>/dev/null; }

plant_5() {
  local V NODE OTHER PHYS REPL
  V=$(rhex 3); NODE=$(pick aiinfra-worker aiinfra-worker2); PHYS=$(pick 2 3); REPL=$((2 * PHYS - 1))
  OTHER=$([ "$NODE" = aiinfra-worker ] && echo aiinfra-worker2 || echo aiinfra-worker)
  i5_sim_stop; mkdir -p "$STATE/5"
  state_write "$STATE/5/variant.env" V="$V" NODE="$NODE" OTHER="$OTHER" PHYS="$PHYS" REPL="$REPL" TAINT="pool-$V"
  echo "prepare-lab: stopping the compose stack (kind needs the RAM), then the kind cluster 'aiinfra' (cold start several minutes)"
  "$P/stack.sh" down >/dev/null 2>&1
  "$P/k8s.sh" up || die "kind cluster did not come up (platform/k8s.sh status)"
  "$P/k8s.sh" gpu-patch --clear >/dev/null 2>&1
  local n t
  for n in aiinfra-worker aiinfra-worker2; do   # reset anything a previous variant left on the nodes
    for t in $(k get node "$n" -o json | jq -r '.spec.taints[]? | select(.key|startswith("pool-")) | .key'); do k taint node "$n" "$t"- >/dev/null 2>&1; done
    k label node "$n" pool- nvidia.com/gpu.deploy.device-plugin- nvidia.com/gpu.present- >/dev/null 2>&1
    k annotate node "$n" aiinfra.course/physical-gpus- >/dev/null 2>&1
    k patch node "$n" --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"},{"op":"remove","path":"/status/allocatable/nvidia.com~1gpu"}]' >/dev/null 2>&1
  done
  k delete ns serving gpu-operator --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
  k create ns serving >/dev/null && k create ns gpu-operator >/dev/null || die "cannot create namespaces"
  k label ns serving gpu-operator course=aiinfra --overwrite >/dev/null
  # the node-pool change (done by someone else): new pool = $NODE
  k label node "$OTHER" pool=gpu-a --overwrite >/dev/null
  k label node "$NODE" "pool=gpu-b-$V" nvidia.com/gpu.deploy.device-plugin=true --overwrite >/dev/null
  k annotate node "$NODE" "aiinfra.course/physical-gpus=$PHYS" --overwrite >/dev/null
  k taint node "$NODE" "pool-$V=gpu:NoSchedule" --overwrite >/dev/null
  i5_write_files "$V" "$NODE" "$PHYS" "$REPL"
  local d="$LAB/incident-5"
  k apply -f "$d/time-slicing.yaml" -f "$d/device-plugin.yaml" -f "$d/model.yaml" >/dev/null || die "could not apply the planted manifests"
  i5_sim_start
  echo "prepare-lab: waiting for the scheduler to report the Pending pods"
  within 90 bash -c "kubectl --context $I5_CTX -n serving get events --field-selector reason=FailedScheduling -o json | jq -e '[.items[].message] | any(test(\"untolerated taint\"))' >/dev/null" \
    || die "the scheduler did not report the untolerated taint (kubectl -n serving get events)"
  state_write "$STATE/5/truth.env" NODE_NAME="$NODE" TAINT_KEY="pool-$V" PENDING_REASONS="untolerated-taint,insufficient-gpu" GPU_CAPACITY_AFTER="$((PHYS * 2))"
  page_5
}

i5_apply() {  # applies the learner's three files; prints errors
  local d="$LAB/incident-5" out
  out=$(k apply -f "$d/time-slicing.yaml" -f "$d/device-plugin.yaml" -f "$d/model.yaml" 2>&1) || { echo "$out" | tail -3; return 1; }
}

verify_5() {
  local V NODE PHYS REPL d="$LAB/incident-5"
  V=$(vget 5 V); NODE=$(vget 5 NODE); PHYS=$(vget 5 PHYS); REPL=$(vget 5 REPL)
  i5_sim_alive || i5_sim_start
  local err; err=$(i5_apply) || { fail 5.1 "kubectl apply of your files failed: $(echo "$err" | tr '\n' ' ' | cut -c1-300)"; blocked 5.2 "needs 5.1"; return; }
  # a hand-patched node does not count: reset capacity to 0 and let the (simulated) plugin recompute it from the cluster objects
  k patch node "$NODE" --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"0"},{"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"0"}]' >/dev/null 2>&1
  k -n gpu-operator delete pods -l app=nvidia-device-plugin-sim --grace-period=1 --wait=false >/dev/null 2>&1
  k -n serving delete pods -l app=model-serve --grace-period=1 --wait=false >/dev/null 2>&1
  settle() { "$PY" "$LIB/gpu_plugin_sim.py" --once >/dev/null 2>&1; [ "$(k -n serving get deploy model-serve -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "$REPL" ]; }
  if ! within 150 settle; then
    local ready; ready=$(k -n serving get deploy model-serve -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local ev; ev=$(k -n serving get events --field-selector reason=FailedScheduling -o json | jq -r '[.items[] | .message] | last // ""' | cut -c1-230)
    local dsn; dsn=$(k -n gpu-operator get ds nvidia-device-plugin-sim -o jsonpath='{.status.numberReady}' 2>/dev/null)
    fail 5.1 "after a clean re-apply of your files ${ready:-0}/$REPL model pods are Ready (device-plugin pods ready: ${dsn:-0}). Scheduler: ${ev:-no FailedScheduling event yet}"
    blocked 5.2 "needs 5.1"; return
  fi
  pass 5.1 "your three files, applied from scratch with node capacity reset to 0, give $REPL/$REPL Ready model pods"
  # 5.2 live: pods on the new pool, capacity is real (probe pod beyond capacity stays Pending with Insufficient), no cheating on replicas/requests
  local cap msg="" bad
  cap=$(k get node "$NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}')
  bad=$(k -n serving get pods -l app=model-serve -o json | jq -r --arg n "$NODE" '[.items[] | select(.status.phase=="Running" and .spec.nodeName==$n)] | length')
  [ "$bad" = "$REPL" ] || msg+="only $bad/$REPL model pods Running on the new pool node; "
  [ "$(k -n serving get deploy model-serve -o jsonpath='{.spec.replicas}')" = "$REPL" ] || msg+="the Deployment no longer asks for $REPL replicas (the requirement is not negotiable); "
  [ "$(k -n serving get deploy model-serve -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu}')" = 1 ] || msg+="each replica must request exactly one nvidia.com/gpu; "
  if ! isint "$cap" || [ "$cap" -gt 12 ]; then msg+="node capacity is ${cap:-none}: more than 6 time-slices per physical GPU is oversubscription, not a fix; "
  elif [ "$cap" -lt "$REPL" ]; then msg+="node capacity $cap is below the $REPL replicas; "
  else
    local extra=$((cap - REPL + 1))
    k -n serving get deploy model-serve -o json | jq --argjson r "$extra" '.metadata.name="capacity-probe" | .spec.replicas=$r | .spec.selector.matchLabels.app="capacity-probe" | .spec.template.metadata.labels.app="capacity-probe"
        | del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.generation,.metadata.annotations,.metadata.managedFields)' | k apply -f - >/dev/null 2>&1
    probe_state() { local run pend; run=$(k -n serving get pods -l app=capacity-probe -o json | jq '[.items[]|select(.status.phase=="Running")]|length'); pend=$(k -n serving get pods -l app=capacity-probe -o json | jq '[.items[]|select(.status.phase=="Pending")]|length'); [ "$run" = $((extra-1)) ] && [ "$pend" = 1 ]; }
    if within 60 probe_state; then
      k -n serving get events --field-selector reason=FailedScheduling -o json | jq -e '[.items[] | select(.involvedObject.name|startswith("capacity-probe")) | .message] | any(test("Insufficient nvidia.com/gpu"))' >/dev/null \
        || msg+="the over-capacity probe pod is Pending but not for 'Insufficient nvidia.com/gpu'; "
    else msg+="capacity is not real: a probe Deployment needing one slice more than ${cap} (${extra} pods) did not end with exactly 1 Pending pod; "; fi
    k -n serving delete deploy capacity-probe --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  echo "$cap" > "$STATE/5/cap.live"
  if [ -z "$msg" ]; then pass 5.2 "model pods Running on $NODE; capacity $cap is enforced (one slice beyond it stays Pending: Insufficient nvidia.com/gpu)"
  else fail 5.2 "${msg%; }"; fi
}
