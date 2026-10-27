#!/usr/bin/env python3
"""Tiny OpenAI-compatible load generator (stdlib only). Prints one JSON summary line.
usage: loadgen.py --urls U1[,U2..] --key K --model M [--workers 1] (--count N | --duration S)
                  [--prompt-chars 200] [--prefix-chars 0] [--max-tokens 16] [--think-ms 0] [--timeout 60]
                  [--tag nonce] [--log FILE]
Requests round-robin over --urls (base URLs ending in /v1 or the server root). Prompt = shared prefix (--prefix-chars)
+ a unique tail, so prefix caching has something to reuse. Summary: codes{status: n}, lat_max, lat_p95 (seconds)."""
import argparse, itertools, json, sys, threading, time, urllib.request, urllib.error

p = argparse.ArgumentParser()
p.add_argument("--urls", required=True); p.add_argument("--key", default="none"); p.add_argument("--model", required=True)
p.add_argument("--workers", type=int, default=1); p.add_argument("--count", type=int, default=0); p.add_argument("--duration", type=float, default=0)
p.add_argument("--prompt-chars", type=int, default=200); p.add_argument("--prefix-chars", type=int, default=0)
p.add_argument("--max-tokens", type=int, default=16); p.add_argument("--think-ms", type=int, default=0)
p.add_argument("--timeout", type=float, default=60); p.add_argument("--tag", default="lg"); p.add_argument("--log", default="")
a = p.parse_args()
urls = [u.rstrip("/") for u in a.urls.split(",") if u]
ctr = itertools.count(); lock = threading.Lock()
codes, lats, events = {}, [], []
t_end = time.time() + a.duration if a.duration else None
WORDS = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango".split()

def filler(n, seed):
    out, i = [], seed
    while sum(len(w) + 1 for w in out) < n:
        out.append(WORDS[i % len(WORDS)]); i += 7
    return (" ".join(out))[:n]

PREFIX = ("You are the assistant of the platform team. " + filler(max(0, a.prefix_chars), 3))[:a.prefix_chars] if a.prefix_chars else ""

def one(i):
    base = urls[i % len(urls)]
    ep = base + ("/chat/completions" if base.endswith("/v1") else "/v1/chat/completions")
    tail = f" Question {a.tag}-{i}: " + filler(max(10, a.prompt_chars - len(PREFIX)), i)
    body = json.dumps({"model": a.model, "messages": [{"role": "user", "content": PREFIX + tail}], "max_tokens": a.max_tokens}).encode()
    req = urllib.request.Request(ep, data=body, headers={"Authorization": "Bearer " + a.key, "Content-Type": "application/json"})
    t0 = time.time(); code = "ERR"
    try:
        with urllib.request.urlopen(req, timeout=a.timeout) as r:
            r.read(); code = str(r.status)
    except urllib.error.HTTPError as e:
        code = str(e.code)
        try: e.read()
        except Exception: pass
    except Exception:
        code = "ERR"
    dt = time.time() - t0
    with lock:
        codes[code] = codes.get(code, 0) + 1; lats.append(dt); events.append((round(t0, 3), i, base, code, round(dt, 3)))

def worker():
    while True:
        i = next(ctr)
        if a.count and i >= a.count: return
        if t_end and time.time() >= t_end: return
        one(i)
        if a.think_ms: time.sleep(a.think_ms / 1000)

ts = [threading.Thread(target=worker) for _ in range(max(1, a.workers))]
[t.start() for t in ts]; [t.join() for t in ts]
lats.sort()
p95 = lats[min(len(lats) - 1, int(0.95 * len(lats)))] if lats else 0
if a.log:
    with open(a.log, "w") as f:
        for e in sorted(events): f.write(json.dumps(e) + "\n")
print(json.dumps({"n": len(lats), "codes": codes, "lat_max": round(max(lats), 3) if lats else 0, "lat_p95": round(p95, 3)}))
