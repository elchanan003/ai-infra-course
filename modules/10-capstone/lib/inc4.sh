#!/usr/bin/env bash
# Incident 4 - artifact: the rollout will not start, and it leaves the air gap.  Sourced by prepare-lab.sh / verify.sh.
# Real: registry (oras), tripwire (dnsmasq query log), Docker network aiinfra-airgap (internal: true), sha256, huggingface_hub's cache/offline logic inside the mock.
# SIMULATED: the serving engine (mock-vllm role of aiinfra-mock) and the "model" (random bytes in real safetensors framing, Qwen2.5-0.5B config geometry).
# Production differs: gigabytes of weights, a real loader (vLLM) that does not checksum shards, an artifact proxy/registry fed from the connected side.

I4_REPO="127.0.0.1:18050/cap4/rollout"; I4_TAG="release-2026-10"
I4_MODEL_DIR="models--cap--rollout"

page_4() {
  cat <<MSG
PAGE 4 - $(date -u +%H:%M) UTC  "The new model rollout will not start"
  The rollout of model cap/rollout to the air-gapped serving pool fails, and the network team asks why the serving subnet made DNS
  lookups to outside names while it tried. Run lab/incident-4/rollout.sh (GIVEN) to see what the pool sees.
  Your files: lab/incident-4/rollout.env (environment of the rollout container) and the model cache lab/incident-4/hf-cache/.
  The connected side published the release as an OCI artifact: ${I4_REPO}:${I4_TAG} (oras, --plain-http), with lab/incident-4/MANIFEST.sha256.
  Counters: tripwire GET http://127.0.0.1:18072/hits (DNS A-queries per name since the last reset).
MSG
}

i4_snap() { echo "$1/$I4_MODEL_DIR/snapshots/$2"; }

i4_write_rollout() {  # D
  local d="$1"
  cat > "$d/rollout.sh" <<'SH'
#!/usr/bin/env bash
# GIVEN (do not edit). "Rolls out" the model to the air-gapped serving pool: starts ONE mock-vllm container (SIMULATED engine) on the
# internal network aiinfra-airgap (no route out; DNS = tripwire, which counts every lookup) with
#   - the model cache lab/incident-4/hf-cache mounted read-only as HF_HUB_CACHE,
#   - the environment from lab/incident-4/rollout.env (yours),
# then waits for /health. Exit 0 = serving, 1 = the engine exited or never became healthy (the last error line is printed).
# Overrides for tests: ROLLOUT_CACHE=<dir> ROLLOUT_ENV=<file> ROLLOUT_NAME=<container> ROLLOUT_WAIT=<seconds>
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME="${ROLLOUT_NAME:-aiinfra-lab10-rollout}"; CACHE="${ROLLOUT_CACHE:-$D/hf-cache}"; ENVF="${ROLLOUT_ENV:-$D/rollout.env}"; WAIT="${ROLLOUT_WAIT:-90}"
IMG="${MOCK_IMAGE:-aiinfra-mock:1.0}"
CFG="$(mktemp -d)"; trap 'rm -rf "$CFG"' EXIT
printf '%s\n' '--model cap/rollout' '--served-model-name chat' '--max-model-len 2048' '--gpu-memory-utilization 0.5' > "$CFG/args"
printf '%s\n' 'name: A10G' 'memory_gib: 24' > "$CFG/gpu.yaml"
chmod 755 "$CFG"; chmod 644 "$CFG"/*
docker rm -f "$NAME" >/dev/null 2>&1
docker network inspect aiinfra-airgap >/dev/null 2>&1 || { echo "rollout: network aiinfra-airgap is missing (platform/stack.sh up store)"; exit 1; }
docker run -d --name "$NAME" --label course=aiinfra --label module=10 --network aiinfra-airgap --dns 172.29.231.2 \
  --cap-drop ALL --security-opt no-new-privileges --memory 256m \
  --env-file "$ENVF" -e HF_HUB_CACHE=/hfcache -e HF_HUB_ETAG_TIMEOUT=3 -e HF_HUB_DOWNLOAD_TIMEOUT=3 -e HF_HUB_DISABLE_XET=1 -e MOCK_TIME_SCALE=0 \
  -v "$CACHE:/hfcache:ro" -v "$CFG:/config:ro" "$IMG" vllm >/dev/null || { echo "rollout: docker run failed"; exit 1; }
echo "rollout: container $NAME started on aiinfra-airgap; waiting up to ${WAIT}s for /health"
start=$(date +%s)
while :; do
  st=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
  if [ "$st" = exited ] || [ -z "$st" ]; then
    echo "rollout: FAILED - the engine exited with code $(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null)"
    docker logs "$NAME" 2>&1 | grep -E 'Error|error|ERROR' | tail -2 | cut -c1-300
    exit 1
  fi
  if docker exec "$NAME" python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)" >/dev/null 2>&1; then
    echo "rollout: OK - $NAME serves model 'chat'"; exit 0
  fi
  [ $(( $(date +%s) - start )) -ge "$WAIT" ] && { echo "rollout: FAILED - not healthy after ${WAIT}s"; docker logs "$NAME" 2>&1 | tail -2 | cut -c1-300; exit 1; }
  sleep 2
done
SH
  chmod +x "$d/rollout.sh"
}

i4_probe() {  # container name -> 0 if a chat completion with a fresh nonce answers 200 from INSIDE aiinfra-airgap
  local name="$1" ip nonce; ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "aiinfra-airgap").IPAddress}}' "$name" 2>/dev/null)
  [ -n "$ip" ] || return 1; nonce=$(rhex 4)
  sandbox_run "$PYTHON_IMAGE" python -c "
import json,sys,urllib.request
r=urllib.request.Request('http://$ip:8000/v1/chat/completions',data=json.dumps({'model':'chat','messages':[{'role':'user','content':'nonce $nonce'}],'max_tokens':8}).encode(),headers={'Content-Type':'application/json'})
d=json.load(urllib.request.urlopen(r,timeout=20)); sys.exit(0 if d['choices'][0]['message']['content'] and d['usage']['total_tokens']>0 else 1)" >/dev/null 2>&1
}

plant_4() {
  local V REV BADIDX BAD HOST d="$LAB/incident-4" G="$STATE/4/good"
  V=$(rhex 3); REV=$(rhex 20); BADIDX=$(pick 1 2); HOST="models-$V.corp.internal"
  BAD="model-0000$BADIDX-of-00002.safetensors"
  rm -rf "$STATE/4"; mkdir -p "$STATE/4"
  echo "prepare-lab: converging profile store (registry, tripwire, hf-mirror)"
  stack_up_inc 4 || die "stack did not come up healthy (platform/stack.sh status)"
  wait_http "$REGISTRY_URL/v2/" 30 || die "registry not reachable"; wait_http "$TRIPWIRE_URL/health" 30 || die "tripwire not reachable"
  docker rm -f aiinfra-lab10-rollout aiinfra-lab10-rollout-neg >/dev/null 2>&1
  # the good release as the connected side built it, and its manifest
  "$PY" "$LIB/mkmodel.py" "$G" "$I4_MODEL_DIR" "$REV" "seed-$V" "$CAP/../../mock/models/qwen2.5-0.5b/config.json" || die "model generation failed"
  local gs; gs=$(i4_snap "$G" "$REV")
  ( cd "$gs" && sha256sum * ) > "$STATE/4/MANIFEST.golden"
  ( cd "$gs" && oras push --plain-http "$I4_REPO:$I4_TAG" $(ls) --artifact-type application/vnd.aiinfra.model.v1 ) >/dev/null 2>&1 || die "could not publish the release to the registry (oras push to $I4_REPO)"
  # the lab copy with the planted artifact problems
  rm -rf "$d"; mkdir -p "$d"
  cp -a "$G" "$d/hf-cache"
  local ls_; ls_=$(i4_snap "$d/hf-cache" "$REV")
  rm -f "$ls_/tokenizer.json"
  local off; off=$(( 8 + $("$PY" -c "import struct,sys; print(struct.unpack('<Q', open(sys.argv[1],'rb').read(8))[0])" "$ls_/$BAD") + 4096 ))
  "$PY" - "$ls_/$BAD" "$off" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read()); b[off] ^= 0x01; open(p, "wb").write(b)
PY
  local badsha; badsha=$(sha256sum "$ls_/$BAD" | cut -c1-12)
  cp "$STATE/4/MANIFEST.golden" "$d/MANIFEST.sha256"
  cat > "$d/rollout.env" <<ENV
# Environment of the rollout container (yours). One KEY=VALUE per line, no quotes, no inline comments (docker --env-file format).
# Inherited from the platform team's rollout template:
HF_ENDPOINT=https://$HOST
ENV
  i4_write_rollout "$d"
  cat > "$d/README.md" <<'MD'
# Incident 4 files
- `rollout.sh` GIVEN: starts the engine on the air-gapped network (see its header). `rollout.env` YOURS. `hf-cache/` YOURS (the model cache the engine mounts read-only).
- `MANIFEST.sha256` GIVEN: checksums from the connected side (`sha256sum -c MANIFEST.sha256` inside the snapshot directory).
- Release artifact: `oras pull --plain-http 127.0.0.1:18050/cap4/rollout:release-2026-10 -o <dir>`.
MD
  chmod_pub "$d"; chmod -R a+rX "$STATE/4"
  state_write "$STATE/4/variant.env" V="$V" REV="$REV" BADIDX="$BADIDX" HOST="$HOST"
  echo "prepare-lab: first rollout attempt (this is what the pool saw)"
  tripwire_reset
  local W0; W0=$(date +%s)
  "$d/rollout.sh" > "$STATE/4/first-run.log" 2>&1 && die "the planted rollout succeeded (it must fail): $(cat "$STATE/4/first-run.log")"
  docker rm -f aiinfra-lab10-rollout >/dev/null 2>&1
  local hits; hits=$(curl -fsS "$TRIPWIRE_URL/hits" | jq -r --arg h "$HOST" '(.hosts // .)[$h] // 0')
  [ "${hits:-0}" -ge 1 ] 2>/dev/null || die "the planted rollout did not look up its endpoint on the air-gap network (tripwire saw $hits): $(cat "$STATE/4/first-run.log")"
  win_set 4 "$W0" "$(date +%s)"
  state_write "$STATE/4/truth.env" MISSING_FILE=tokenizer.json BAD_FILE="$BAD" BAD_SHA="$badsha" TRIPWIRE_HOST="$HOST" TRIPWIRE_HITS="$hits"
  page_4
}

i4_manifest_diff() {  # snapshot dir -> prints names of files that differ from the golden manifest (missing or sha mismatch)
  local snap="$1" h f
  while read -r h f; do
    [ -f "$snap/$f" ] || { echo "$f"; continue; }
    [ "$(sha256sum "$snap/$f" | cut -d' ' -f1)" = "$h" ] || echo "$f"
  done < "$STATE/4/MANIFEST.golden"
}

verify_4() {
  local d="$LAB/incident-4" REV HOST snap
  REV=$(vget 4 REV); HOST=$(vget 4 HOST); snap=$(i4_snap "$d/hf-cache" "$REV")
  cp "$STATE/4/MANIFEST.golden" "$d/MANIFEST.sha256"; i4_write_rollout "$d"; chmod_pub "$d"     # GIVEN files are restored
  inc_env 4; STACK_ALLOW_EXITED=1 "$P/stack.sh" up store >/dev/null 2>&1
  docker rm -f aiinfra-lab10-rollout aiinfra-lab10-rollout-neg >/dev/null 2>&1
  tripwire_reset
  local out rc diff nd
  out=$("$d/rollout.sh" 2>&1); rc=$?
  diff=$(i4_manifest_diff "$snap"); nd=$(printf '%s' "$diff" | grep -c .)
  local hits1; hits1=$(tripwire_hits)
  if [ "$nd" -gt 0 ]; then
    fail 4.1 "$nd file(s) of the model snapshot do not match MANIFEST.sha256 (missing or different content): a running engine is not proof of an intact artifact - verify the files against the manifest from the connected side"
  elif [ "$rc" != 0 ]; then
    fail 4.1 "the files match the manifest but the rollout still fails: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-280)"
  elif ! i4_probe aiinfra-lab10-rollout; then
    fail 4.1 "the rollout reports healthy but a chat completion from inside aiinfra-airgap does not answer 200"
  else pass 4.1 "all snapshot files match the manifest and the engine serves a chat completion on the air-gapped network"; fi
  docker rm -f aiinfra-lab10-rollout >/dev/null 2>&1
  if ! passed 4.1; then blocked 4.2 "needs 4.1"; return; fi
  # negative control: same settings, a snapshot with a missing tokenizer -> must fail closed, still without touching the network
  local tmp; tmp=$(mktemp -d "$STATE/4/neg.XXXXXX"); cp -a "$d/hf-cache/." "$tmp/"; rm -f "$(i4_snap "$tmp" "$REV")/tokenizer.json"; chmod_pub "$tmp"
  local nout nrc; nout=$(ROLLOUT_CACHE="$tmp" ROLLOUT_NAME=aiinfra-lab10-rollout-neg ROLLOUT_WAIT=60 "$d/rollout.sh" 2>&1); nrc=$?
  local hits2; hits2=$(tripwire_hits)
  docker rm -f aiinfra-lab10-rollout-neg >/dev/null 2>&1; rm -rf "$tmp"
  local msg=""
  [ "$hits1" = 0 ] || msg+="the rollout made $hits1 DNS lookups from the air-gapped network (tripwire) - a serving pool must not even try to resolve outside names; "
  [ "$nrc" != 0 ] || msg+="with the tokenizer removed the rollout still reported success: the loader should fail closed on an incomplete artifact; "
  [ "$hits2" = "$hits1" ] || msg+="the failing rollout (tokenizer removed) went to the network ($((hits2 - hits1)) more lookups) instead of failing locally: offline behaviour is not proven by the happy path alone; "
  if [ -z "$msg" ]; then pass 4.2 "no DNS lookup left the air gap, and an incomplete artifact fails closed without touching the network"
  else fail 4.2 "${msg%; }"; fi
}
