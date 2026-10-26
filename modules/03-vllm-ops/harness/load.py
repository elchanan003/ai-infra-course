#!/usr/bin/env python3
"""Deterministic load driver for mock-vllm (module 03). Stdlib only.

  load.py --url http://127.0.0.1:18022 --preset task3|pressure|sweep|snapshot [--params FILE] [--seed N] [--json]
  load.py --url URL --n 8 --prompt-tokens 3000 --max-tokens 1000          (ad-hoc barrier burst)

Presets read their numbers from --params (default: lab/slo/load.json next to lab/). A "burst" releases all
requests at the same instant (barrier) so the mock's admission order is reproducible. A background sampler
polls /metrics every 50 ms and reports peaks. Prompt token counts follow the mock convention
(ceil(bytes/4) + 4 per message + 3 priming): content is sized so usage.prompt_tokens == prompt_tokens.
"""
import argparse, http.client, json, os, random, re, sys, threading, time, urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))


def content_for(tokens, tag):
    nbytes = max(4, 4 * (tokens - 7))
    head = f"req-{tag} "
    body = ("alpha bravo charlie delta echo foxtrot " * (nbytes // 38 + 2))
    return (head + body)[:nbytes]


def post(conn_args, path, body, timeout=600):
    host, port = conn_args
    c = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        c.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
        r = c.getresponse()
        data = r.read()
        return r.status, data
    except Exception as e:  # noqa
        return 0, str(e).encode()
    finally:
        c.close()


def get(conn_args, path, timeout=10):
    host, port = conn_args
    c = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        c.request("GET", path)
        r = c.getresponse()
        return r.status, r.read().decode("utf-8", "replace")
    except Exception as e:  # noqa
        return 0, str(e)
    finally:
        c.close()


def metric(text, name, **labels):
    """Sum of samples of `name` (exact family name) whose labels match."""
    tot, found = 0.0, False
    for line in text.splitlines():
        if not line.startswith(name + "{") and not line.startswith(name + " "):
            continue
        m = re.match(r"^([^{\s]+)(\{[^}]*\})?\s+([^\s]+)", line)
        if not m or m.group(1) != name:
            continue
        lab = dict(re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', m.group(2) or ""))
        if all(lab.get(k) == v for k, v in labels.items()):
            tot += float(m.group(3)); found = True
    return tot if found else None


class Sampler(threading.Thread):
    def __init__(self, conn, period=0.05):
        super().__init__(daemon=True)
        self.conn, self.period, self.stop_ev = conn, period, threading.Event()
        self.peak_running = self.peak_waiting = 0.0
        self.peak_kv = 0.0
        self.samples = 0

    def run(self):
        while not self.stop_ev.is_set():
            st, t = get(self.conn, "/metrics", 5)
            if st == 200:
                self.samples += 1
                self.peak_running = max(self.peak_running, metric(t, "vllm:num_requests_running") or 0)
                self.peak_waiting = max(self.peak_waiting, metric(t, "vllm:num_requests_waiting") or 0)
                self.peak_kv = max(self.peak_kv, metric(t, "vllm:kv_cache_usage_perc") or 0)
            self.stop_ev.wait(self.period)


def model_name(conn):
    st, t = get(conn, "/v1/models")
    return json.loads(t)["data"][0]["id"]


def burst(conn, model, specs, stream=False):
    """specs: list of (prompt_tokens, max_tokens, tag). Barrier-released. Returns list of (status, usage|None)."""
    n = len(specs)
    bar = threading.Barrier(n)
    out = [None] * n

    def one(i):
        pt, mt, tag = specs[i]
        body = {"model": model, "max_tokens": mt, "messages": [{"role": "user", "content": content_for(pt, tag)}]}
        bar.wait()
        st, data = post(conn, "/v1/chat/completions", body)
        u = None
        if st == 200:
            try:
                u = json.loads(data)["usage"]
            except Exception:  # noqa
                pass
        out[i] = (st, u)

    ths = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in ths: t.start()
    for t in ths: t.join()
    return out


def stats(conn):
    st, t = get(conn, "/admin/stats")
    return json.loads(t) if st == 200 else {}


def run_specs(conn, specs, label):
    model = model_name(conn)
    s0 = stats(conn)
    p0 = metric(get(conn, "/metrics")[1], "vllm:num_preemptions_total") or 0
    smp = Sampler(conn); smp.start()
    res = burst(conn, model, specs)
    time.sleep(0.15)
    smp.stop_ev.set(); smp.join(2)
    s1 = stats(conn)
    p1 = metric(get(conn, "/metrics")[1], "vllm:num_preemptions_total") or 0
    codes = {}
    for st, _ in res:
        codes[str(st)] = codes.get(str(st), 0) + 1
    eng = s1.get("engine", {})
    return {
        "preset": label, "requests": len(specs), "status": codes,
        "peak_running": smp.peak_running, "peak_waiting": smp.peak_waiting, "peak_kv_sampled": round(smp.peak_kv, 4),
        "kv_peak_usage": eng.get("kv_peak_usage"), "preemptions": int(p1 - p0),
        "virtual_time_s": round((eng.get("virtual_time_s") or 0) - ((s0.get("engine") or {}).get("virtual_time_s") or 0), 3),
        "completion_tokens": sum((u or {}).get("completion_tokens", 0) for _, u in res),
        "prompt_tokens": sum((u or {}).get("prompt_tokens", 0) for _, u in res),
    }


def specs_for(preset, params, seed):
    p = params[preset]
    rnd = random.Random(f"{preset}-{seed}")
    n = p["n"]
    out = []
    for i in range(n):
        pt = p["prompt_tokens"]; mt = p["max_tokens"]
        j = p.get("jitter", 0)
        if j:
            pt = int(pt * (1 + rnd.uniform(-j, j))); mt = int(mt * (1 + rnd.uniform(-j, j)))
        out.append((max(8, pt), max(1, mt), f"{preset}-{seed}-{i:03d}"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--target", choices=["a", "b", "x"], help="a=:18021 b=:18022 x=:18160 (scratch)")
    ap.add_argument("--preset", choices=["task3", "pressure", "sweep", "snapshot"])
    ap.add_argument("--params")
    ap.add_argument("--seed", default="1")
    ap.add_argument("--n", type=int); ap.add_argument("--prompt-tokens", type=int); ap.add_argument("--max-tokens", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    url = a.url or {"a": "http://127.0.0.1:18021", "b": "http://127.0.0.1:18022", "x": "http://127.0.0.1:18160"}.get(a.target or "")
    if not url:
        ap.error("--url or --target required")
    u = urllib.parse.urlparse(url); conn = (u.hostname, u.port or 80)
    if a.preset == "snapshot":
        model = model_name(conn)
        params = json.load(open(a.params or os.path.join(HERE, "..", "slo", "load.json")))
        sizes = params["snapshot"]["prompt_tokens"]
        for i, pt in enumerate(sizes):  # sequential => deterministic (README 3.10)
            st, _ = post(conn, "/v1/chat/completions", {"model": model, "max_tokens": params["snapshot"]["max_tokens"],
                                                         "messages": [{"role": "user", "content": content_for(pt, f"snap-{a.seed}-{i}")}]})
            if st != 200:
                print(f"request {i} failed: HTTP {st}", file=sys.stderr); sys.exit(1)
        print(f"snapshot scenario done: {len(sizes)} sequential requests")
        return
    if a.preset:
        params = json.load(open(a.params or os.path.join(HERE, "..", "slo", "load.json")))
        specs = specs_for(a.preset, params, a.seed)
        label = a.preset
    else:
        if not (a.n and a.prompt_tokens and a.max_tokens):
            ap.error("give --preset or --n/--prompt-tokens/--max-tokens")
        specs = [(a.prompt_tokens, a.max_tokens, f"adhoc-{i:03d}") for i in range(a.n)]
        label = "adhoc"
    r = run_specs(conn, specs, label)
    if a.json:
        print(json.dumps(r))
    else:
        for k, v in r.items():
            print(f"{k:18} {v}")


main()
