#!/usr/bin/env python3
"""Verify helper: judge proxy logs. Prints OK or a cause message; exit 0 iff OK."""
import json, sys


def load(p):
    try:
        return [json.loads(x) for x in open(p) if x.strip()]
    except OSError:
        return []


def done(ok, msg):
    print("OK" if ok else msg)
    sys.exit(0 if ok else 1)


def chat(log):
    return [e for e in load(log) if e["path"].endswith("/chat/completions")]


def linkage(log, expect):
    ents = chat(log)
    if len(ents) < 2:
        done(False, f"gateway saw {len(ents)} chat request(s); a tool-calling run needs a second request carrying the tool result")
    e0, e1 = ents[0], ents[1]
    if not e0["n_tools"]:
        done(False, "first request advertised no `tools`: the model cannot call what it is not told about")
    calls = e0["resp_calls"]
    if len(calls) != len(expect):
        done(False, f"expected {len(expect)} tool call(s) from the model, got {len(calls)}")
    ids = [c["id"] for c in calls]
    k = len(ids)
    if e1["roles"][-(k + 1):] != ["assistant"] + ["tool"] * k:
        done(False, f"second request must end with the assistant message holding tool_calls followed by {k} tool message(s); roles were {e1['roles']}")
    if sorted(e1["asst_call_ids"]) != sorted(ids):
        done(False, "the assistant message in history lost or changed its tool_calls (ids differ from what the model returned)")
    got = {t["id"]: t["content"] for t in e1["tool_msgs"]}
    if sorted(got) != sorted(ids):
        done(False, f"tool messages must answer each tool_call_id exactly once; answered {sorted(got)} for calls {sorted(ids)}")
    for c in calls:
        tid = json.loads(c["args"]).get("ticket_id")
        if expect.get(tid) not in got[c["id"]]:
            done(False, f"the tool message for call {c['id']} does not hold the result for {tid}: results were attached to the wrong call or not executed")
    done(True, "")


def steps(log, n):
    c = len(chat(log))
    done(c == n, f"gateway saw {c} chat request(s) for --max-steps {n}; the loop must stop after exactly that many model calls")


def embed(log, n):
    ents = [e for e in load(log) if e["path"].endswith("/embeddings")]
    req, tot = len(ents), sum(e["n_inputs"] for e in ents)
    if tot < n:
        done(False, f"only {tot} text(s) were embedded for {n} chunks")
    done(req <= n // 2, f"{req} embedding requests for {n} chunks: send many chunks per request (theory 5.1)")


def mounts(path, jobname):
    try:
        d = json.load(open(path))
    except Exception:
        done(False, "the probe produced no result: the runner no longer runs the job")
    bad = []
    if d.get("sockets"):
        bad.append("socket file(s) " + ",".join(d["sockets"]))
    for m in d.get("mounts", []):
        mp, root, fs = m["mountpoint"], m["root"], m["fstype"]
        if mp == "/" or fs == "tmpfs" or any(mp == p or mp.startswith(p + "/") for p in ("/proc", "/sys", "/dev")):
            continue
        if mp in ("/etc/hosts", "/etc/hostname", "/etc/resolv.conf"):
            continue
        if root.rstrip("/").endswith(jobname) or root.rstrip("/").endswith(jobname + "/probe.py"):
            continue
        bad.append(f"{mp} (host path ...{root[-40:]})")
    done(not bad, "the job sees host resources it was never given: " + "; ".join(bad))


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "linkage":
        linkage(sys.argv[2], json.loads(sys.argv[3]))
    elif c == "steps":
        steps(sys.argv[2], int(sys.argv[3]))
    elif c == "embed":
        embed(sys.argv[2], int(sys.argv[3]))
    elif c == "mounts":
        mounts(sys.argv[2], sys.argv[3])
