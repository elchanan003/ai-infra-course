#!/usr/bin/env python3
"""Reference solution 7.5 (search)."""
import argparse
import os

import requests

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:18040")
LAB_KEY = os.environ.get("LAB_KEY", "")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "embed")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:18033")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--collection", required=True)
    ap.add_argument("question")
    args = ap.parse_args()
    r = requests.post(f"{GATEWAY}/v1/embeddings", timeout=60, headers={"Authorization": f"Bearer {LAB_KEY}"},
                      json={"model": EMBED_MODEL, "input": [args.question]})
    r.raise_for_status()
    vec = r.json()["data"][0]["embedding"]
    q = requests.post(f"{QDRANT_URL}/collections/{args.collection}/points/query", timeout=60,
                      json={"query": vec, "limit": 3, "with_payload": True})
    q.raise_for_status()
    for p in q.json()["result"]["points"]:
        pl = p["payload"]
        print(f"{p['score']:.4f}\t{pl['source']}#{pl['chunk_index']}\t{pl['text'].splitlines()[0]}")


if __name__ == "__main__":
    main()
