"""vLLM-style capacity model: weights, KV bytes/token, KV blocks, startup refusal."""
import json, math, os, shlex
from .common import load_yaml

GiB = 1024 ** 3

DTYPE_BYTES = {"float32": 4, "float": 4, "float16": 2, "half": 2, "bfloat16": 2, "bf16": 2, "fp16": 2}
QUANT_BPP = {  # bytes per parameter
    "awq": 0.5625, "gptq": 0.5625, "gptq_marlin": 0.5625, "awq_marlin": 0.5625, "bitsandbytes": 0.5625,
    "int4": 0.5625, "fp8": 1.0, "int8": 1.0, "compressed-tensors": 1.0, "experts_int8": 1.0,
}
KV_DTYPE_BYTES = {"fp8": 1, "fp8_e4m3": 1, "fp8_e5m2": 1}
GPU_PRESETS = {  # name -> (memory_gib, mem_bandwidth_GBs, dense fp16 TFLOPs)
    "A100-80GB": (80, 2039, 312), "A100-40GB": (40, 1555, 312), "H100-80GB": (80, 3350, 990),
    "L4": (24, 300, 121), "L40S": (48, 864, 362), "A10G": (24, 600, 125), "T4": (16, 320, 65),
}


class StartupError(Exception):
    """Raised for conditions where real vLLM refuses to start. str() is the real error text."""
    def __init__(self, etype, msg):
        super().__init__(f"{etype}: {msg}")
        self.etype, self.msg = etype, msg


def gib(x):
    return round(x / GiB, 2)


# ---------------------------------------------------------------- args
BOOL_FLAGS = {"enable-prefix-caching": True, "enforce-eager": True, "trust-remote-code": True,
              "enable-chunked-prefill": True, "disable-log-requests": True, "disable-log-stats": True,
              "enable-auto-tool-choice": True}
DEFAULTS = {
    "served-model-name": None, "max-model-len": None, "gpu-memory-utilization": 0.92, "max-num-seqs": 256,
    "max-num-batched-tokens": 8192, "tensor-parallel-size": 1, "kv-cache-dtype": "auto",
    "enable-prefix-caching": True, "quantization": None, "dtype": "auto", "block-size": 16, "seed": 0,
    "api-key": None, "port": 8000, "host": "0.0.0.0",
}
INT_KEYS = {"max-model-len", "max-num-seqs", "max-num-batched-tokens", "tensor-parallel-size", "block-size", "seed", "port"}


def parse_args(text):
    toks = shlex.split(text, comments=True)
    a = dict(DEFAULTS)
    a["_unknown"] = []
    i = 0
    if toks and toks[0] == "serve":
        toks = toks[1:]
    while i < len(toks):
        t = toks[i]
        if not t.startswith("--"):
            a["model"] = t  # positional model (vllm serve <model>)
            i += 1
            continue
        k = t[2:]
        v = None
        if "=" in k:
            k, v = k.split("=", 1)
        k = k.replace("_", "-")
        if k.startswith("no-") and k[3:] in BOOL_FLAGS:
            a[k[3:]] = False
            i += 1
            continue
        if k in BOOL_FLAGS and v is None:
            a[k] = True
            i += 1
            continue
        if v is None:
            if i + 1 < len(toks) and not toks[i + 1].startswith("--"):
                v = toks[i + 1]
                i += 1
            else:
                v = True
        if k == "served-model-name" and isinstance(v, str):
            while i + 1 < len(toks) and not toks[i + 1].startswith("--"):
                v += " " + toks[i + 1]
                i += 1
        a[k] = v
        if k not in DEFAULTS and k not in ("model", "max-model-len") and k not in BOOL_FLAGS and not k.startswith("mock-"):
            a["_unknown"].append(k)
        i += 1
    for k in INT_KEYS:
        if isinstance(a.get(k), str):
            try:
                a[k] = int(a[k])
            except ValueError:
                raise StartupError("ValueError", f"invalid value for --{k}: {a[k]!r}")
    if isinstance(a.get("gpu-memory-utilization"), str):
        a["gpu-memory-utilization"] = float(a["gpu-memory-utilization"])
    return a


# ---------------------------------------------------------------- model geometry
def load_model(path):
    cfgp = os.path.join(path, "config.json")
    if not os.path.isfile(cfgp):
        raise StartupError("OSError", f"{path} does not appear to have a file named config.json. "
                                      f"Checkout the model repo or pass a local path containing config.json.")
    c = json.load(open(cfgp))
    h = c["hidden_size"]
    heads = c["num_attention_heads"]
    kv = c.get("num_key_value_heads", heads)
    hd = c.get("head_dim") or h // heads
    L = c["num_hidden_layers"]
    inter = c["intermediate_size"]
    vocab = c["vocab_size"]
    tie = bool(c.get("tie_word_embeddings", False))
    attn = h * heads * hd + 2 * h * kv * hd + heads * hd * h
    params = vocab * h * (1 if tie else 2) + L * (attn + 3 * h * inter + 2 * h) + h
    params = int(c.get("mock_num_parameters", params))
    return dict(path=path, hidden=h, heads=heads, kv_heads=kv, head_dim=hd, layers=L, inter=inter, vocab=vocab,
                params=params, max_pos=int(c.get("max_position_embeddings", 4096)),
                torch_dtype=str(c.get("torch_dtype", "bfloat16")), name=c.get("_name_or_path") or os.path.basename(path.rstrip("/")))


def load_gpu(path):
    g = load_yaml(path, {})
    name = g.get("name", "A100-80GB")
    pre = None
    for k, v in GPU_PRESETS.items():
        if k.lower() in str(name).lower().replace(" ", "-").replace("nvidia-", "") or k.lower() == str(name).lower():
            pre = v
    pre = pre or GPU_PRESETS["A100-80GB"]
    return dict(name=name, memory_gib=float(g.get("memory_gib", pre[0])), count=int(g.get("count", 1)),
                other_process_gib=float(g.get("other_process_gib", 0)),
                mem_bandwidth_gbs=float(g.get("mem_bandwidth_gbs", pre[1])), tflops=float(g.get("tflops", pre[2])))


# ---------------------------------------------------------------- the model
def compute(args, m, gpu, other_extra_gib=0.0, allow_long=False):
    """Return the capacity dict or raise StartupError with the real vLLM error text."""
    tp = args["tensor-parallel-size"]
    if m["heads"] % tp:
        raise StartupError("ValueError", f"Total number of attention heads ({m['heads']}) must be divisible by tensor parallel size ({tp}).")
    if tp > gpu["count"]:
        raise StartupError("ValueError", f"World size ({tp}) is larger than the number of available GPUs ({gpu['count']}) in this node. "
                                         f"If this is intentional and you are using:\n"
                                         f"- ray, set '--distributed-executor-backend ray'.\n"
                                         f"- multiprocessing, set '--distributed-executor-backend mp'.")
    derived = m["max_pos"]
    mml = args["max-model-len"] or derived
    if mml > derived and not allow_long:
        raise StartupError("ValueError", f"User-specified max_model_len ({mml}) is greater than the derived max_model_len "
                                         f"(max_position_embeddings={float(derived)} or model_max_length=None in model's config.json). "
                                         f"To allow overriding this maximum, set the env var VLLM_ALLOW_LONG_MAX_MODEL_LEN=1. "
                                         f"VLLM_ALLOW_LONG_MAX_MODEL_LEN must be used with extreme caution. If the model uses relative position "
                                         f"encoding (RoPE), positions exceeding derived_max_model_len lead to nan. If the model uses absolute "
                                         f"position encoding, positions exceeding derived_max_model_len will cause a CUDA array out-of-bounds error.")
    dt = args["dtype"]
    if dt == "auto":
        dt = "bfloat16" if "bfloat16" in m["torch_dtype"] else "float16" if m["torch_dtype"] in ("float16", "float32") else m["torch_dtype"]
    dbytes = DTYPE_BYTES.get(dt)
    if dbytes is None:
        raise StartupError("ValueError", f"Unknown dtype {dt!r}")
    q = args["quantization"]
    bpp = QUANT_BPP.get(q, dbytes) if q else dbytes
    if q and q not in QUANT_BPP:
        raise StartupError("ValueError", f"Unknown quantization method: {q}. Must be one of {sorted(QUANT_BPP)}.")
    kvd = args["kv-cache-dtype"]
    kv_bytes = KV_DTYPE_BYTES.get(kvd, dbytes) if kvd != "auto" else dbytes
    total = gpu["memory_gib"] * GiB
    other = (gpu["other_process_gib"] + other_extra_gib) * GiB
    util = args["gpu-memory-utilization"]
    requested = util * total
    weights = m["params"] * bpp / tp
    mnbt = args["max-num-batched-tokens"]
    mns = args["max-num-seqs"]
    activation = mnbt * (m["hidden"] + 2 * m["inter"] / tp) * dbytes * 2 + mns * m["vocab"] * 4
    nontorch = (0.6 + (0.5 if tp > 1 else 0)) * GiB
    free = total - other
    if free < requested:
        raise StartupError("ValueError", f"Free memory on device cuda:0 ({gib(free)}/{gib(total)} GiB) on startup is less than desired GPU "
                                         f"memory utilization ({util}, {gib(requested)} GiB). Decrease GPU memory utilization or reduce GPU "
                                         f"memory used by other processes.")
    if weights > free:
        left = 0.31 * GiB
        raise StartupError("torch.OutOfMemoryError", f"CUDA out of memory. Tried to allocate 448.00 MiB. GPU 0 has a total capacity of "
                                                      f"{gib(total)} GiB of which {gib(left)} GiB is free. Including non-PyTorch memory, this "
                                                      f"process has {gib(free - left)} GiB memory in use. (model weights need {gib(weights)} GiB "
                                                      f"per GPU at tensor_parallel_size={tp}, but only {gib(free)} GiB are available)")
    kv_mem = requested - weights - activation - nontorch
    kv_heads_pg = max(1, math.ceil(m["kv_heads"] / tp))
    kv_tok_total = 2 * m["layers"] * m["kv_heads"] * m["head_dim"] * kv_bytes          # whole model, all GPUs
    kv_tok_pg = 2 * m["layers"] * kv_heads_pg * m["head_dim"] * kv_bytes               # per GPU
    if kv_mem <= 0:
        raise StartupError("ValueError", "No available memory for the cache blocks. Try increasing `gpu_memory_utilization` when "
                                         f"initializing the engine. (weights {gib(weights)} GiB + activations {gib(activation)} GiB + "
                                         f"non-torch {gib(nontorch)} GiB exceed the {gib(requested)} GiB budget)")
    bs = args["block-size"]
    block_bytes = kv_tok_pg * bs
    num_blocks = int(kv_mem // block_bytes)                                            # includes the reserved null block
    cap_tokens = num_blocks * bs
    max_tokens_avail = (num_blocks - 1) * bs                                           # null block is not allocatable
    needed = kv_tok_pg * math.ceil(mml / bs) * bs
    if needed > max_tokens_avail * kv_tok_pg or max_tokens_avail < mml:
        raise StartupError("ValueError",
                           f"To serve at least one request with the model's max seq len ({mml}), ({gib(needed)} GiB KV cache is needed, "
                           f"which is larger than the available KV cache memory ({gib(kv_mem)} GiB). Based on the available memory, the "
                           f"estimated maximum model length is {max_tokens_avail}. Try increasing `gpu_memory_utilization` or decreasing "
                           f"`max_model_len` when initializing the engine. See https://docs.vllm.ai/en/latest/configuration/conserving_memory/ "
                           f"for more details.")
    return dict(
        model=m["name"], params=m["params"], dtype=dt, dtype_bytes=dbytes, quantization=q, bytes_per_param=bpp, tp=tp,
        weights_bytes_per_gpu=int(weights), activation_bytes=int(activation), nontorch_bytes=int(nontorch),
        gpu_total_bytes=int(total), requested_bytes=int(requested), kv_cache_memory_bytes=int(kv_mem),
        kv_dtype_bytes=kv_bytes, kv_bytes_per_token=kv_tok_total, kv_bytes_per_token_per_gpu=kv_tok_pg,
        block_size=bs, block_bytes_per_gpu=block_bytes, num_gpu_blocks=num_blocks, usable_blocks=num_blocks - 1,
        kv_cache_size_tokens=cap_tokens, max_model_len=mml, derived_max_model_len=derived,
        max_concurrency=round(cap_tokens / mml, 4), max_num_seqs=mns, max_num_batched_tokens=mnbt,
        prefix_caching=bool(args["enable-prefix-caching"]), gpu_memory_utilization=util,
        mem_bandwidth_gbs=gpu["mem_bandwidth_gbs"], tflops=gpu["tflops"],
        gpu_free_bytes_at_start=int(free), other_process_bytes=int(other),
    )
