#!/usr/bin/env bash
# Module 02 prepare: converge to profiles store+llm, assign the per-learner variant (.state/, stable across
# cleanups), generate the synthetic sharded repo in the mirror's HF cache, the 5 pickle files and the damaged
# incoming bundle (only if missing). Idempotent. Never reveals answers.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"; export COURSE_DIR
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"; mkdir -p "$STATE"
CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"; HUB="$CACHE/hf/hub"
mkdir -p "$HUB" 2>/dev/null || { echo "prepare-lab: cannot write $HUB (ownership? platform/setup.sh fixes it)"; exit 1; }
[ -w "$HUB" ] || { echo "prepare-lab: $HUB is not writable by $USER (platform/setup.sh fixes ownership via a throwaway container)"; exit 1; }

python3 - "$MODULE_DIR" "$HUB" <<'PY' || exit 1
import json, os, random, sys
mod, hub = sys.argv[1], sys.argv[2]
sys.path.insert(0, mod + "/.lib"); import fixtures as fx
st = mod + "/.state"; lab = mod + "/lab"
vp = st + "/variant.json"
if not os.path.exists(vp):
    r = random.SystemRandom()
    v = dict(vid="%06x" % r.randrange(1 << 24), seed=r.randrange(1 << 30), commit="".join(r.choice("0123456789abcdef") for _ in range(40)),
             gguf=r.choice(["qwen2.5-0.5b-instruct-q4_k_m.gguf", "Qwen2.5-Coder-0.5B-Q4_K_M.gguf"]), canary="/tmp/aiinfra-canary-%06x" % r.randrange(1 << 24))
    json.dump(v, open(vp, "w"), indent=1)
v = json.load(open(vp)); repo = "aiinfra-lab/tiny-" + v["vid"]
files, meta = fx.build_repo_files(v["vid"], v["seed"], os.path.join(os.environ["COURSE_DIR"], "mock/models/qwen2.5-0.5b/config.json"))
d = os.path.join(hub, "models--aiinfra-lab--tiny-" + v["vid"])
if not os.path.isdir(os.path.join(d, "snapshots", v["commit"])):
    fx.write_cache(hub, repo, v["commit"], files)
serving = {k: fx.sha256(b) for k, b in files.items() if k.endswith(fx.SERVE_PATTERNS) and "/" not in k}
truth = dict(repo=repo, commit=v["commit"], serving=serving, decoys=["pytorch_model.bin", "onnx/model.onnx", "README.md"], **meta)
json.dump(truth, open(st + "/truth.json", "w"), indent=1)
open(lab + "/REPOS.env", "w").write("REPO=%s\nCOMMIT=%s\nGGUF_FILE=%s\n" % (repo, v["commit"], v["gguf"]))
if not os.path.isdir(lab + "/pickles") or not os.listdir(lab + "/pickles"):
    pt = fx.make_pickles(lab + "/pickles", v["canary"], random.Random(v["seed"] + 1))
    json.dump(pt, open(st + "/pickles.json", "w"), indent=1)
if not os.path.isdir(lab + "/incoming") or not os.listdir(lab + "/incoming"):
    b = fx.make_bundle(lab + "/incoming", files, random.Random(v["seed"] + 2))
    json.dump(b, open(st + "/bundle.json", "w"), indent=1)
    import time
    t = time.time() - 600
    for fn in b["good"]: os.utime(lab + "/incoming/" + fn, (t, t))
    json.dump({fn: os.stat(lab + "/incoming/" + fn).st_mtime for fn in b["good"]}, open(st + "/bundle-mtimes.json", "w"))
PY
rc=$?; [ $rc = 0 ] || { echo "prepare-lab: fixture generation failed"; exit 1; }
chmod -R a+rX "$LAB" 2>/dev/null
"$PLATFORM_DIR/stack.sh" up store llm >/dev/null || { echo "prepare-lab: stack did not come up healthy (platform/stack.sh status)"; exit 1; }
docker ps -a --filter name=aiinfra-lab02- -q | xargs -r docker rm -f >/dev/null 2>&1
REPO=$(env_kv "$LAB/REPOS.env" REPO)
wait_http "$HFMIRROR_URL/api/models/$REPO" 30 || { echo "prepare-lab: hf-mirror does not serve $REPO"; exit 1; }
# bucket for the weights (the sync job in task 2.3 also creates it if missing)
cat <<MSG
prepare-lab: ready (profiles store llm).
  hf-mirror  $HFMIRROR_URL   repo/commit/GGUF: lab/REPOS.env
  S3         $S3_URL   registry 127.0.0.1:18050   tripwire $TRIPWIRE_URL/hits
  Given: lab/pickles/ (5 files)  lab/incoming/ (the bundle that arrived)   Yours: see lab.md ownership table
MSG
