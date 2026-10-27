#!/usr/bin/env bash
# Incident 3 - GPU + router: a sick node stays in rotation.  Sourced by prepare-lab.sh / verify.sh.
# SIMULATED: the GPU hardware faults (mock-dcgm XID + thermal on one node) and the slow/failing engine on that node (mock-vllm fault.yaml).
# Real: LiteLLM router (retries, timeout, allowed_fails, cooldown), Prometheus. Production differs: real DCGM exporter, a real node that really misbehaves,
# drain/cordon through Kubernetes and a hardware ticket. The hardware fault is re-asserted on every restart (fault.yaml) - you cannot remove it, only protect users from it.

page_3() {
  cat <<MSG
PAGE 3 - $(date -u +%H:%M) UTC  "One replica is slow and the gateway keeps sending it traffic"
  p95 latency of the chat alias roughly doubled; about half of the requests are slow and a few fail. Load is normal.
  Two serving replicas (A, B) on two GPU nodes behind one gateway (http://127.0.0.1:18040, model "chat").
  Your file: lab/incident-3/litellm/config.yaml (gateway). Node-level facts: DCGM at :18031 (node A) / :18032 (node B), Prometheus :18090.
  Decide separately what you do about the node and what you do about the routing. Give the incident a minute or two to develop in the graphs.
  Restart the gateway after a config edit with the given lab/incident-3/restart.sh.
  $(win_text 3)
MSG
}

i3_write_state() {  # V NODE XID TEMP IDX  (healthy baseline; faults are added later)
  local V="$1" NODE="$2" XID="$3" TEMP="$4" IDX="$5"
  "$PY" - "$STATE/3" "$P/stack/config" "$NODE" "$XID" "$TEMP" "$IDX" <<'PY'
import os, shutil, sys, uuid, yaml
state, cfg, node, xid, temp, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
r = uuid
ids = {}
for n in "ab":
    for d in ("mock-vllm-" + n, "dcgm-" + n):
        os.makedirs(os.path.join(state, d), exist_ok=True)
    for f in ("args", "gpu.yaml"):
        shutil.copy(os.path.join(cfg, "mock-vllm-" + n, f), os.path.join(state, "mock-vllm-" + n, f))
    gl = []
    for i in range(2):
        u = "GPU-" + str(uuid.uuid4()); ids[(n, i)] = u
        gl.append(dict(model="NVIDIA A100-SXM4-80GB", memory_mib=81920, power_limit_w=400, util=34 + 5 * i, uuid=u))
    yaml.safe_dump(dict(hostname="gpu-node-" + n, gpus=gl), open(os.path.join(state, "dcgm-" + n, "gpus.yaml"), "w"), sort_keys=False)
    for d in ("mock-vllm-" + n, "dcgm-" + n):
        fp = os.path.join(state, d, "fault.yaml")
        if os.path.exists(fp): os.remove(fp)
open(os.path.join(state, "gpu_uuid"), "w").write(ids[(node, idx)])
PY
}

i3_inject() {  # writes the fault files of the sick node (they are re-read at every container start)
  local NODE XID TEMP IDX; NODE=$(vget 3 NODE); XID=$(vget 3 XID); TEMP=$(vget 3 TEMP); IDX=$(vget 3 IDX)
  cat > "$STATE/3/dcgm-$NODE/fault.yaml" <<YAML
faults:
  - {gpu: $IDX, xid: $XID}
  - {gpu: $IDX, thermal: $TEMP}
YAML
  cat > "$STATE/3/mock-vllm-$NODE/fault.yaml" <<YAML
latency_ms: 6000      # SIMULATED: requests on the sick GPU stall (virtual ms, paced in real time at MOCK_TIME_SCALE=1)
error_rate: 0.3
YAML
  chmod_pub "$STATE/3"
}

i3_config() {
  mkdir -p "$LAB/incident-3/litellm"
  cat > "$LAB/incident-3/litellm/config.yaml" <<'YAML'
# Gateway config (yours). Restart after edits:  lab/incident-3/restart.sh   (never "stack.sh up" without the lab environment)
model_list:
  - model_name: chat
    litellm_params: {model: openai/chat, api_base: "http://mock-vllm-a:8000/v1", api_key: none}   # SIMULATED replica A (gpu-node-a)
    model_info: {id: chat-a}
  - model_name: chat
    litellm_params: {model: openai/chat, api_base: "http://mock-vllm-b:8000/v1", api_key: none}   # SIMULATED replica B (gpu-node-b)
    model_info: {id: chat-b}

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  proxy_batch_write_at: 5                      # lab-only

litellm_settings:
  callbacks: ["prometheus"]
  require_auth_for_metrics_endpoint: false     # lab-only

# "Tuned for the November load test so that nothing flaps."
router_settings:
  routing_strategy: simple-shuffle
  num_retries: 0
  allowed_fails: 1000
  cooldown_time: 1
YAML
  write_restart 3 "$LAB/incident-3/restart.sh" "Recreates the gateway so it re-reads lab/incident-3/litellm/config.yaml."
  chmod_pub "$LAB/incident-3"
}

plant_3() {
  local V NODE XID TEMP IDX
  V=$(rhex 3); NODE=$(pick a b); XID=$(pick 79 48); TEMP=$(pick 89 90 91 92 93 94); IDX=$(pick 0 1)
  rm -rf "$STATE/3"; mkdir -p "$STATE/3"
  state_write "$STATE/3/variant.env" V="$V" NODE="$NODE" XID="$XID" TEMP="$TEMP" IDX="$IDX"
  i3_write_state "$V" "$NODE" "$XID" "$TEMP" "$IDX"
  i3_config
  echo "prepare-lab: converging profiles gw mock obs (healthy first; the fault is planted after a baseline)"
  stack_up_inc 3 || die "stack did not come up healthy (platform/stack.sh status)"
  inc_env 3; recreate mock-vllm-a mock-vllm-b mock-dcgm-a mock-dcgm-b
  local s; for s in mock-vllm-a mock-vllm-b mock-dcgm-a mock-dcgm-b; do svc_health "$s" 60 || die "$s not healthy"; done
  recreate litellm   # fresh DNS/connection pool: recreated backends get new container IPs (a stale pool/DNS entry may hit another container -> 404)
  gw_wait "$GW1" 120 || die "gateway not healthy"; prom_ready 60 || die "Prometheus not ready"
  echo "prepare-lab: 40 s of normal traffic (your 'before')"
  local b; b=$("$PY" "$LIB/loadgen.py" --urls "$GW1" --key "$LITELLM_KEY" --model chat --workers 1 --duration 40 --think-ms 700 --tag base)
  [ "$(echo "$b" | jq -r '.codes | keys | length')" = 1 ] && [ "$(echo "$b" | jq -r '.codes["200"] // 0')" -ge 10 ] || die "baseline traffic not clean: $b"
  echo "prepare-lab: hardware fault on one GPU node; traffic continues (70 s)"
  i3_inject; recreate "mock-vllm-$NODE" "mock-dcgm-$NODE"
  svc_health "mock-vllm-$NODE" 60 && svc_health "mock-dcgm-$NODE" 60 || die "sick node containers not healthy"
  recreate litellm; gw_wait "$GW1" 120 || die "gateway not healthy after the node restart"
  local t0; t0=$(date +%s)
  b=$("$PY" "$LIB/loadgen.py" --urls "$GW1" --key "$LITELLM_KEY" --model chat --workers 1 --duration 70 --think-ms 700 --timeout 30 --tag inc)
  win_set 3 "$t0" "$(date +%s)"
  [ "$(mock_chat_count "$(echo "$NODE" | tr a-z A-Z)")" -ge 3 ] || die "the sick replica received no traffic: $b"
  state_write "$STATE/3/truth.env" AFFECTED_NODE="$NODE" XID_CODE="$XID" GPU_UUID="$(cat "$STATE/3/gpu_uuid")" DRAIN_DECISION=drain TEMP_C="$TEMP"
  page_3
}

verify_3() {
  local NODE SICK n40 s0 s1 delta
  NODE=$(vget 3 NODE); SICK=$(echo "$NODE" | tr a-z A-Z)
  inc_env 3
  STACK_ALLOW_EXITED=1 "$P/stack.sh" up gw mock obs >/dev/null 2>&1
  i3_inject
  # hardware faults are re-asserted on the sick node (fresh containers read fault.yaml); the gateway restarts with the learner's file
  recreate "mock-vllm-$NODE" "mock-dcgm-$NODE"
  recreate litellm
  if ! { svc_health "mock-vllm-$NODE" 60 && gw_wait "$GW1" 150; }; then
    fail 3.1 "the gateway did not come back healthy with your config: $(svc_log_error litellm) (platform/stack.sh logs litellm)"; blocked 3.2 "needs 3.1"; return
  fi
  local sf; sf=$(curl -fsS "$(case $NODE in a) echo $MOCK_A_URL;; *) echo $MOCK_B_URL;; esac)/admin/fault" 2>/dev/null)
  [ "$(echo "$sf" | jq -r '.error_rate // 0')" != 0 ] || { warn 3.0 "the simulated hardware fault is not active on node $SICK - run ./prepare-lab.sh 3 again"; fail 3.1 "environment: fault not active"; blocked 3.2 "needs 3.1"; return; }
  s0=$(mock_chat_count "$SICK")
  n40=$("$PY" "$LIB/loadgen.py" --urls "$GW1" --key "$LITELLM_KEY" --model chat --workers 1 --count 40 --timeout 40 --tag "v$(rhex 2)")
  s1=$(mock_chat_count "$SICK"); delta=$((s1 - s0))
  # control: clear the fault on the sick replica; ejection must be temporary (it must serve again once the cooldown expires)
  curl -fsS -X DELETE "$(case $NODE in a) echo $MOCK_A_URL;; *) echo $MOCK_B_URL;; esac)/admin/fault" >/dev/null 2>&1
  local sc="$s1" back=0 t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 80 ]; do
    req_code "$GW1" "$LITELLM_KEY" chat "recover" >/dev/null
    sc=$(mock_chat_count "$SICK"); [ "$sc" -gt "$s1" ] && { back=1; break; }
    sleep 1
  done
  recreate "mock-vllm-$NODE"; svc_health "mock-vllm-$NODE" 60   # fault.yaml re-asserted
  if [ "$delta" -gt "$I3_SICK_MAX_HITS" ]; then
    fail 3.1 "the sick replica served $delta of 40 requests (allowed $I3_SICK_MAX_HITS): the router keeps routing to a deployment that fails and stalls - what takes a deployment out of rotation, and when does it come back? (theory 3.3)"
  elif [ "$back" != 1 ]; then
    fail 3.1 "after the fault was cleared the replica got no traffic for 80 s: ejection must be temporary (a cooldown), not permanent or very long"
  else pass 3.1 "the router stops sending traffic to the failing replica and takes it back after a cooldown once it is healthy"
    echo "~ sick replica served $delta/40 (limit $I3_SICK_MAX_HITS)"; fi
  if ! passed 3.1; then blocked 3.2 "needs 3.1"; return; fi
  local e5 lm; e5=$(echo "$n40" | jq -r '[.codes | to_entries[] | select(.key|test("^5|ERR")) | .value] | add // 0'); lm=$(echo "$n40" | jq -r '.lat_max')
  if [ "$e5" != 0 ]; then fail 3.2 "$e5 of 40 user requests failed (5xx/transport) while the sick replica was still in rotation: the router should retry on the healthy peer"
  elif ! awk -v m="$lm" -v t="$I3_MAX_WALL_S" 'BEGIN{exit !(m<t)}'; then fail 3.2 "the slowest user request took ${lm}s - about as long as the sick replica stalls: bound how long the router waits for one deployment"
  else pass 3.2 "40/40 user requests answered and none waited as long as the sick replica stalls, with the replica still faulty"
    echo "~ slowest request ${lm}s (limit ${I3_MAX_WALL_S}s)"; fi
}
