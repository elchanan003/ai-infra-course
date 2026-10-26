#!/usr/bin/env bash
# Module 09 verify.   ./verify.sh [A|B|all]     (default: all)
# A (tasks 9.1-9.3): reads the SIMULATED mock-dcgm nodes, runs your alert rules through real promtool and a real Prometheus.
# B (tasks 9.4-9.7, T): runs your files against the REAL kind scheduler; GPU capacity is SIMULATED (node-status patch).
# verify applies and deletes its own pods/deployments in namespace gpu-lab; it injects and clears one XID fault on node A.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"
PART="${1:-all}"
case "$PART" in A|B|all) ;; *) echo "usage: $0 [A|B|all]" >&2; exit 2 ;; esac
IDS_A=(9.1a 9.1b 9.1c 9.2a 9.2b 9.2c 9.2d 9.3a 9.3b 9.3c)
IDS_B=(9.4a 9.4b 9.4c 9.4d 9.5a 9.5b 9.5c 9.5d 9.6a 9.6b 9.6c 9.7a 9.7b 9.7c 9.7d 9.7e T.1 T.2)
TMP="$(mktemp -d)"
NS=gpu-lab; BIG=aiinfra-worker; SMALL=aiinfra-worker2
PY="$PLATFORM_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3
NONCE="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() {
  [ -n "${INJ_IDX:-}" ] && curl -s -o /dev/null -X POST "http://127.0.0.1:18031/admin/fault" -H 'Content-Type: application/json' \
    -d "{\"gpu\": $INJ_IDX, \"xid\": 0}" 2>/dev/null
  if kubectl --context kind-aiinfra get ns "$NS" >/dev/null 2>&1; then
    k -n "$NS" delete pods,deploy --all --grace-period=1 --wait=false >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

block_ids() { local msg="$1"; shift; local i; for i in "$@"; do blocked "$i" "$msg"; done; }
ans() { # FILE KEY -> value (inline "  # comment" and surrounding blanks removed)
  sed -n "s/^$2=//p" "$LAB/answers/$1" | tail -1 | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/'
}

alert_count() { prom_value "count(ALERTS{alertname=\"$1\",alertstate=\"firing\",UUID=\"$2\"${3:+,Hostname=\"$3\"}})"; }
alert_is_firing() { [ "$(alert_count "$@")" = 1 ]; }
alert_is_quiet() { [ -z "$(alert_count "$@")" ]; }

# =================================================================================== PART A
part_a() {
  local ok=1
  [ -s "$STATE/variant.env" ] || { echo "[PRE] variant: missing (run ./prepare-lab.sh A)"; ok=0; }
  [ "$ok" = 1 ] && { set -a; . "$STATE/variant.env"; set +a; }
  precond "mock-dcgm A healthy" wait_http http://127.0.0.1:18031/health 20 || ok=0
  precond "mock-dcgm B healthy" wait_http http://127.0.0.1:18032/health 20 || ok=0
  precond "Prometheus ready" wait_http "$PROM_URL/-/ready" 20 || ok=0
  local mnt; mnt=$(docker inspect aiinfra-prometheus-1 --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
  precond "Prometheus uses lab/prometheus" test "$mnt" = "$LAB/prometheus" || ok=0
  if [ "$ok" = 1 ]; then
    local live; live=$(curl -fsS http://127.0.0.1:1803$([ "$XID_NODE" = A ] && echo 1 || echo 2)/metrics 2>/dev/null \
      | grep "^DCGM_FI_DEV_XID_ERRORS{" | grep "UUID=\"$XID_UUID\"" | awk '{print $NF}')
    precond "variant XID fault visible in DCGM" test "${live%.*}" = "$XID_CODE" || ok=0
  fi
  if [ "$ok" != 1 ]; then block_ids "environment not ready - run ./prepare-lab.sh A" "${IDS_A[@]}"; return; fi

  # ---------------- 9.1 fake nvidia-smi
  local rows; rows=$("$MODULE_DIR/bin/smi" A --query-gpu=index,uuid,temperature.gpu,memory.total,power.limit --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  local best_idx best_uuid best_mem best_pow
  IFS=, read -r best_idx best_uuid _ best_mem best_pow < <(echo "$rows" | sort -t, -k3 -n -r | head -1)
  best_pow=${best_pow%.*}; best_mem=${best_mem%.*}
  local a_idx a_uuid a_mem a_pow
  a_idx=$(ans smi.env HOT_GPU_INDEX); a_uuid=$(ans smi.env HOT_GPU_UUID); a_mem=$(ans smi.env VRAM_TOTAL_MIB); a_pow=$(ans smi.env POWER_CAP_W)
  if [ -z "$a_idx$a_uuid$a_mem$a_pow" ]; then
    fail 9.1a "lab/answers/smi.env is empty"
  elif [ "$a_idx" != "$best_idx" ]; then
    fail 9.1a "HOT_GPU_INDEX is not the hottest GPU of node A right now - compare the Temp column across all GPUs (theory 3.1)"
  elif [ "$a_uuid" != "$best_uuid" ]; then
    fail 9.1a "HOT_GPU_UUID is not the UUID of GPU $a_idx - the UUID, not the index, is the identity (nvidia-smi -L)"
  else pass 9.1a "hottest GPU of node A identified (index and UUID agree)"; fi
  if [ "$a_mem" = "$best_mem" ] && [ "$a_pow" = "$best_pow" ]; then pass 9.1b "VRAM total and power cap of that GPU are right"
  else fail 9.1b "VRAM_TOTAL_MIB/POWER_CAP_W do not match the hottest GPU (MiB not GB; the power CAP/limit, not the current draw)"; fi
  if [[ "$a_idx" =~ ^[0-9]+$ && "$a_uuid" =~ ^GPU-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ && "$a_mem" =~ ^[0-9]+$ && "$a_pow" =~ ^[0-9]+$ ]]; then
    pass 9.1c "answer file is complete and well-formed"
  else fail 9.1c "smi.env must hold an integer index, a full GPU-<uuid>, integer MiB and integer W (no placeholders, no units)"; fi

  # ---------------- 9.2 alert rules
  local rules="$LAB/prometheus/rules/dcgm-alerts.yml" names_ok=1 n
  local chk; chk=$(promtool_check "$rules" 2>&1); local chk_rc=$?
  local have; have=$("$PY" - "$rules" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(" ".join(r.get("alert", "") for g in (d.get("groups") or []) for r in (g.get("rules") or [])))
PY
)
  local missing=""
  for n in GpuXidError GpuTooHot GpuEccUncorrected GpuMemoryLeak; do [[ " $have " == *" $n "* ]] || missing="$missing $n"; done
  if [ "$chk_rc" != 0 ]; then fail 9.2a "promtool check rules failed: $(echo "$chk" | grep -v '^$' | head -2 | tr '\n' ' ' | cut -c1-200)"
  elif [ -n "$missing" ]; then fail 9.2a "rule file is valid but alerts are missing:$missing"
  else pass 9.2a "promtool accepts the rules; all four alerts exist"; fi

  if passed 9.2a; then
    cp "$rules" "$TMP/rules.yml"
    "$PY" - "$NONCE" "$TMP" <<'PY'
import sys, os
nonce, out = sys.argv[1:3]
H = "gpu-node-t"
dflt = dict(XID="0x119", TEMP="60x119", DBE="0x119", SBE="0x119", USED="40000x119", FREE="41920x119")
M = dict(XID="DCGM_FI_DEV_XID_ERRORS", TEMP="DCGM_FI_DEV_GPU_TEMP", DBE="DCGM_FI_DEV_ECC_DBE_VOL_TOTAL",
         SBE="DCGM_FI_DEV_ECC_SBE_VOL_TOTAL", USED="DCGM_FI_DEV_FB_USED", FREE="DCGM_FI_DEV_FB_FREE")
SC = {  # name -> (alert it must fire, eval time, overrides)
 "XID":    ("GpuXidError", "2m", dict(XID="79x119")),
 "HOT":    ("GpuTooHot", "4m", dict(TEMP="92x119")),
 "ECC":    ("GpuEccUncorrected", "5m", dict(DBE="0x8 2x110")),
 "LEAK":   ("GpuMemoryLeak", "14m", dict(USED="30000+300x119", FREE="51920-300x119")),
 "WARM":   (None, None, dict(TEMP="84x119")),                 # hot but below the threshold, all day
 "SPIKE":  (None, None, dict(TEMP="60x7 95x2 60x109")),       # 30 s above the threshold
 "OLDECC": (None, None, dict(DBE="3x119")),                   # old uncorrected errors, no new ones
 "SBE":    (None, None, dict(SBE="0+1x119")),                 # corrected errors keep rising
 "FULL":   (None, None, dict(USED="78000x119", FREE="3920x119")),   # 95% full but flat
 "SLOW":   (None, None, dict(USED="20000+2.5x119", FREE="61920-2.5x119")),  # 10 MiB/min drift
 "OK":     (None, None, {}),
}
def uuid(n): return f"GPU-{nonce}-{n}"
def header():
    s = ["rule_files: [rules.yml]", "evaluation_interval: 15s", "tests:", "  - interval: 15s", "    input_series:"]
    for i, (n, (_, _, ov)) in enumerate(SC.items()):
        v = dict(dflt); v.update(ov)
        lab = f'Hostname="{H}",gpu="{i}",UUID="{uuid(n)}",device="nvidia{i}",modelName="NVIDIA A100-SXM4-80GB",instance="mock-dcgm-t",job="mock-dcgm"'
        for k, m in M.items():
            s.append(f"      - series: '{m}{{{lab}}}'")
            s.append(f"        values: '{v[k]}'")
    s.append("    promql_expr_test:")
    return s
for alert in ("GpuXidError", "GpuTooHot", "GpuEccUncorrected", "GpuMemoryLeak"):
    bad = [n for n, (a, _, _) in SC.items() if a == alert][0]
    t = SC[bad][1]
    s = header()
    s += [f"      - expr: count(ALERTS{{alertname=\"{alert}\",alertstate=\"firing\",UUID=\"{uuid(bad)}\",Hostname=\"{H}\"}})",
          f"        eval_time: {t}", "        exp_samples:", "          - {labels: '{}', value: 1}"]
    open(os.path.join(out, f"fire_{alert}.yml"), "w").write("\n".join(s) + "\n")
    quiet = "|".join(uuid(n) for n in SC if n != bad)
    s = header()
    for et in ("2m", "5m", "8m", "14m", "20m"):
        s += [f"      - expr: count(ALERTS{{alertname=\"{alert}\",alertstate=\"firing\",UUID=~\"{quiet}\"}})", f"        eval_time: {et}"]
    open(os.path.join(out, f"quiet_{alert}.yml"), "w").write("\n".join(s) + "\n")
PY
    local why_f="" why_q="" desc
    declare -A DESC=([GpuXidError]="XID stuck at 79 (value stays non-zero)" [GpuTooHot]="92 C sustained" [GpuEccUncorrected]="uncorrected ECC counter jumped" [GpuMemoryLeak]="framebuffer growing 1200 MiB/min")
    for n in GpuXidError GpuTooHot GpuEccUncorrected GpuMemoryLeak; do
      promtool_test "$TMP/fire_$n.yml" >"$TMP/o" 2>&1 || why_f="$why_f $n(${DESC[$n]})"
    done
    if [ -z "$why_f" ]; then pass 9.2b "every alert fires on its bad series with UUID and Hostname intact"
    else fail 9.2b "did not fire (or lost UUID/Hostname) on:$why_f - check expression type, for: duration and by() labels"; fi
    if passed 9.2b; then
      for n in GpuXidError GpuTooHot GpuEccUncorrected GpuMemoryLeak; do
        promtool_test "$TMP/quiet_$n.yml" >"$TMP/o" 2>&1 || why_q="$why_q $n"
      done
      if [ -z "$why_q" ]; then pass 9.2c "alerts stay quiet on healthy, hot-but-below-threshold, flat-high, old-ECC and slow-drift GPUs"
      else fail 9.2c "false positives from:$why_q - quiet GPUs: 84 C all day, 30 s spike, old ECC count, SBE growth, flat 95% VRAM, 10 MiB/min drift"; fi
    else blocked 9.2c "needs 9.2b (a rule that never fires is trivially quiet)"; fi
  else
    block_ids "needs 9.2a" 9.2b 9.2c
  fi

  # live: real Prometheus + mock-dcgm fault API
  if passed 9.2a; then
    curl -fsS -o /dev/null -X POST "$PROM_URL/-/reload" 2>/dev/null
    local fire_re='GpuXidError|GpuTooHot|GpuEccUncorrected|GpuMemoryLeak'
    local dcgm_a=http://127.0.0.1:18031/admin/fault
    curl -s -o /dev/null -X POST "$dcgm_a" -H 'Content-Type: application/json' -d "{\"gpu\": $INJ_IDX, \"xid\": 0}"
    within 90 alert_is_quiet GpuXidError "$INJ_UUID"
    curl -s -o /dev/null -X POST "$dcgm_a" -H 'Content-Type: application/json' -d "{\"gpu\": $INJ_IDX, \"xid\": 74}"
    local fired=0
    within 90 alert_is_firing GpuXidError "$INJ_UUID" gpu-node-a && fired=1
    local healthy_re="" u
    for u in $A_UUIDS $B_UUIDS; do [ "$u" = "$INJ_UUID" ] || [ "$u" = "$XID_UUID" ] || healthy_re="${healthy_re:+$healthy_re|}$u"; done
    local noisy; noisy=$(prom_value "count(ALERTS{alertname=~\"$fire_re\",alertstate=\"firing\",UUID=~\"$healthy_re\"})")
    local others; others=$(prom_value "count(ALERTS{alertname=\"GpuXidError\",alertstate=\"firing\",UUID!=\"$INJ_UUID\",UUID!=\"$XID_UUID\"})")
    curl -s -o /dev/null -X POST "$dcgm_a" -H 'Content-Type: application/json' -d "{\"gpu\": $INJ_IDX, \"xid\": 0}"
    local resolved=0
    within 90 alert_is_quiet GpuXidError "$INJ_UUID" && resolved=1
    if [ "$fired" != 1 ]; then fail 9.2d "no GpuXidError for the injected GPU within 90 s (XID 74 on node A): check the expression against the live series and a short for: for hard faults"
    elif [ -n "${noisy:-}" ] || [ -n "${others:-}" ]; then fail 9.2d "alert fired for GPUs that are healthy (${noisy:-0} lab alerts on healthy GPUs, ${others:-0} extra XID alerts) - keep UUID/Hostname per GPU, do not aggregate them away"
    elif [ "$resolved" != 1 ]; then fail 9.2d "GpuXidError did not resolve within 90 s after the fault was cleared (value back to 0)"
    else pass 9.2d "live: fired for exactly the injected GPU, healthy GPUs quiet, resolved after the fault cleared"; fi
  else block_ids "needs 9.2a" 9.2d; fi

  # ---------------- 9.3 drain or wait
  local x_code x_node x_uuid x_act x_why
  x_code=$(ans xid.env XID_CODE); x_node=$(ans xid.env XID_NODE); x_uuid=$(ans xid.env XID_GPU_UUID); x_act=$(ans xid.env ACTION); x_why=$(ans xid.env REASON)
  if [ -z "$x_code$x_node$x_uuid" ]; then fail 9.3a "lab/answers/xid.env is empty"
  elif [ "$x_code" = "$XID_CODE" ] && [ "${x_node^^}" = "$XID_NODE" ] && [ "$x_uuid" = "$XID_UUID" ]; then pass 9.3a "XID code, node and GPU UUID match the live fault"
  else fail 9.3a "XID_CODE/XID_NODE/XID_GPU_UUID do not describe the active fault - read DCGM_FI_DEV_XID_ERRORS on both nodes (non-zero value, its UUID label)"; fi
  if passed 9.3a; then
    if [ "${x_act,,}" = "$XID_ACTION" ]; then pass 9.3b "ACTION is the right class for this XID"
    else fail 9.3b "ACTION '$x_act' is wrong for XID $XID_CODE - is it application-class or hardware-class (theory 3.3), and does the GPU recover by itself?"; fi
    local words; words=$(echo "$x_why" | wc -w)
    if [ "$words" -ge 5 ] && echo "$x_why" | grep -qiE "xid|$XID_CODE|hardware|application|ecc|bus|nvlink|link|memory|workload|restart|drain|cordon|replica|pdb|ticket|rma"; then
      pass 9.3c "REASON is a real sentence that cites the evidence or the class"
    else fail 9.3c "REASON must be one sentence (5+ words) that cites the XID code or its class (hardware/application) and the consequence"; fi
  else block_ids "needs 9.3a (a decision only counts for the right fault)" 9.3b 9.3c; fi
}

# =================================================================================== PART B
sched_msg() { k -n "$NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null; }
pod_phase() { k -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
pod_node()  { k -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
pod_running() { [ "$(pod_phase "$1")" = Running ]; }
wait_running() { within "${2:-90}" pod_running "$1"; }
has_unsched() { [ -n "$(k -n "$NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.reason=="Unschedulable")].message}' 2>/dev/null)" ]; }
wait_unsched() { within "${2:-60}" has_unsched "$1"; }
alloc() { k get node "$1" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null; }
capac() { k get node "$1" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null; }
caps_match() { [ "$(alloc $BIG)" = "$1" ] && [ "$(capac $BIG)" = "$1" ] && [ "$(alloc $SMALL)" = "$2" ] && [ "$(capac $SMALL)" = "$2" ]; }
app_running() { [ "$(k -n "$NS" get pods -l "app=$1" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running)" -ge 1 ]; }
app_msg() { k -n "$NS" get pods -l "app=$1" -o jsonpath='{.items[0].status.conditions[?(@.reason=="Unschedulable")].message}' 2>/dev/null; }
app_has_msg() { [ -n "$(app_msg "$1")" ]; }
wipe_ns() { k -n "$NS" delete pods,deploy --all --grace-period=1 --wait=true --timeout=90s >/dev/null 2>&1; }
gpu_state() { # jq snapshot of everything node-gpu.sh is responsible for
  k get nodes -o json | jq -S '[.items[] | {n: .metadata.name, c: .status.capacity["nvidia.com/gpu"], a: .status.allocatable["nvidia.com/gpu"],
    l: (.metadata.labels | with_entries(select(.key | startswith("nvidia.com/")))), t: [.spec.taints[]? | select(.key == "nvidia.com/gpu") | {key, value, effect}]}] | sort_by(.n)'
}
node_val() { k get node "$1" -o json | jq -r "$2"; }
ctl_pod() { # NAME GPUS TOLERATE(1|0)
  cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS, labels: {course: aiinfra}}
spec:
  terminationGracePeriodSeconds: 0
  $([ "$3" = 1 ] && echo 'tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]')
  containers:
    - name: main
      image: python:3.12-slim
      imagePullPolicy: IfNotPresent
      command: ["sleep", "3600"]
      resources: {limits: {nvidia.com/gpu: $2}}
YAML
}

part_b() {
  local ok=1
  precond "kind cluster aiinfra reachable" k get nodes || ok=0
  [ "$ok" = 1 ] && { precond "3 nodes Ready" test "$(k get nodes --no-headers 2>/dev/null | grep -c ' Ready')" = 3 || ok=0
                     precond "namespace $NS exists" k get ns "$NS" || ok=0
                     precond "stand-in image present on the nodes" bash -c "docker exec aiinfra-worker crictl images 2>/dev/null | grep -q python"; }
  command -v kubeconform >/dev/null || { echo "[PRE] kubeconform missing (platform/setup.sh)"; ok=0; }
  command -v jq >/dev/null || { echo "[PRE] jq missing"; ok=0; }
  if [ "$ok" != 1 ]; then block_ids "environment not ready - run ./prepare-lab.sh B" "${IDS_B[@]}"; return; fi
  wipe_ns

  # ---------------- 9.4 node advertises GPUs (your script, run against a nonce inventory and the real one)
  local script="$LAB/k8s/node-gpu.sh" cw cw2 rc out
  cw=$((3 + RANDOM % 3)); cw2=$((2 + RANDOM % 3))
  printf '# verify inventory\n%s %s NVIDIA-VERIFY-%s %s\n%s %s NVIDIA-NONCE-%s %s\n' "$BIG" "$cw" "$NONCE" 11111 "$SMALL" "$cw2" "$NONCE" 22222 > "$TMP/inv.txt"
  "$PLATFORM_DIR/k8s.sh" gpu-patch --clear >/dev/null 2>&1
  local err1="" err2="" okrun1=1 okrun2=1
  if [ -x "$script" ]; then
    out=$(INVENTORY="$TMP/inv.txt" timeout 120 "$script" 2>&1 >/dev/null); rc=$?; [ $rc = 0 ] || { okrun1=0; err1="exit $rc: $(echo "$out" | tail -1 | cut -c1-160)"; }
  else okrun1=0; err1="lab/k8s/node-gpu.sh is missing or not executable"; fi
  local s1_cap_ok=0
  within 30 caps_match "$cw" "$cw2" && s1_cap_ok=1
  local s1_lab_ok=0
  [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.product"]')" = "NVIDIA-VERIFY-$NONCE" ] && [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.count"]')" = "$cw" ] \
    && [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.memory"]')" = 11111 ] && [ "$(node_val $SMALL '.metadata.labels["nvidia.com/gpu.product"]')" = "NVIDIA-NONCE-$NONCE" ] \
    && [ "$(node_val $SMALL '.metadata.labels["nvidia.com/gpu.memory"]')" = 22222 ] && s1_lab_ok=1
  "$PLATFORM_DIR/k8s.sh" gpu-patch --clear >/dev/null 2>&1
  if [ -x "$script" ]; then
    out=$(timeout 120 "$script" 2>&1 >/dev/null); rc=$?; [ $rc = 0 ] || { okrun2=0; err2="exit $rc: $(echo "$out" | tail -1 | cut -c1-160)"; }
  else okrun2=0; err2="lab/k8s/node-gpu.sh is missing or not executable"; fi
  local s2_cap_ok=0 s2_lab_ok=0
  within 30 caps_match 2 1 && s2_cap_ok=1
  [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.product"]')" = NVIDIA-A100-SXM4-80GB ] && [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.count"]')" = 2 ] \
    && [ "$(node_val $BIG '.metadata.labels["nvidia.com/gpu.memory"]')" = 81920 ] && [ "$(node_val $SMALL '.metadata.labels["nvidia.com/gpu.product"]')" = NVIDIA-L4 ] \
    && [ "$(node_val $SMALL '.metadata.labels["nvidia.com/gpu.count"]')" = 1 ] && [ "$(node_val $SMALL '.metadata.labels["nvidia.com/gpu.memory"]')" = 23034 ] && s2_lab_ok=1
  if [ "$s1_cap_ok$s2_cap_ok" = 11 ]; then pass 9.4a "nvidia.com/gpu capacity and allocatable follow the inventory (also a changed nonce inventory)"
  elif [ "$okrun1$okrun2" != 11 ]; then fail 9.4a "node-gpu.sh failed (${err1:-$err2}) - extended resources are patched in the node STATUS (subresource), '/' is '~1' in a JSON pointer"
  elif [ "$s2_cap_ok" = 1 ]; then fail 9.4a "works for the shipped inventory only - read INVENTORY and the counts from it, do not hard-code"
  else fail 9.4a "capacity/allocatable of $BIG/$SMALL do not match the inventory after running node-gpu.sh (the scheduler reads allocatable)"; fi
  if [ "$s1_lab_ok$s2_lab_ok" = 11 ]; then pass 9.4b "GFD-style product/count/memory labels match exactly (also for the nonce inventory)"
  elif [ "$s2_lab_ok" = 1 ]; then fail 9.4b "labels are right for the shipped inventory only - they must come from the inventory file"
  else fail 9.4b "nvidia.com/gpu.product/.count/.memory labels missing or not the exact inventory strings on $BIG/$SMALL"; fi
  local cp; cp=$(k get nodes -l node-role.kubernetes.io/control-plane -o name | head -1)
  local tn; tn=$(k get nodes -o json | jq -r '[.items[] | select(.metadata.name=="'$BIG'" or .metadata.name=="'$SMALL'") | select([.spec.taints[]? | select(.key=="nvidia.com/gpu" and .effect=="NoSchedule")] | length == 1)] | length')
  local cpg; cpg=$(k get "$cp" -o json | jq -r '(.status.allocatable["nvidia.com/gpu"] // "") + (.metadata.labels["nvidia.com/gpu.product"] // "")')
  if [ "$tn" = 2 ] && [ -z "$cpg" ]; then pass 9.4c "both GPU nodes carry the nvidia.com/gpu NoSchedule taint; the control-plane advertises no GPU"
  elif [ "$tn" != 2 ]; then fail 9.4c "GPU nodes must be tainted nvidia.com/gpu=present:NoSchedule (what a GPU node pool does)"
  else fail 9.4c "the control-plane node advertises GPU data - only inventory nodes should"; fi
  local snap1 snap2; snap1=$(gpu_state)
  if [ -x "$script" ]; then timeout 120 "$script" >/dev/null 2>&1; rc=$?; else rc=127; fi
  sleep 1; snap2=$(gpu_state)
  if [ "$rc" = 0 ] && [ "$snap1" = "$snap2" ] && [ "$s2_cap_ok" = 1 ]; then pass 9.4d "a second run changes nothing and exits 0"
  else fail 9.4d "second run exit=$rc, state changed=$([ "$snap1" = "$snap2" ] && echo no || echo yes) - use idempotent operations (patch add of the same value, label/taint --overwrite)"; fi

  # reference state for the scheduling tasks (independent of your script)
  "$PLATFORM_DIR/k8s.sh" gpu-patch "$MODULE_DIR/.tutor/topology.yaml" >/dev/null 2>&1
  within 30 caps_match 2 1

  # ---------------- 9.5 GPU pod + negative controls
  local f="$LAB/k8s/gpu-pod.yaml" ap
  ap=$(k apply -f "$f" 2>&1); local arc=$?
  if [ $arc != 0 ]; then
    fail 9.5a "kubectl apply gpu-pod.yaml failed: $(echo "$ap" | head -1 | cut -c1-180)"
    fail 9.5b "no pod gpu-ok to inspect"
  else
    if wait_running gpu-ok 90 && [ "$(pod_node gpu-ok)" = "$BIG" ]; then pass 9.5a "gpu-ok is Running on $BIG (the A100 node)"
    elif [ "$(pod_phase gpu-ok)" = Running ]; then fail 9.5a "gpu-ok runs on $(pod_node gpu-ok), not on the node with the A100 product label"
    else fail 9.5a "gpu-ok not Running: $(sched_msg gpu-ok | cut -c1-230)"; fi
    local lim req
    lim=$(k -n "$NS" get pod gpu-ok -o jsonpath='{.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null)
    req=$(k -n "$NS" get pod gpu-ok -o jsonpath='{.spec.containers[0].resources.requests.nvidia\.com/gpu}' 2>/dev/null)
    if [ "$lim" = 1 ] && { [ -z "$req" ] || [ "$req" = 1 ]; }; then pass 9.5b "live object: limits nvidia.com/gpu = 1"
    else fail 9.5b "live object has limits nvidia.com/gpu='${lim:-none}' requests='${req:-none}' - extended resources go in limits, integer 1"; fi
  fi
  if passed 9.5a; then
    ctl_pod gpu-too-big 4 1; ctl_pod gpu-no-toleration 1 0
    wait_unsched gpu-too-big 60; wait_unsched gpu-no-toleration 60
    local m1 m2; m1=$(sched_msg gpu-too-big); m2=$(sched_msg gpu-no-toleration)
    if [ "$(pod_phase gpu-too-big)" = Pending ] && [[ "$m1" == *"Insufficient nvidia.com/gpu"* ]]; then pass 9.5c "control: a 4-GPU pod stays Pending with Insufficient nvidia.com/gpu (capacity is enforced)"
    else fail 9.5c "control pod asking 4 GPUs was not held back by capacity (phase=$(pod_phase gpu-too-big), msg='${m1:0:120}') - are the nodes advertising their real counts?"; fi
    if [ "$(pod_phase gpu-no-toleration)" = Pending ] && [[ "$m2" == *"untolerated taint {nvidia.com/gpu: present}"* ]]; then pass 9.5d "control: a pod without your toleration stays Pending on the untolerated taint"
    else fail 9.5d "control pod without toleration was not held back by the GPU taint (phase=$(pod_phase gpu-no-toleration)) - are both GPU nodes tainted?"; fi
  else block_ids "needs 9.5a" 9.5c 9.5d; fi
  wipe_ns

  # ---------------- 9.6 time-slicing ConfigMap (validated, not exercised)
  local cm="$LAB/k8s/timeslicing-cm.yaml" KC=(kubeconform -strict -summary -schema-location "$MODULE_DIR/schemas/{{.ResourceKind}}{{.KindSuffix}}.json")
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x, namespace: gpu-lab}\ndata: {any: 4}\n' > "$TMP/bad-cm.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x, namespace: gpu-nope-%s}\ndata: {any: "a: 1"}\n' "$NONCE" > "$TMP/bad-ns.yaml"
  precond "kubeconform rejects a malformed ConfigMap (control)" bash -c "! kubeconform -strict -summary -schema-location '$MODULE_DIR/schemas/{{.ResourceKind}}{{.KindSuffix}}.json' '$TMP/bad-cm.yaml'" 
  precond "server-side dry-run rejects a missing namespace (control)" bash -c "! kubectl --context kind-aiinfra apply --dry-run=server -f '$TMP/bad-ns.yaml'" 
  local meta; meta=$("$PY" - "$cm" <<'PY' 2>/dev/null
import sys, yaml
try:
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
except Exception as e:
    print("PARSE-ERROR", e); sys.exit(0)
if len(docs) != 1: print("DOCS", len(docs)); sys.exit(0)
d = docs[0]
print(d.get("kind"), (d.get("metadata") or {}).get("name"), (d.get("metadata") or {}).get("namespace"))
PY
)
  if [ "$meta" != "ConfigMap time-slicing-config gpu-lab" ]; then fail 9.6a "timeslicing-cm.yaml must contain exactly one ConfigMap time-slicing-config in namespace gpu-lab (found: ${meta:-nothing})"
  elif kubeconform -strict -summary -schema-location "$MODULE_DIR/schemas/{{.ResourceKind}}{{.KindSuffix}}.json" "$cm" >"$TMP/kc" 2>&1; then pass 9.6a "kubeconform: schema valid"
  else fail 9.6a "kubeconform rejects the file: $(head -2 "$TMP/kc" | tr '\n' ' ' | cut -c1-200) (data values must be strings - think about what 'any: |' holds)"; fi
  if [ ! -s "$cm" ]; then fail 9.6b "file is empty"
  elif k apply --dry-run=server -f "$cm" >"$TMP/dr" 2>&1; then pass 9.6b "API server accepts it (server-side dry-run; NOT applied)"
  else fail 9.6b "server-side dry-run rejected: $(head -1 "$TMP/dr" | cut -c1-200)"; fi
  local cfg; cfg=$("$PY" - "$cm" <<'PY' 2>&1
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    raw = (d.get("data") or {}).get("any")
    if raw is None: print("data key 'any' missing"); sys.exit(0)
    c = yaml.safe_load(raw)
    if not isinstance(c, dict): print("data.any is not a YAML mapping"); sys.exit(0)
    if c.get("version") != "v1": print("version must be v1"); sys.exit(0)
    ts = ((c.get("sharing") or {}).get("timeSlicing") or {})
    if ts.get("renameByDefault") is not True: print("sharing.timeSlicing.renameByDefault must be true (it is a key of timeSlicing, not of a resource entry)"); sys.exit(0)
    if ts.get("failRequestsGreaterThanOne") is not True: print("sharing.timeSlicing.failRequestsGreaterThanOne must be true"); sys.exit(0)
    res = [r for r in (ts.get("resources") or []) if isinstance(r, dict) and r.get("name") == "nvidia.com/gpu" and r.get("replicas") == 4]
    if len(res) != 1: print("timeSlicing.resources needs one entry: name nvidia.com/gpu, replicas 4 (integer)"); sys.exit(0)
    print("OK")
except Exception as e:
    print("cannot parse:", e)
PY
)
  if [ "$cfg" = OK ]; then pass 9.6c "embedded device-plugin config: v1, nvidia.com/gpu x4, renameByDefault, failRequestsGreaterThanOne (validated, not exercised)"
  else fail 9.6c "embedded plugin config: $cfg"; fi

  # ---------------- 9.7 TP=2 Deployment
  local d="$LAB/k8s/vllm-tp2.yaml"
  ap=$(k apply -f "$d" 2>&1); arc=$?
  if [ $arc != 0 ]; then
    block_ids "kubectl apply vllm-tp2.yaml failed: $(echo "$ap" | head -1 | cut -c1-150)" 9.7a 9.7b 9.7c 9.7d 9.7e
  else
    local ready=0 pods
    within 90 app_running vllm-tp2 && ready=1
    pods=$(k -n "$NS" get pods -l app=vllm-tp2 -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ')
    if [ "$ready" = 1 ] && [ "${pods% }" = "$BIG" ]; then pass 9.7a "vllm-tp2 pod Running on $BIG (the only node with 2 GPUs)"
    else
      local pn; pn=$(k -n "$NS" get pods -l app=vllm-tp2 -o name | head -1); pn=${pn#pod/}
      fail 9.7a "vllm-tp2 not Running on $BIG: ${pn:+$(sched_msg "$pn" | cut -c1-200)} nodes='${pods}'"
    fi
    local dj; dj=$(k -n "$NS" get deploy vllm-tp2 -o json)
    local lim req txt tp
    lim=$(echo "$dj" | jq -r '.spec.template.spec.containers[0].resources.limits["nvidia.com/gpu"] // ""')
    req=$(echo "$dj" | jq -r '.spec.template.spec.containers[0].resources.requests["nvidia.com/gpu"] // ""')
    txt=$(echo "$dj" | jq -r '.spec.template.spec.containers[0] | ((.command // []) + (.args // [])) | join(" ")')
    tp=$(echo "$txt" | grep -oE -- '--tensor-parallel-size[= ][0-9]+' | head -1 | grep -oE '[0-9]+$')
    if [ "$lim" = 2 ] && [ "$tp" = 2 ] && { [ -z "$req" ] || [ "$req" = 2 ]; }; then pass 9.7b "limits nvidia.com/gpu = 2 and --tensor-parallel-size 2 agree"
    else fail 9.7b "limits.nvidia.com/gpu='${lim:-none}' vs --tensor-parallel-size='${tp:-none}' - a TP=N server needs N GPUs in its pod, and they must agree"; fi
    local shm; shm=$(echo "$dj" | jq -r '[.spec.template.spec.containers[0].volumeMounts[]? | select(.mountPath=="/dev/shm") | .name] as $n | [.spec.template.spec.volumes[]? | select(.name as $v | $n | any(. == $v)) | select(.emptyDir.medium=="Memory")] | length')
    if [ "$shm" = 1 ]; then pass 9.7c "/dev/shm is a Memory emptyDir"
    else fail 9.7c "/dev/shm is not a Memory-backed emptyDir - the default 64 MiB shared memory breaks TP worker communication"; fi
    if passed 9.7a; then
      local rn="n$NONCE" rok=0
      k -n "$NS" patch deploy vllm-tp2 --type merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"verify/rollout\":\"$rn\"}}}}}" >/dev/null 2>&1
      k -n "$NS" rollout status deploy/vllm-tp2 --timeout=120s >/dev/null 2>&1 && rok=1
      local cur; cur=$(k -n "$NS" get pods -l app=vllm-tp2 -o json | jq -r --arg r "$rn" '[.items[] | select(.metadata.annotations["verify/rollout"]==$r and .status.phase=="Running")] | length')
      if [ "$rok" = 1 ] && [ "$cur" -ge 1 ]; then pass 9.7d "a new revision rolls out to Running with no spare GPU (strategy lets the old pod go first)"
      else
        local st; st=$(echo "$dj" | jq -r '.spec.strategy | tostring' | cut -c1-80)
        fail 9.7d "rollout of a new revision did not finish in 120 s (strategy $st): the new pod needs 2 GPUs while the old one still holds them"
      fi
      # negative control: same pod template, forced to the 1-GPU node
      local live; live=$(k -n "$NS" get deploy vllm-tp2 -o json)
      k -n "$NS" delete deploy vllm-tp2 --grace-period=1 --wait=true --timeout=90s >/dev/null 2>&1
      echo "$live" | jq --arg n "$SMALL" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"vllm-tp2-small",namespace:"gpu-lab",labels:{course:"aiinfra"}},
        spec:{replicas:1,strategy:{type:"Recreate"},selector:{matchLabels:{app:"vllm-tp2-small"}},
        template:{metadata:{labels:{app:"vllm-tp2-small",course:"aiinfra"}},spec:(.spec.template.spec | .nodeSelector={"kubernetes.io/hostname":$n} | del(.nodeName))}}}' | k apply -f - >/dev/null 2>&1
      within 60 app_has_msg vllm-tp2-small
      local sm sp; sp=$(k -n "$NS" get pods -l app=vllm-tp2-small -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
      sm=$(k -n "$NS" get pods -l app=vllm-tp2-small -o jsonpath='{.items[0].status.conditions[?(@.reason=="Unschedulable")].message}' 2>/dev/null)
      if [ "$sp" = Pending ] && [[ "$sm" == *"Insufficient nvidia.com/gpu"* ]]; then pass 9.7e "control: the same pod forced onto the 1-GPU node stays Pending with Insufficient nvidia.com/gpu"
      else fail 9.7e "the 2-GPU pod template was not rejected by the 1-GPU node (phase=${sp:-none}) - check that limits really is 2"; fi
    else block_ids "needs 9.7a" 9.7d 9.7e; fi
  fi
  wipe_ns

  # ---------------- T planted fault
  local bp="$LAB/k8s/broken-gpu-pod.yaml"
  ap=$(k apply -f "$bp" 2>&1); arc=$?
  if [ $arc != 0 ]; then fail T.1 "kubectl apply broken-gpu-pod.yaml failed: $(echo "$ap" | head -1 | cut -c1-180)"
  elif wait_running broken-gpu 90; then
    lim=$(k -n "$NS" get pod broken-gpu -o jsonpath='{.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null)
    if [ "$lim" = 1 ]; then pass T.1 "broken-gpu is Running and holds one GPU"
    else fail T.1 "broken-gpu runs but requests nvidia.com/gpu='${lim:-none}' - the task keeps the one-GPU request"; fi
  else fail T.1 "broken-gpu not Running: $(sched_msg broken-gpu | cut -c1-260)"; fi
  if passed T.1; then
    local pinned tol keys
    pinned=$("$PY" -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print((d.get('spec') or {}).get('nodeName',''))" "$bp" 2>/dev/null)
    tol=$(k -n "$NS" get pod broken-gpu -o json | jq -r '[.spec.tolerations[]? | select(.key=="nvidia.com/gpu")] | length')
    keys=$(k -n "$NS" get pod broken-gpu -o json | jq -r '[.spec.containers[0].resources.limits | keys[] | select(startswith("nvidia"))] | join(",")')
    if [ -z "$pinned" ] && [ "$tol" -ge 1 ] && [ "$keys" = "nvidia.com/gpu" ] && [ "$(node_val $BIG '[.spec.taints[]?|select(.key=="nvidia.com/gpu")]|length')" = 1 ]; then pass T.2 "fixed properly: correct resource name and a toleration; no nodeName pinning, taints untouched"
    else fail T.2 "pod runs but not by the intended fix (nodeName='${pinned}', tolerations=${tol}, gpu keys='${keys}', taint on $BIG intact?)"; fi
  else blocked T.2 "needs T.1"; fi
  wipe_ns
}

[ "$PART" = A ] || [ "$PART" = all ] && part_a
[ "$PART" = B ] || [ "$PART" = all ] && part_b
summary
