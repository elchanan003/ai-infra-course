#!/usr/bin/env python3
"""Verify helper: write a deterministic-per-seed corpus into DIR; print the expectations as JSON."""
import json, os, random, re, sys

d, seed = sys.argv[1], sys.argv[2]
r = random.Random(seed)
os.makedirs(d, exist_ok=True)
adj = ["amber", "velvet", "copper", "silent", "crimson", "granite", "lunar", "wicker", "marble", "saffron", "cobalt", "ivory"]
noun = ["heron", "falcon", "otter", "badger", "lantern", "anchor", "compass", "thistle", "harbor", "quarry", "meadow", "kestrel"]
r.shuffle(adj); r.shuffle(noun)
f1 = (adj[0], noun[0]); f2 = (adj[1], noun[1])
t1 = f"{r.randint(1,5):02d}:{r.choice(['07','15','40','52'])}"
code2 = f"{r.choice('KMQXZ')}{r.randint(100,999)}"
topics = [
    "Backups of the {x} database run nightly and are copied to the cold store after {n} minutes.",
    "The {x} dashboard refreshes every {n} seconds and keeps {n} days of history.",
    "Certificates for the {x} service are rotated {n} days before they expire.",
    "Disk alerts for the {x} cluster fire at {n} percent usage and page the storage team.",
    "The {x} queue drops messages older than {n} hours and counts them in a metric.",
    "Every deployment of {x} needs {n} approvals recorded in the change ticket.",
    "Logs from {x} are shipped in batches of {n} megabytes to the central index.",
    "The {x} scheduler retries failed jobs {n} times with exponential backoff.",
]
xs = ["billing", "reporting", "audit", "inventory", "payroll", "search", "mailer", "archive", "metrics", "identity", "catalog", "ledger"]
def para(): return r.choice(topics).format(x=r.choice(xs), n=r.randint(3, 90))
fact1 = f"The {f1[0]} {f1[1]} gateway is restarted by the maintenance runbook at {t1} UTC every Sunday."
fact2 = f"The emergency override for the {f2[0]} {f2[1]} cluster is the code {code2} and only the duty engineer may use it."
files = {
    "operations.md": ["# Operations notes", para(), para(), "Line one of a two-line paragraph about shifts.\nLine two continues the same paragraph.", fact1, para()],
    "network.txt": [para(), para(), fact2, para(), para(), para()],
    "faq.md": ["# FAQ", para(), para(), para(), para(), para(), para()],
}
paras = []
for name, ps in files.items():
    sep = "\n\n"
    body = sep.join(ps)
    if name == "faq.md":
        body = body.replace(ps[2] + sep, ps[2] + "\n   \n", 1)   # a whitespace-only line is a blank line
    open(os.path.join(d, name), "w").write(body + "\n")
    for p in re.split(r"\n\s*\n", body):
        p = p.strip()
        if p: paras.append({"source": name, "chunk_index": len([x for x in paras if x["source"] == name]), "text": p})
open(os.path.join(d, "ignore.json"), "w").write(json.dumps({"note": "not a document"}))
facts = [
    {"question": f"At what time is the {f1[0]} {f1[1]} gateway restarted?", "source": "operations.md", "text": fact1},
    {"question": f"What is the emergency override code for the {f2[0]} {f2[1]} cluster?", "source": "network.txt", "text": fact2},
]
for f in facts:
    m = [p for p in paras if p["text"] == f["text"]][0]
    f["chunk_index"] = m["chunk_index"]
print(json.dumps({"chunks": len(paras), "paragraphs": paras, "facts": facts}))
