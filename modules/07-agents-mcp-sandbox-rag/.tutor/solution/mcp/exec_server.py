#!/usr/bin/env python3
"""Reference solution 7.4."""
import argparse
import json
import os
import subprocess
import tempfile

from mcp.server.mcpserver import MCPServer

RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sandbox", "run_sandboxed.sh")
MAX_TIMEOUT = 30
MAX_OUT = 64 * 1024

app = MCPServer("exec-tools")


def _clip(b: bytes) -> str:
    return b[:MAX_OUT].decode("utf-8", errors="replace")


@app.tool()
def run_python(code: str, timeout_s: int = 5) -> str:
    """Run Python 3 code in a locked-down sandbox (no network, read-only filesystem, 256 MiB RAM, only /tmp writable).
    Returns a JSON string with stdout, stderr, exit_code and timed_out. timeout_s is clamped to 1..30 seconds."""
    t = max(1, min(int(timeout_s), MAX_TIMEOUT))
    with tempfile.TemporaryDirectory(prefix="job-") as d:
        path = os.path.join(d, "job.py")
        with open(path, "w") as f:
            f.write(code)
        os.chmod(path, 0o644)
        try:
            p = subprocess.run([RUNNER, path, str(t)], capture_output=True, timeout=t + 20)
            out, err, rc = p.stdout, p.stderr, p.returncode
        except subprocess.TimeoutExpired as e:
            out, err, rc = e.stdout or b"", e.stderr or b"", 124
    return json.dumps({"stdout": _clip(out), "stderr": _clip(err), "exit_code": rc, "timed_out": rc == 124})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    app.run("streamable-http", host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
