"""Fixture generation for module 02 (harness side): synthetic sharded HF repo in cache layout, inert hostile
pickles (+ benign ones), and the damaged 'incoming' bundle. Stdlib only, deterministic from the variant."""
import hashlib, io, json, os, pickle, random, shutil, struct, sys, types, zipfile

SERVE_PATTERNS = (".json", ".txt", ".safetensors")
KINDS = ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "mlp.up_proj", "mlp.down_proj", "mlp.gate_proj", "input_layernorm", "post_attention_layernorm"]
SHAPES = [(512, 512), (1024, 256), (256, 256), (768, 384)]
DT = {"BF16": 2, "F16": 2, "F32": 4}


def sha256(b): return hashlib.sha256(b).hexdigest()
def git_sha1(b): return hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()


def st_bytes(tensors, rnd):
    """tensors: list of (name, dtype, shape) -> safetensors file bytes (random payload)."""
    hdr = {"__metadata__": {"format": "pt"}}; off = 0; blobs = []
    for name, dt, shape in tensors:
        n = DT[dt]
        for d in shape: n *= d
        hdr[name] = {"dtype": dt, "shape": list(shape), "data_offsets": [off, off + n]}; off += n; blobs.append(rnd.randbytes(n))
    h = json.dumps(hdr, separators=(",", ":")).encode(); h += b" " * (-len(h) % 8)
    return struct.pack("<Q", len(h)) + h + b"".join(blobs)


def build_repo_files(vid, seed, config_src):
    """Returns (files: {relpath: bytes}, meta)."""
    rnd = random.Random(seed)
    nshards = rnd.choice([3, 4, 5]); ntensors = rnd.randint(9, 21)
    dtypes = sorted(rnd.sample(["BF16", "F16", "F32"], rnd.choice([2, 2, 3])))
    tensors = []
    for i in range(ntensors):
        nm = "model.layers.%d.%s.weight" % (i // len(KINDS), KINDS[i % len(KINDS)]); dt = dtypes[i % len(dtypes)]
        tensors.append((nm, dt, rnd.choice(SHAPES)))
    per = [tensors[i::nshards] for i in range(nshards)]
    files = {}; wmap = {}; total = 0
    for k, ts in enumerate(per):
        fn = "model-%05d-of-%05d.safetensors" % (k + 1, nshards)
        files[fn] = st_bytes(ts, rnd)
        for nm, dt, shape in ts:
            wmap[nm] = fn; n = DT[dt]
            for d in shape: n *= d
            total += n
    files["model.safetensors.index.json"] = json.dumps({"metadata": {"total_size": total}, "weight_map": wmap}, indent=1).encode()
    cfg = json.load(open(config_src)); cfg["_name_or_path"] = "aiinfra-lab/tiny-" + vid
    files["config.json"] = json.dumps(cfg, indent=1).encode()
    files["generation_config.json"] = json.dumps({"bos_token_id": 1, "eos_token_id": 2, "do_sample": False}).encode()
    files["tokenizer.json"] = json.dumps({"version": "1.0", "model": {"type": "BPE", "vocab": {"a": 0, "b": 1}, "merges": []}, "pad_token": "<pad>"}).encode()
    files["tokenizer_config.json"] = json.dumps({"tokenizer_class": "PreTrainedTokenizerFast", "model_max_length": 2048}).encode()
    files["special_tokens_map.json"] = json.dumps({"eos_token": "</s>", "pad_token": "<pad>"}).encode()
    # decoys (must NOT be downloaded by a correct --include)
    files["pytorch_model.bin"] = pickle.dumps({"w": rnd.randbytes(200_000)}, protocol=2)
    files["onnx/model.onnx"] = rnd.randbytes(300_000)
    files["README.md"] = ("# tiny-%s\nSynthetic lab model.\n" % vid).encode()
    meta = dict(nshards=nshards, tensors=ntensors, params=sum(_n(s) for _, _, s in tensors), dtypes=dtypes, total_size=total,
                shards=sorted(f for f in files if f.endswith(".safetensors")))
    return files, meta


def _n(shape):
    n = 1
    for d in shape: n *= d
    return n


def write_cache(hub, repo, commit, files):
    d = os.path.join(hub, "models--" + repo.replace("/", "--"))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "blobs")); os.makedirs(os.path.join(d, "refs"))
    snap = os.path.join(d, "snapshots", commit)
    for rel, data in files.items():
        big = rel.endswith((".safetensors", ".bin", ".onnx"))
        blob = sha256(data) if big else git_sha1(data)
        bp = os.path.join(d, "blobs", blob)
        if not os.path.exists(bp): open(bp, "wb").write(data)
        lp = os.path.join(snap, rel); os.makedirs(os.path.dirname(lp), exist_ok=True)
        depth = rel.count("/") + 2
        os.symlink("../" * depth + "blobs/" + blob, lp)
    open(os.path.join(d, "refs", "main"), "w").write(commit)
    os.chmod(d, 0o775)


# ----------------------------------------------------------------------------------- pickles
def _fake_torch():
    torch = types.ModuleType("torch"); utils = types.ModuleType("torch._utils")
    def _rebuild_tensor_v2(*a): pass
    def _rebuild_parameter(*a): pass
    for fn_ in (_rebuild_tensor_v2, _rebuild_parameter): fn_.__module__ = "torch._utils"; fn_.__qualname__ = fn_.__name__
    utils._rebuild_tensor_v2 = _rebuild_tensor_v2; utils._rebuild_parameter = _rebuild_parameter
    class FloatStorage: pass
    class BFloat16Storage: pass
    for c in (FloatStorage, BFloat16Storage): c.__module__ = "torch"; c.__qualname__ = c.__name__; setattr(torch, c.__name__, c)
    torch._utils = utils
    sys.modules["torch"] = torch; sys.modules["torch._utils"] = utils
    return torch, utils


class _T:  # a tensor-like whose pickle form references torch globals, like a real checkpoint
    def __init__(self, fn, storage, rows): self.fn, self.storage, self.rows = fn, storage, rows
    def __reduce__(self): return (self.fn, (self.storage, 0, (self.rows, 4), (4, 1), False))


def make_pickles(outdir, canary, rnd):
    """Writes 5 files; returns {filename: 'dangerous'|'safe'}. Hostile payloads only touch `canary`."""
    from collections import OrderedDict
    torch, utils = _fake_torch()
    class Evil1:
        def __reduce__(self): import os as _os; return (_os.system, ("touch " + canary,))
    class Evil2:
        def __reduce__(self): return (exec, ("import pathlib; pathlib.Path(%r).touch()" % canary,))
    def zipped(obj, proto):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("archive/data.pkl", pickle.dumps(obj, protocol=proto)); z.writestr("archive/version", "3\n"); z.writestr("archive/data/0", rnd.randbytes(2048))
        return buf.getvalue()
    sd1 = OrderedDict((f"layer{i}.weight", _T(utils._rebuild_tensor_v2, torch.FloatStorage, 2 + i)) for i in range(3))
    sd2 = OrderedDict((f"block{i}.bias", _T(utils._rebuild_parameter, torch.BFloat16Storage, 3 + i)) for i in range(2))
    note = {"note": "ran: os.system('echo hi'); posix system; subprocess.Popen; builtins.eval", "lr": 0.001, "steps": [1, 2, 3]}
    items = [
        ("evil-os-system", pickle.dumps({"state": Evil1(), "epoch": 3}, protocol=4), "bin", "dangerous"),                # STACK_GLOBAL, raw
        ("evil-exec-zip", zipped({"state": Evil2(), "epoch": 7}, 2), "pt", "dangerous"),                                  # GLOBAL, inside a zip
        ("ok-torch-state", pickle.dumps(sd1, protocol=2), "bin", "safe"),                                                 # GLOBAL torch._utils..., collections
        ("ok-torch-zip", zipped(sd2, 4), "pt", "safe"),                                                                   # STACK_GLOBAL torch names, zip
        ("ok-strings", pickle.dumps(note, protocol=4), "bin", "safe"),                                                    # dangerous words as data only
    ]
    rnd.shuffle(items); truth = {}
    os.makedirs(outdir, exist_ok=True)
    for i, (_, data, ext, verdict) in enumerate(items):
        fn = "ckpt-%d.%s" % (i + 1, ext); open(os.path.join(outdir, fn), "wb").write(data); truth[fn] = verdict
    return truth


# ----------------------------------------------------------------------------------- incoming bundle
def make_bundle(outdir, files, rnd):
    serving = {k: v for k, v in files.items() if k.endswith(SERVE_PATTERNS) and "/" not in k}
    shutil.rmtree(outdir, ignore_errors=True); os.makedirs(outdir)
    for k, v in serving.items(): open(os.path.join(outdir, k), "wb").write(v)
    sums = "".join("%s  %s\n" % (sha256(v), k) for k, v in sorted(serving.items()))
    open(os.path.join(outdir, "SHA256SUMS"), "w").write(sums)
    missing = rnd.choice(["tokenizer.json", "tokenizer_config.json"])
    os.remove(os.path.join(outdir, missing))
    shard = rnd.choice(sorted(k for k in serving if k.endswith(".safetensors")))
    data = bytearray(serving[shard]); pos = len(data) - 1 - rnd.randrange(1000); data[pos] ^= 0x01
    open(os.path.join(outdir, shard), "wb").write(bytes(data))
    return dict(missing=[missing], corrupt=[dict(file=shard, expected_sha256=sha256(serving[shard]), actual_sha256=sha256(bytes(data)))],
                good=sorted(k for k in serving if k not in (missing, shard)))
