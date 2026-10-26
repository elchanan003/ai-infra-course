#!/usr/bin/env python3
"""Execute every panel query of a provisioned Grafana dashboard through /api/ds/query. Output JSON.
   dashcheck.py GRAFANA_URL USER:PASS DASH_UID [--panel-expr TITLE]
   --panel-expr prints only the first target expr of panel TITLE with variables substituted (for promtool tests)."""
import base64, json, re, sys, urllib.request, urllib.error

base, auth, uid = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
H = {"Authorization": "Basic " + base64.b64encode(auth.encode()).decode(), "Content-Type": "application/json"}


def call(path, body=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers=H)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}
    except Exception as e:  # noqa
        return 0, {"message": str(e)}


def flatten(panels):
    for p in panels or []:
        if p.get("type") == "row":
            yield from flatten(p.get("panels"))
        else:
            yield p


def subst(expr):
    expr = re.sub(r"\$\{?model\}?", ".*", expr)
    expr = re.sub(r"\$\{?replica\}?", ".*", expr)
    expr = expr.replace("$__rate_interval", "1m").replace("${__rate_interval}", "1m").replace("$__interval", "15s").replace("$__range", "10m")
    return expr


code, d = call(f"/api/dashboards/uid/{uid}")
if code != 200:
    print(json.dumps({"error": f"dashboard uid '{uid}' not found in Grafana (HTTP {code})"})); sys.exit(0)
panels = list(flatten(d["dashboard"].get("panels")))
if "--panel-expr" in sys.argv:
    t = sys.argv[sys.argv.index("--panel-expr") + 1]
    for p in panels:
        if p.get("title") == t and p.get("targets"):
            print(subst(p["targets"][0].get("expr", ""))); sys.exit(0)
    sys.exit(1)
out = {"panels": {}}
for p in panels:
    title = p.get("title", "")
    res = {"frames": 0, "points": 0, "max": None, "error": None, "queries": 0}
    pds = (p.get("datasource") or {})
    for tg in p.get("targets") or []:
        expr = tg.get("expr")
        if not expr:
            continue
        res["queries"] += 1
        ds = tg.get("datasource") or pds or {"uid": "prometheus"}
        duid = ds.get("uid") if isinstance(ds, dict) else "prometheus"
        if duid in ("${DS_PROMETHEUS}", "$datasource", None):
            duid = "prometheus"
        body = {"queries": [{"refId": "A", "datasource": {"type": "prometheus", "uid": duid}, "expr": subst(expr), "range": True, "instant": False,
                             "interval": "15s", "intervalMs": 15000, "maxDataPoints": 200}], "from": "now-10m", "to": "now"}
        c, r = call("/api/ds/query", body)
        if c != 200:
            res["error"] = f"datasource '{duid}': HTTP {c} {(r.get('message') or '')[:120]}"; continue
        ra = (r.get("results") or {}).get("A", {})
        if ra.get("error"):
            res["error"] = ra["error"][:160]; continue
        for f in ra.get("frames") or []:
            vals = (f.get("data") or {}).get("values") or []
            if len(vals) >= 2:
                nz = [x for x in vals[1] if x is not None]
                if nz:
                    res["frames"] += 1; res["points"] += len(nz)
                    m = max(nz); res["max"] = m if res["max"] is None else max(res["max"], m)
    out["panels"][title] = res
print(json.dumps(out))
