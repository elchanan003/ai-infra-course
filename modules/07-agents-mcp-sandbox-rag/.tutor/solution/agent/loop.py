#!/usr/bin/env python3
"""Reference solution 7.1."""
import argparse
import json
import os
import sys

import requests

from tools import TOOL_FUNCS

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:18040")
LAB_KEY = os.environ.get("LAB_KEY", "")
MODEL = os.environ.get("AGENT_MODEL", "mock-a")

TOOLS = [{
    "type": "function",
    "function": {
        "name": "lookup_ticket",
        "description": "Return the record of a support ticket (status, owner, reference) by id, e.g. T-1001.",
        "parameters": {"type": "object", "properties": {"ticket_id": {"type": "string", "description": "ticket id like T-1001"}},
                       "required": ["ticket_id"]},
    },
}]


def chat(messages):
    r = requests.post(f"{GATEWAY}/v1/chat/completions", timeout=90,
                      headers={"Authorization": f"Bearer {LAB_KEY}"},
                      json={"model": MODEL, "messages": messages, "tools": TOOLS})
    r.raise_for_status()
    return r.json()


def run_tool(name, arguments_json):
    fn = TOOL_FUNCS.get(name)
    if fn is None:
        return f"error: unknown tool {name}"
    try:
        args = json.loads(arguments_json or "{}")
    except json.JSONDecodeError as e:
        return f"error: arguments are not valid JSON ({e}); send a JSON object"
    try:
        return str(fn(**args))
    except Exception as e:  # tool errors go back to the model, not up the stack
        return f"error: {type(e).__name__}: {e}"


def run_agent(task, max_steps):
    messages = [{"role": "system", "content": "You are a support assistant. Use the tools when you need ticket data."},
                {"role": "user", "content": task}]
    for _ in range(max_steps):
        msg = chat(messages)["choices"][0]["message"]
        calls = msg.get("tool_calls") or []
        if not calls:
            return msg.get("content") or ""
        messages.append({"role": "assistant", "content": msg.get("content"), "tool_calls": calls})
        for c in calls:
            messages.append({"role": "tool", "tool_call_id": c["id"],
                             "content": run_tool(c["function"]["name"], c["function"]["arguments"])})
    return None


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
