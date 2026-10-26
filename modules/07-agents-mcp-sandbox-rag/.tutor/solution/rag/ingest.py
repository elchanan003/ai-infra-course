#!/usr/bin/env python3
"""Reference solution 7.5 (ingest)."""
import argparse
import glob
import os
import re
import uuid

import requests

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:18040")
LAB_KEY = os.environ.get("LAB_KEY", "")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "embed")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:18033")
NS = uuid.UUID("6f1c0a5e-7a55-4b1e-9a57-0c3c5a0b7e07")
BATCH = 16


def chunks(docs):
    out = []
    for path in sorted(glob.glob(os.path.join(docs, "*"))):
        if not path.endswith((".md", ".txt")):
            continue
        text = open(path, encoding="utf-8").read()
        paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
        for i, p in enumerate(paras):
            out.append((os.path.basename(path), i, p))
    return out


def embed(texts):
    r = requests.post(f"{GATEWAY}/v1/embeddings", timeout=120, headers={"Authorization": f"Bearer {LAB_KEY}"},
                      json={"model": EMBED_MODEL, "input": texts})
    r.raise_for_status()
    return [d["embedding"] for d in sorted(r.json()["data"], key=lambda d: d["index"])]


def ensure_collection(name, dim):
    r = requests.get(f"{QDRANT_URL}/collections/{name}", timeout=30)
    if r.status_code == 200:
        have = r.json()["result"]["config"]["params"]["vectors"]["size"]
        if have != dim:
            raise SystemExit(f"collection {name} has vector size {have}, the embedding model returns {dim}")
        return
    requests.put(f"{QDRANT_URL}/collections/{name}", timeout=30,
                 json={"vectors": {"size": dim, "distance": "Cosine"}}).raise_for_status()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", required=True)
    ap.add_argument("--collection", required=True)
    args = ap.parse_args()
    items = chunks(args.docs)
    created = False
    for i in range(0, len(items), BATCH):
        batch = items[i:i + BATCH]
        vecs = embed([t for _, _, t in batch])
        if not created:
            ensure_collection(args.collection, len(vecs[0]))
            created = True
        points = [{"id": str(uuid.uuid5(NS, f"{src}:{idx}")), "vector": v,
                   "payload": {"source": src, "chunk_index": idx, "text": text}}
                  for (src, idx, text), v in zip(batch, vecs)]
        requests.put(f"{QDRANT_URL}/collections/{args.collection}/points", params={"wait": "true"},
                     json={"points": points}, timeout=120).raise_for_status()
    print(f"ingested {len(items)} chunks into {args.collection}")


if __name__ == "__main__":
    main()
