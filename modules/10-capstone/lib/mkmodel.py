#!/usr/bin/env python3
"""Build the small synthetic model of incident 4 in HF-cache layout (stdlib only; SIMULATED weights: random bytes).
usage: mkmodel.py CACHE_DIR REPO_DIRNAME REV SEED CONFIG_JSON
Creates CACHE_DIR/REPO_DIRNAME/{refs/main, snapshots/REV/<files>}.
Files: config.json, generation_config.json, tokenizer.json, tokenizer_config.json, model.safetensors.index.json,
model-00001-of-00002.safetensors, model-00002-of-00002.safetensors.  Real safetensors layout (8-byte header length + JSON header + data)."""
import hashlib, json, os, random, shutil, struct, sys
cache, repo, rev, seed, cfg = sys.argv[1:6]
rnd = random.Random(seed)
snap = os.path.join(cache, repo, "snapshots", rev)
os.makedirs(snap, exist_ok=True); os.makedirs(os.path.join(cache, repo, "refs"), exist_ok=True)
open(os.path.join(cache, repo, "refs", "main"), "w").write(rev)
shutil.copy(cfg, os.path.join(snap, "config.json"))
json.dump({"bos_token_id": 151643, "eos_token_id": 151645, "max_new_tokens": 2048}, open(os.path.join(snap, "generation_config.json"), "w"))
json.dump({"tokenizer_class": "Qwen2Tokenizer", "model_max_length": 32768}, open(os.path.join(snap, "tokenizer_config.json"), "w"))
vocab = {f"tok{i}": i for i in range(64)}
json.dump({"version": "1.0", "model": {"type": "BPE", "vocab": vocab, "merges": []}, "added_tokens": []}, open(os.path.join(snap, "tokenizer.json"), "w"))

def shard(path, names):
    hdr, off, blobs = {}, 0, []
    for n in names:
        data = bytes(rnd.getrandbits(8) for _ in range(512 * 512 * 2))        # 512x512 BF16 = 524288 bytes
        hdr[n] = {"dtype": "BF16", "shape": [512, 512], "data_offsets": [off, off + len(data)]}
        off += len(data); blobs.append(data)
    hdr["__metadata__"] = {"format": "pt"}
    h = json.dumps(hdr, separators=(",", ":")).encode()
    h += b" " * ((8 - len(h) % 8) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(h))); f.write(h)
        for b in blobs: f.write(b)
    return off

wm, total = {}, 0
for i, names in enumerate([["model.embed_tokens.weight", "model.layers.0.mlp.up_proj.weight"], ["model.layers.1.mlp.up_proj.weight", "lm_head.weight"]], 1):
    fn = f"model-0000{i}-of-00002.safetensors"
    total += shard(os.path.join(snap, fn), names)
    for n in names: wm[n] = fn
json.dump({"metadata": {"total_size": total}, "weight_map": wm}, open(os.path.join(snap, "model.safetensors.index.json"), "w"), indent=1)
