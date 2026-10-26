import hashlib, os, subprocess, json
import pytest
from conftest import Server, http, hf_cli
from test_vllm import write_tiny_hub


@pytest.fixture
def mirror(tmp_path):
    hub = str(tmp_path / "hub")
    write_tiny_hub(hub, "acme/tiny")
    d = tmp_path / "m"
    d.mkdir()
    s = Server("hf-mirror", str(d), dict(MOCK_DATA_DIR=hub))
    assert s.wait()
    yield s, hub
    s.stop()


def test_four_endpoints_and_log(mirror):
    s, hub = mirror
    c, info = s.get("/api/models/acme/tiny/revision/main")
    assert c == 200 and info["sha"] == "a" * 40 and {x["rfilename"] for x in info["siblings"]} >= {"config.json", "model.safetensors"}
    c, tree = s.get(f"/api/models/acme/tiny/tree/{'a' * 40}?recursive=true&expand=false")
    assert c == 200 and {t["path"] for t in tree} >= {"config.json"} and all(t["type"] == "file" for t in tree)
    c, _, h = http("HEAD", s.url + "/acme/tiny/resolve/main/model.safetensors", raw=True)
    assert c == 200 and h["x-repo-commit"] == "a" * 40 and int(h["content-length"]) == 8 + 124 + 8320 or int(h["content-length"]) > 8000
    c, b, h = http("GET", s.url + f"/acme/tiny/resolve/{'a' * 40}/config.json", raw=True)
    assert c == 200 and json.loads(b)["hidden_size"] == 896
    c, b, h = http("GET", s.url + "/acme/tiny/resolve/main/model.safetensors", headers={"range": "bytes=0-7"}, raw=True)
    assert c == 206 and len(b) == 8 and h["content-range"].startswith("bytes 0-7/")
    assert http("GET", s.url + "/api/models/acme/nope/revision/main", raw=True)[0] == 404
    assert http("GET", s.url + "/acme/tiny/resolve/main/missing.bin", raw=True)[0] == 404
    reqs = s.get("/admin/requests")[1]
    assert [r["method"] for r in reqs][:3] == ["GET", "GET", "HEAD"] and reqs[0]["status"] == 200
    s.delete("/admin/requests")
    assert s.get("/admin/requests")[1] == []


@pytest.mark.skipif(hf_cli() is None, reason="no hf CLI venv")
def test_hf_download_through_mirror(mirror, tmp_path):
    s, hub = mirror
    out = tmp_path / "dl"
    env = dict(os.environ, HF_ENDPOINT=s.url, HF_HOME=str(tmp_path / "hfhome"), HF_HUB_DISABLE_XET="1", HF_HUB_DISABLE_TELEMETRY="1")
    for k in ("HF_TOKEN", "HF_HUB_OFFLINE"):
        env.pop(k, None)
    r = subprocess.run([hf_cli(), "download", "acme/tiny", "--include", "*.json", "--include", "*.safetensors", "--local-dir", str(out)],
                       env=env, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr + r.stdout
    blob = (out / "model.safetensors").read_bytes()
    src = [f for f in os.listdir(os.path.join(hub, "models--acme--tiny", "blobs")) if len(f) == 64][0]
    assert hashlib.sha256(blob).hexdigest() == src
    paths = [r["path"] for r in s.get("/admin/requests")[1]]
    assert any("/api/models/acme/tiny/revision/main" in p for p in paths) and any(p.endswith("/resolve/" + "a" * 40 + "/model.safetensors") for p in paths)
