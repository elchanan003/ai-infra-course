#!/usr/bin/env python3
"""Harness-side checks for module 02. Prints 'STATUS ID message' lines (PASS|FAIL|BLOCKED)."""
import hashlib, json, os, struct, subprocess, sys, time

def out(st, i, m): print(f"{st} {i} {m}", flush=True)
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""): h.update(c)
    return h.hexdigest()
def header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]; return json.loads(f.read(n))


def cmd_model(lab, state):
    t = json.load(open(f"{state}/truth.json")); md = f"{lab}/model"; need = t["serving"]
    bad = None
    for name, want in sorted(need.items()):
        p = f"{md}/{name}"
        if not os.path.isfile(p): bad = f"{name} is missing from lab/model/ (the serving set of the pinned commit: *.json, *.txt, *.safetensors)"; break
        if sha(p) != want: bad = f"{name} does not match the source hash"; break
    sumf = f"{lab}/model.sha256"
    if not bad:
        if not os.path.isfile(sumf): bad = "lab/model.sha256 does not exist"
        else:
            r = subprocess.run(["sha256sum", "-c", "--quiet", "../model.sha256"], cwd=md, capture_output=True, text=True)
            listed = {l.split(None, 1)[1].strip().lstrip("*") for l in open(sumf) if l.strip()}
            if r.returncode != 0: bad = "sha256sum -c ../model.sha256 fails inside lab/model/: " + (r.stdout + r.stderr).strip().splitlines()[0][:100]
            elif not set(need) <= listed: bad = "model.sha256 does not list every file: first missing entry is " + sorted(set(need) - listed)[0]
    out("FAIL" if bad else "PASS", "2.1.1", bad or "serving set complete, hashes match the source, model.sha256 verifies")
    if bad: out("BLOCKED", "2.1.2", "needs 2.1.1")
    else:
        extra = []
        for d, ds, fs in os.walk(md):
            ds[:] = [x for x in ds if x != ".cache"]
            for fn in fs:
                rel = os.path.relpath(os.path.join(d, fn), md)
                if rel in t["decoys"] or not rel.endswith((".json", ".txt", ".safetensors")): extra.append(rel)
        out("FAIL" if extra else "PASS", "2.1.2", ("files that serving does not need were downloaded (%s) - use explicit --include patterns" % extra[0]) if extra else "no decoy or unneeded files downloaded")
    try: a = json.load(open(f"{lab}/answers/header.json"))
    except Exception as e: out("FAIL", "2.1.3", f"header.json unreadable: {e}"); return
    ok = a.get("shards") == t["nshards"] and a.get("tensors") == t["tensors"] and a.get("total_params") == t["params"] and sorted(a.get("dtypes") or []) == t["dtypes"]
    out("PASS" if ok else "FAIL", "2.1.3", "header.json equals the values computed from the safetensors headers" if ok else "header.json differs from what the safetensors headers say (shards from the index, tensors and parameter count from the header JSONs, dtype names as written there)")


def cmd_s3(lab, state, envfile_serve):
    import boto3
    from botocore.client import Config
    from botocore.exceptions import ClientError
    t = json.load(open(f"{state}/truth.json")); prefix = f"{t['repo']}/{t['commit']}/"
    def client(ak, sk, ep="http://127.0.0.1:18070"):
        return boto3.client("s3", endpoint_url=ep, aws_access_key_id=ak, aws_secret_access_key=sk, region_name="us-east-1", config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 1}))
    rw = client("rwkey", "rwsecret123")
    try: rw.head_bucket(Bucket="models")
    except ClientError: rw.create_bucket(Bucket="models")
    for o in rw.list_objects_v2(Bucket="models", Prefix=prefix).get("Contents", []): rw.delete_object(Bucket="models", Key=o["Key"])
    env = {}
    for l in open(envfile_serve):
        l = l.strip()
        if "=" in l and not l.startswith("#"): k, v = l.split("=", 1); env[k.strip()] = v.strip()
    e2 = dict(os.environ, S3_ENDPOINT="http://127.0.0.1:18070", S3_ACCESS_KEY="rwkey", S3_SECRET_KEY="rwsecret123")
    py = sys.executable
    try: r = subprocess.run([py, f"{lab}/s3-sync.py"], env=e2, capture_output=True, text=True, timeout=300, cwd=lab)
    except Exception as e: r = None; err = str(e)
    ok = bool(r) and r.returncode == 0
    msg = None
    if not ok: msg = "s3-sync.py failed: " + ((r.stderr or r.stdout).strip().splitlines() or ["no output"])[-1][:140] if r else err
    sv = client(env.get("S3_ACCESS_KEY", ""), env.get("S3_SECRET_KEY", ""), env.get("S3_ENDPOINT", "http://127.0.0.1:18070"))
    if ok:
        try:
            for name, want in sorted(t["serving"].items()):
                body = sv.get_object(Bucket="models", Key=prefix + name)["Body"].read()
                if hashlib.sha256(body).hexdigest() != want: msg = f"object {name} read with the serving credentials does not match the source hash"; break
            if not msg:
                sums = sv.get_object(Bucket="models", Key=prefix + "SHA256SUMS")["Body"].read().decode()
                listed = {l.split(None, 1)[1].strip(): l.split()[0] for l in sums.splitlines() if l.strip()}
                if any(listed.get(n) != h for n, h in t["serving"].items()): msg = "SHA256SUMS object is missing entries or has wrong hashes"
        except ClientError as e: msg = f"reading with the credentials in lab/s3-serve.env failed: {e.response['Error']['Code']} (is the identity allowed to read? did the sync upload everything?)"
        except Exception as e: msg = f"reading with lab/s3-serve.env failed: {type(e).__name__}"
    out("FAIL" if msg else "PASS", "2.3.1", msg or "all objects present under the prefix and readable with the serving credentials; hashes match")
    for i, op in (("2.3.2", "put"), ("2.3.3", "delete")):
        if msg: out("BLOCKED", i, "needs 2.3.1 (a denial is only meaningful when the same identity can read)"); continue
        try:
            if op == "put": sv.put_object(Bucket="models", Key=prefix + "tamper.txt", Body=b"x")
            else: sv.delete_object(Bucket="models", Key=prefix + "model.safetensors.index.json")
            out("FAIL", i, f"the serving credentials were allowed to {op.upper()} - the serving identity must be read-only (403 AccessDenied)")
        except ClientError as e:
            c = e.response["Error"]["Code"]
            out("PASS" if c == "AccessDenied" else "FAIL", i, f"{op.upper()} denied with 403 AccessDenied" if c == "AccessDenied" else f"{op.upper()} failed with {c}, not AccessDenied - a wrong key and a read-only identity are different failures")
    try: rw.delete_object(Bucket="models", Key=prefix + "tamper.txt")
    except Exception: pass


def cmd_bundle(lab, state):
    b = json.load(open(f"{state}/bundle.json")); inc = f"{lab}/incoming"
    try: a = json.load(open(f"{lab}/answers/incident.json"))
    except Exception as e: out("FAIL", "2.6.1", f"incident.json unreadable: {e}"); a = None
    if a is not None:
        c = b["corrupt"][0]; got = a.get("corrupt") or []
        ok = sorted(a.get("missing") or []) == sorted(b["missing"]) and len(got) == 1 and got[0].get("file") == c["file"] \
            and got[0].get("expected_sha256") == c["expected_sha256"] and got[0].get("actual_sha256") == c["actual_sha256"]
        out("PASS" if ok else "FAIL", "2.6.1", "incident.json names the missing and the corrupt file with the right hashes" if ok else "incident.json: the missing list or the corrupt entry (file, expected sha from SHA256SUMS, actual sha of the damaged file as it arrived) is wrong - compare the bundle with its manifest and check completeness, not only hashes")
    mt = json.load(open(f"{state}/bundle-mtimes.json"))
    r = subprocess.run(["sha256sum", "-c", "--quiet", "SHA256SUMS"], cwd=inc, capture_output=True, text=True)
    touched = [n for n, m in mt.items() if not os.path.exists(f"{inc}/{n}") or abs(os.stat(f"{inc}/{n}").st_mtime - m) > 1.0]
    if r.returncode != 0: out("FAIL", "2.6.2", "bundle still fails its manifest: " + (r.stdout + r.stderr).strip().splitlines()[0][:100])
    elif touched: out("FAIL", "2.6.2", f"{touched[0]} was good but has been replaced - repair only the broken files")
    else: out("PASS", "2.6.2", "every file matches SHA256SUMS and no good file was re-downloaded")


if __name__ == "__main__":
    globals()["cmd_" + sys.argv[1]](*sys.argv[2:])
