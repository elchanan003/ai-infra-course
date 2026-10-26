#!/usr/bin/env python3
"""VRAM calculator from the platform team wiki ("works fine, ask Dana").

usage: team_calc.py MODEL.json --gpu 80 --tp 2 --seq 8192 --seqs 16 [--kv-bytes 2] [--util 0.9] [--overhead 2]
MODEL.json: params_b, bytes_per_param, layers, num_attention_heads, num_key_value_heads, head_dim (or hidden_size).
Prints JSON: weights_gib, kv_gib, per_gpu_gib, budget_gib, fits
"""
import argparse, json

p = argparse.ArgumentParser()
p.add_argument("model")
p.add_argument("--gpu", type=float, required=True, help="GPU memory in GiB")
p.add_argument("--tp", type=int, default=1)
p.add_argument("--seq", type=int, required=True)
p.add_argument("--seqs", type=int, required=True)
p.add_argument("--kv-bytes", type=float, default=2)
p.add_argument("--util", type=float, default=0.9)
p.add_argument("--overhead", type=float, default=2.0)
a = p.parse_args()
m = json.load(open(a.model))
head_dim = m.get("head_dim") or m["hidden_size"] // m["num_attention_heads"]

weights = m["params_b"] * 1e9 * m["bytes_per_param"] / 1024 ** 3
kv_per_token = 2 * m["layers"] * m["num_key_value_heads"] * head_dim * a.kv_bytes
kv = kv_per_token * a.seq * a.seqs / 1024 ** 3
per_gpu = (weights + kv) / a.tp + a.overhead
budget = a.gpu * a.util
print(json.dumps({"weights_gib": round(weights, 3), "kv_gib": round(kv, 3), "per_gpu_gib": round(per_gpu, 3),
                  "budget_gib": round(budget, 3), "fits": per_gpu <= budget}))
