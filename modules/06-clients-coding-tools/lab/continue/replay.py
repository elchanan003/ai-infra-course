#!/usr/bin/env python3
"""Given. Replays what the Continue extension would send for ONE chat request and ONE autocomplete request, reading
lab/continue/config.yaml (pyyaml from platform/.venv). Prints JSON. Usage: replay.py [config.yaml]"""
import json, sys, urllib.request, urllib.error, yaml

def post(url, key, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=60); return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}
    except Exception as e:
        return 0, {"error": str(e)}

cfg = yaml.safe_load(open(sys.argv[1] if len(sys.argv) > 1 else __file__.rsplit("/", 1)[0] + "/config.yaml")) or {}
models = cfg.get("models") or []
def by_role(role):
    for m in models:
        if role in (m.get("roles") or ["chat", "edit", "apply"]):
            return m
out = {}
m = by_role("chat")
if m:
    st, js = post(m["apiBase"].rstrip("/") + "/chat/completions", m["apiKey"],
                  {"model": m["model"], "messages": [{"role": "user", "content": "Explain this function in one line: def add(a, b): return a + b"}],
                   "max_tokens": (m.get("defaultCompletionOptions") or {}).get("maxTokens", 64)})
    out["chat"] = {"status": st, "apiBase": m["apiBase"], "model": m["model"]}
m = by_role("autocomplete")
if m:
    prefix, suffix = "def add(a, b):\n    ", "\n\nprint(add(1, 2))\n"
    st, js = post(m["apiBase"].rstrip("/") + "/completions", m["apiKey"],
                  {"model": m["model"], "prompt": prefix, "suffix": suffix, "temperature": 0,
                   "max_tokens": (m.get("defaultCompletionOptions") or {}).get("maxTokens", 64), "stop": ["\n\n"]})
    out["autocomplete"] = {"status": st, "apiBase": m["apiBase"], "model": m["model"], "text": (js.get("choices") or [{}])[0].get("text", "")[:120]}
print(json.dumps(out))
