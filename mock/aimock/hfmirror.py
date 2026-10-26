"""hf-mirror: HF-Hub-compatible read-only mirror over an HF cache dir (models--org--name/snapshots/<sha>/...)."""
import hashlib, json, mimetypes, os, re, time
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from .common import log

HEX64 = re.compile(r"^[0-9a-f]{64}$")


def create_app(data):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    reqs = []

    def roots():
        return [r for r in (data, os.path.join(data, "hub")) if os.path.isdir(r)]

    def repo_dir(repo):
        d = "models--" + repo.replace("/", "--")
        for r in roots():
            p = os.path.join(r, d)
            if os.path.isdir(os.path.join(p, "snapshots")):
                return p
        return None

    def resolve_rev(p, rev):
        snaps = os.path.join(p, "snapshots")
        if os.path.isdir(os.path.join(snaps, rev)):
            return rev
        ref = os.path.join(p, "refs", rev)
        if os.path.isfile(ref):
            s = open(ref).read().strip()
            if os.path.isdir(os.path.join(snaps, s)):
                return s
        if rev == "main":
            l = sorted(os.listdir(snaps))
            if len(l) == 1:
                return l[0]
        return None

    def files(p, sha):
        base = os.path.join(p, "snapshots", sha)
        for d, _, fs in os.walk(base):
            for fn in sorted(fs):
                fp = os.path.join(d, fn)
                rel = os.path.relpath(fp, base)
                yield rel, os.path.realpath(fp)

    def etag(real, rel):
        b = os.path.basename(real)
        return b if HEX64.match(b) or re.match(r"^[0-9a-f]{40}$", b) else hashlib.sha1(rel.encode()).hexdigest()

    def err(status, code, msg):
        return JSONResponse({"error": msg}, status_code=status, headers={"x-error-code": code, "x-error-message": msg})

    @app.middleware("http")
    async def logmw(request: Request, call_next):
        resp = await call_next(request)
        if not request.url.path.startswith("/admin"):
            e = dict(i=len(reqs), t=round(time.time(), 3), method=request.method, path=request.url.path, query=request.url.query,
                     status=resp.status_code, range=request.headers.get("range"), user_agent=request.headers.get("user-agent"),
                     host=request.headers.get("host"), authorization=bool(request.headers.get("authorization")))
            reqs.append(e)
            del reqs[:-5000]
            log("INFO", f"{e['method']} {e['path']} -> {e['status']}", "hf-mirror")
        return resp

    def model_info(repo, rev, tree=False, recursive=True):
        p = repo_dir(repo)
        if not p:
            return err(404, "RepoNotFound", f"Repository not found: {repo}")
        sha = resolve_rev(p, rev)
        if not sha:
            return err(404, "RevisionNotFound", f"Invalid rev id: {rev}")
        fl = list(files(p, sha))
        if tree:
            return JSONResponse([dict(type="file", path=r, size=os.path.getsize(a), oid=etag(a, r),
                                      **({"lfs": dict(oid=etag(a, r), size=os.path.getsize(a), pointerSize=134)} if HEX64.match(os.path.basename(a)) else {}))
                                 for r, a in fl])
        return JSONResponse(dict(_id=sha[:24], id=repo, modelId=repo, sha=sha, private=False, disabled=False, gated=False, tags=[],
                                 siblings=[dict(rfilename=r, size=os.path.getsize(a)) for r, a in fl]))

    @app.get("/api/models/{repo:path}/revision/{rev}")
    async def revision(repo: str, rev: str):
        return model_info(repo, rev)

    @app.get("/api/models/{repo:path}/tree/{rev}")
    async def tree(repo: str, rev: str):
        return model_info(repo, rev, tree=True)

    @app.get("/api/models/{repo:path}/xet-read-token/{rev}")
    async def xet(repo: str, rev: str):
        return err(404, "EntryNotFound", "xet not available on this mirror")

    @app.get("/api/models/{repo:path}")
    async def model(repo: str):
        return model_info(repo, "main")

    @app.api_route("/{repo:path}/resolve/{rev}/{path:path}", methods=["GET", "HEAD"])
    async def resolve(request: Request, repo: str, rev: str, path: str):
        p = repo_dir(repo)
        if not p:
            return err(404, "RepoNotFound", f"Repository not found: {repo}")
        sha = resolve_rev(p, rev)
        if not sha:
            return err(404, "RevisionNotFound", f"Invalid rev id: {rev}")
        fp = os.path.join(p, "snapshots", sha, path)
        if not os.path.isfile(fp) or ".." in path.split("/"):
            return err(404, "EntryNotFound", f"Entry not found: {path}")
        real = os.path.realpath(fp)
        size = os.path.getsize(real)
        et = etag(real, path)
        h = {"etag": f'"{et}"', "x-repo-commit": sha, "accept-ranges": "bytes", "content-type": mimetypes.guess_type(path)[0] or "application/octet-stream"}
        if HEX64.match(os.path.basename(real)):
            h["x-linked-etag"] = f'"{et}"'
            h["x-linked-size"] = str(size)
        start, end, status = 0, size - 1, 200
        m = re.match(r"bytes=(\d*)-(\d*)", request.headers.get("range", ""))
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else size - 1
            else:
                start = max(0, size - int(m.group(2)))
            end = min(end, size - 1)
            if start >= size:
                return Response(status_code=416, headers={"content-range": f"bytes */{size}"})
            status = 206
            h["content-range"] = f"bytes {start}-{end}/{size}"
        n = end - start + 1
        h["content-length"] = str(n)
        if request.method == "HEAD":
            return Response(status_code=status, headers=h)

        def it():
            with open(real, "rb") as f:
                f.seek(start)
                left = n
                while left > 0:
                    b = f.read(min(1 << 20, left))
                    if not b:
                        break
                    left -= len(b)
                    yield b
        return StreamingResponse(it(), status_code=status, headers=h)

    @app.get("/health")
    async def health():
        return {"status": "ok", "roots": roots()}

    @app.get("/admin/requests")
    async def admin_requests(since: int = 0):
        return reqs[since:]

    @app.delete("/admin/requests")
    async def admin_reset():
        reqs.clear()
        return {"status": "cleared"}

    return app
