#!/usr/bin/env python3
"""Task 7.5 - ingest *.md / *.txt from DIR into a Qdrant collection, embeddings via the gateway.

Usage: python ingest.py --docs DIR --collection NAME
Chunking: one chunk per non-empty paragraph (blocks separated by a blank line; a line with only spaces is blank), stripped.
Payload per point: source (file name), chunk_index (0-based within the file), text.
Environment: GATEWAY, LAB_KEY, EMBED_MODEL, QDRANT_URL.
"""
import argparse
import os

import requests

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:18040")
LAB_KEY = os.environ.get("LAB_KEY", "")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "embed")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:18033")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", required=True)
    ap.add_argument("--collection", required=True)
    args = ap.parse_args()
    # TODO(7.5): chunk -> embed in batches -> create collection if missing (size from the embedding, Cosine)
    #            -> upsert with deterministic ids and wait=true
    raise SystemExit("ingest.py: not implemented (task 7.5)")


if __name__ == "__main__":
    main()
