import json
res = {}
for p in ("/var/tmp/__NONCE__", "/etc/__NONCE__", "/usr/__NONCE__", "/__NONCE__"):
    try:
        open(p, "w").write("x"); res[p] = True
    except OSError:
        res[p] = False
print(json.dumps(res))
