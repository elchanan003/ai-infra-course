#!/usr/bin/env python3
"""Task 7.1 - a tool-calling agent loop against the gateway (OpenAI wire format).

Usage: python loop.py --task "<text>" [--max-steps 6]
Contract: stdout = the final answer only; exit 0. Exit 2 if --max-steps is exhausted without a final answer.
Environment (from lab/env.sh): GATEWAY, LAB_KEY, AGENT_MODEL, TICKETS_JSON.
"""
import argparse
import json
import os
import sys

import requests

from tools import TOOL_FUNCS

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:18040")
LAB_KEY = os.environ.get("LAB_KEY", "")
MODEL = os.environ.get("AGENT_MODEL", "mock-a")

TOOLS = []  # TODO(7.1): the OpenAI `tools` array (type "function", name, description, JSON Schema parameters) for lookup_ticket


def chat(messages):
    """TODO(7.1): POST {GATEWAY}/v1/chat/completions with model, messages and tools; return the parsed JSON response."""
    raise NotImplementedError


def run_tool(name, arguments_json):
    """TODO(7.1): execute one tool call; `arguments_json` is a STRING. Always return a string (errors included)."""
    raise NotImplementedError


def run_agent(task, max_steps):
    """TODO(7.1): the loop. Return the final answer text, or None when max_steps is exhausted."""
    raise NotImplementedError


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True)
    ap.add_argument("--max-steps", type=int, default=6)
    args = ap.parse_args()
    answer = run_agent(args.task, args.max_steps)
    if answer is None:
        print("max steps exhausted", file=sys.stderr)
        sys.exit(2)
    print(answer)


if __name__ == "__main__":
    main()
