#!/usr/bin/env bash
# Generic checks N.3 (root cause), N.4 (evidence vs live data) and N.5 (postmortem).  Sourced by verify.sh after common.sh.
COMPONENTS="gateway router serving gpu artifact kubernetes client"
CAUSES="bad-release misconfiguration rate-limit-misconfig kv-cache-exhaustion capacity-overload hardware-fault artifact-integrity air-gap-leak scheduling-config dependency-outage runaway-client"
exp_comp() { case "$1" in 1) echo gateway;; 2) echo serving;; 3) echo gpu;; 4) echo artifact;; 5) echo kubernetes;; esac; }
exp_cause() { case "$1" in 1) echo rate-limit-misconfig;; 2) echo kv-cache-exhaustion;; 3) echo hardware-fault;; 4) echo artifact-integrity;; 5) echo scheduling-config;; esac; }
kw() { case "$1" in   # mechanism keywords (regex alternatives, comma separated) for the statement and the postmortem root cause
  1) echo "limit,rpm,parallel,cache,valkey,redis,replica";;
  2) echo "max.num.seqs,kv,cache,preempt,slots,prefix";;
  3) echo "xid,gpu,node,cooldown,timeout,router,eject,drain";;
  4) echo "checksum,sha,manifest,tokenizer,shard,offline,integrity,artifact";;
  5) echo "taint,toleration,time.slicing,capacity,resource,device.plugin,pending";;
esac; }

cause_hint() {  # N CAUSE -> discrimination rule that rejects the wrong enum value (never the answer)
  case "$1:$2" in
    1:runaway-client) echo "runaway-client needs a correct agreement that the client broke - was there any enforced limit on that key, and at which scope? (theory 6)";;
    1:capacity-overload|2:capacity-overload|3:capacity-overload) echo "capacity-overload means demand exceeds capacity with everything configured correctly - check saturation signals and whether the load or the configuration changed (theory 6)";;
    1:bad-release|3:bad-release) echo "bad-release needs a deployed change in the component's own behaviour; ask what changed and whether the symptom follows the change (theory 6)";;
    2:bad-release) echo "the release is the trigger; the enum asks which resource saturated because of it (theory 6)";;
    3:misconfiguration|1:misconfiguration|5:misconfiguration|2:misconfiguration) echo "misconfiguration is the catch-all; the enum has a more specific class for this failure - pick the class that names the broken mechanism (theory 6)";;
    4:air-gap-leak) echo "the lookups are real, but ask which fault would remain if the network were perfect - the enum names the root, the leak is a contributing factor (theory 6)";;
    4:dependency-outage|5:dependency-outage|1:dependency-outage|2:dependency-outage|3:dependency-outage) echo "dependency-outage needs a downstream system that is down; check whether anything the path depends on actually was (theory 6)";;
    5:hardware-fault|5:capacity-overload) echo "hardware-fault needs a fault signal from the device; capacity-overload needs real demand. Read what the scheduler says first (theory 3.5, 6)";;
    *) echo "the CAUSE does not fit the evidence of this incident - compare the enum definitions in lab.md with the signals you collected (theory 6)";;
  esac
}
comp_hint() { echo "the layer that shows the symptom is not necessarily the layer where the first failing mechanism lives - walk down the layers and find the deepest one that explains the signals (theory 2, 6)"; }

check_3() {  # N
  local N="$1" f="$LAB/answers/$1-rootcause.env" comp cause st nw
  comp=$(lc "$(kvf "$f" COMPONENT)"); cause=$(lc "$(kvf "$f" CAUSE)"); st=$(kvf "$f" STATEMENT)
  if tmpl "$comp" || tmpl "$cause"; then fail "$N.3" "lab/answers/$N-rootcause.env: COMPONENT and CAUSE still hold the template placeholders - pick one value from each list in lab.md"
  elif ! [[ " $COMPONENTS " == *" $comp "* ]]; then fail "$N.3" "COMPONENT='$comp' is not one of: $COMPONENTS"
  elif ! [[ " $CAUSES " == *" $cause "* ]]; then fail "$N.3" "CAUSE='$cause' is not in the enum table of lab.md"
  elif [ "$comp" != "$(exp_comp "$N")" ]; then fail "$N.3" "COMPONENT=$comp: $(comp_hint)"
  elif [ "$cause" != "$(exp_cause "$N")" ]; then fail "$N.3" "CAUSE=$cause: $(cause_hint "$N" "$cause")"
  else
    nw=$(nwords "$st")
    if tmpl "$st" || [ "$nw" -lt 6 ]; then fail "$N.3" "STATEMENT needs one sentence of your own (at least 6 words): what was configured how, and why that hurt users"
    elif ! printf '%s' "$(lc "$st")" | grep -Eq "$(kw "$N" | tr ',' '|')"; then fail "$N.3" "STATEMENT names no mechanism - say what was configured how (the keywords are in the signals you found), not just the symptom"
    else pass "$N.3" "COMPONENT and CAUSE match the incident and the statement names the mechanism"; fi
  fi
}

# ---- evidence ---------------------------------------------------------------------------------------
ef() { kvf "$LAB/answers/$1-evidence.env" "$2"; }       # N FIELD
near() {  # VALUE TARGET REL ABS -> 0 if |v-t| <= max(abs, rel*t)
  awk -v v="$1" -v t="$2" -v r="$3" -v a="$4" 'BEGIN{d=v-t; if(d<0)d=-d; m=r*t; if(m<a)m=a; exit !(d<=m)}'
}
check_4() {
  local N="$1" bad="" v t live src=""
  case "$N" in
  1)
    src="the gateway key list/team info (/key/list, /team/info), the gateway's failure metrics in Prometheus for the chat key's alias, and a comparison of the two replicas"
    v=$(ef 1 HEAVY_KEY_ALIAS); [ "$(lc "$v")" = "agent-$(vget 1 V)" ] || bad+="HEAVY_KEY_ALIAS, "
    v=$(ef 1 TEAM_RPM_LIMIT); [ "$v" = "$(vget 1 TEAM_RPM)" ] || bad+="TEAM_RPM_LIMIT, "
    v=$(ef 1 CHAT_429_COUNT); t=$(tget 1 CHAT_429_COUNT); { num "$v" && near "$v" "$t" 0.25 3; } || bad+="CHAT_429_COUNT, "
    v=$(lc "$(ef 1 LIMIT_SCOPE)"); [ "$v" = per-replica ] || bad+="LIMIT_SCOPE, " ;;
  2)
    src="Prometheus over the incident window printed by prepare-lab (max_over_time / increase on the vllm:* series of mock-vllm-a) and lab/incident-2/RELEASE-NOTES.md"
    live=$(pq_win 2 'max_over_time(vllm:kv_cache_usage_perc{instance="mock-vllm-a"}[%D%])')
    if [ -z "$live" ]; then bad+="(Prometheus has no data for the incident window - is the obs profile up?) "; else
      v=$(ef 2 KV_PEAK); { num "$v" && near "$v" "$(awk -v x="$live" 'BEGIN{printf "%.1f", x*100}')" 0 4; } || bad+="KV_PEAK, "
      live=$(pq_win 2 'increase(vllm:num_preemptions_total{instance="mock-vllm-a"}[%D%])')
      v=$(ef 2 PREEMPTIONS); { num "$v" && near "$v" "${live:-0}" 0.2 3; } || bad+="PREEMPTIONS, "
      live=$(pq_win 2 'max_over_time(vllm:num_requests_waiting{instance="mock-vllm-a"}[%D%])')
      v=$(ef 2 PEAK_WAITING); { num "$v" && near "$v" "${live:-0}" 0.25 3; } || bad+="PEAK_WAITING, "
    fi
    v=$(ef 2 PLANTED_MAX_NUM_SEQS); [ "$v" = "$(vget 2 SEQS)" ] || bad+="PLANTED_MAX_NUM_SEQS, " ;;
  3)
    src="the DCGM exporters of both nodes (:18031 / :18032, nvidia-smi inside the container) and the per-backend request counters"
    v=$(lc "$(ef 3 AFFECTED_NODE)"); [ "$v" = "$(vget 3 NODE)" ] || bad+="AFFECTED_NODE, "
    v=$(ef 3 XID_CODE); [ "$v" = "$(vget 3 XID)" ] || bad+="XID_CODE, "
    v=$(lc "$(ef 3 GPU_UUID)"); [ "$v" = "$(lc "$(cat "$STATE/3/gpu_uuid")")" ] || bad+="GPU_UUID, "
    v=$(lc "$(ef 3 DRAIN_DECISION)"); [ "$v" = drain ] || bad+="DRAIN_DECISION, "
    v=$(ef 3 TEMP_C); { num "$v" && near "$v" "$(vget 3 TEMP)" 0 3; } || bad+="TEMP_C, " ;;
  4)
    src="sha256sum -c MANIFEST.sha256 on the snapshot as you found it, the tripwire /hits counter, and rollout.env"
    v=$(ef 4 MISSING_FILE); [ "$v" = "$(tget 4 MISSING_FILE)" ] || bad+="MISSING_FILE, "
    v=$(ef 4 BAD_FILE); [ "$v" = "$(tget 4 BAD_FILE)" ] || bad+="BAD_FILE, "
    v=$(lc "$(ef 4 BAD_SHA)"); [ "${#v}" -ge 12 ] && [ "${v:0:12}" = "$(tget 4 BAD_SHA)" ] || bad+="BAD_SHA, "
    v=$(lc "$(ef 4 TRIPWIRE_HOST)"); [ "$v" = "$(lc "$(tget 4 TRIPWIRE_HOST)")" ] || bad+="TRIPWIRE_HOST, "
    v=$(ef 4 TRIPWIRE_HITS); t=$(tget 4 TRIPWIRE_HITS); { num "$v" && [ "${v%.*}" -ge 1 ] && [ "${v%.*}" -le $((3 * t + 3)) ]; } || bad+="TRIPWIRE_HITS, " ;;
  5)
    src="kubectl describe pod / describe node / get events in namespace serving, and your own two files"
    v=$(ef 5 NODE_NAME); [ "$v" = "$(vget 5 NODE)" ] || bad+="NODE_NAME, "
    v=$(ef 5 TAINT_KEY); [ "$v" = "pool-$(vget 5 V)" ] || bad+="TAINT_KEY, "
    v=$(ef 5 WRONG_RESOURCE); [ "$v" = "nvidia.com/gpus" ] || bad+="WRONG_RESOURCE, "
    v=$(lc "$(ef 5 FIRST_REASON)"); [ "$v" = untolerated-taint ] || bad+="FIRST_REASON, "
    v=$(lc "$(ef 5 SECOND_REASON)"); [ "$v" = insufficient-gpu ] || bad+="SECOND_REASON, "
    live=$(k get node "$(vget 5 NODE)" -o json 2>/dev/null | jq -r '.status.allocatable["nvidia.com/gpu"] // empty')
    v=$(ef 5 GPU_CAPACITY_AFTER); { num "$v" && [ -n "$live" ] && [ "$live" -ge 1 ] && [ "$v" = "$live" ]; } || bad+="GPU_CAPACITY_AFTER, " ;;
  esac
  local f="$LAB/answers/$N-evidence.env" tp=0 line
  [ -f "$f" ] && while IFS= read -r line; do case "$line" in "#"*|"") ;; *) tmpl "$(printf '%s' "${line#*=}" | sed -E 's/[[:space:]]+#.*$//')" && tp=1;; esac; done < "$f"
  if [ ! -f "$f" ]; then fail "$N.4" "lab/answers/$N-evidence.env is missing"
  elif [ "$tp" = 1 ]; then fail "$N.4" "lab/answers/$N-evidence.env still has empty or template (<...>) fields - every value must come from the live signals ($src)"
  elif [ -n "$bad" ]; then fail "$N.4" "fields that do not match the live data of this incident: ${bad%, } - read them from $src; the values are specific to your run"
  else pass "$N.4" "all evidence fields match the live data of this incident"; fi
}

check_5() {
  local N="$1" r; r=$("$PY" "$LIB/pm_check.py" "$LAB/postmortem-$N.md" "$(exp_comp "$N")" "$(kw "$N")")
  case "$r" in OK*) pass "$N.5" "postmortem is complete: sections, UTC timeline, root cause with mechanism, mitigation vs fix, owned action items";; *) fail "$N.5" "lab/postmortem-$N.md: ${r#FAIL }";; esac
}
