#!/usr/bin/env python3
"""Task 7.2 - your MCP server (Streamable HTTP at /mcp on 127.0.0.1:PORT).

Tools: word_count(text) -> int ; ticket_status(ticket_id) -> str (reads $TICKETS_JSON; ../agent/tools.py is yours to import).
Log to stderr only. SDK: `from mcp.server.mcpserver import MCPServer` (mcp 2.3.0).
"""
import argparse
import sys

# TODO(7.2): create the server object and register the two tools with type hints and docstrings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    # TODO(7.2): serve Streamable HTTP on 127.0.0.1:args.port
    sys.exit("server.py: not implemented (task 7.2)")


if __name__ == "__main__":
    main()
