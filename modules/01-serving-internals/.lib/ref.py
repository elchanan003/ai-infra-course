"""Reference formulas + variant generation for module 01 (harness side; used by prepare, verify, solve)."""
import json, math, random

GiB = 2 ** 30
CATALOG = {  # name: params_b, layers, heads, kv_heads, head_dim, hidden
    "llama-3.1-8b":  dict(params_b=8.03, layers=32, num_attention_heads=32, num_key_value_heads=8, head_dim=128, hidden_size=4096),
    "qwen2.5-7b":    dict(params_b=7.62, layers=28, num_attention_heads=28, num_key_value_heads=4, head_dim=128, hidden_size=3584),
    "llama-2-7b":    dict(params_b=6.74, layers=32, num_attention_heads=32, num_key_value_heads=32, head_dim=128, hidden_size=4096),
    "qwen2.5-0.5b":  dict(params_b=0.49, layers=24, num_attention_heads=14, num_key_value_heads=2, head_dim=64, hidden_size=896),
    "llama-3.1-70b": dict(params_b=70.55, layers=80, num_attention_heads=64, num_key_value_heads=8, head_dim=128, hidden_size=8192),
    "qwen2.5-72b":   dict(params_b=72.7, layers=80, num_attention_heads=64, num_key_value_heads=8, head_dim=128, hidden_size=8192),
    "mid-40h":       dict(params_b=14.8, layers=48, num_attention_heads=40, num_key_value_heads=8, head_dim=128, hidden_size=5120),
}
MIG = {"80gb": [("1g.10gb", 10), ("1g.20gb", 20), ("2g.20gb", 20), ("3g.40gb", 40), ("4g.40gb", 40), ("7g.80gb", 80)],
       "40gb": [("1g.5gb", 5), ("2g.10gb", 10), ("3g.20gb", 20), ("4g.20gb", 20), ("7g.40gb", 40)]}


def model(name, bpp):
    m = dict(CATALOG[name]); m["name"] = name; m["bytes_per_param"] = bpp
    return m


def hd(m):
    return m.get("head_dim") or m["hidden_size"] // m["num_attention_heads"]


def weights_gib(params_b, bpp): return params_b * 1e9 * bpp / GiB
def kv_bpt(layers, kvh, head_dim, kvb): return 2 * layers * kvh * head_dim * kvb
def kv_gib(layers, kvh, head_dim, kvb, seq, n): return kv_bpt(layers, kvh, head_dim, kvb) * seq * n / GiB


def need_per_gpu(m, tp, seq, n, kvb, overhead=2.0):
    w = weights_gib(m["params_b"], m["bytes_per_param"])
    kv = kv_gib(m["layers"], m["num_key_value_heads"], hd(m), kvb, seq, n)
    return (w + kv) / tp + overhead


def fits(m, gpu, util, tp, seq, n, kvb, overhead=2.0):
    return need_per_gpu(m, tp, seq, n, kvb, overhead) <= gpu * util


def min_tp(m, gpu, util, seq, n, kvb, overhead=2.0):
    for tp in (1, 2, 4, 8):
        if m["num_attention_heads"] % tp == 0 and m["num_key_value_heads"] % tp == 0 and fits(m, gpu, util, tp, seq, n, kvb, overhead):
            return tp
    return None


def max_seqs(m, gpu, util, tp, seq, kvb, overhead=2.0):
    w = weights_gib(m["params_b"], m["bytes_per_param"])
    pool = gpu * util - w / tp - overhead
    per = kv_bpt(m["layers"], m["num_key_value_heads"], hd(m), kvb) * seq / tp / GiB
    return max(0, int(pool // per)) if pool > 0 else 0


def mig_profile(m, family, util, seq, n, kvb, overhead=2.0):
    need = need_per_gpu(m, 1, seq, n, kvb, overhead)
    for name, gib in MIG[family]:
        if need <= gib * util:
            return name
    return None


def gen_variant(rng):
    # 1.2: single-GPU budget
    while True:
        name = rng.choice(["llama-3.1-8b", "qwen2.5-7b", "llama-2-7b"])
        bpp = rng.choice([2, 2, 1]); kvb = rng.choice([2, 1]); gpu = rng.choice([24, 40, 80])
        seq = rng.choice([4096, 8192]); util = 0.9
        m = model(name, bpp)
        pool = gpu * util - weights_gib(m["params_b"], bpp) - 2.0
        if pool > 1.5 and max_seqs(m, gpu, util, 1, seq, kvb) >= 2:
            break
    v12 = dict(model=name, bytes_per_param=bpp, kv_bytes=kvb, gpu_gib=gpu, util=util, seq_len=seq)
    # 1.6 large
    while True:
        name = rng.choice(["llama-3.1-70b", "qwen2.5-72b", "llama-3.1-70b"])
        bpp = rng.choice([2, 1]); kvb = rng.choice([2, 1]); gpu = rng.choice([40, 80])
        seq = rng.choice([4096, 8192, 16384]); n = rng.choice([4, 6, 8, 12, 16, 24])
        m = model(name, bpp)
        t = min_tp(m, gpu, 0.92, seq, n, kvb)
        if t in (2, 4, 8) and max_seqs(m, gpu, 0.92, t, seq, kvb) >= n:
            break
    large = dict(model=name, bytes_per_param=bpp, kv_bytes=kvb, gpu_gib=gpu, util=0.92, seq_len=seq, n_seqs=n)
    # 1.6 small / MIG
    while True:
        name = rng.choice(["llama-3.1-8b", "qwen2.5-7b", "qwen2.5-0.5b"])
        bpp = rng.choice([1, 0.5625, 2]); fam = rng.choice(["80gb", "40gb"]); n = rng.choice([2, 4, 6, 8])
        seq = 4096; kvb = rng.choice([2, 1])
        m = model(name, bpp)
        p = mig_profile(m, fam, 0.9, seq, n, kvb)
        if p and p not in ("7g.80gb", "7g.40gb"):
            break
    small = dict(model=name, bytes_per_param=bpp, kv_bytes=kvb, mig_family=fam, util=0.9, seq_len=seq, n_seqs=n)
    pair = rng.choice([("qwen2.5-0.5b-instruct-q4_k_m.gguf", "qwen2.5-0.5b-instruct-q8_0.gguf"),
                       ("Qwen2.5-Coder-0.5B-Q4_K_M.gguf", "Qwen2.5-Coder-0.5B-Q8_0.gguf")])
    return dict(seed=rng.randrange(1 << 30), sizing=v12, large=large, small=small, pair=list(pair))


def model_json(name, bpp, drop_head_dim=False):
    m = model(name, bpp)
    if drop_head_dim or name in ("qwen2.5-7b", "qwen2.5-0.5b"):
        m.pop("head_dim", None)
    return m


WORDS = ("cluster gateway token queue replica engine scheduler weights cache prefix decode prefill latency budget tenant key "
         "limit route fallback metric dashboard alert sandbox registry mirror digest manifest shard tensor kernel driver "
         "node pool slot batch window context stream request response backend upstream timeout retry policy").split()


def make_doc(seed, words=1100):
    r = random.Random(seed); out = []
    for i in range(words // 11):
        s = " ".join(r.choice(WORDS) for _ in range(10)) + "."
        out.append(s[0].upper() + s[1:])
    return " ".join(out)


if __name__ == "__main__":
    import sys
    print(json.dumps(gen_variant(random.SystemRandom()), indent=1))
