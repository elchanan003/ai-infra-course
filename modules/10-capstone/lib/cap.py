#!/usr/bin/env python3
"""Capacity numbers with the mock's own formulas (mock/aimock/capacity.py).
usage: cap.py ARGS_FILE GPU_YAML MODEL_DIR  -> JSON {usable_blocks, kv_tokens, max_util, error}"""
import json, os, sys
root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "mock"))
sys.path.insert(0, root)
from aimock import capacity as c
args_file, gpu_yaml, model_dir = sys.argv[1:4]
try:
    a = c.parse_args(open(args_file).read()); m = c.load_model(model_dir); g = c.load_gpu(gpu_yaml)
    r = c.compute(a, m, g)
    print(json.dumps({"usable_blocks": r["usable_blocks"], "kv_tokens": r["usable_blocks"] * a["block-size"], "max_util": round((g["memory_gib"] - g["other_process_gib"]) / g["memory_gib"], 4)}))
except c.StartupError as e:
    print(json.dumps({"error": str(e)[:200]}))
