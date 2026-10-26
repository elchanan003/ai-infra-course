#!/usr/bin/env python3
"""One reconciliation traffic run: N sequential gateway requests with a fresh key alias + B direct engine requests (hidden count, variant).
Prints: START=<epoch> END=<epoch> KEY_ALIAS=<alias> and appends a record to .state/traffic-runs.jsonl (truth for verify)."""
import json, os, sys, time, urllib.request

MOD = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
V = json.load(open(os.path.join(MOD, ".state", "variant.json")))
LITELLM = os.environ.get("LITELLM_URL", "http://127.0.0.1:18040"); MASTER = os.environ.get("LITELLM_KEY", "sk-aiinfra-master")
MOCK_A = os.environ.get("MOCK_A_URL", "http://127.0.0.1:18021")


def post(url, body, key):
    r = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(r, timeout=120) as f:
        return json.loads(f.read())


alias = f"recon-{int(time.time())}"
k = post(LITELLM + "/key/generate", {"key_alias": alias, "models": ["mock-a"]}, MASTER)["key"]
prompt = "reconcile " + ("alpha bravo charlie " * 30)
body = lambda m: {"model": m, "max_tokens": 32, "messages": [{"role": "user", "content": prompt}]}
n, b = V["n_gateway"], V["bypass"]
start = int(time.time())
gw_tokens = 0; eng_tokens = 0; per_req = 0
direct_at = set(range(3, 3 + b))  # interleave direct engine calls after the 3rd gateway request
for i in range(n):
    u = post(LITELLM + "/v1/chat/completions", body("mock-a"), k)["usage"]
    per_req = u["total_tokens"]; gw_tokens += per_req
    if i in direct_at:
        post(MOCK_A + "/v1/chat/completions", body("chat"), "none")
end = int(time.time()) + 1
rec = dict(alias=alias, key=k, start=start, end=end, n=n, bypass=b, per_req=per_req, gateway_tokens=gw_tokens, engine_tokens=(n + b) * per_req)
os.makedirs(os.path.join(MOD, ".state"), exist_ok=True)
open(os.path.join(MOD, ".state", "traffic-runs.jsonl"), "a").write(json.dumps(rec) + "\n")
print(f"START={start} END={end} KEY_ALIAS={alias}")
