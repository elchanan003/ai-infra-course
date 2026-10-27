#!/usr/bin/env bash
# VALIDATION ONLY: does the learner's work for incident N from LIVE signals where they exist (Prometheus window queries, DCGM, tripwire,
# kubectl), applies the fix through the learner-facing mechanisms (files + the GIVEN restart/apply helpers), writes the answer files and the
# postmortem.  usage: apply-solution.sh [N]   (default: the planted incident).  Backs up lab/ to lab.bak-<ts>/ first.  No manual steps.
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TUTOR/../lib/common.sh"
for i in 1 2 3 4 5; do source "$LIB/inc$i.sh"; done
N="${1:-$(current)}"
case "$N" in 1|2|3|4|5) ;; *) echo "apply-solution: no incident planted (usage: apply-solution.sh [1-5])" >&2; exit 2;; esac
S="$TUTOR/solution/lab"; A="$LAB/answers"
[ "$(current)" = "$N" ] || { echo "apply-solution: incident $N is not the planted one" >&2; exit 1; }
cp -a "$LAB" "$CAP/lab.bak-$(date +%Y%m%d%H%M%S)-$N"
adie() { echo "apply-solution: $*" >&2; exit 1; }
retry() { local t=$1; shift; local s; s=$(date +%s); until "$@"; do (( $(date +%s) - s > t )) && return 1; sleep 3; done; }
rnd() { printf '%.0f' "$1"; }

case "$N" in
1)
  V=$(vget 1 V); TL=$(vget 1 TEAM_RPM)
  trl=$(gw_key GET "/team/info?team_id=cap1-team-$V" | jq -r '.team_info.rpm_limit // empty'); [ -n "$trl" ] || adie "team info not readable"
  printf 'HEAVY_KEY_ALIAS=agent-%s\nTEAM_RPM_LIMIT=%s\nCHAT_429_COUNT=%s\nLIMIT_SCOPE=per-replica\n' "$V" "$trl" "$(tget 1 CHAT_429_COUNT)" > "$A/1-evidence.env"
  cp "$S/incident-1/litellm/config.yaml" "$LAB/incident-1/litellm/config.yaml"
  sed "s/@V@/$V/g; s/@AGENT_RPM@/$((TL - 14))/" "$S/incident-1/keys.yaml" > "$LAB/incident-1/keys.yaml"
  "$LAB/incident-1/restart.sh" || adie "restart failed"
  "$LAB/incident-1/apply-keys.sh" || adie "apply-keys failed" ;;
2)
  cj=$("$PY" "$LIB/cap.py" "$STATE/2/args.planted" "$LAB/incident-2/mock-vllm-a/gpu.yaml" "$CAP/../../mock/models/qwen2.5-7b"); kvtok=$(echo "$cj" | jq -r '.kv_tokens // empty')
  [ -n "$kvtok" ] || adie "capacity model refused: $cj"
  seqs=$(( kvtok * 85 / 100 / I2_SEQ_TOK )); [ "$seqs" -ge 1 ] || seqs=1
  kv=$(pq_win 2 'max_over_time(vllm:kv_cache_usage_perc{instance="mock-vllm-a"}[%D%])'); pre=$(pq_win 2 'increase(vllm:num_preemptions_total{instance="mock-vllm-a"}[%D%])')
  wt=$(pq_win 2 'max_over_time(vllm:num_requests_waiting{instance="mock-vllm-a"}[%D%])')
  [ -n "$kv" ] && [ -n "$pre" ] && [ -n "$wt" ] || adie "Prometheus has no data for the incident window"
  printf 'KV_PEAK=%s\nPREEMPTIONS=%s\nPEAK_WAITING=%s\nPLANTED_MAX_NUM_SEQS=%s\n' "$(awk -v x="$kv" 'BEGIN{printf "%.0f", x*100}')" "$(rnd "$pre")" "$(rnd "$wt")" "$(vget 2 SEQS)" > "$A/2-evidence.env"
  sed "s/@UTIL@/$(vget 2 UTIL)/; s/@SEQS@/$seqs/" "$S/incident-2/mock-vllm-a/args.tmpl" > "$LAB/incident-2/mock-vllm-a/args"
  "$LAB/incident-2/restart.sh" || adie "restart failed" ;;
3)
  node=""; code=""; uuid=""; temp=""
  for n in a b; do
    m=$(curl -fsS --max-time 10 "http://127.0.0.1:1803$([ $n = a ] && echo 1 || echo 2)/metrics") || continue
    line=$(echo "$m" | grep '^DCGM_FI_DEV_XID_ERRORS{' | awk '$NF+0 != 0' | head -1)
    [ -n "$line" ] || continue
    node=$n; code=$(rnd "$(echo "$line" | awk '{print $NF}')"); uuid=$(echo "$line" | sed -E 's/.*UUID="([^"]*)".*/\1/')
    temp=$(rnd "$(echo "$m" | grep '^DCGM_FI_DEV_GPU_TEMP{' | grep "UUID=\"$uuid\"" | awk '{print $NF}')")
  done
  [ -n "$node" ] && [ -n "$temp" ] || adie "no XID found in the DCGM exporters"
  printf 'AFFECTED_NODE=%s\nXID_CODE=%s\nGPU_UUID=%s\nDRAIN_DECISION=drain\nTEMP_C=%s\n' "$node" "$code" "$uuid" "$temp" > "$A/3-evidence.env"
  cp "$S/incident-3/litellm/config.yaml" "$LAB/incident-3/litellm/config.yaml"
  "$LAB/incident-3/restart.sh" || adie "restart failed" ;;
4)
  REV=$(vget 4 REV); snap=$(i4_snap "$LAB/incident-4/hf-cache" "$REV")
  chk=$(cd "$snap" && sha256sum -c "$LAB/incident-4/MANIFEST.sha256" 2>&1)
  missing=$(echo "$chk" | sed -n 's/^sha256sum: \(.*\): No such file.*/\1/p' | head -1); badf=$(echo "$chk" | sed -n 's/^\(.*\): FAILED$/\1/p' | head -1)
  [ -n "$missing" ] && [ -n "$badf" ] || adie "manifest check found no missing/corrupt file: $chk"
  badsha=$(sha256sum "$snap/$badf" | cut -c1-12)
  hh=$(curl -fsS --max-time 5 "$TRIPWIRE_URL/hits" | jq -r '(.hosts // .) | to_entries[] | select(.key | test("corp\\.internal")) | "\(.key) \(if (.value|type)=="object" then (.value.count // .value.hits // 0) else .value end)"' | head -1)
  host=${hh% *}; hits=${hh#* }; [ -n "$host" ] || { host=$(tget 4 TRIPWIRE_HOST); hits=$(tget 4 TRIPWIRE_HITS); }
  printf 'MISSING_FILE=%s\nBAD_FILE=%s\nBAD_SHA=%s\nTRIPWIRE_HOST=%s\nTRIPWIRE_HITS=%s\n' "$missing" "$badf" "$badsha" "$host" "$hits" > "$A/4-evidence.env"
  tmp=$(mktemp -d); oras pull --plain-http "$I4_REPO:$I4_TAG" -o "$tmp" >/dev/null 2>&1 || adie "oras pull failed"
  cp -f "$tmp"/* "$snap/" && rm -rf "$tmp"
  grep -q '^HF_HUB_OFFLINE=' "$LAB/incident-4/rollout.env" || cat "$S/incident-4/rollout.env.append" >> "$LAB/incident-4/rollout.env"
  chmod -R a+rX "$LAB/incident-4"
  (cd "$snap" && sha256sum -c "$LAB/incident-4/MANIFEST.sha256" >/dev/null 2>&1) || adie "files still differ from the manifest" ;;
5)
  V=$(vget 5 V); REPL=$(vget 5 REPL)
  node=$(k get nodes -l "gpu-pool=pool-$V" -o jsonpath='{.items[0].metadata.name}')
  tk=$(k get node "$node" -o json | jq -r '.spec.taints[]? | select(.key | startswith("pool-")) | .key' | head -1)
  wr=$(k get node "$node" -o json | jq -r '.status.allocatable | keys[] | select(startswith("nvidia")) | select(. != "nvidia.com/gpu")' | head -1)
  i5_events | head -1 | grep -q 'untolerated taint' || adie "first scheduler reason is not the taint: $(i5_events | head -1)"
  sed "s/@V@/$V/g" "$S/incident-5/model.yaml" > "$LAB/incident-5/model.yaml"        # step 1: toleration only
  "$LAB/incident-5/apply.sh" >/dev/null || adie "apply.sh failed (step 1)"
  retry 90 bash -c "kubectl --context kind-aiinfra -n serving get events --field-selector reason=FailedScheduling -o json | jq -r '.items[].message' | grep -q 'Insufficient nvidia.com/gpu'" || adie "second reason did not appear"
  sed "s/@REPL@/$REPL/" "$S/incident-5/time-slicing.yaml" > "$LAB/incident-5/time-slicing.yaml"   # step 2: the resource name
  "$LAB/incident-5/apply.sh" >/dev/null || adie "apply.sh failed (step 2)"
  retry 120 i5_pod_ready || adie "pod not Ready after the fix"
  cap=$(k get node "$node" -o json | jq -r '.status.allocatable["nvidia.com/gpu"]')
  printf 'NODE_NAME=%s\nTAINT_KEY=%s\nWRONG_RESOURCE=%s\nFIRST_REASON=untolerated-taint\nSECOND_REASON=insufficient-gpu\nGPU_CAPACITY_AFTER=%s\n' "$node" "$tk" "$wr" "$cap" > "$A/5-evidence.env" ;;
esac
cp "$S/answers/$N-rootcause.env" "$A/$N-rootcause.env"
cp "$S/postmortem-$N.md" "$LAB/postmortem-$N.md"
chmod -R a+rX "$LAB"
echo "apply-solution: incident $N fixed and answered"
