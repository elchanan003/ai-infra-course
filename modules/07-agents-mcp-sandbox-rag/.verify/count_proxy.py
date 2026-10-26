#!/usr/bin/env python3
"""Verify helper: logging pass-through proxy in front of the gateway (records request/response shapes as JSON lines)."""
import argparse, json, threading, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--upstream", required=True)
ap.add_argument("--log", required=True)
A = ap.parse_args()
LOCK = threading.Lock()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _record(self, body, data, status):
        rec = {"path": self.path, "status": status}
        try:
            rq = json.loads(body or b"{}")
        except Exception:
            rq = {}
        msgs = rq.get("messages") or []
        rec["roles"] = [m.get("role") for m in msgs]
        rec["n_tools"] = len(rq.get("tools") or [])
        rec["tool_msgs"] = [{"id": m.get("tool_call_id"), "content": str(m.get("content"))} for m in msgs if m.get("role") == "tool"]
        asst = [m for m in msgs if m.get("role") == "assistant"]
        rec["asst_call_ids"] = [c.get("id") for c in (asst[-1].get("tool_calls") or [])] if asst else []
        inp = rq.get("input")
        rec["n_inputs"] = len(inp) if isinstance(inp, list) else (1 if inp is not None else 0)
        try:
            msg = json.loads(data)["choices"][0]["message"]
            rec["resp_calls"] = [{"id": c["id"], "name": c["function"]["name"], "args": c["function"]["arguments"]}
                                 for c in (msg.get("tool_calls") or [])]
            rec["content"] = msg.get("content")
        except Exception:
            rec["resp_calls"] = []
        with LOCK, open(A.log, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def _fwd(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        hdr = {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "content-type", "accept")}
        req = urllib.request.Request(A.upstream + self.path, data=body if self.command != "GET" else None,
                                     headers=hdr, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                status, data, ctype = r.status, r.read(), r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            status, data, ctype = e.code, e.read(), e.headers.get("Content-Type", "application/json")
        except Exception as e:
            status, data, ctype = 502, json.dumps({"error": str(e)}).encode(), "application/json"
        if self.command == "POST":
            self._record(body, data, status)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = _fwd


ThreadingHTTPServer(("127.0.0.1", A.port), H).serve_forever()
