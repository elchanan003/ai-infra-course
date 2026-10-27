#!/usr/bin/env python3
"""Variant seeding + starter/solution generation for module 03 (stdlib only).

  gen.py init [--variant N] [--force]   write .state/variant.json (once) and (re)generate lab/ files
  gen.py solution OUTDIR                write the reference solution tree (lab/ mirror) for the seeded variant

Learner-owned files are only rewritten when still pristine (sha in .state/starter.sha) or with --force.
Given files (configs, SLO.md, load.json) are always rewritten.
"""
import hashlib, json, math, os, random, sys

MOD = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
LAB = os.path.join(MOD, "lab")
STATE = os.path.join(MOD, ".state")
MODELS = os.path.realpath(os.path.join(MOD, "..", "..", "mock", "models"))
GiB = 1024 ** 3

VARIANTS = [
    dict(pseqs=32, floor_a=65536, t3=(3000, 200), roles=["start", "fail-kv", "fail-gpu-free"], pred_other=2.0,
         pred=dict(start=(0.85, 16384), kv=(0.90, 98304), gpu=(0.95, 8192)),
         limiter="kv", press=dict(n=48, p=500, m=1000, seqs=256), node2_other=2.5, snap_seed="s0"),
    dict(pseqs=48, floor_a=57344, t3=(2500, 300), roles=["fail-gpu-free", "start", "fail-kv"], pred_other=2.0,
         pred=dict(start=(0.80, 12288), kv=(0.90, 81920), gpu=(0.97, 8192)),
         limiter="seq-cap", press=dict(n=48, p=500, m=1000, seqs=8), node2_other=3.0, snap_seed="s1"),
    dict(pseqs=64, floor_a=73728, t3=(3500, 150), roles=["fail-kv", "fail-gpu-free", "start"], pred_other=1.5,
         pred=dict(start=(0.88, 16384), kv=(0.90, 131072), gpu=(0.96, 8192)),
         limiter="kv", press=dict(n=48, p=400, m=1200, seqs=256), node2_other=2.0, snap_seed="s2"),
]
SERVED = "--served-model-name chat"
LLAMA = "--model /models/llama-3.1-8b"


# ---------------------------------------------------------------- pure-math capacity (mirrors mock/README 3.2)
def geometry():
    c = json.load(open(os.path.join(MODELS, "llama-3.1-8b", "config.json")))
    h, heads, kv = c["hidden_size"], c["num_attention_heads"], c.get("num_key_value_heads", c["num_attention_heads"])
    hd = c.get("head_dim") or h // heads
    L, inter, vocab = c["num_hidden_layers"], c["intermediate_size"], c["vocab_size"]
    tie = bool(c.get("tie_word_embeddings", False))
    attn = h * heads * hd + 2 * h * kv * hd + heads * hd * h
    params = vocab * h * (1 if tie else 2) + L * (attn + 3 * h * inter + 2 * h) + h
    return dict(h=h, heads=heads, kv=kv, hd=hd, L=L, inter=inter, vocab=vocab, params=params, maxpos=c["max_position_embeddings"])


def capacity(util, mml, seqs, mem_gib, other_gib=0.0, mnbt=8192, kvbytes=2, block=16):
    g = geometry()
    total = mem_gib * GiB
    req = util * total
    weights = g["params"] * 2
    act = mnbt * (g["h"] + 2 * g["inter"]) * 2 * 2 + seqs * g["vocab"] * 4
    kvmem = req - weights - act - 0.6 * GiB
    per_tok = 2 * g["L"] * g["kv"] * g["hd"] * kvbytes
    blocks = int(kvmem // (per_tok * block)) if kvmem > 0 else 0
    free_ok = (total - other_gib * GiB) >= req
    return dict(free_ok=free_ok, blocks=blocks, tokens=blocks * block, max_len_fit=max(0, (blocks - 1) * block),
                kv_ok=(blocks - 1) * block >= mml, per_tok=per_tok)


# ---------------------------------------------------------------- file writers
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else ""


class Writer:
    def __init__(self, root, manifest=None, force=False):
        self.root, self.manifest, self.force = root, manifest, force

    def given(self, rel, text):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)

    def owned(self, rel, text):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if self.manifest is not None and os.path.exists(p) and not self.force:
            if sha(p) != self.manifest.get(rel, "?"):  # learner edited it (or manifest missing): keep
                return
        open(p, "w").write(text)
        if self.manifest is not None:
            self.manifest[rel] = sha(p)


def gpu_yaml(name, mem=None, other=0.0, note=""):
    s = f"# SIMULATED GPU for mock-vllm (contract: mock/README.md section 2). {note}\nname: {name}\ncount: 1\n"
    if mem:
        s += f"memory_gib: {mem}\n"
    if other:
        s += f"other_process_gib: {other}   # memory held by another process at startup\n"
    return s


def args_line(*parts):
    return " ".join(parts) + "\n"


def snapshot_sizes(seed):
    r = random.Random(seed)
    small = [r.randint(60, 420) for _ in range(34)]
    big = [r.randint(3200, 6500) for _ in range(6)]
    xs = small + big
    r.shuffle(xs)
    return xs


def build(w, v, vi, owned=True):
    P, M = v["t3"]
    pr = v["pred"]
    cfg = {"start": pr["start"], "fail-kv": pr["kv"], "fail-gpu-free": pr["gpu"]}
    # ---- 3.1 predict (given configs; role order shuffled per variant)
    order = v["roles"]
    for i, role in enumerate(order, 1):
        util, mml = cfg[role]
        w.given(f"predict/cfg-{i}.args", f"# candidate config {i} (model/GPU: see gpu.yaml in this folder)\n"
                + args_line(LLAMA, SERVED, f"--max-model-len {mml}", f"--gpu-memory-utilization {util}", f"--max-num-seqs {v['pseqs']}"))
    w.given("predict/gpu.yaml", gpu_yaml("A10G", other=v["pred_other"], note="Node used for all three candidates."))
    w.given("predict/model/config.json", open(os.path.join(MODELS, "llama-3.1-8b", "config.json")).read())
    if owned:
        w.owned("predict/PREDICT.env", "# Task 3.1: predict BEFORE launching. OUTCOME_N = start | fail-kv | fail-gpu-free\n"
                "# KV_TOKENS_N = tokens in the KV pool (configs that start), MAX_LEN_FIT_N = 'estimated maximum model length' (fail-kv), else 0\n"
                + "".join(f"OUTCOME_{i}=REPLACE_ME\nKV_TOKENS_{i}=REPLACE_ME\nMAX_LEN_FIT_{i}=REPLACE_ME\n" for i in (1, 2, 3)))
    # ---- 3.2 vllm-a
    w.given("vllm-a/gpu.yaml", gpu_yaml("A10G", other=0.5, note="Node-1: a small monitoring agent holds 0.5 GiB."))
    w.given("vllm-a/model/config.json", open(os.path.join(MODELS, "llama-3.1-8b", "config.json")).read())
    if owned:
        w.owned("vllm-a/args", "# Task 3.2: this config crash-loops. Fix it without dropping --max-model-len below the floor (slo/SLO.md).\n"
                + args_line(LLAMA, SERVED, "--max-model-len 131072", "--gpu-memory-utilization 0.90", "--max-num-seqs 64"))
    # ---- 3.3 vllm-b
    w.given("vllm-b/gpu.yaml", gpu_yaml("A10G", note="Same GPU type as node-1, nothing else on it."))
    w.given("vllm-b/model/config.json", open(os.path.join(MODELS, "llama-3.1-8b", "config.json")).read())
    if owned:
        w.owned("vllm-b/args", "# Task 3.3: 8 concurrent requests must run together without preemption (slo/SLO.md).\n"
                + args_line(LLAMA, SERVED, "--max-model-len 8192", "--gpu-memory-utilization 0.75", "--max-num-seqs 4"))
    # ---- 3.5 pressure (given, fixed config)
    q = v["press"]
    w.given("pressure/args", "# Task 3.5: fixed config (do not edit). Run it on the scratch instance: tools/apply.sh x --args lab/pressure/args --gpu lab/pressure/gpu.yaml\n"
            + args_line(LLAMA, SERVED, "--max-model-len 4096", "--gpu-memory-utilization 0.90", f"--max-num-seqs {q['seqs']}"))
    w.given("pressure/gpu.yaml", gpu_yaml("A10G"))
    w.given("pressure/model/config.json", open(os.path.join(MODELS, "llama-3.1-8b", "config.json")).read())
    # ---- 3.6 slo
    w.given("slo/gpu.yaml", gpu_yaml("A100-80GB", note="Shared GPU: another tenant owns the rest, so the utilization below is fixed."))
    if owned:
        w.owned("slo/args", "# Task 3.6: tune --max-num-seqs (and --max-num-batched-tokens). Utilization and max length are FIXED by the platform team.\n"
                + args_line(LLAMA, SERVED, "--max-model-len 4096", "--gpu-memory-utilization 0.30", "--max-num-seqs 8"))
    # ---- 3.8 vllm-t
    w.given("vllm-t/gpu.node1.yaml", gpu_yaml("A10G", note="node-1: nothing else on the GPU."))
    w.given("vllm-t/gpu.node2.yaml", gpu_yaml("A10G", other=v["node2_other"], note="node-2: another process holds this much GPU memory."))
    w.given("vllm-t/model/config.json", open(os.path.join(MODELS, "llama-3.1-8b", "config.json")).read())
    if owned:
        w.owned("vllm-t/args", "# Task 3.8: starts on node-1, dies on node-2. Fix it for BOTH nodes; do not change --max-model-len.\n"
                + args_line(LLAMA, SERVED, "--max-model-len 8192", "--gpu-memory-utilization 0.98", "--max-num-seqs 32"))
    # ---- answers
    if owned:
        w.owned("answers/ttft.env", "# Task 3.4\nP95_TTFT_SECONDS=REPLACE_ME\nBUCKET_LOWER=REPLACE_ME\nBUCKET_UPPER=REPLACE_ME\n")
        w.owned("answers/pressure.env", "# Task 3.5: KV_PEAK = peak kv_cache_usage_perc (0..1), PREEMPTIONS = counter delta,\n"
                "# LIMITER = seq-cap | kv  (which budget limited the burst)\nKV_PEAK=REPLACE_ME\nPREEMPTIONS=REPLACE_ME\nLIMITER=REPLACE_ME\n")
    # ---- given: SLO.md + load.json
    w.given("slo/load.json", json.dumps({
        "task3": {"n": 8, "prompt_tokens": P, "max_tokens": M},
        "pressure": {"n": q["n"], "prompt_tokens": q["p"], "max_tokens": q["m"]},
        "sweep": {"n": 96, "prompt_tokens": 600, "max_tokens": 300, "jitter": 0.3},
        "snapshot": {"max_tokens": 16, "prompt_tokens": snapshot_sizes(v["snap_seed"])},
    }, indent=1) + "\n")
    w.given("slo/SLO.md", f"""# Given numbers for tasks 3.2, 3.3, 3.6, 3.8

## 3.2 (vllm-a, llama-3.1-8b on node-1: A10G 24 GiB, other process 0.5 GiB)
- Context floor required by the product: **{v['floor_a']}** tokens (`--max-model-len` must be >= this).
- Utilization may not exceed 0.95 on this node.

## 3.3 (vllm-b)
- Load: 8 concurrent chat requests, each prompt ~{P} tokens, `max_tokens` {M}
  (`python3 lab/tools/load.py --target b --preset task3`).
- Needed: all 8 run at the same time (peak `num_requests_running` >= 8), no preemption, all HTTP 200.

## 3.6 (slo/ — A100-80GB shared with another tenant: utilization fixed at 0.30, max length fixed at 4096)
Load family (verify uses the same family with another seed): one burst of 96 requests, prompt ~600 tokens, `max_tokens` ~300 (+-30%).

| SLO | Target |
|---|---|
| p95 inter-token latency | <= 0.1 s (at least 95% of inter-token gaps in the bucket `le="0.1"` or below) |
| Output throughput (generation tokens per **virtual** second of busy time) | >= 1450 tok/s |
| Preemptions | 0 |
TTFT is not graded here: in a single synchronized burst TTFT is just queue position; in production you gate TTFT on a realistic arrival process (module 08).

## 3.8 (vllm-t, node-2)
Same GPU type as node-1, but another process holds part of the GPU memory on node-2 (see `lab/vllm-t/gpu.node2.yaml`;
in production you would see it in `nvidia-smi`). Required headroom: configured utilization must be at least 0.02 below the free fraction.
""")
    # ---- tools (symlinks created by prepare; ensure dir exists)
    os.makedirs(os.path.join(w.root, "tools"), exist_ok=True)


def solution(outdir, v):
    P, M = v["t3"]
    w = Writer(outdir)
    pr = v["pred"]
    cfg = {"start": pr["start"], "fail-kv": pr["kv"], "fail-gpu-free": pr["gpu"]}
    lines = []
    for i, role in enumerate(v["roles"], 1):
        util, mml = cfg[role]
        c = capacity(util, mml, v["pseqs"], 24, v["pred_other"])
        if not c["free_ok"]:
            out = "fail-gpu-free"; tok = 0; fit = 0
        elif not c["kv_ok"]:
            out = "fail-kv"; tok = 0; fit = c["max_len_fit"]
        else:
            out = "start"; tok = c["tokens"]; fit = 0
        lines += [f"OUTCOME_{i}={out}", f"KV_TOKENS_{i}={tok}", f"MAX_LEN_FIT_{i}={fit}"]
    w.given("predict/PREDICT.env", "\n".join(lines) + "\n")
    w.given("vllm-a/args", args_line(LLAMA, SERVED, f"--max-model-len {v['floor_a']}", "--gpu-memory-utilization 0.92",
                                    "--kv-cache-dtype fp8", "--max-num-seqs 64"))
    w.given("vllm-b/args", args_line(LLAMA, SERVED, "--max-model-len 8192", "--gpu-memory-utilization 0.90", "--max-num-seqs 16"))
    w.given("slo/args", args_line(LLAMA, SERVED, "--max-model-len 4096", "--gpu-memory-utilization 0.30", "--max-num-seqs 56"))
    w.given("vllm-t/args", args_line(LLAMA, SERVED, "--max-model-len 8192", "--gpu-memory-utilization 0.85", "--max-num-seqs 32"))
    # answers that depend on live replays are written by .tutor/apply-solution.sh (it replays the scenarios); placeholders here
    return w


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    os.makedirs(STATE, exist_ok=True)
    vp = os.path.join(STATE, "variant.json")
    force = "--force" in sys.argv
    if cmd == "init":
        if "--variant" in sys.argv:
            vi = int(sys.argv[sys.argv.index("--variant") + 1]) % len(VARIANTS)
        elif os.path.exists(vp):
            vi = json.load(open(vp))["index"]
        else:
            vi = random.SystemRandom().randrange(len(VARIANTS))
        v = VARIANTS[vi]
        json.dump(dict(index=vi, **{k: v[k] for k in v}), open(vp, "w"), indent=1)
        mp = os.path.join(STATE, "starter.sha")
        vm = os.path.join(LAB, ".variant")
        fresh = (not os.path.exists(mp)) or (not os.path.exists(vm)) or open(vm).read().strip() != str(vi)
        man = json.load(open(mp)) if not fresh else {}
        w = Writer(LAB, man, force or fresh)
        build(w, v, vi)
        open(os.path.join(LAB, ".variant"), "w").write(str(vi) + "\n")
        json.dump(man, open(mp, "w"), indent=1)
    elif cmd == "solution":
        vi = json.load(open(vp))["index"]
        v = VARIANTS[vi]
        solution(sys.argv[2], v)
    elif cmd == "get":  # gen.py get KEY -> print variant value (json)
        d = json.load(open(vp))
        for k in sys.argv[2].split("."):
            d = d[int(k)] if isinstance(d, list) else d[k]
        print(d if isinstance(d, (str, int, float)) else json.dumps(d))
    else:
        print(__doc__); sys.exit(2)


main()
