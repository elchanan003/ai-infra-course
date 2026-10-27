#!/usr/bin/env python3
"""Harness-side checks for module 01. Each subcommand prints lines 'STATUS ID message' (STATUS = PASS|FAIL)."""
import importlib.util, json, math, os, random, re, statistics, subprocess, sys, tempfile, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import ref  # noqa: E402


def out(st, id_, msg): print(f"{st} {id_} {msg}", flush=True)
def close(a, b, rel=0.02, ab=0.0): return a is not None and isinstance(a, (int, float)) and abs(a - b) <= max(abs(b) * rel, ab)
def load_py(path, name="learner"):
    spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
def variant(p): return json.load(open(p))
def http(url, body=None, timeout=300, method=None):
    req = urllib.request.Request(url, json.dumps(body).encode() if body is not None else None, {"Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r: return json.loads(r.read().decode() or "null")
def metric(url, name):
    with urllib.request.urlopen(url + "/metrics", timeout=10) as r:
        for line in r.read().decode().splitlines():
            if line.startswith(name + " "): return float(line.split()[1])
    return None
def ntok(url, text): return len(http(url + "/tokenize", {"content": text})["tokens"])


# ------------------------------------------------------------------------------------------ 1.1
def cmd_sizing(path, vpath):
    v = variant(vpath); rng = random.Random(v["seed"])
    try: S = load_py(path)
    except Exception as e:
        for i in ("1.1.1", "1.1.2", "1.1.3", "1.1.4"): out("FAIL", i, f"sizing.py does not import: {type(e).__name__}: {e}")
        return
    names = ["llama-3.1-8b", "qwen2.5-7b", "llama-2-7b", "llama-3.1-70b", "mid-40h", "qwen2.5-7b"]
    cases = []
    for k, n in enumerate(names):
        bpp = rng.choice([2, 1, 0.5625, 2]); m = ref.model_json(n, bpp) if k == 1 else ref.model(n, bpp)
        if k != 1: pass
        cases.append(dict(m=m, kvb=rng.choice([2, 1]), seq=rng.choice([2048, 4096, 8192, 32768]), n=rng.choice([1, 4, 16, 64]),
                          gpu=rng.choice([24, 40, 80]), util=rng.choice([0.9, 0.92])))

    def run(id_, f):
        for i, c in enumerate(cases):
            try: ok, msg = f(c)
            except Exception as e: out("FAIL", id_, f"raised {type(e).__name__}: {e} (case {i + 1}/6)"); return
            if not ok: out("FAIL", id_, f"case {i + 1}/6: {msg}"); return
        out("PASS", id_, "all 6 hidden cases correct")

    def c1(c):
        m = c["m"]; w = S.weights_gb(m["params_b"], m["bytes_per_param"]); ew = ref.weights_gib(m["params_b"], m["bytes_per_param"])
        if not close(w, ew, 0.005): return False, f"weights_gb({m['params_b']}, {m['bytes_per_param']}) = {w:.3f}, off by {abs(w-ew)/ew*100:.1f}% - check units (GiB, theory section 'Units')"
        k = S.kv_bytes_per_token(m["layers"], m["num_key_value_heads"], ref.hd(m), c["kvb"]); ek = ref.kv_bpt(m["layers"], m["num_key_value_heads"], ref.hd(m), c["kvb"])
        if k != ek: return False, f"kv_bytes_per_token = {k}, wrong for layers={m['layers']} kv_heads={m['num_key_value_heads']} (which head count sets KV size? theory 2.1)"
        return True, ""
    def c2(c):
        m = c["m"]; g = S.kv_gb(m["layers"], m["num_key_value_heads"], ref.hd(m), c["kvb"], c["seq"], c["n"]); e = ref.kv_gib(m["layers"], m["num_key_value_heads"], ref.hd(m), c["kvb"], c["seq"], c["n"])
        return (close(g, e, 0.005), f"kv_gb = {g:.4f} for seq={c['seq']} n_seqs={c['n']} kv_bytes={c['kvb']} (units? scaling with sequences and KV dtype?)")
    run("1.1.1", c1); run("1.1.2", c2)
    # fits: 4 regular + 2 boundary (+-1% around the exact threshold)
    fc = [dict(c, tp=rng.choice([1, 2, 4])) for c in cases]
    for j in (4, 5):
        c = fc[j]; need = ref.need_per_gpu(c["m"], c["tp"], c["seq"], c["n"], c["kvb"]); c["gpu"] = need / c["util"] * (0.99 if j == 4 else 1.01)
    for i, c in enumerate(fc):
        try: got = S.fits(c["m"], c["gpu"], c["util"], c["tp"], c["seq"], c["n"], c["kvb"])
        except Exception as e: out("FAIL", "1.1.3", f"fits raised {type(e).__name__}: {e}"); break
        exp = ref.fits(c["m"], c["gpu"], c["util"], c["tp"], c["seq"], c["n"], c["kvb"])
        if bool(got) != exp:
            out("FAIL", "1.1.3", f"case {i + 1}/6: fits() says {bool(got)} for {c['m']['name']} tp={c['tp']} on {c['gpu']:.1f} GiB x util {c['util']} - re-derive the per-GPU budget (weights+KV shard by TP, overhead, util; theory 6)"); break
    else: out("PASS", "1.1.3", "fits() correct incl. both sides of the boundary")
    # min_tp: 4 random + divisibility traps
    mc = [dict(c) for c in cases[:4]]
    m = ref.model("qwen2.5-7b", 2); mm = ref.model_json("qwen2.5-7b", 2)
    n4 = ref.need_per_gpu(m, 4, 4096, 8, 2); n8 = ref.need_per_gpu(m, 8, 4096, 8, 2)
    mc.append(dict(m=mm, kvb=2, seq=4096, n=8, util=0.9, gpu=(n4 + n8) / 2 / 0.9))  # fits only at invalid TP=8 -> None
    ml = ref.model("llama-3.1-8b", 2); n2 = ref.need_per_gpu(ml, 2, 8192, 8, 2); n3 = ref.need_per_gpu(ml, 3, 8192, 8, 2)
    mc.append(dict(m=ml, kvb=2, seq=8192, n=8, util=0.9, gpu=(n2 + n3) / 2 / 0.9))      # TP=3 would fit; answer is 4
    for i, c in enumerate(mc):
        try: got = S.min_tp(c["m"], c["gpu"], c["util"], c["seq"], c["n"], c["kvb"])
        except Exception as e: out("FAIL", "1.1.4", f"min_tp raised {type(e).__name__}: {e}"); break
        exp = ref.min_tp(c["m"], c["gpu"], c["util"], c["seq"], c["n"], c["kvb"])
        if got != exp:
            out("FAIL", "1.1.4", f"case {i + 1}/6: min_tp = {got!r} for {c['m']['name']} on {c['gpu']:.1f} GiB (heads {c['m']['num_attention_heads']}, kv heads {c['m']['num_key_value_heads']}) - which TP values are legal? (theory 6.2)"); break
    else: out("PASS", "1.1.4", "min_tp correct incl. divisibility and the no-fit case")


# ------------------------------------------------------------------------------------------ 1.2
def parse_env(path):
    d = {}
    for l in open(path):
        l = l.split("#")[0].strip()
        if "=" in l: k, v = l.split("=", 1); d[k.strip()] = v.strip().strip("\"'")
    return d
def num(x):
    try: return float(x)
    except Exception: return None

def cmd_vram(path, vpath):
    s = variant(vpath)["sizing"]; m = ref.model(s["model"], s["bytes_per_param"]); e = parse_env(path) if os.path.exists(path) else {}
    w = ref.weights_gib(m["params_b"], s["bytes_per_param"]); kb = ref.kv_bpt(m["layers"], m["num_key_value_heads"], ref.hd(m), s["kv_bytes"])
    pool = s["gpu_gib"] * s["util"] - w - 2.0; ms = ref.max_seqs(m, s["gpu_gib"], s["util"], 1, s["seq_len"], s["kv_bytes"])
    out("PASS" if close(num(e.get("WEIGHTS_GIB")), w, 0.02) else "FAIL", "1.2.1", "WEIGHTS_GIB ok" if close(num(e.get("WEIGHTS_GIB")), w, 0.02) else "WEIGHTS_GIB is not the weight memory of this variant model (params x bytes/param, in GiB)")
    ok = num(e.get("KV_BYTES_PER_TOKEN")) == kb
    out("PASS" if ok else "FAIL", "1.2.2", "KV_BYTES_PER_TOKEN exact" if ok else "KV_BYTES_PER_TOKEN is wrong: read num_key_value_heads/head_dim from lab/variant/model.json (head_dim may be missing) and the KV dtype")
    ok = close(num(e.get("KV_POOL_GIB")), pool, 0.02, 0.05) and num(e.get("MAX_SEQS")) is not None and abs(num(e.get("MAX_SEQS")) - ms) <= max(1, 0.02 * ms)
    out("PASS" if ok else "FAIL", "1.2.3", "KV pool and MAX_SEQS correct" if ok else "KV_POOL_GIB / MAX_SEQS differ from the budget gpu x util - weights - overhead at TP=1, divided by KV per sequence")


# ------------------------------------------------------------------------------------------ 1.6
def cmd_tp(path, vpath):
    v = variant(vpath); L = v["large"]; S = v["small"]
    try: a = json.load(open(path))
    except Exception as e:
        for i in ("1.6.1", "1.6.2", "1.6.3", "1.6.4"): out("FAIL", i, f"tp.json unreadable: {e}")
        return
    m = ref.model(L["model"], L["bytes_per_param"]); t = ref.min_tp(m, L["gpu_gib"], L["util"], L["seq_len"], L["n_seqs"], L["kv_bytes"])
    out("PASS" if a.get("min_tp_large") == t else "FAIL", "1.6.1", "min_tp_large correct" if a.get("min_tp_large") == t else "min_tp_large is wrong for this variant (weights + KV for the required sequences, TP divisibility, util 0.92, 2 GiB per GPU)")
    ms = ref.max_seqs(m, L["gpu_gib"], L["util"], t, L["seq_len"], L["kv_bytes"]) if t else 0
    g = a.get("max_seqs_at_min_tp"); ok = isinstance(g, (int, float)) and abs(g - ms) <= max(1, 0.02 * ms)
    out("PASS" if ok else "FAIL", "1.6.2", "max_seqs_at_min_tp correct" if ok else "max_seqs_at_min_tp is wrong: per-GPU KV pool after weights/TP and overhead, divided by the per-GPU KV of one sequence")
    sm = ref.model(S["model"], S["bytes_per_param"]); p = ref.mig_profile(sm, S["mig_family"], S["util"], S["seq_len"], S["n_seqs"], S["kv_bytes"])
    out("PASS" if a.get("mig_profile_small") == p else "FAIL", "1.6.3", "mig_profile_small correct" if a.get("mig_profile_small") == p else "mig_profile_small is not the smallest profile of the GPU family that holds weights + KV + overhead within util x slice memory (list in theory 6.4)")
    e = str(a.get("explain_no_tp3", "")).lower()
    ok = re.search(r"attention.?heads|num_attention_heads|heads", e) and re.search(r"kv.?heads|key.?value|num_key_value_heads", e) and re.search(r"divi|multiple", e)
    out("PASS" if ok else "FAIL", "1.6.4", "explanation mentions head divisibility" if ok else "explain_no_tp3 must say that TP has to divide the attention heads and the KV heads")


# ------------------------------------------------------------------------------------------ 1.7
def cmd_calc(path, vpath):
    v = variant(vpath); rng = random.Random(v["seed"] + 7); tmp = tempfile.mkdtemp()
    names = ["llama-3.1-8b", "qwen2.5-7b", "llama-3.1-70b", "mid-40h", "llama-2-7b", "llama-3.1-70b"]
    bad = None; contract = True; n = 0
    for k, nm in enumerate(names):
        bpp = rng.choice([2, 1]); m = ref.model_json(nm, bpp)
        tp = [2, 4, 4, 2, 1, 8][k]; gpu = [24, 40, 80, 40, 24, 40][k]; seq = rng.choice([4096, 8192]); seqs = rng.choice([4, 8, 16]); kvb = rng.choice([2, 1]); util = 0.9
        mp = os.path.join(tmp, f"m{k}.json"); json.dump(m, open(mp, "w"))
        cmd = [sys.executable, path, mp, "--gpu", str(gpu), "--tp", str(tp), "--seq", str(seq), "--seqs", str(seqs), "--kv-bytes", str(kvb), "--util", str(util), "--overhead", "2"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        try: o = json.loads(r.stdout)
        except Exception: contract = False; bad = bad or f"case {k+1}/6: team_calc.py exited {r.returncode} without JSON ({r.stderr.strip()[-120:]})"; continue
        if set(o) != {"weights_gib", "kv_gib", "per_gpu_gib", "budget_gib", "fits"}: contract = False
        mm = ref.model(nm, bpp); w = ref.weights_gib(mm["params_b"], bpp); kv = ref.kv_gib(mm["layers"], mm["num_key_value_heads"], ref.hd(mm), kvb, seq, seqs)
        pg = (w + kv) / tp + 2.0; fits = pg <= gpu * util
        for key, ev in (("weights_gib", w), ("kv_gib", kv), ("per_gpu_gib", pg), ("budget_gib", gpu * util)):
            if not close(o.get(key), ev, 0.02, 0.01): bad = bad or f"case {k+1}/6: {key} = {o.get(key)} for {nm} tp={tp} differs from the correct value (units, KV head count, tensor-parallel split are independent suspects)"
        if o.get("fits") != fits: bad = bad or f"case {k+1}/6: 'fits' verdict is wrong for {nm} tp={tp} on {gpu} GiB"
    out("PASS" if not bad else "FAIL", "1.7.1", "team_calc.py agrees with the reference on 6 hidden cases" if not bad else bad)
    out("PASS" if contract else "FAIL", "1.7.2", "CLI contract intact" if contract else "CLI contract broken (flags or output keys changed)")


# ------------------------------------------------------------------------------------------ llama helpers
def mkprompt(url, target, seed):
    r = random.Random(seed); words = []
    while True:
        words += [r.choice(ref.WORDS) for _ in range(120)]
        t = " ".join(words)
        if ntok(url, t) >= target: break
    lo, hi = 1, len(words)
    while lo < hi:
        mid = (lo + hi) // 2
        if ntok(url, " ".join(words[:mid])) >= target: hi = mid
        else: lo = mid + 1
    return " ".join(words[:lo])

def cmd_slots(url, target="1800"):
    target = int(target); res = [None] * 4
    prompts = [mkprompt(url, target, 100 + i) for i in range(4)]
    def go(i):
        try:
            o = http(url + "/v1/chat/completions", {"messages": [{"role": "user", "content": prompts[i]}], "max_tokens": 8, "temperature": 0, "cache_prompt": False}, timeout=300)
            res[i] = ("200", o["usage"]["prompt_tokens"])
        except urllib.error.HTTPError as e: res[i] = (str(e.code), 0)
        except Exception as e: res[i] = ("ERR", 0)
    th = [threading.Thread(target=go, args=(i,)) for i in range(4)]; [t.start() for t in th]; [t.join() for t in th]
    try: nctx = [s.get("n_ctx") for s in http(url + "/slots")]
    except Exception: nctx = "?"
    ok = all(r and r[0] == "200" and r[1] >= 0.95 * target for r in res)
    out("PASS" if ok else "FAIL", "1.3.1", "4 concurrent ~1800-token prompts served untruncated" if ok else f"not all 4 concurrent ~{target}-token prompts were served in full (statuses/prompt_tokens: {res}; per-slot n_ctx reported by /slots: {nctx}) - how is the context divided between slots? (theory 3.1)")

def cmd_measure(url, conc="4", maxtok="32"):
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lab"))
    conc = int(conc); maxtok = int(maxtok)
    prompts = ["Write a long story about a lighthouse keeper.", "Explain how a bicycle works in detail.", "List many facts about the planet Mars.", "Describe a day in the life of a baker."]
    b = metric(url, "llamacpp:tokens_predicted_total"); t0 = time.time()
    def go(i): http(url + "/v1/chat/completions", {"messages": [{"role": "user", "content": prompts[i % 4]}], "max_tokens": maxtok, "temperature": 0.7, "cache_prompt": False})
    th = [threading.Thread(target=go, args=(i,)) for i in range(conc)]; [t.start() for t in th]; [t.join() for t in th]
    wall = time.time() - t0; a = metric(url, "llamacpp:tokens_predicted_total")
    print(json.dumps({"tokens_per_s": (a - b) / wall}))

def cmd_cache(url, builder, vpath, labvar):
    v = variant(vpath); system = open(os.path.join(labvar, "system.txt")).read(); doc = open(os.path.join(labvar, "doc.txt")).read()
    refn = ntok(url, system + "\n\n" + doc)
    try: B = load_py(builder, "builder")
    except Exception as e: out("FAIL", "1.4.1", f"prompt_template.py does not import: {e}"); return
    def req(q):
        msgs = B.build_messages(system, doc, q, f"2026-10-26T{random.randrange(24):02d}:{random.randrange(60):02d}:{random.randrange(60):02d}Z", "req-%08x" % random.randrange(1 << 32))
        return http(url + "/v1/chat/completions", {"messages": msgs, "max_tokens": 4, "temperature": 0, "cache_prompt": True})
    try:
        req("Which words repeat most often?"); time.sleep(0.2)
        c0 = metric(url, "llamacpp:prompt_tokens_cached_total") or 0
        o = req("Name one noun from the document.")
    except Exception as e: out("FAIL", "1.4.1", f"build_messages failed: {type(e).__name__}: {e}"); return
    cached = (o.get("usage", {}).get("prompt_tokens_details") or {}).get("cached_tokens", 0)
    delta = (metric(url, "llamacpp:prompt_tokens_cached_total") or 0) - c0
    got = max(cached, delta)
    ok = got >= 0.8 * refn
    out("PASS" if ok else "FAIL", "1.4.1", f"second request reused {got:.0f} of ~{refn} stable-prefix tokens" if ok else f"second request reused only {got:.0f} of ~{refn} shared tokens: what comes first in your prompt differs between requests (theory 4: strict prefix)")
    # determinism of the stable part
    a = B.build_messages(system, doc, "q one", "t1", "r1"); b = B.build_messages(system, doc, "q two", "t2-different", "r2-different")
    fa = "\n".join(m["role"] + ":" + m["content"] for m in a); fb = "\n".join(m["role"] + ":" + m["content"] for m in b)
    cp = os.path.commonprefix([fa, fb])
    ok = len(cp) >= len(system) + len(doc)
    out("PASS" if ok else "FAIL", "1.4.2", "stable part (system + document) is a byte-identical leading prefix" if ok else f"only {len(cp)} leading characters are identical between two calls (system+document are {len(system)+len(doc)}): something volatile precedes them")
    return refn

def cmd_cacheans(url, labvar, answers):
    system = open(os.path.join(labvar, "system.txt")).read(); doc = open(os.path.join(labvar, "doc.txt")).read(); refn = ntok(url, system + "\n\n" + doc)
    try: a = json.load(open(answers))
    except Exception as e: out("FAIL", "1.4.3", f"cache.json unreadable: {e}"); return
    p = a.get("stable_prefix_tokens"); b = a.get("cached_tokens_before"); f = a.get("cached_tokens_after")
    ok = close(p, refn, 0.03) and isinstance(b, (int, float)) and 0 <= b <= 0.1 * refn and isinstance(f, (int, float)) and f >= 0.8 * refn
    out("PASS" if ok else "FAIL", "1.4.3", "cache.json consistent with the live token counts" if ok else "cache.json: stable_prefix_tokens must match /tokenize of system + blank line + document (within 3%), cached_tokens_before <= 10% and cached_tokens_after >= 80% of it")

# ------------------------------------------------------------------------------------------ 1.5
def parse_log(text):
    ft = re.search(r"file type\s*=\s*(.+?)\s*$", text, re.M); bpw = re.search(r"\(([\d.]+)\s*BPW\)", text)
    types = sorted(set(m.group(1).lower() for m in re.finditer(r"- type\s+(\S+?):\s+\d+ tensors", text)))
    return dict(ftype=ft.group(1).strip() if ft else None, bpw=float(bpw.group(1)) if bpw else None, types=types)

def cmd_logparse(logfile): print(json.dumps(parse_log(open(logfile).read())))

def cmd_pspeed(url, rounds="3"):
    vals = []
    for i in range(int(rounds)):
        p = mkprompt(url, 700, 500 + i)
        t0 = metric(url, "llamacpp:prompt_tokens_total"); s0 = metric(url, "llamacpp:prompt_seconds_total")
        http(url + "/v1/chat/completions", {"messages": [{"role": "user", "content": p}], "max_tokens": 1, "temperature": 0, "cache_prompt": False})
        t1 = metric(url, "llamacpp:prompt_tokens_total"); s1 = metric(url, "llamacpp:prompt_seconds_total")
        vals.append((t1 - t0) / max(s1 - s0, 1e-6))
    print(json.dumps({"tps": statistics.median(vals), "all": vals}))

def cmd_quant(answers, truthfile):
    t = json.load(open(truthfile))
    try: a = json.load(open(answers))
    except Exception as e:
        for i in ("1.5.1", "1.5.2", "1.5.3", "1.5.4"): out("FAIL", i, f"quant.json unreadable: {e}")
        return
    ok = a.get("size_q4_bytes") == t["size_q4"] and a.get("size_q8_bytes") == t["size_q8"]
    out("PASS" if ok else "FAIL", "1.5.1", "file sizes exact" if ok else "file sizes are not the exact byte counts of the two GGUF files in lab/variant/models.txt (stat, not ls -h)")
    lc = lambda x: sorted(str(s).lower() for s in (x or []))
    ok = str(a.get("ftype_q4", "")).strip().lower() == (t["q4"]["ftype"] or "?").lower() and str(a.get("ftype_q8", "")).strip().lower() == (t["q8"]["ftype"] or "?").lower() and lc(a.get("tensor_types_q4")) == t["q4"]["types"] and lc(a.get("tensor_types_q8")) == t["q8"]["types"]
    out("PASS" if ok else "FAIL", "1.5.2", "ftype and tensor types match the load logs" if ok else "ftype / tensor type sets differ from what llama-server prints when it loads these files (read the 'llama_model_loader' lines of the load log)")
    r = a.get("prompt_eval_ratio_q8_over_q4"); rv = t["ratio"]
    if rv is None: out("FAIL", "1.5.3", "verify could not measure a stable ratio (host busy?) - rerun when idle"); 
    else:
        ok = isinstance(r, (int, float)) and r > 1.5 and rv / 1.6 <= r <= rv * 1.6
        out("PASS" if ok else "FAIL", "1.5.3", f"ratio {r} consistent with the measured {rv:.2f}" if ok else f"prompt_eval_ratio_q8_over_q4 must be above 1.5 and within a factor 1.6 of verify's own measurement (measure prompt processing with a long prompt and cache_prompt=false, not generation)")
    ok = a.get("why_q8_prompt_faster") == "q8_simple_int8_blocks_map_to_dotprod_kernels" and close(a.get("bpw_q4"), t["q4"]["bpw"], 0.01) and close(a.get("bpw_q8"), t["q8"]["bpw"], 0.01)
    out("PASS" if ok else "FAIL", "1.5.4", "enum right and BPW evidence matches the variant files" if ok else "why_q8_prompt_faster is wrong or bpw_q4/bpw_q8 do not match the load logs of your variant's files (the enum only counts together with the evidence)")

if __name__ == "__main__":
    globals()["cmd_" + sys.argv[1]](*sys.argv[2:])
