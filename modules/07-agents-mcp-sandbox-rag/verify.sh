#!/usr/bin/env bash
# Module 07 verify: executes YOUR loop, MCP servers, sandbox runner, RAG scripts and legacy runner live.
# Everything is measured by behaviour with fresh nonces; nothing is grepped. Takes ~3-5 minutes with a complete solution.
# Simulated parts: the "model" behind alias mock-a is scripted mock-chat (mock/README.md 3.8); embeddings are real (llama.cpp bge-small).
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; VH="$MODULE_DIR/.verify"; ST="$MODULE_DIR/.state"
PY="$PLATFORM_DIR/.venv/bin/python"
KEY="sk-lab07-student"
IMG="$PYTHON_IMAGE"
P_PROXY=18130; P_MCP=18131; P_EXEC=18132
ALL_IDS=(7.1a 7.1b 7.1c 7.1d 7.2a 7.2b 7.2c 7.2d 7.3a 7.3b 7.3c 7.3d 7.3e 7.3f 7.3g 7.3h 7.3i
         7.4a 7.4b 7.4c 7.4d 7.4e 7.4f 7.5a 7.5b 7.5c 7.5d 7.5e 7.5f T.1 T.2 T.3)

mkdir -p "$ST/pids" 2>/dev/null
W="$(mktemp -d "$ST/verify.XXXXXX")" || { echo "verify: run ./prepare-lab.sh first"; exit 1; }
chmod 755 "$W"
NONCE() { head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
COL=""

bg_start() { # NAME cmd... (env must be set by the caller); stdout/stderr -> $W/NAME.log
  local n="$1"; shift
  nohup "$@" >"$W/$n.log" 2>&1 &
  echo $! > "$ST/pids/$n"
}
bg_stop() {
  [ -f "$ST/pids/$1" ] || return 0
  local p; p="$(cat "$ST/pids/$1")"
  kill "$p" 2>/dev/null; sleep 0.3; kill -9 "$p" 2>/dev/null
  rm -f "$ST/pids/$1"
}
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
sbx_left() { docker ps -aq --filter label=course=aiinfra --filter name=sbx- | wc -l; }
no_sbx() { [ "$(sbx_left)" = 0 ]; }
final_cleanup() {
  for n in proxy mcp exec; do bg_stop "$n"; done
  docker ps -aq --filter label=course=aiinfra --filter name=sbx- | xargs -r docker rm -f >/dev/null 2>&1
  docker ps -aq --filter label=course=aiinfra --filter label=module=07 | xargs -r docker rm -f >/dev/null 2>&1
  [ -n "$COL" ] && curl -fsS -o /dev/null --max-time 10 -X DELETE "$QDRANT_URL/collections/$COL" 2>/dev/null
  rm -rf "$W"
}
trap final_cleanup EXIT

# ------------------------------------------------------------------ preconditions (not scored)
pre_ok=1
precond "gateway up" wait_http "$LITELLM_URL/health/liveliness" 20 || pre_ok=0
precond "lab key works on mock-a (run ./prepare-lab.sh)" test "$(litellm_code "$KEY" mock-a ping)" = 200 || pre_ok=0
precond "mock-chat script loaded on mock-vllm A" bash -c "curl -fsS $MOCK_A_URL/admin/stats | jq -e '.script.enabled==true'" || pre_ok=0
precond "embedding alias answers" bash -c "curl -fsS -m 30 $LITELLM_URL/v1/embeddings -H 'Authorization: Bearer $KEY' -H 'Content-Type: application/json' -d '{\"model\":\"embed\",\"input\":[\"x\"]}' | jq -e '.data[0].embedding|length>0'" || pre_ok=0
precond "Qdrant up" wait_http "$QDRANT_URL/readyz" 20 || pre_ok=0
precond "tripwire up" wait_http "$TRIPWIRE_URL/health" 20 || pre_ok=0
precond "sandbox image present ($IMG)" docker image inspect "$IMG" || pre_ok=0
precond "venv python" test -x "$PY" || pre_ok=0
for p in $P_PROXY $P_MCP $P_EXEC; do
  if port_open $p; then echo "[PRE] port $p free: NOT OK (stop your dev servers on 18130-18132; use 18133/18134 for your own)"; pre_ok=0; fi
done
if [ "$pre_ok" != 1 ]; then
  for id in "${ALL_IDS[@]}"; do blocked "$id" "environment not ready - run ./prepare-lab.sh (see [PRE] lines above)"; done
  summary
fi
wait_idle 85 60 || { warn load "host CPU is busy; refusing to score (try again in a minute)"; exit 3; }

export GATEWAY="http://127.0.0.1:$P_PROXY" LAB_KEY="$KEY" AGENT_MODEL=mock-a EMBED_MODEL=embed QDRANT_URL SANDBOX_IMAGE="$IMG"
docker ps -aq --filter label=course=aiinfra --filter name=sbx- | xargs -r docker rm -f >/dev/null 2>&1   # leftovers from your experiments
LOG="$W/proxy.jsonl"; : > "$LOG"
bg_start proxy "$PY" "$VH/count_proxy.py" --port $P_PROXY --upstream "$LITELLM_URL" --log "$LOG"
within 15 port_open $P_PROXY || { for id in "${ALL_IDS[@]}"; do blocked "$id" "verify's logging proxy did not start"; done; summary; }

# =================================================================== 7.1 tool-calling loop
T1="T-$((RANDOM % 9000 + 1000))"; T2="T-$((RANDOM % 9000 + 1000))"; N1="$(NONCE)"; N2="$(NONCE)"
while [ "$T1" = "$T2" ]; do T2="T-$((RANDOM % 9000 + 1000))"; done
jq -n --arg a "$T1" --arg b "$T2" --arg na "$N1" --arg nb "$N2" \
  '{($a):("status=open owner=ops nonce="+$na), ($b):("status=closed owner=net nonce="+$nb), "T-0000":"status=open owner=nobody nonce=zero000000"}' > "$W/tickets.json"
chmod 644 "$W/tickets.json"
run_loop() { # TASK [extra args] -> OUT (stdout) RC
  : > "$LOG"
  OUT=$(cd "$MODULE_DIR" && TICKETS_JSON="$W/tickets.json" timeout 120 "$PY" lab/agent/loop.py --task "$1" "${@:2}" 2>"$W/loop.err"); RC=$?
}
run_loop "What is the status of ticket $T1?"
if [ $RC -eq 0 ] && grep -q "$N1" <<<"$OUT" && [ "$(printf '%s\n' "$OUT" | grep -c '')" -le 1 ]; then
  pass 7.1a "final answer carries the nonce that only exists in the tool result, stdout holds only the answer"
else
  if [ $RC -ne 0 ]; then fail 7.1a "loop.py exited $RC: $(tail -c 250 "$W/loop.err" | tr '\n' ' ')"
  elif ! grep -q "$N1" <<<"$OUT"; then fail 7.1a "the tool result never reached the final answer (did the model get the tools and the tool message? see theory 1.1)"
  else fail 7.1a "stdout must contain only the final answer (extra lines found)"; fi
fi
if passed 7.1a; then
  r=$("$PY" "$VH/analyze.py" linkage "$LOG" "$(jq -nc --arg t "$T1" --arg n "$N1" '{($t):$n}')") && pass 7.1b "second request carries the assistant tool_calls and a tool message with the matching tool_call_id" || fail 7.1b "$r"
else blocked 7.1b "needs 7.1a"; fi
if passed 7.1a; then
  run_loop "please compare $T1 and $T2"
  if [ $RC -ne 0 ]; then fail 7.1c "two tool calls in one assistant message: loop.py exited $RC: $(tail -c 200 "$W/loop.err" | tr '\n' ' ')"
  else
    r=$("$PY" "$VH/analyze.py" linkage "$LOG" "$(jq -nc --arg a "$T1" --arg b "$T2" --arg na "$N1" --arg nb "$N2" '{($a):$na,($b):$nb}')") \
      && pass 7.1c "two tool calls in one message: both answered, each result attached to its own tool_call_id" || fail 7.1c "$r"
  fi
else blocked 7.1c "needs 7.1a"; fi
if passed 7.1a; then
  run_loop "NEVERENDING ticket T-0000" --max-steps 3
  if [ $RC -ne 2 ]; then fail 7.1d "a model that never stops calling tools must end the run with exit code 2 after --max-steps (got exit $RC)"
  elif [ -n "$OUT" ]; then fail 7.1d "nothing but the final answer may go to stdout (a run without an answer prints none)"
  else r=$("$PY" "$VH/analyze.py" steps "$LOG" 3) && pass 7.1d "step limit enforced: exit 2 after exactly 3 model calls" || fail 7.1d "$r"; fi
else blocked 7.1d "needs 7.1a"; fi
bg_stop proxy

# =================================================================== 7.2 MCP server
W2="T-$((RANDOM % 9000 + 1000))"; N3="$(NONCE)"
jq -n --arg t "$W2" --arg n "$N3" '{($t):("status=pending owner=sre nonce="+$n)}' > "$W/tickets2.json"; chmod 644 "$W/tickets2.json"
(cd "$MODULE_DIR" && TICKETS_JSON="$W/tickets2.json" bg_start mcp "$PY" lab/mcp/server.py --port $P_MCP)
MCP_URL="http://127.0.0.1:$P_MCP/mcp"
mcp() { timeout 90 "$PY" "$VH/mcp_call.py" "$MCP_URL" "$@" 2>/dev/null; }
if within 25 port_open $P_MCP; then
  L=$(mcp list)
  if jq -e '(.tools|map(.name)|sort)==["ticket_status","word_count"]
      and all(.tools[]; (.description|length)>0 and .schema.type=="object")
      and ((.tools[]|select(.name=="word_count")|.schema.required)==["text"])
      and ((.tools[]|select(.name=="ticket_status")|.schema.required)==["ticket_id"])' <<<"$L" >/dev/null 2>&1; then
    pass 7.2a "tools/list: exactly word_count and ticket_status, described, typed object schemas with the right required parameter"
    ok2=1
  else
    fail 7.2a "tools/list must show exactly word_count(text) and ticket_status(ticket_id) with descriptions and an object inputSchema; got: $(jq -c '[.tools[]?|{name,desc:(.description|length),req:.schema.required}] // .' <<<"$L" 2>/dev/null | head -c 300)"
    ok2=0
  fi
else
  fail 7.2a "nothing listens on 127.0.0.1:$P_MCP after 25 s (Streamable HTTP, --port honoured?): $(tail -c 250 "$W/mcp.log" | tr '\n' ' ')"
  ok2=0
fi
if [ "$ok2" = 1 ]; then
  K=$((RANDOM % 7 + 6)); SENT=""; for _ in $(seq $K); do SENT="$SENT w$(NONCE)"; done
  R=$(mcp call word_count "$(jq -nc --arg t "$SENT" '{text:$t}')")
  [ "$(jq -r '.text' <<<"$R" 2>/dev/null)" = "$K" ] && [ "$(jq -r '.is_error' <<<"$R" 2>/dev/null)" = false ] \
    && pass 7.2b "word_count counted a nonce-word sentence correctly" || fail 7.2b "word_count of a $K-word sentence returned: $(jq -c . <<<"$R" 2>/dev/null | head -c 200)"
  R=$(mcp call ticket_status "$(jq -nc --arg t "$W2" '{ticket_id:$t}')")
  grep -q "$N3" <<<"$(jq -r '.text' <<<"$R" 2>/dev/null)" && pass 7.2c "ticket_status returned the record from the ticket file (nonce present)" \
    || fail 7.2c "ticket_status did not return the record of $W2 from \$TICKETS_JSON: $(jq -c . <<<"$R" 2>/dev/null | head -c 200)"
  R=$(mcp call "no_such_tool_$(NONCE)" '{}')
  R2=$(mcp call word_count '{"text":"still alive"}')
  rejected=$(jq -r 'if .is_error==true or has("exception") then "yes" else "no" end' <<<"$R" 2>/dev/null)
  if [ "$rejected" = yes ] && [ "$(jq -r '.text' <<<"$R2" 2>/dev/null)" = 2 ] && kill -0 "$(cat "$ST/pids/mcp")" 2>/dev/null; then
    pass 7.2d "unknown tool rejected (error result), server still serves requests"
  else fail 7.2d "unknown tool must be rejected without killing the server (rejected=$rejected, next call: $(jq -c .text <<<"$R2" 2>/dev/null))"; fi
else
  for id in 7.2b 7.2c 7.2d; do blocked $id "needs 7.2a"; done
fi
bg_stop mcp

# =================================================================== 7.3 sandbox runner
RUNNER="$LAB/sandbox/run_sandboxed.sh"
mkprobe() { # NAME [SECS] -> $W/NAME.py with the nonce filled in
  sed "s/__NONCE__/$SN/g;s/__SECS__/${2:-1}/g" "$VH/probes/$1.py" > "$W/$1.py"; chmod 644 "$W/$1.py"
}
run_sbx() { # SCRIPT [TIMEOUT] -> OUT RC ELAPSED
  local s=$SECONDS
  OUT=$(timeout 90 bash "$RUNNER" "$1" "${2:-10}" 2>"$W/sbx.err"); RC=$?
  ELAPSED=$((SECONDS - s))
}
SN="$(NONCE)"
[ -f "$RUNNER" ] || { for id in 7.3a 7.3b 7.3c 7.3d 7.3e 7.3f 7.3g 7.3h 7.3i; do fail $id "lab/sandbox/run_sandboxed.sh is missing"; done; }
if [ -f "$RUNNER" ]; then
  # b (computed first because a and i depend on it)
  mkprobe net; run_sbx "$W/net.py"
  net_ok=0
  jq -e '(.ifs|length)==0 and .connect==false and .dns==false' <<<"$OUT" >/dev/null 2>&1 && net_ok=1
  mkprobe benign; run_sbx "$W/benign.py"; ben_rc=$RC; ben_out="$OUT"; ben_err="$(tail -c 200 "$W/sbx.err" | tr '\n' ' ')"
  if [ $net_ok = 1 ] && [ $ben_rc -eq 0 ] && grep -q "OK $SN" <<<"$ben_out"; then pass 7.3a "benign job runs: prints its nonce and uses /tmp (hardening did not break the sandbox)"
  elif [ $net_ok = 0 ]; then blocked 7.3a "needs 7.3b (a sandbox that denies nothing proves nothing)"
  else fail 7.3a "benign job failed (exit $ben_rc): $ben_err"; fi
  if [ $net_ok = 1 ]; then pass 7.3b "no network interface besides lo, outbound connect and DNS fail"
  elif jq -e . >/dev/null 2>&1 <<<"$OUT"; then fail 7.3b "the job still has network access (interfaces: $(jq -c .ifs <<<"$OUT"), connect=$(jq .connect <<<"$OUT"), dns=$(jq .dns <<<"$OUT")): which docker network mode removes the interface? (theory 4.2)"
  else fail 7.3b "net probe produced no result (exit $RC): $(tail -c 200 "$W/sbx.err" | tr '\n' ' ')"; fi

  mkprobe write; run_sbx "$W/write.py"
  if [ $RC -eq 0 ] && jq -e 'all(.[]; .==false)' <<<"$OUT" >/dev/null 2>&1; then pass 7.3c "root filesystem not writable (/var/tmp, /etc, /usr, /)"
  elif jq -e . >/dev/null 2>&1 <<<"$OUT"; then fail 7.3c "job could write to: $(jq -r 'to_entries|map(select(.value)|.key)|join(" ")' <<<"$OUT"); a non-root user alone does not make /var/tmp read-only"
  else fail 7.3c "write probe produced no result (exit $RC): $(tail -c 200 "$W/sbx.err" | tr '\n' ' ')"; fi

  mkprobe tmpfs; run_sbx "$W/tmpfs.py"
  mib=$(jq -r '.mib' <<<"$OUT" 2>/dev/null)
  if [ -n "$mib" ] && [ "$mib" -ge 1 ] && [ "$mib" -le 32 ]; then pass 7.3d "/tmp is writable but capped (wrote $mib MiB before ENOSPC)"
  elif [ -n "$mib" ] && [ "$mib" -ge 33 ]; then fail 7.3d "/tmp took $mib MiB: an uncapped writable area lets a job fill the disk (theory 4.2, tmpfs size)"
  else fail 7.3d "/tmp must be writable (the benign job needs it); probe result: ${mib:-none}"; fi

  mkprobe fork; run_sbx "$W/fork.py" 20
  forked=$(jq -r '.forked' <<<"$OUT" 2>/dev/null)
  if [ -n "$forked" ] && [ "$forked" -lt 150 ] && [ "$(jq -r '.error' <<<"$OUT")" != null ]; then pass 7.3e "fork bomb contained after $forked processes"
  elif [ -n "$forked" ]; then fail 7.3e "$forked child processes were forked without hitting a limit: what bounds the number of processes in a container?"
  else fail 7.3e "fork probe produced no result (exit $RC): $(tail -c 200 "$W/sbx.err" | tr '\n' ' ')"; fi

  mkprobe mem; run_sbx "$W/mem.py" 20
  last=$(printf '%s\n' "$OUT" | tail -1)
  swap_note=""
  mkprobe sleep 8; (timeout 60 bash "$RUNNER" "$W/sleep.py" 20 >/dev/null 2>&1 &) ; sleep 0.5
  sid=""; for _ in $(seq 20); do sid=$(docker ps -q --no-trunc --filter name=sbx- | head -1); [ -n "$sid" ] && break; sleep 0.5; done
  [ -n "$sid" ] && docker inspect "$sid" > "$W/live.json" 2>/dev/null
  if [ "$RC" -ne 0 ] && [ -n "$last" ] && [ "$last" -lt 400 ] 2>/dev/null; then
    swap_ok=1
    if ! docker info 2>/dev/null | grep -qi 'swap limit'; then
      jq -e '.[0].HostConfig | .Memory>0 and .MemorySwap==.Memory' "$W/live.json" >/dev/null 2>&1 || swap_ok=0
    else warn 7.3f "host kernel has no swap limit support: swap setting not checked"; fi
    if [ $swap_ok = 1 ]; then pass 7.3f "memory hog killed (exit $RC) at ~${last} MiB, swap equals memory"
    else fail 7.3f "hog stopped at ${last} MiB but the container may still use swap: compare HostConfig Memory and MemorySwap (theory 4.2 notes)"; fi
  elif [ "$RC" -eq 0 ]; then fail 7.3f "memory hog ran to completion (${last} MiB): no memory limit applies"
  else fail 7.3f "hog reached ${last:-?} MiB before dying (limit too high, or swap lets it grow past the cap)"; fi
  for _ in $(seq 30); do [ "$(sbx_left)" = 0 ] && break; sleep 1; done

  mkprobe id; run_sbx "$W/id.py"
  if jq -e '.uid!=0 and (.caps|test("^0+$")) and .nnp==1' <<<"$OUT" >/dev/null 2>&1; then pass 7.3g "uid $(jq .uid <<<"$OUT"), no effective capabilities, no-new-privileges set"
  elif jq -e . >/dev/null 2>&1 <<<"$OUT"; then fail 7.3g "identity inside the job: uid=$(jq .uid <<<"$OUT") CapEff=$(jq -r .caps <<<"$OUT") NoNewPrivs=$(jq .nnp <<<"$OUT"); a sandbox runs as nobody with no capabilities and cannot gain privileges"
  else fail 7.3g "id probe produced no result (exit $RC): $(tail -c 200 "$W/sbx.err" | tr '\n' ' ')"; fi

  # h: both timeout layers + naming/labelling + no leaked containers
  mkprobe loop; run_sbx "$W/loop.py" 3; l_rc=$RC; l_el=$ELAPSED; l_out="$OUT"
  mkprobe ignore_term; run_sbx "$W/ignore_term.py" 3; i_rc=$RC; i_el=$ELAPSED; i_out="$OUT"
  within 15 no_sbx; left_n=$(sbx_left)
  name_ok=0
  if [ -n "$sid" ] && jq -e '.[0] | (.Name|startswith("/sbx-")) and (.Config.Labels["course"]=="aiinfra")' "$W/live.json" >/dev/null 2>&1; then name_ok=1; fi
  if [ $l_rc -eq 124 ] && [ $i_rc -eq 124 ] && [ $l_el -le 14 ] && [ $i_el -le 14 ] && [ "$left_n" = 0 ] && [ $name_ok = 1 ]; then
    pass 7.3h "spin loop and SIGTERM-ignoring job both end with exit 124 within the timeout+grace, no sbx-* container left, containers are named sbx-* and labelled"
  else
    fail 7.3h "timeouts/cleanup: spin loop exit=$l_rc in ${l_el}s, SIGTERM-ignoring exit=$i_rc in ${i_el}s (want 124, <=14s), leaked containers=$left_n, named+labelled=$name_ok. Two layers are needed: what stops a process that ignores SIGTERM?"
  fi

  # i: control - same caps, but an open (air-gap) network: the tripwire must see the probe
  if [ $net_ok = 1 ]; then
    mkprobe net
    CO=$(sandbox_run --read-only --tmpfs /tmp:size=16m --pids-limit 64 --memory 256m --memory-swap 256m --user 65534:65534 \
        -v "$W/net.py:/job.py:ro" "$IMG" python /job.py 2>/dev/null)
    tw_seen() { [ "$(tripwire_hits "x$SN")" -ge 1 ]; }
    within 8 tw_seen
    th=$(tripwire_hits "x$SN")
    if jq -e '(.ifs|length)>=1 and .dns==true' <<<"$CO" >/dev/null 2>&1 && [ "${th:-0}" -ge 1 ]; then
      pass 7.3i "control: same caps with an open network DOES reach the tripwire ($th hit), so 7.3b measures your --network choice"
    else fail 7.3i "control probe did not behave as expected (verify's own air-gap run: ifs/dns=$(jq -c '[.ifs,.dns]' <<<"$CO" 2>/dev/null), tripwire hits=$th): is the stack profile 'store' healthy?"; fi
  else blocked 7.3i "needs 7.3b"; fi
fi
docker ps -aq --filter label=course=aiinfra --filter name=sbx- | xargs -r docker rm -f >/dev/null 2>&1

# =================================================================== 7.4 code execution as an MCP tool
if passed 7.3a; then
  (cd "$MODULE_DIR" && SANDBOX_IMAGE="$IMG" bg_start exec "$PY" lab/mcp/exec_server.py --port $P_EXEC)
  MCP_URL="http://127.0.0.1:$P_EXEC/mcp"
  call_py() { # CODE [TIMEOUT_S] -> R (tool result JSON) ; ELAPSED
    local s=$SECONDS args
    args=$(jq -nc --arg c "$1" --argjson t "${2:-5}" '{code:$c,timeout_s:$t}')
    R=$(mcp call run_python "$args"); ELAPSED=$((SECONDS - s))
    RES=$(jq -r '.text // empty' <<<"$R" 2>/dev/null)
  }
  if within 25 port_open $P_EXEC; then
    NA=$((RANDOM % 900 + 100)); NB=$((RANDOM % 90 + 10)); prod=$((NA * NB))
    cat > "$W/code4a.py" <<'PY'
s = "$(id -u) `x` ';\" "
print(s + str(__A__ * __B__))
PY
    code=$(sed "s/__A__/$NA/;s/__B__/$NB/" "$W/code4a.py")
    exp="\$(id -u) \`x\` ';\" $prod"
    call_py "$code"
    if [ "$(jq -r .exit_code <<<"$RES" 2>/dev/null)" = 0 ] && [ "$(jq -r .stdout <<<"$RES" 2>/dev/null)" = "$exp" ]; then
      pass 7.4a "run_python returned the right stdout (shell metacharacters survived) and exit_code 0 through a real MCP client"
    else fail 7.4a "unexpected result: $(printf '%s' "$R" | head -c 300) (code goes to a file and is passed by argv, never through a shell string)"; fi
    call_py "raise ValueError('$SN')"
    ec=$(jq -r .exit_code <<<"$RES" 2>/dev/null)
    if [ -n "$ec" ] && [ "$ec" != 0 ] && [ "$ec" != null ] && jq -r .stderr <<<"$RES" | grep -q "ValueError: $SN" && port_open $P_EXEC; then
      pass 7.4b "raising code: exit_code $ec, traceback in stderr, server alive"
    else fail 7.4b "a script that raises must come back as exit_code != 0 with the traceback in stderr, and the server must survive: $(printf '%s' "$R" | head -c 250)"; fi
    mkprobe spin45; call_py "$(cat "$W/spin45.py")" 600
    if [ "$(jq -r .timed_out <<<"$RES" 2>/dev/null)" = true ] && [ $ELAPSED -le 42 ]; then pass 7.4c "timeout_s=600 was clamped: timed_out true within the cap"
    else fail 7.4c "spin loop with timeout_s=600: timed_out=$(jq -r .timed_out <<<"$RES" 2>/dev/null) after ${ELAPSED}s (must be true within ~33 s): the model controls timeout_s, you control the maximum"; fi
    within 15 no_sbx
    [ "$(sbx_left)" = 0 ] && pass 7.4d "no sbx-* container left after success, error and timeout" || fail 7.4d "$(sbx_left) sbx-* container(s) left after the calls"
    mkprobe net; call_py "$(cat "$W/net.py")"
    if jq -e '(.stdout|fromjson) | (.ifs|length)==0 and .connect==false and .dns==false' <<<"$RES" >/dev/null 2>&1; then pass 7.4e "hostile network code through the tool: no interface, connect and DNS fail"
    else fail 7.4e "code run through the tool can still use the network: $(jq -r .stdout <<<"$RES" 2>/dev/null | head -c 200)"; fi
    call_py 'import sys; sys.stdout.write("x" * 300000)'
    len=$(jq -r '.stdout|length' <<<"$RES" 2>/dev/null)
    if [ -n "$len" ] && [ "$len" -gt 0 ] && [ "$len" -le 70000 ]; then pass 7.4f "300000 bytes of output were cut to $len"
    else fail 7.4f "output must be truncated (64 KiB) before it goes back into the model context; stdout length was ${len:-?}"; fi
  else
    fail 7.4a "nothing listens on 127.0.0.1:$P_EXEC after 25 s: $(tail -c 250 "$W/exec.log" | tr '\n' ' ')"
    for id in 7.4b 7.4c 7.4d 7.4e 7.4f; do blocked $id "needs 7.4a"; done
  fi
  bg_stop exec
else
  for id in 7.4a 7.4b 7.4c 7.4d 7.4e 7.4f; do blocked $id "needs 7.3a (a working sandbox runner)"; done
fi

# =================================================================== 7.5 RAG ingestion
CS="$(NONCE)"; COL="v07-$CS"
"$PY" "$VH/mkcorpus.py" "$W/docs" "$CS" > "$W/exp.json"
NCH=$(jq .chunks "$W/exp.json")
DIM=$(curl -fsS -m 30 "$LITELLM_URL/v1/embeddings" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"embed","input":["dim"]}' | jq '.data[0].embedding|length')
bg_start proxy "$PY" "$VH/count_proxy.py" --port $P_PROXY --upstream "$LITELLM_URL" --log "$LOG"
within 15 port_open $P_PROXY
: > "$LOG"
ingest() { (cd "$MODULE_DIR" && timeout 300 "$PY" lab/rag/ingest.py --docs "$W/docs" --collection "$COL" >"$W/ingest.out" 2>&1); }
ingest; irc=$?
ecount=$("$PY" "$VH/analyze.py" embed "$LOG" "$NCH")   # judged on the FIRST run only
erc=$?
qc() { curl -fsS --max-time 30 "$QDRANT_URL$1" "${@:2}" 2>/dev/null; }
count() { qc "/collections/$COL/points/count" -H 'Content-Type: application/json' -d '{"exact":true}' | jq -r '.result.count'; }
if [ $irc -ne 0 ]; then
  fail 7.5a "ingest.py exited $irc: $(tail -c 250 "$W/ingest.out" | tr '\n' ' ')"
  for id in 7.5b 7.5c 7.5d 7.5e 7.5f; do blocked $id "needs 7.5a"; done
else
  info=$(qc "/collections/$COL")
  if jq -e --argjson d "$DIM" '.result.config.params.vectors | (.size==$d and .distance=="Cosine")' <<<"$info" >/dev/null 2>&1; then
    pass 7.5a "collection exists: size $DIM (the embedding model's dimension), Cosine"
  else fail 7.5a "collection must be one unnamed vector of size $DIM with Cosine distance; got $(jq -c '.result.config.params.vectors' <<<"$info" 2>/dev/null)"; fi
  c1=$(count)
  [ "$c1" = "$NCH" ] && pass 7.5b "points_count $c1 == $NCH non-empty paragraphs (.md/.txt only)" \
    || fail 7.5b "points_count is ${c1:-?}, expected $NCH: one point per non-empty paragraph, .json ignored, a whitespace-only line is a blank line"
  qc "/collections/$COL/points/scroll" -H 'Content-Type: application/json' -d '{"limit":1000,"with_payload":true,"with_vector":false}' \
    | jq -c '[.result.points[].payload|{source,chunk_index,text}]|sort_by(.source,.chunk_index)' > "$W/got.json" 2>/dev/null
  jq -c '[.paragraphs[]|{source,chunk_index,text}]|sort_by(.source,.chunk_index)' "$W/exp.json" > "$W/want.json"
  if cmp -s "$W/got.json" "$W/want.json"; then pass 7.5c "payloads (source, chunk_index, text) match the paragraphs exactly"
  else fail 7.5c "payloads differ from the expected paragraphs: got $(jq length "$W/got.json" 2>/dev/null) payload(s) vs $NCH expected; fields are source (file name), chunk_index (0-based per file), text (stripped paragraph)"; fi
  ingest
  c2=$(count)
  [ "$c2" = "$NCH" ] && [ "$c1" = "$NCH" ] && pass 7.5d "re-running ingest left points_count at $c2 (idempotent)" \
    || fail 7.5d "after a second ingest points_count is ${c2:-?} (first run: ${c1:-?}, expected $NCH): what must the point id be derived from?"
  okq=1; msgq=""
  for i in 0 1; do
    q=$(jq -r ".facts[$i].question" "$W/exp.json"); want="$(jq -r ".facts[$i].source" "$W/exp.json")#$(jq -r ".facts[$i].chunk_index" "$W/exp.json")"
    so=$(cd "$MODULE_DIR" && timeout 120 "$PY" lab/rag/search.py --collection "$COL" "$q" 2>"$W/search.err")
    top=$(head -1 <<<"$so" | cut -f2)
    nl=$(printf '%s\n' "$so" | grep -c '.')
    if [ "$top" != "$want" ] || [ "$nl" -ne 3 ]; then okq=0; msgq="$msgq fact$((i+1)): top='${top:-none}' want='$want' lines=$nl;"; fi
  done
  [ $okq = 1 ] && pass 7.5e "two known facts rank first; 3 lines of '<score>\\t<source>#<chunk_index>\\t<first line>' each" \
    || fail 7.5e "search ranking/format wrong:$msgq $(tail -c 150 "$W/search.err" | tr '\n' ' ')"
  [ $erc -eq 0 ] && pass 7.5f "embeddings were batched (all $NCH chunks embedded in few requests)" || fail 7.5f "$ecount"
fi
bg_stop proxy

# =================================================================== T the runner that "passed review"
LR="$LAB/sandbox/legacy_runner.sh"
JD="$ST/job-$(NONCE)"; JN="$(basename "$JD")"; mkdir -p "$JD"; chmod 755 "$JD"
TN="$(NONCE)"
cp "$VH/probes/mounts.py" "$JD/probe.py"
sed "s/__NONCE__/$TN/g" "$VH/probes/benign.py" > "$JD/benign.py"
sed "s/__NONCE__/$TN/g;s/__SECS__/10/g" "$VH/probes/sleep.py" > "$JD/sleep-$TN.py"
chmod 644 "$JD"/*.py
[ -S "$ST/run/dockerd.sock" ] || "$PY" -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()" "$ST/run/dockerd.sock"
if [ ! -f "$LR" ]; then
  for id in T.1 T.2 T.3; do fail $id "lab/sandbox/legacy_runner.sh was deleted: edit it, do not remove it"; done
else
  OUT=$(timeout 60 bash "$LR" "$JD/probe.py" 30 2>"$W/lr.err"); lrc=$?
  printf '%s' "$OUT" > "$W/mounts.json"
  r=$("$PY" "$VH/analyze.py" mounts "$W/mounts.json" "$JN") && pass T.1 "the job sees no Docker socket and no host path besides its job directory" || fail T.1 "$r"
  # live container (T.3): start a long job, inspect while it runs
  (timeout 60 bash "$LR" "$JD/sleep-$TN.py" 30 >/dev/null 2>&1 &); lid=""
  for _ in $(seq 30); do lid=$(docker ps --no-trunc --format '{{.ID}}|{{.Command}}' | grep "sleep-$TN" | head -1 | cut -d'|' -f1); [ -n "$lid" ] && break; sleep 0.5; done
  if [ -z "$lid" ]; then fail T.3 "could not find the running job container (does the runner still start the job?)"
  else
    docker inspect "$lid" > "$W/lr.json"
    bad=$(jq -r '.[0] | ([.Mounts[]? | select((.Source|test("docker\\.sock$")) or (.Destination|test("docker\\.sock$")) or .Source=="/etc" or (.Source|startswith("/etc/")) or .Source=="/" or .Source=="/var/run" or .Source=="/run") | .Source+" -> "+.Destination] + (if .HostConfig.Privileged then ["--privileged"] else [] end)) | join(", ")' "$W/lr.json")
    [ -z "$bad" ] && pass T.3 "inspected on the live container: no socket/host-/etc mount, not privileged" || fail T.3 "live container still has: $bad (docker inspect: Mounts, HostConfig.Privileged)"
  fi
  if passed T.1 && passed T.3; then
    OUT=$(timeout 60 bash "$LR" "$JD/benign.py" 30 2>"$W/lr.err"); lrc=$?
    [ $lrc -eq 0 ] && grep -q "OK $TN" <<<"$OUT" && pass T.2 "benign job still runs and prints its nonce" || fail T.2 "the runner no longer runs a benign job (exit $lrc): $(tail -c 200 "$W/lr.err" | tr '\n' ' ')"
  else blocked T.2 "needs T.1 and T.3 (a runner that runs nothing is not a fix)"; fi
fi
docker ps -aq --filter label=course=aiinfra --filter label=role=legacy | xargs -r docker rm -f >/dev/null 2>&1
rm -rf "$JD"
summary
