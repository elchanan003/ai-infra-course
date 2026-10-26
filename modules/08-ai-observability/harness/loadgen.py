#!/usr/bin/env python3
"""Closed-loop load generator (stdlib). loadgen.py --url URL --model M --concurrency N --duration S [--prompt-tokens P] [--max-tokens T] [--key K] [--n TOTAL]
Runs N client loops until DURATION seconds pass (or TOTAL requests are done); prints a JSON summary {status: {code: n}, prompt_tokens, completion_tokens}."""
import argparse, http.client, json, threading, time, urllib.parse

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True); ap.add_argument("--model", default="chat")
ap.add_argument("--concurrency", type=int, default=4); ap.add_argument("--duration", type=float, default=10)
ap.add_argument("--prompt-tokens", type=int, default=200); ap.add_argument("--max-tokens", type=int, default=64)
ap.add_argument("--key", default=""); ap.add_argument("--n", type=int, default=0); ap.add_argument("--tag", default="lg")
ap.add_argument("--path", default="/v1/chat/completions")
a = ap.parse_args()
u = urllib.parse.urlparse(a.url)
lock = threading.Lock(); st = {}; pt = ct = 0; sent = 0; end = time.time() + a.duration


def content(i):
    nbytes = max(4, 4 * (a.prompt_tokens - 7))
    return (f"req-{a.tag}-{i} " + "alpha bravo charlie delta echo foxtrot " * (nbytes // 38 + 2))[:nbytes]


def loop(w):
    global pt, ct, sent
    while time.time() < end:
        with lock:
            if a.n and sent >= a.n:
                return
            sent += 1; i = sent
        body = {"model": a.model, "max_tokens": a.max_tokens, "messages": [{"role": "user", "content": content(i)}]}
        h = {"Content-Type": "application/json"}
        if a.key: h["Authorization"] = "Bearer " + a.key
        try:
            c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=300)
            c.request("POST", a.path, json.dumps(body), h)
            r = c.getresponse(); d = r.read(); code = r.status; c.close()
            us = json.loads(d).get("usage", {}) if code == 200 else {}
        except Exception:
            code, us = 0, {}
        with lock:
            st[str(code)] = st.get(str(code), 0) + 1
            pt += us.get("prompt_tokens", 0); ct += us.get("completion_tokens", 0)


ths = [threading.Thread(target=loop, args=(w,)) for w in range(a.concurrency)]
for t in ths: t.start()
for t in ths: t.join()
print(json.dumps({"status": st, "prompt_tokens": pt, "completion_tokens": ct, "requests": sent}))
