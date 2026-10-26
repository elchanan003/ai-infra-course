#!/usr/bin/env python3
"""Task 7.4 - code execution as an MCP tool (Streamable HTTP at /mcp on 127.0.0.1:PORT).

Tool: run_python(code: str, timeout_s: int = 5) -> str   (JSON string: stdout, stderr, exit_code, timed_out)
Use ../sandbox/run_sandboxed.sh from task 7.3. Log to stderr only.
"""
import argparse
import sys

# TODO(7.4): server object + the run_python tool


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    # TODO(7.4): serve Streamable HTTP on 127.0.0.1:args.port
    sys.exit("exec_server.py: not implemented (task 7.4)")


if __name__ == "__main__":
    main()
