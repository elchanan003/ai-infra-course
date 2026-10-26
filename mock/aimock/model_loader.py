"""Model resolution + integrity checks, mimicking vLLM/transformers startup.

--model = local dir OR HF repo id. Repo ids are resolved with the REAL huggingface_hub (snapshot_download), so
HF_HUB_OFFLINE, HF_HOME, HF_HUB_CACHE, HF_ENDPOINT, HF_TOKEN behave genuinely (DNS query to HF_ENDPOINT when online).
"""
import hashlib, json, os, re, struct
from .capacity import StartupError
from .common import log

HF_PATTERNS = ["*.json", "*.txt", "*.model", "*.safetensors", "tokenizer*", "merges.txt", "vocab.*"]
ST_DTYPES = {"F32": ("float32", 4), "F16": ("float16", 2), "BF16": ("bfloat16", 2), "F8_E4M3": ("fp8", 1),
             "I8": ("int8", 1), "U8": ("uint8", 1), "I32": ("int32", 4), "I64": ("int64", 8), "F64": ("float64", 8)}
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def resolve(model, download_dir=None, revision=None):
    if os.path.isdir(model):
        return model, False
    if model.startswith(("/", "./", "../")) or model.count("/") > 1:
        raise StartupError("OSError", f"Incorrect path_or_model_id: '{model}'. Please provide either the path to a local folder or the repo_id of a model on the Hub.")
    try:
        from huggingface_hub import snapshot_download
    except Exception as e:  # pragma: no cover
        raise StartupError("ImportError", str(e))
    ep = os.environ.get("HF_ENDPOINT", "https://huggingface.co")
    offline = os.environ.get("HF_HUB_OFFLINE", "") in ("1", "true", "TRUE", "yes")
    log("INFO", f"Resolving model repo '{model}' via huggingface_hub (endpoint={ep}, offline={offline})", "APIServer pid=1")
    try:
        d = snapshot_download(model, allow_patterns=HF_PATTERNS, cache_dir=download_dir, revision=revision)
        return d, True
    except Exception as e:
        et = type(e).__name__
        name = model
        if offline or "LocalEntryNotFound" in et or "OfflineMode" in et:
            raise StartupError("OSError", f"We couldn't connect to '{ep}' to load the files, and couldn't find them in the cached files.\n"
                                          f"Check your internet connection or see how to run the library in offline mode at "
                                          f"'https://huggingface.co/docs/transformers/installation#offline-mode'.\n"
                                          f"(huggingface_hub {et}: {str(e)[:300]})")
        if "RepositoryNotFound" in et or "RevisionNotFound" in et or "GatedRepo" in et:
            raise StartupError("OSError", f"{name} is not a local folder and is not a valid model identifier listed on '{ep}/models'\n"
                                          f"If this is a private repository, make sure to pass a token having permission to this repo "
                                          f"either by logging in with `hf auth login` or by passing `token=<your_token>`\n({et}: {str(e)[:300]})")
        raise StartupError("OSError", f"We couldn't connect to '{ep}' to load the files, and couldn't find them in the cached files.\n"
                                      f"Check your internet connection or see how to run the library in offline mode at "
                                      f"'https://huggingface.co/docs/transformers/installation#offline-mode'.\n({et}: {str(e)[:300]})")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_st_header(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        raw = f.read(8)
        if len(raw) < 8:
            raise StartupError("safetensors_rust.SafetensorError", f"Error while deserializing header: MetadataIncompleteBuffer ({os.path.basename(path)})")
        n = struct.unpack("<Q", raw)[0]
        if n > 100_000_000 or 8 + n > size:
            raise StartupError("safetensors_rust.SafetensorError", f"Error while deserializing header: HeaderTooLarge or MetadataIncompleteBuffer ({os.path.basename(path)})")
        try:
            hdr = json.loads(f.read(n))
        except Exception:
            raise StartupError("safetensors_rust.SafetensorError", f"Error while deserializing header: InvalidHeaderDeserialization ({os.path.basename(path)})")
    end = max([v["data_offsets"][1] for k, v in hdr.items() if k != "__metadata__"] or [0])
    if 8 + n + end != size:
        raise StartupError("safetensors_rust.SafetensorError", f"Error while deserializing header: MetadataIncompleteBuffer: "
                                                                f"{os.path.basename(path)} is truncated or has trailing bytes (expected {8 + n + end} bytes, found {size})")
    return hdr


def inspect(path, model_arg, from_hub):
    """Checks tokenizer + weights. Returns dict(strict, tensors, params, dtype, shards) or raises StartupError."""
    files = set(os.listdir(path))
    st = sorted(f for f in files if f.endswith(".safetensors"))
    strict_env = os.environ.get("MOCK_STRICT_MODEL")
    strict = bool(st) or any(f.startswith("tokenizer") for f in files) or from_hub
    if strict_env is not None:
        strict = strict_env not in ("0", "false", "")
    info = dict(strict=strict, tensors=0, params=None, dtype=None, shards=[])
    if not strict:
        log("INFO", f"Model dir {path} has only config.json (fixture mode: no tokenizer/weights checked)", "APIServer pid=1")
        return info
    # tokenizer
    miss = [f for f in ("tokenizer_config.json",) if f not in files]
    if "tokenizer.json" not in files and not ({"vocab.json", "merges.txt"} <= files or "tokenizer.model" in files):
        miss.insert(0, "tokenizer.json")
    if miss:
        raise StartupError("OSError", f"Can't load tokenizer for '{model_arg}'. If you were trying to load it from 'https://huggingface.co/models', "
                                      f"make sure you don't have a local directory with the same name. Otherwise, make sure '{model_arg}' is the "
                                      f"correct path to a directory containing all relevant files for a PreTrainedTokenizerFast tokenizer. "
                                      f"(missing file: {miss[0]})")
    if not st:
        raise StartupError("OSError", f"Error no file named model.safetensors, pytorch_model.bin found in directory {path}.")
    idx = None
    if "model.safetensors.index.json" in files:
        idx = json.load(open(os.path.join(path, "model.safetensors.index.json")))
        shards = sorted(set(idx.get("weight_map", {}).values()))
        for s in shards:
            if s not in files:
                raise StartupError("OSError", f"Error no file named {s} found in directory {path}. (shard listed in model.safetensors.index.json is missing)")
    else:
        shards = ["model.safetensors"] if "model.safetensors" in files else st
    sums = {}
    sp = os.path.join(path, "SHA256SUMS")
    if os.path.isfile(sp):
        for line in open(sp):
            p = line.split()
            if len(p) == 2:
                sums[os.path.basename(p[1].lstrip("*"))] = p[0]
    tensors, params, by_dtype, total_bytes = 0, 0, {}, 0
    for s in shards:
        fp = os.path.join(path, s)
        hdr = read_st_header(fp)
        real = os.path.realpath(fp)
        want = os.path.basename(real) if HEX64.match(os.path.basename(real)) else sums.get(s)
        if want:
            got = _sha256(real)
            if got != want:
                raise StartupError("RuntimeError", f"Error loading checkpoint shard '{s}': sha256 mismatch (expected {want}, file content hashes to {got}). "
                                                   f"The file is corrupted or was modified; re-download it.")
        for k, v in hdr.items():
            if k == "__metadata__":
                continue
            n = 1
            for d in v["shape"]:
                n *= d
            dt, nb = ST_DTYPES.get(v["dtype"], (v["dtype"], 2))
            tensors += 1
            params += n
            by_dtype[dt] = by_dtype.get(dt, 0) + n
            total_bytes += n * nb
    if idx and idx.get("metadata", {}).get("total_size") not in (None, total_bytes):
        raise StartupError("RuntimeError", f"Checkpoint shards are inconsistent with model.safetensors.index.json: metadata.total_size="
                                           f"{idx['metadata']['total_size']} but tensors add up to {total_bytes} bytes.")
    dom = max(by_dtype, key=by_dtype.get) if by_dtype else None
    info.update(tensors=tensors, params=params, dtype=dom, shards=shards, total_bytes=total_bytes)
    log("INFO", f"Loaded safetensors headers: {len(shards)} shard(s), {tensors} tensors, {params/1e9:.3f}B params, dtype {dom}", "EngineCore pid=38")
    return info
