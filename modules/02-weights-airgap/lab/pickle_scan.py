#!/usr/bin/env python3
"""Static pickle scanner (task 2.2). usage: pickle_scan.py FILE...

Contract: for every FILE print one JSON line
    {"file": FILE, "verdict": "safe"|"dangerous", "findings": [{"opcode": ..., "module": ..., "name": ...}]}
Exit code 0 if every file is safe, 1 if any file is dangerous. A file that cannot be parsed is dangerous.
Files are raw pickles or PyTorch zip checkpoints (scan every *.pkl member). NEVER call pickle.load / torch.load.
Use pickletools.genops().
"""
import json, sys


def scan(path):
    # TODO: replace this stub
    return {"file": path, "verdict": "safe", "findings": []}


if __name__ == "__main__":
    results = [scan(p) for p in sys.argv[1:]]
    for r in results:
        print(json.dumps(r))
    sys.exit(1 if any(r["verdict"] == "dangerous" for r in results) else 0)
