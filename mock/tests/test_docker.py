"""Image-level tests (docker run, label course=aiinfra, ports 18190-18199). Run under the lab lock via run_tests.sh."""
import json, os, subprocess, time, uuid
import pytest
from conftest import MOCK, MODELS, http

pytestmark = pytest.mark.docker
PORTS = iter(range(18190, 18200))


def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


@pytest.fixture(scope="module")
def images():
    for img, ctx in (("aiinfra-mock:1.0", MOCK), ("aiinfra-tripwire:1.0", os.path.join(MOCK, "tripwire"))):
        r = sh("docker", "build", "-q", "-t", img, ctx)
        assert r.returncode == 0, r.stderr


@pytest.fixture
def run(images):
    names = []

    def go(img, *args, port=None, env=None, mounts=(), net=None, extra=()):
        name = "aiinfra-test-" + uuid.uuid4().hex[:8]
        names.append(name)
        cmd = ["docker", "run", "-d", "--name", name, "--label", "course=aiinfra"]
        if port:
            cmd += ["-p", f"127.0.0.1:{port}:8000"]
        for k, v in (env or {}).items():
            cmd += ["-e", f"{k}={v}"]
        for m in mounts:
            cmd += ["-v", m]
        cmd += list(extra) + [img, *args]
        r = sh(*cmd)
        assert r.returncode == 0, r.stderr
        return name
    yield go
    for n in names:
        sh("docker", "rm", "-f", "-v", n)


def wait_health(port, t=40):
    t0 = time.time()
    while time.time() - t0 < t:
        try:
            if http("GET", f"http://127.0.0.1:{port}/health", raw=True, timeout=2)[0] == 200:
                return True
        except Exception:
            time.sleep(0.3)
    return False


def test_vllm_image_runs_with_shipped_models(run, tmp_path):
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "args").write_text("--model /models/qwen2.5-7b --served-model-name chat --max-model-len 8192 --max-num-seqs 64\n")
    port = next(PORTS)
    n = run("aiinfra-mock:1.0", "vllm", port=port, mounts=[f"{cfg}:/config:ro"], env={"MOCK_TIME_SCALE": "0"})
    assert wait_health(port), sh("docker", "logs", n).stdout
    c, r = http("POST", f"http://127.0.0.1:{port}/v1/chat/completions", dict(model="chat", messages=[{"role": "user", "content": "hi"}], max_tokens=3))
    assert c == 200 and r["usage"]["completion_tokens"] == 3
    assert sh("docker", "inspect", "-f", "{{.Config.Labels.course}}", n).stdout.strip() == "aiinfra"


def test_vllm_image_refuses_and_exits_1(run, tmp_path):
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "args").write_text("--model /models/llama-3.1-70b --max-model-len 8192\n")
    n = run("aiinfra-mock:1.0", "vllm", mounts=[f"{cfg}:/config:ro"])
    assert sh("docker", "wait", n).stdout.strip() == "1"
    assert "CUDA out of memory" in sh("docker", "logs", n).stdout


def test_dcgm_image_and_docker_exec_nvidia_smi(run, tmp_path):
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "gpus.yaml").write_text("hostname: node-b\ngpus: {count: 2, model: 'NVIDIA H100 80GB HBM3', memory_mib: 81559, power_limit_w: 700}\n")
    port = next(PORTS)
    n = run("aiinfra-mock:1.0", "dcgm", port=port, mounts=[f"{cfg}:/config:ro"])
    assert wait_health(port)
    http("POST", f"http://127.0.0.1:{port}/admin/fault", dict(gpu=1, xid=79))
    out = sh("docker", "exec", n, "nvidia-smi", "--query-gpu=index,name,memory.total", "--format=csv,noheader")
    assert out.returncode == 0 and out.stdout.startswith("0, NVIDIA H100 80GB HBM3, 81559 MiB")
    full = sh("docker", "exec", n, "nvidia-smi")
    assert full.returncode == 255 and "Unable to determine the device handle for GPU" in full.stdout
    assert "Xid" in sh("docker", "exec", n, "dmesg").stdout
    http("DELETE", f"http://127.0.0.1:{port}/admin/fault")
    assert "NVIDIA-SMI" in sh("docker", "exec", n, "nvidia-smi").stdout
    assert "DCGM_FI_DEV_GPU_TEMP" in http("GET", f"http://127.0.0.1:{port}/metrics", raw=True)[1].decode()


def test_tripwire_counts_dns_queries(run):
    port = next(PORTS)
    n = run("aiinfra-tripwire:1.0", port=port)
    assert wait_health(port)
    ip = sh("docker", "inspect", "-f", "{{.NetworkSettings.IPAddress}}", n).stdout.strip()
    url = f"http://127.0.0.1:{port}/hits"
    assert http("DELETE", url)[0] == 200
    for host in ("huggingface.co", "huggingface.co", "pypi.org"):
        r = sh("docker", "exec", n, "nslookup", host, "127.0.0.1")
        assert ip in r.stdout, r.stdout + r.stderr
    time.sleep(0.5)
    c, hits = http("GET", url)
    assert hits["huggingface.co"] == 2 and hits["pypi.org"] == 1
    # HTTP sink accepts anything, host recorded; TLS connect recorded via SNI
    sh("docker", "exec", n, "python3", "-c", "import urllib.request;urllib.request.urlopen(urllib.request.Request('http://127.0.0.1/x', headers={'Host':'api.example.com'}))")
    c, d = http("GET", url + "?detail=1")
    assert d["http"].get("api.example.com") == 1
    assert http("DELETE", url)[0] == 200 and http("GET", url)[1] == {}
