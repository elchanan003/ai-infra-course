#!/usr/bin/env bash
# Incident 4 - artifact + air gap: a model rollout that will not start and leaves the isolated network.  Sourced by prepare-lab.sh / verify.sh.
# Real: tripwire (dnsmasq query log), hf-mirror, the Docker air-gap network, huggingface_hub inside the engine image, sha256.
# SIMULATED: the engine (mock-vllm: it implements the loader checks of vLLM/transformers - tokenizer present, safetensors header, shard hashes); the model itself is tiny synthetic data.
# Production differs: a real engine does NOT verify weight hashes (a flipped byte can load and give wrong answers) - the manifest check is yours.

I4_REPO="aiinfra/capstone-tiny"
I4_HUB="$AIINFRA_CACHE/hf/hub/models--aiinfra--capstone-tiny"
I4_NAME=aiinfra-lab10-rollout

page_4() {
  cat <<MSG
PAGE 4 - $(date -u +%H:%M) UTC  "The new model rollout will not start"
  The rollout of model ${I4_REPO} to the air-gapped serving network hangs for a while and then fails. Separately, the network team
  noticed DNS lookups from the serving subnet that should never happen there.
  Your files in lab/incident-4/: rollout.env (environment of the rollout container) and hf-cache/ (the model files the container mounts).
  Given: rollout.sh (run it), MANIFEST.sha256 (hashes made on the connected side), README. Mirror for re-fetching: http://127.0.0.1:18071.
  Tripwire (DNS query log of the air-gapped network): http://127.0.0.1:18072/hits
MSG
}

i4_seed_pristine() {  # V BADIDX -> writes pristine HF cache layout into $I4_HUB, prints "commit"
  "$PY" - "$I4_HUB" "$CAP/../../mock/models/qwen2.5-0.5b/config.json" "$1" <<'PY'
import hashlib, json, os, random, shutil, struct, sys
hub, cfg, seed = sys.argv[1], sys.argv[2], sys.argv[3]
rnd = random.Random(seed)
shutil.rmtree(hub, ignore_errors=True)
for d in ("blobs", "refs", "snapshots"): os.makedirs(os.path.join(hub, d))
files = {}
files["config.json"] = open(cfg, "rb").read()
files["tokenizer_config.json"] = json.dumps({"tokenizer_class": "Qwen2Tokenizer", "model_max_length": 32768}).encode()
vocab = {f"tok{i}": i for i in range(300)}
files["tokenizer.json"] = json.dumps({"version": "1.0", "model": {"type": "BPE", "vocab": vocab, "merges": []}, "added_tokens": []}).encode()
wm, total = {}, 0
for i in (1, 2, 3):
    name = f"model-0000{i}-of-00003.safetensors"
    t = f"layers.{i}.weight"
    data = bytes(rnd.randrange(256) for _ in range(8192))
    hdr = json.dumps({"__metadata__": {"format": "pt"}, t: {"dtype": "BF16", "shape": [64, 64], "data_offsets": [0, 8192]}}).encode()
    hdr += b" " * ((8 - len(hdr) % 8) % 8)
    files[name] = struct.pack("<Q", len(hdr)) + hdr + data
    wm[t] = name; total += 8192
files["model.safetensors.index.json"] = json.dumps({"metadata": {"total_size": total}, "weight_map": wm}, indent=1).encode()
commit = hashlib.sha1(seed.encode()).hexdigest()
os.makedirs(os.path.join(hub, "snapshots", commit))
for name, data in files.items():
    blob = hashlib.sha256(data).hexdigest() if name.endswith(".safetensors") else hashlib.sha1(data).hexdigest()
    open(os.path.join(hub, "blobs", blob), "wb").write(data)
    os.symlink(os.path.join("..", "..", "blobs", blob), os.path.join(hub, "snapshots", commit, name))
open(os.path.join(hub, "refs", "main"), "w").write(commit)
print(commit)
PY
}

i4_files() {  # V BAD HOST  -> lab/incident-4 (rollout.sh, rollout.env, hf-cache planted, MANIFEST.sha256)
  local V="$1" BAD="$2" HOST="$3" d="$LAB/incident-4" commit
  commit=$(cat "$I4_HUB/refs/main")
  mkdir -p "$d"
  rm -rf "$d/hf-cache"; mkdir -p "$d/hf-cache"; cp -a "$I4_HUB" "$d/hf-cache/"
  local snap="$d/hf-cache/models--aiinfra--capstone-tiny/snapshots/$commit" blobs="$d/hf-cache/models--aiinfra--capstone-tiny/blobs"
  # manifest from the pristine copy (what the connected side produced)
  ( cd "$I4_HUB/snapshots/$commit" && for f in $(ls | sort); do printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done ) > "$d/MANIFEST.sha256"
  # plant 1: tokenizer.json is gone
  local tb; tb=$(basename "$(readlink "$snap/tokenizer.json")"); rm -f "$snap/tokenizer.json" "$blobs/$tb"
  # plant 2: one byte of one shard payload flipped (header stays valid)
  local bad="model-0000${BAD}-of-00003.safetensors" bb
  bb=$(basename "$(readlink "$snap/$bad")")
  "$PY" - "$blobs/$bb" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-100] ^= 0x01; open(p, "wb").write(bytes(b))
PY
  sha256sum "$blobs/$bb" | cut -c1-12 > "$STATE/4/bad_sha"
  cat > "$d/rollout.env" <<ENV
# Environment of the rollout container (yours). Format: KEY=VALUE per line, no quotes, no export (docker --env-file).
HF_ENDPOINT=https://$HOST
HF_HUB_DISABLE_XET=1
ENV
  cat > "$d/rollout.sh" <<'SH'
#!/usr/bin/env bash
# GIVEN (do not edit). Starts the model server for aiinfra/capstone-tiny (SIMULATED engine: image aiinfra-mock:1.0, role vllm) on the air-gapped
# network aiinfra-airgap (internal, DNS = tripwire) with rollout.env and a throwaway copy of hf-cache/ mounted as HF_HUB_CACHE.
# Exit 0 = serving; exit 1 = the container exited or did not become healthy within 90 s.   Env: HF_CACHE_DIR, ROLLOUT_NAME (used by verify).
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME="${ROLLOUT_NAME:-aiinfra-lab10-rollout}"; SRC="${HF_CACHE_DIR:-$D/hf-cache}"; RUN="/tmp/$NAME.cache"
docker network inspect aiinfra-airgap >/dev/null 2>&1 || { echo "rollout: network aiinfra-airgap missing (platform/stack.sh up store)"; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$RUN"; mkdir -p "$RUN"; cp -a "$SRC/." "$RUN/"; chmod -R a+rwX "$RUN"
docker run -d --name "$NAME" --label course=aiinfra --label module=10 --network aiinfra-airgap --dns 172.29.231.2 \
  --memory 256m --cap-drop ALL --security-opt no-new-privileges \
  --env-file "$D/rollout.env" -e HF_HUB_CACHE=/hf-cache -e MOCK_TIME_SCALE=0 \
  -e MOCK_VLLM_ARGS="--model aiinfra/capstone-tiny --served-model-name chat --max-model-len 2048" \
  -v "$RUN:/hf-cache" aiinfra-mock:1.0 vllm >/dev/null || { echo "rollout: docker run failed"; exit 1; }
for i in $(seq 1 90); do
  st=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
  if [ "$st" = exited ] || [ "$st" = dead ]; then
    echo "rollout: container exited with code $(docker inspect -f '{{.State.ExitCode}}' "$NAME")"; docker logs "$NAME" 2>&1 | grep -E "Error|error" | tail -3; exit 1
  fi
  if docker exec "$NAME" python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2)" >/dev/null 2>&1; then
    echo "rollout: serving aiinfra/capstone-tiny as 'chat' in container $NAME"; exit 0
  fi
  sleep 1
done
echo "rollout: not healthy after 90 s"; docker logs "$NAME" 2>&1 | tail -3; exit 1
SH
  chmod +x "$d/rollout.sh"
  cat > "$d/README.md" <<MD
# Incident 4 workspace
- rollout.sh (given) - run it from here: ./rollout.sh
- rollout.env (yours) - environment of the rollout container
- hf-cache/ (yours) - HF cache layout the container mounts (a throwaway copy per run; the original is never modified by the container)
- MANIFEST.sha256 (given) - sha256 of every file of the snapshot, made on the connected side
MD
  chmod_pub "$d"
}

plant_4() {
  local V BAD HOST
  V=$(rhex 3); BAD=$(pick 1 2 3); HOST="hub-$V.models.corp.example"
  [ -w "$AIINFRA_CACHE/hf/hub" ] || die "$AIINFRA_CACHE/hf/hub is not writable (run platform/setup.sh once to fix cache ownership)"
  rm -rf "$STATE/4"; mkdir -p "$STATE/4"
  state_write "$STATE/4/variant.env" V="$V" BAD="$BAD" HOST="$HOST"
  echo "prepare-lab: converging profile store (tripwire, hf-mirror, registry, S3)"
  stack_up_inc 4 || die "stack did not come up healthy (platform/stack.sh status)"
  wait_http "$TRIPWIRE_URL/health" 30 && wait_http "$HFMIRROR_URL/health" 30 || die "tripwire/hf-mirror not ready"
  i4_seed_pristine "cap4-$V" >/dev/null || die "could not seed the connected-side copy of the model"
  i4_files "$V" "$BAD" "$HOST"
  docker rm -f "$I4_NAME" >/dev/null 2>&1
  tripwire_reset
  echo "prepare-lab: the rollout is attempted on the air-gapped network (can take up to 90 s)"
  local out rc; out=$( cd "$LAB/incident-4" && ./rollout.sh 2>&1 ); rc=$?
  [ "$rc" != 0 ] || die "the planted rollout unexpectedly succeeded: $out"
  local hits; hits=$(tripwire_hits "$HOST")
  [ "${hits:-0}" -ge 1 ] || die "the planted rollout did not query $HOST (tripwire shows $(curl -s "$TRIPWIRE_URL/hits")): $out"
  docker rm -f "$I4_NAME" >/dev/null 2>&1
  state_write "$STATE/4/truth.env" MISSING_FILE=tokenizer.json BAD_FILE="model-0000${BAD}-of-00003.safetensors" BAD_SHA="$(cat "$STATE/4/bad_sha")" TRIPWIRE_HOST="$HOST" TRIPWIRE_HITS="$hits"
  page_4
}

i4_manifest_diff() {  # prints the number of manifest mismatches (missing, wrong hash, extra files)
  local d="$LAB/incident-4" commit snap
  commit=$(cat "$d/hf-cache/models--aiinfra--capstone-tiny/refs/main" 2>/dev/null)
  snap="$d/hf-cache/models--aiinfra--capstone-tiny/snapshots/$commit"
  "$PY" - "$snap" "$d/MANIFEST.sha256" <<'PY'
import hashlib, os, sys
snap, man = sys.argv[1], sys.argv[2]
want = {l.split()[1]: l.split()[0] for l in open(man) if l.strip()}
bad = 0
for n, h in want.items():
    try: got = hashlib.sha256(open(os.path.join(snap, n), "rb").read()).hexdigest()
    except OSError: got = None
    bad += got != h
try: extra = set(os.listdir(snap)) - set(want)
except OSError: extra = set()
print(bad + len(extra))
PY
}

verify_4() {
  local d="$LAB/incident-4" HOST; HOST=$(vget 4 HOST)
  stack_up_inc 4
  local msg="" md hits out rc
  md=$(i4_manifest_diff); [ "${md:-9}" = 0 ] || msg+="${md} file(s) of the model snapshot do not match MANIFEST.sha256 (missing, corrupt or extra); "
  docker rm -f "$I4_NAME" >/dev/null 2>&1; tripwire_reset
  out=$( cd "$d" && timeout 150 ./rollout.sh 2>&1 ); rc=$?
  hits=$(tripwire_hits)
  [ "$rc" = 0 ] || msg+="rollout.sh failed: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-300); "
  [ "${hits:-0}" = 0 ] || msg+="the rollout made ${hits} DNS lookup(s) outside the air gap (tripwire /hits: $(curl -s "$TRIPWIRE_URL/hits" | tr -d '\n' | cut -c1-120)) - does the loader know it must not reach for a network? (theory 3.6); "
  if [ -z "$msg" ]; then pass 4.1 "manifest matches (live sha256), rollout.sh serves the model, 0 tripwire hits"; else fail 4.1 "${msg%; }"; blocked 4.2 "needs 4.1"; return; fi
  # 4.2: in-network probe + a fail-closed control with the same rollout.env and a broken copy
  local ip nonce="nonce-$(rhex 3)" code
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "aiinfra-airgap").IPAddress}}' "$I4_NAME" 2>/dev/null)
  code=$(docker run --rm --label course=aiinfra --network aiinfra-airgap --entrypoint python aiinfra-mock:1.0 -c "
import json,urllib.request
r=urllib.request.Request('http://$ip:8000/v1/chat/completions',data=json.dumps({'model':'chat','messages':[{'role':'user','content':'$nonce'}],'max_tokens':8}).encode(),headers={'Content-Type':'application/json'})
try:
    x=urllib.request.urlopen(r,timeout=20); b=json.load(x); print(x.status if b.get('choices') else 0)
except Exception as e: print(0)" 2>/dev/null | tail -1)
  local ctl=/tmp/cap4-control.$$ crc chits
  rm -rf "$ctl"; mkdir -p "$ctl"; cp -a "$d/hf-cache/." "$ctl/"
  local csnap; csnap="$ctl/models--aiinfra--capstone-tiny/snapshots/$(cat "$ctl/models--aiinfra--capstone-tiny/refs/main")"
  rm -f "$csnap/tokenizer.json"
  docker rm -f aiinfra-lab10-control >/dev/null 2>&1; tripwire_reset
  ( cd "$d" && HF_CACHE_DIR="$ctl" ROLLOUT_NAME=aiinfra-lab10-control timeout 150 ./rollout.sh >/dev/null 2>&1 ); crc=$?
  chits=$(tripwire_hits)
  docker rm -f aiinfra-lab10-control >/dev/null 2>&1; rm -rf "$ctl" "/tmp/aiinfra-lab10-control.cache"
  msg=""
  [ "$code" = 200 ] || msg+="an in-network request to the new model did not get a 200 (got ${code:-none}); "
  [ "$crc" != 0 ] || msg+="control: with tokenizer.json removed the rollout still reported success; "
  [ "${chits:-0}" = 0 ] || msg+="control: with a broken artifact the loader went to the network (${chits} DNS lookup(s)) instead of failing locally and immediately - the air gap is only proven when a failure stays inside it; "
  if [ -z "$msg" ]; then pass 4.2 "in-network request answered 200; broken-artifact control failed closed (non-zero, 0 DNS lookups)"; else fail 4.2 "${msg%; }"; fi
}
