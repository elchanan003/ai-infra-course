#!/usr/bin/env python3
"""Task 7.5 - semantic search.  Usage: python search.py --collection NAME "question"
Prints the top 3 hits, one per line:  <score>\t<source>#<chunk_index>\t<first line of the text>
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
    ap.add_argument("--collection", required=True)
    ap.add_argument("question")
    args = ap.parse_args()
    # TODO(7.5): embed the question with the SAME alias, query Qdrant, print the hits
    raise SystemExit("search.py: not implemented (task 7.5)")


if __name__ == "__main__":
    main()
