#!/usr/bin/env python3
"""Aggregate generation throughput of a llama-server (task 1.3).

usage: bench.py --url http://127.0.0.1:18120 --concurrency 4 --max-tokens 48
Prints one JSON object: {"tokens_per_s": ..., "tokens": ..., "wall_s": ...}

tokens_per_s = (increase of the llamacpp:tokens_predicted_total counter on /metrics) / wall time.
Do not estimate tokens yourself: the counter is the truth.
"""
import argparse, json, threading, time, urllib.request

PROMPTS = ["Write a long story about a lighthouse keeper.", "Explain how a bicycle works in detail.",
           "List many facts about the planet Mars.", "Describe a day in the life of a baker.",
           "Explain what a database index is, with examples.", "Write about the history of tea.",
           "Describe how a river forms.", "Tell a long story about a robot learning to paint."]


def counter(url, name):
    """Return the current value (float) of the Prometheus counter `name` served at URL/metrics."""
    with urllib.request.urlopen(url + "/metrics", timeout=10) as r:
        for line in r.read().decode().splitlines():
            if line.startswith(name + " "):
                return float(line.split()[1])
    raise RuntimeError("metric %s not found (is --metrics on?)" % name)


def one_request(url, i, max_tokens):
    body = json.dumps({"messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
                       "max_tokens": max_tokens, "temperature": 0.7, "cache_prompt": False}).encode()
    req = urllib.request.Request(url + "/v1/chat/completions", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--max-tokens", type=int, default=48)
    a = ap.parse_args()
    before = counter(a.url, "llamacpp:tokens_predicted_total")
    t0 = time.time()
    th = [threading.Thread(target=one_request, args=(a.url, i, a.max_tokens)) for i in range(a.concurrency)]
    [t.start() for t in th]
    [t.join() for t in th]
    wall = time.time() - t0
    after = counter(a.url, "llamacpp:tokens_predicted_total")
    tokens = after - before
    tps = round(tokens / wall, 2)
    print(json.dumps({"tokens_per_s": tps, "tokens": tokens, "wall_s": round(wall, 3)}))


if __name__ == "__main__":
    main()
