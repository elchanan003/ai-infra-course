#!/usr/bin/env python3
"""Verify helper: MCP client (mcp 2.3.0). Usage: mcp_call.py URL list | URL call NAME [JSON_ARGS]. Prints one JSON object."""
import asyncio, json, sys
from mcp import Client


async def main():
    url, op = sys.argv[1], sys.argv[2]
    try:
        async with Client(url) as c:
            if op == "list":
                r = await c.list_tools()
                out = {"tools": [{"name": t.name, "description": t.description or "", "schema": t.input_schema} for t in r.tools]}
            else:
                args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
                try:
                    r = await c.call_tool(sys.argv[3], args)
                    out = {"is_error": bool(r.is_error), "text": "".join(getattr(x, "text", "") or "" for x in r.content),
                           "structured": r.structured_content}
                except Exception as e:
                    out = {"exception": type(e).__name__, "message": str(e)[:300]}
    except Exception as e:
        out = {"connect_error": f"{type(e).__name__}: {str(e)[:300]}"}
    print(json.dumps(out))


asyncio.run(main())
