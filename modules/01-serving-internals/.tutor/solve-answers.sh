#!/usr/bin/env bash
# Reference method for the answer files of module 01 (what a learner does with the tools).
set -uo pipefail
TUTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MODULE_DIR="$(cd "$TUTOR/.." && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
LAB="$MODULE_DIR/lab"; V="$MODULE_DIR/.state/variant.json"; CK="$MODULE_DIR/.lib/checks.py"
MODELS="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/models"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$LAB" <<'PY'
import json, sys, os
lab = sys.argv[1]; sys.path.insert(0, lab); import sizing
m = json.load(open(f"{lab}/variant/model.json")); g = json.load(open(f"{lab}/variant/gpu.json"))
hd = m.get("head_dim") or m["hidden_size"] // m["num_attention_heads"]
w = sizing.weights_gb(m["params_b"], m["bytes_per_param"]); kb = sizing.kv_bytes_per_token(m["layers"], m["num_key_value_heads"], hd, m["kv_bytes"])
pool = g["gpu_gib"] * g["util"] - w - g["overhead_gib"]
per = kb * m["seq_len"] / 2 ** 30
open(f"{lab}/answers/vram.env", "w").write(f"WEIGHTS_GIB={w:.3f}\nKV_BYTES_PER_TOKEN={kb}\nKV_POOL_GIB={pool:.3f}\nMAX_SEQS={int(pool // per)}\n")
L = json.load(open(f"{lab}/variant/large.json")); S = json.load(open(f"{lab}/variant/small.json"))
t = sizing.min_tp(L, L["gpu_gib"], L["util"], L["seq_len"], L["n_seqs"], L["kv_bytes"])
lhd = L.get("head_dim") or L["hidden_size"] // L["num_attention_heads"]
lw = sizing.weights_gb(L["params_b"], L["bytes_per_param"])
pool = L["gpu_gib"] * L["util"] - lw / t - L["overhead_gib"]
per = sizing.kv_bytes_per_token(L["layers"], L["num_key_value_heads"], lhd, L["kv_bytes"]) * L["seq_len"] / t / 2 ** 30
MIG = {"80gb": [("1g.10gb", 10), ("1g.20gb", 20), ("2g.20gb", 20), ("3g.40gb", 40), ("4g.40gb", 40), ("7g.80gb", 80)],
       "40gb": [("1g.5gb", 5), ("2g.10gb", 10), ("3g.20gb", 20), ("4g.20gb", 20), ("7g.40gb", 40)]}
prof = next(n for n, gib in MIG[S["mig_family"]] if sizing.fits(S, gib, S["util"], 1, S["seq_len"], S["n_seqs"], S["kv_bytes"], S["overhead_gib"]))
json.dump({"min_tp_large": t, "max_seqs_at_min_tp": int(pool // per), "mig_profile_small": prof,
           "explain_no_tp3": "TP must divide num_attention_heads and num_key_value_heads (64 and 8 here), 3 divides neither, so only 1, 2, 4, 8 are legal."},
          open(f"{lab}/answers/tp.json", "w"), indent=1)
PY
# 1.3: batching ratio with the learner's (solution) bench.py and run-llama.sh
bench() { python3 "$LAB/bench.py" --url http://127.0.0.1:18120 --concurrency 4 --max-tokens 32 | jq -r .tokens_per_s; }
med3() { python3 -c 'import sys,statistics;print(statistics.median([float(x) for x in sys.argv[1:]]))' "$@"; }
for P in 1 4; do
  PARALLEL=$P CTX=8192 "$LAB/bin/run-llama.sh" >/dev/null || exit 1
  r=(); for i in 1 2 3; do r+=("$(bench)"); done; declare "T$P=$(med3 "${r[@]}")"
done
"$LAB/bin/run-llama.sh" stop >/dev/null
jq -n --argjson a "$T1" --argjson b "$T4" '{parallel1_tps:$a, parallel4_tps:$b, ratio:($b/$a), why:"continuous_batching_shares_weight_reads"}' > "$LAB/answers/batching.json"
# 1.4: cache before (starter layout) and after (solution layout)
PARALLEL=1 CTX=4096 "$LAB/bin/run-llama.sh" >/dev/null || exit 1
python3 - "$LAB" "$MODULE_DIR" <<'PY'
import sys, json, importlib.util
sys.path.insert(0, sys.argv[2] + "/.lib"); import checks
lab = sys.argv[1]; url = "http://127.0.0.1:18120"
system = open(f"{lab}/variant/system.txt").read(); doc = open(f"{lab}/variant/doc.txt").read()
refn = checks.ntok(url, system + "\n\n" + doc)
def measure(path):
    B = checks.load_py(path, "b" + path[-12:])
    def req(q, i):
        msgs = B.build_messages(system, doc, q, "2026-10-26T10:%02d:00Z" % i, "req-%d" % (1000 + i))
        return checks.http(url + "/v1/chat/completions", {"messages": msgs, "max_tokens": 4, "temperature": 0, "cache_prompt": True})
    req("first question", 1)
    o = req("second question", 2)
    return (o["usage"].get("prompt_tokens_details") or {}).get("cached_tokens", 0)
before = measure(sys.argv[2] + "/.lib/starter_prompt_template.py"); after = measure(lab + "/prompt_template.py")
json.dump({"stable_prefix_tokens": refn, "cached_tokens_before": before, "cached_tokens_after": after}, open(f"{lab}/answers/cache.json", "w"), indent=1)
PY
"$LAB/bin/run-llama.sh" stop >/dev/null
# 1.5: sizes, load logs, prompt speed
Q4=$(env_kv "$LAB/variant/models.txt" Q4); Q8=$(env_kv "$LAB/variant/models.txt" Q8)
for q in Q4 Q8; do
  f=${!q}; MODEL=$f PARALLEL=1 CTX=2048 "$LAB/bin/run-llama.sh" >/dev/null || exit 1
  docker logs aiinfra-lab01-llama >"$TMP/log-$q.txt" 2>&1
  python3 "$CK" logparse "$TMP/log-$q.txt" > "$TMP/p-$q.json"
  python3 "$CK" pspeed http://127.0.0.1:18120 3 | jq -r .tps > "$TMP/s-$q.txt"
done
"$LAB/bin/run-llama.sh" stop >/dev/null
jq -n --argjson a "$(cat "$TMP/p-Q4.json")" --argjson b "$(cat "$TMP/p-Q8.json")" --argjson s4 "$(stat -c%s "$MODELS/$Q4")" --argjson s8 "$(stat -c%s "$MODELS/$Q8")" \
  --argjson t4 "$(cat "$TMP/s-Q4.txt")" --argjson t8 "$(cat "$TMP/s-Q8.txt")" \
  '{size_q4_bytes:$s4,size_q8_bytes:$s8,ftype_q4:$a.ftype,ftype_q8:$b.ftype,tensor_types_q4:$a.types,tensor_types_q8:$b.types,bpw_q4:$a.bpw,bpw_q8:$b.bpw,prompt_eval_ratio_q8_over_q4:($t8/$t4),why_q8_prompt_faster:"q8_simple_int8_blocks_map_to_dotprod_kernels"}' > "$LAB/answers/quant.json"
