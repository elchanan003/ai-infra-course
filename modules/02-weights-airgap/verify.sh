#!/usr/bin/env bash
# Module 02 verify: executes your scanner, sync script, air-gap launcher, offline env and bundle repair live.
# Own nonces: hostile pickles use a per-learner canary, loaders run on the air-gapped network with the tripwire.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"; CK="$MODULE_DIR/.lib/checks.py"
PY="$PLATFORM_DIR/.venv/bin/python"; CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
TMP="$(mktemp -d)"
cleanup_v() { docker ps -aq --filter name=aiinfra-lab02- | xargs -r docker rm -f >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup_v EXIT
ALL=(2.1.1 2.1.2 2.1.3 2.2.1 2.2.2 2.2.3 2.2.4 2.3.1 2.3.2 2.3.3 2.4.1 2.4.2 2.4.3 2.5.1 2.5.2 2.5.3 2.6.1 2.6.2 2.6.3)
emit() { local st id msg; while read -r st id msg; do case "$st" in PASS) pass "$id" "$msg";; FAIL) fail "$id" "$msg";; BLOCKED) blocked "$id" "$msg";; esac; done; }
[ -s "$STATE/truth.json" ] || { for id in "${ALL[@]}"; do blocked "$id" "run ./prepare-lab.sh first"; done; summary; }
REPO=$(env_kv "$LAB/REPOS.env" REPO); COMMIT=$(env_kv "$LAB/REPOS.env" COMMIT); GGUF=$(env_kv "$LAB/REPOS.env" GGUF_FILE)
precond "hf-mirror serves $REPO" curl -fsS "$HFMIRROR_URL/api/models/$REPO" && precond "registry up" curl -fsS "$REGISTRY_URL/v2/" && precond "tripwire up" curl -fsS "$TRIPWIRE_URL/hits" \
  && precond "air-gap network exists" docker network inspect aiinfra-airgap || { for id in "${ALL[@]}"; do blocked "$id" "environment not ready - run ./prepare-lab.sh"; done; summary; }
wait_idle 80 60 || warn env "host CPU is busy (timing is not graded here, continuing)"

# ---- 2.1 -------------------------------------------------------------------------------------
emit < <("$PY" "$CK" model "$LAB" "$STATE")

# ---- 2.2 pickle scanner ------------------------------------------------------------------------
CAN=$(jq -r .canary "$STATE/variant.json"); rm -f "$CAN"
declare -A V
for f in "$LAB"/pickles/*; do
  fn=$(basename "$f"); res=$(cd "$LAB" && timeout 60 "$PY" pickle_scan.py "pickles/$fn" 2>/dev/null); rc=$?
  verdict=$(echo "$res" | head -1 | jq -r '.verdict // "none"' 2>/dev/null); V[$fn]="$verdict:$rc"
done
miss=""; fp=""
for fn in $(jq -r 'to_entries[]|select(.value=="dangerous")|.key' "$STATE/pickles.json"); do [ "${V[$fn]:-}" = "dangerous:1" ] || miss="$fn"; done
for fn in $(jq -r 'to_entries[]|select(.value=="safe")|.key' "$STATE/pickles.json"); do [ "${V[$fn]:-}" = "safe:0" ] || fp="$fn"; done
[ -z "$miss" ] && pass 2.2.1 "both hostile checkpoints are flagged (exit 1)" || fail 2.2.1 "hostile checkpoint $miss was not flagged: what does the opcode stream import, and how do protocol-4 and zip-wrapped files hide it? (theory 2.2, 4.1)"
if ! passed 2.2.1; then blocked 2.2.2 "needs 2.2.1 (false positives only mean something once detection works)"; blocked 2.2.3 "needs 2.2.1"
else
  [ -z "$fp" ] && pass 2.2.2 "no false positives on the benign checkpoints" || fail 2.2.2 "benign checkpoint $fp was flagged: real torch checkpoints legitimately reference some globals, and strings are data (theory 2.2)"
  [ ! -e "$CAN" ] && pass 2.2.3 "canary file does not exist: the scanner never executed the pickles" || { fail 2.2.3 "the canary $CAN exists: your scanner executed a hostile pickle (never unpickle)"; rm -f "$CAN"; }
fi
bad=$(ls "$LAB"/pickles | head -1); head -c $(( $(stat -c%s "$LAB/pickles/$bad") / 2 )) "$LAB/pickles/$bad" > "$TMP/truncated.bin"
res=$(cd "$TMP" && timeout 60 "$PY" "$LAB/pickle_scan.py" truncated.bin 2>/dev/null); rc=$?
[ "$(echo "$res" | head -1 | jq -r .verdict 2>/dev/null)" = dangerous ] && [ "$rc" = 1 ] && pass 2.2.4 "a truncated pickle is reported dangerous (exit 1)" || fail 2.2.4 "a truncated pickle was not reported dangerous: a file you cannot parse must not pass"
rm -f "$CAN"

# ---- 2.3 S3 --------------------------------------------------------------------------------------
if passed 2.1.1; then emit < <("$PY" "$CK" s3 "$LAB" "$STATE" "$LAB/s3-serve.env")
else for id in 2.3.1 2.3.2 2.3.3; do blocked $id "needs 2.1.1 (nothing to sync)"; done; fi

# ---- 2.4 air-gapped serving ----------------------------------------------------------------------
IPA() { docker inspect -f '{{with index .NetworkSettings.Networks "aiinfra-airgap"}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null; }
tripwire_reset
docker rm -f aiinfra-lab02-serve >/dev/null 2>&1
bash "$LAB/airgap/run.sh" >"$TMP/run.log" 2>&1
SIP=$(IPA aiinfra-lab02-serve); ok1=0
if [ -n "$SIP" ] && within 60 sandbox_run --entrypoint curl "$LLAMACPP_IMAGE" -fsS "http://$SIP:8080/health"; then
  body=$(sandbox_run --entrypoint curl "$LLAMACPP_IMAGE" -sS --max-time 60 "http://$SIP:8080/completion" -H 'Content-Type: application/json' -d '{"prompt":"Hello","n_predict":8,"temperature":0}' 2>/dev/null)
  [ -n "$(echo "$body" | jq -r '.content // empty' 2>/dev/null)" ] && ok1=1
fi
[ "$ok1" = 1 ] && pass 2.4.1 "completion answered from inside the air-gapped network" || fail 2.4.1 "no completion from aiinfra-lab02-serve on aiinfra-airgap (did lab/airgap/run.sh start it? $(tail -1 "$TMP/run.log" | head -c 120))"
nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' aiinfra-lab02-serve 2>/dev/null | xargs)
dns=$(docker inspect -f '{{range .HostConfig.Dns}}{{.}} {{end}}' aiinfra-lab02-serve 2>/dev/null)
cmdl=$(docker inspect -f '{{join .Config.Cmd " "}}' aiinfra-lab02-serve 2>/dev/null)
hits=$(tripwire_hits)
if [ "$nets" != "aiinfra-airgap" ]; then fail 2.4.2 "the container must be attached to aiinfra-airgap only (is on: ${nets:-nothing})"
elif [[ " $dns " != *" $TRIPWIRE_AIRGAP_IP "* ]]; then fail 2.4.2 "the container does not use the tripwire as DNS ($TRIPWIRE_AIRGAP_IP): a leak would not be visible"
elif [[ "$cmdl" == *" -hf "* || "$cmdl" == *"--hf-repo"* || "$cmdl" == *"-hfr "* ]]; then fail 2.4.2 "the engine is started with a Hugging Face download flag; serve the local file"
elif [ "${hits:-0}" != 0 ]; then fail 2.4.2 "the tripwire saw $hits DNS queries while your container started and served"
else pass 2.4.2 "air-gapped network only, tripwire as DNS, local model, zero tripwire hits"; fi
docker rm -f aiinfra-lab02-serve >/dev/null 2>&1

# model loader on the air-gap network: mock-vllm resolves the repo id with the real huggingface_hub
loader() {  # NAME ENVFILE|"" -> sets L_STATE (healthy|exited|timeout), L_LOG
  local name="$1" envf="$2" ea=() hfc="$TMP/hfc-$1"
  rm -rf "$hfc"; if [ -d "$LAB/hf-cache" ]; then cp -a "$LAB/hf-cache" "$hfc"; else mkdir -p "$hfc"; fi
  if [ -n "$envf" ]; then ea=(--env-file "$envf"); else ea=(-e HF_HOME=/hf); fi
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --label course=aiinfra --label module=02 --network aiinfra-airgap --dns "$TRIPWIRE_AIRGAP_IP" \
    --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)" --tmpfs /tmp -v "$hfc:/hf" "${ea[@]}" \
    -e "MOCK_VLLM_ARGS=--model $REPO --revision $COMMIT --served-model-name lab" "$MOCK_IMAGE" vllm >/dev/null 2>&1 || { L_STATE=exited; L_LOG="docker run failed"; return; }
  local ip start=$(date +%s); L_STATE=timeout
  while (( $(date +%s) - start < 60 )); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]; then L_STATE=exited; break; fi
    ip=$(IPA "$name")
    if [ -n "$ip" ] && sandbox_run --entrypoint curl "$LLAMACPP_IMAGE" -fsS --max-time 3 "http://$ip:8000/health" >/dev/null 2>&1; then L_STATE=healthy; break; fi
    sleep 1
  done
  L_LOG=$(docker logs "$name" 2>&1 | grep -E "Error|error" | tail -1 | head -c 220)
}
tripwire_reset; loader aiinfra-lab02-ctrl ""; ch=$(tripwire_hits); docker rm -f aiinfra-lab02-ctrl >/dev/null 2>&1
precond "control run (no offline settings) trips the wire" test "${ch:-0}" -ge 1
if [ "${ch:-0}" -lt 1 ]; then blocked 2.4.3 "the tripwire did not react to the control run - cannot prove anything; check ./prepare-lab.sh and platform/stack.sh status"
else
  tripwire_reset; loader aiinfra-lab02-probe "$LAB/airgap/offline.env"; hh=$(tripwire_hits); docker rm -f aiinfra-lab02-probe >/dev/null 2>&1
  if [ "$L_STATE" = healthy ] && [ "${hh:-0}" = 0 ]; then pass 2.4.3 "the loader started from your cache with your offline.env and the tripwire stayed silent (control run: $ch hits)"
  elif [ "${hh:-0}" != 0 ]; then fail 2.4.3 "the loader still contacted the network: $hh tripwire hits with your offline.env (what does the client do when it is not told to stay local?)"
  else fail 2.4.3 "the loader did not start offline from lab/hf-cache ($L_STATE: ${L_LOG:-no error line}) - cache populated with the pinned commit? HF_HOME/HF_HUB_CACHE pointing at /hf?"; fi
fi

# ---- 2.5 registry / ORAS ----------------------------------------------------------------------------
AE="$LAB/registry/answers.env"; ID=$(env_kv "$AE" IMAGE_DIGEST); AD=$(env_kv "$AE" ARTIFACT_DIGEST); GS=$(env_kv "$AE" GGUF_SHA256)
ACC='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
found=""
for tg in $(curl -fsS "$REGISTRY_URL/v2/aiinfra/llama/tags/list" 2>/dev/null | jq -r '.tags[]?' 2>/dev/null); do
  d=$(curl -sI -H "Accept: $ACC" "$REGISTRY_URL/v2/aiinfra/llama/manifests/$tg" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [ -n "$ID" ] && [ "$d" = "$ID" ] && found="$tg"
done
[ -n "$found" ] && pass 2.5.1 "IMAGE_DIGEST is the registry's manifest digest of aiinfra/llama:$found" || fail 2.5.1 "IMAGE_DIGEST is not the digest the registry reports for any tag of aiinfra/llama (read it from the registry response, not from the local image store - theory 6.1)"
ctr=""; for c in $(docker ps -q --filter label=course=aiinfra); do img=$(docker inspect -f '{{.Config.Image}}' "$c"); [ -n "$ID" ] && [ "$img" = "localhost:18050/aiinfra/llama@$ID" ] && ctr="$c"; done
[ -n "$ctr" ] && pass 2.5.2 "a running course container was created from localhost:18050/aiinfra/llama@<digest>" || fail 2.5.2 "no running course container uses the image reference localhost:18050/aiinfra/llama@<IMAGE_DIGEST> (tags are mutable; run by digest, label it course=aiinfra)"
want=$(sha256sum "$CACHE/models/$GGUF" | cut -d' ' -f1); okp=0
if [ -n "$AD" ] && [ "$AD" != TODO ]; then
  m=$(oras manifest fetch --plain-http "127.0.0.1:18050/aiinfra/models/gguf@$AD" 2>/dev/null)
  mkdir -p "$TMP/pull"
  if [ "$(echo "$m" | jq -r .artifactType 2>/dev/null)" = application/vnd.aiinfra.model.v1 ] && [ "$(echo "$m" | jq -r '.layers[0].mediaType' 2>/dev/null)" = application/vnd.aiinfra.gguf ] \
     && oras pull --plain-http -o "$TMP/pull" "127.0.0.1:18050/aiinfra/models/gguf@$AD" >/dev/null 2>&1; then
    got=$(sha256sum "$TMP/pull"/* 2>/dev/null | head -1 | cut -d' ' -f1)
    [ "$got" = "$want" ] && [ "$GS" = "$want" ] && okp=1
  fi
fi
[ "$okp" = 1 ] && pass 2.5.3 "oras pull of the recorded artifact yields your variant's GGUF (sha256 $want), media types as specified" || fail 2.5.3 "the artifact aiinfra/models/gguf@ARTIFACT_DIGEST is missing, has the wrong artifactType/layer mediaType, or its file hash is not GGUF_SHA256 = the sha256 of $GGUF"

# ---- 2.6 bundle -------------------------------------------------------------------------------------
emit < <("$PY" "$CK" bundle "$LAB" "$STATE")
docker rm -f aiinfra-lab02-bundle >/dev/null 2>&1
docker run -d --name aiinfra-lab02-bundle --label course=aiinfra --label module=02 --network aiinfra-airgap --cap-drop ALL --user "$(id -u):$(id -g)" \
  -v "$LAB/incoming:/bundle:ro" -e "MOCK_VLLM_ARGS=--model /bundle --served-model-name lab" "$MOCK_IMAGE" vllm >/dev/null 2>&1
st=timeout; start=$(date +%s)
while (( $(date +%s) - start < 40 )); do
  [ "$(docker inspect -f '{{.State.Running}}' aiinfra-lab02-bundle 2>/dev/null)" = true ] || { st=exited; break; }
  ip=$(IPA aiinfra-lab02-bundle); [ -n "$ip" ] && sandbox_run --entrypoint curl "$LLAMACPP_IMAGE" -fsS --max-time 3 "http://$ip:8000/health" >/dev/null 2>&1 && { st=healthy; break; }
  sleep 1
done
[ "$st" = healthy ] && pass 2.6.3 "the repaired bundle loads: tokenizer present, index and shards consistent, headers parse, hashes match" || fail 2.6.3 "the bundle does not load: $(docker logs aiinfra-lab02-bundle 2>&1 | grep -E 'Error' | tail -1 | head -c 200)"
summary
