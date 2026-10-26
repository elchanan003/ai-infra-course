#!/usr/bin/env python3
"""Reference solution 7.2."""
import argparse
import os
import sys

from mcp.server.mcpserver import MCPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "agent"))
from tools import lookup_ticket  # noqa: E402

app = MCPServer("lab-tools")


@app.tool()
def word_count(text: str) -> int:
    """Count the whitespace-separated words in `text`."""
    return len(text.split())


@app.tool()
def ticket_status(ticket_id: str) -> str:
    """Return the status record of a support ticket by id (for example T-1001)."""
    return lookup_ticket(ticket_id)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    app.run("streamable-http", host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
