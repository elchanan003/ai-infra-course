#!/usr/bin/env python3
"""Prometheus-text helpers for the mock-vllm /metrics snapshots.
  mq.py sum NAME FILE                 sum of all samples of NAME (labels ignored)
  mq.py delta NAME BEFORE AFTER       sum(AFTER) - sum(BEFORE)  (counter reset => AFTER)
  mq.py p95 NAME BEFORE AFTER         p95 (upper bucket bound, seconds) of the histogram NAME between the snapshots; 999999 if > last finite bucket
  mq.py label NAME LABEL FILE         first value of LABEL on NAME (e.g. cache_config_info)"""
import re, sys

def parse(path):
    out = []
    try:
        for line in open(path):
            if line.startswith("#") or not line.strip(): continue
            m = re.match(r'^([A-Za-z_:][A-Za-z0-9_:]*)(\{[^}]*\})?\s+(\S+)', line)
            if m:
                try: out.append((m.group(1), m.group(2) or "", float(m.group(3))))
                except ValueError: pass
    except OSError:
        pass
    return out

def ssum(rows, name): return sum(v for n, l, v in rows if n == name)

def buckets(rows, name):
    d = {}
    for n, l, v in rows:
        if n == name + "_bucket":
            le = re.search(r'le="([^"]+)"', l)
            if le: d[float("inf") if le.group(1) == "+Inf" else float(le.group(1))] = d.get(float("inf") if le.group(1) == "+Inf" else float(le.group(1)), 0) + v
    return d

cmd = sys.argv[1]
if cmd == "sum": print(ssum(parse(sys.argv[3]), sys.argv[2]))
elif cmd == "delta":
    b, a = ssum(parse(sys.argv[3]), sys.argv[2]), ssum(parse(sys.argv[4]), sys.argv[2])
    print(a - b if a >= b else a)
elif cmd == "p95":
    name = sys.argv[2]; b0, b1 = buckets(parse(sys.argv[3]), name), buckets(parse(sys.argv[4]), name)
    d = {k: b1.get(k, 0) - b0.get(k, 0) for k in b1}
    if any(v < 0 for v in d.values()): d = b1
    ks = sorted(d); tot = d[ks[-1]] if ks else 0
    if tot <= 0: print(0); sys.exit()
    for k in ks:
        if d[k] >= 0.95 * tot:
            print(999999 if k == float("inf") else k); break
elif cmd == "label":
    for n, l, v in parse(sys.argv[4]):
        if n == sys.argv[2]:
            m = re.search(sys.argv[3] + r'="([^"]*)"', l)
            if m: print(m.group(1)); break
