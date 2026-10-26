#!/usr/bin/env bash
# Module 01 prepare: converge to profiles llm+mock, assign the per-learner variant (.state/variant.json,
# stable across cleanups), write the variant inputs into lab/variant/ (only if missing). Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; STATE="$MODULE_DIR/.state"; mkdir -p "$STATE" "$LAB/variant"
PY=python3

[ -s "$STATE/variant.json" ] || $PY "$MODULE_DIR/.lib/ref.py" > "$STATE/variant.json"
V="$STATE/variant.json"
if [ ! -s "$LAB/variant/model.json" ]; then
  $PY - "$V" "$LAB/variant" "$MODULE_DIR/.lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3]); import ref
v = json.load(open(sys.argv[1])); d = sys.argv[2]
s, L, S = v["sizing"], v["large"], v["small"]
def w(name, o): json.dump(o, open(f"{d}/{name}", "w"), indent=1)
w("model.json", dict(ref.model_json(s["model"], s["bytes_per_param"]), kv_bytes=s["kv_bytes"], seq_len=s["seq_len"]))
w("gpu.json", {"gpu_gib": s["gpu_gib"], "util": s["util"], "overhead_gib": 2.0, "tp": 1})
w("large.json", dict(ref.model_json(L["model"], L["bytes_per_param"]), kv_bytes=L["kv_bytes"], seq_len=L["seq_len"],
                     n_seqs=L["n_seqs"], gpu_gib=L["gpu_gib"], util=L["util"], overhead_gib=2.0))
w("small.json", dict(ref.model_json(S["model"], S["bytes_per_param"]), kv_bytes=S["kv_bytes"], seq_len=S["seq_len"],
                     n_seqs=S["n_seqs"], mig_family=S["mig_family"], util=S["util"], overhead_gib=2.0))
open(f"{d}/models.txt", "w").write("Q4=%s\nQ8=%s\n" % tuple(v["pair"]))
open(f"{d}/system.txt", "w").write("You are a careful assistant for the platform team. Answer only from the document that follows.")
open(f"{d}/doc.txt", "w").write(ref.make_doc(v["seed"]))
PY
fi
cat > "$LAB/variant/README.txt" <<'TXT'
Per-learner inputs for the tasks (given; do not edit):
  model.json gpu.json     task 1.2     large.json small.json   task 1.6
  models.txt              task 1.5     system.txt doc.txt      task 1.4
MODEL.json files use the config.json field names; head_dim may be missing (derive it from hidden_size).
TXT
chmod -R a+rX "$LAB"
"$PLATFORM_DIR/stack.sh" up llm mock >/dev/null || { echo "prepare-lab: stack did not come up healthy (platform/stack.sh status)"; exit 1; }
docker ps -a --filter name=aiinfra-lab01- -q | xargs -r docker rm -f >/dev/null 2>&1
echo "prepare-lab: ready (profiles llm mock). Your llama-server: lab/bin/run-llama.sh (127.0.0.1:18120). Inputs: lab/variant/"
