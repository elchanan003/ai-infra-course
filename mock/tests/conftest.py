import json, os, shutil, signal, socket, subprocess, sys, time, urllib.request, urllib.error
import pytest

MOCK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(MOCK, "models")
GOLDEN = os.path.join(MOCK, "tests", "golden", "vllm-metrics-golden.txt")
_port = [18150]


def next_port():
    while True:
        _port[0] += 1
        assert _port[0] <= 18199, "test port range 18150-18199 exhausted"
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", _port[0])) != 0:
                return _port[0]


def http(method, url, body=None, headers=None, raw=False, timeout=60):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    h = {"content-type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data, h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        code, b, hd = r.status, r.read(), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        code, b, hd = e.code, e.read(), {k.lower(): v for k, v in e.headers.items()}
    if raw:
        return code, b, hd
    try:
        return code, json.loads(b) if b else None
    except ValueError:
        return code, b.decode(errors="replace")


class Server:
    def __init__(self, role, cfg, env=None, port=None):
        self.port = port or next_port()
        self.url = f"http://127.0.0.1:{self.port}"
        e = dict(os.environ, MOCK_CONFIG_DIR=str(cfg), MOCK_PORT=str(self.port), MOCK_HOST="127.0.0.1", PYTHONPATH=MOCK)
        e.update(env or {})
        self.log = open(os.path.join(str(cfg), f"server-{self.port}.log"), "w+")
        self.p = subprocess.Popen([sys.executable, "-m", "aimock", role], env=e, stdout=self.log, stderr=subprocess.STDOUT, cwd=MOCK)

    def wait(self, timeout=60):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.p.poll() is not None:
                return False
            try:
                if http("GET", self.url + "/health", raw=True, timeout=2)[0] == 200:
                    return True
            except Exception:
                pass
            time.sleep(0.2)
        return False

    def logtext(self):
        self.log.flush()
        self.log.seek(0)
        return self.log.read()

    def stop(self):
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()

    def get(self, path, **kw):
        return http("GET", self.url + path, **kw)

    def post(self, path, body=None, **kw):
        return http("POST", self.url + path, body, **kw)

    def delete(self, path, **kw):
        return http("DELETE", self.url + path, **kw)

    def chat(self, content="hello", model="chat", **kw):
        b = dict(model=model, messages=[{"role": "user", "content": content}], **kw)
        return self.post("/v1/chat/completions", b)


def write_cfg(tmp, model="qwen2.5-7b", args="", gpu=None, script=None, extra=None):
    d = tmp
    os.makedirs(d, exist_ok=True)
    mp = os.path.join(MODELS, model) if os.path.isdir(os.path.join(MODELS, model)) else model
    open(os.path.join(d, "args"), "w").write(f"--model {mp} --served-model-name chat {args}\n")
    if gpu is not None:
        open(os.path.join(d, "gpu.yaml"), "w").write(gpu)
    if script is not None:
        open(os.path.join(d, "script.yaml"), "w").write(script)
    for k, v in (extra or {}).items():
        open(os.path.join(d, k), "w").write(v)
    return d


@pytest.fixture
def vllm(tmp_path):
    made = []

    def make(model="qwen2.5-7b", args="--max-model-len 8192", gpu=None, script=None, env=None, extra=None, wait=True):
        cfg = write_cfg(str(tmp_path / f"cfg{len(made)}"), model, args, gpu, script, extra)
        s = Server("vllm", cfg, {**dict(MOCK_TIME_SCALE="0"), **(env or {})})
        made.append(s)
        if wait:
            assert s.wait(), s.logtext()
        return s
    yield make
    for s in made:
        s.stop()


@pytest.fixture
def dcgm(tmp_path):
    made = []

    def make(yaml_text="hostname: node-a\ngpus: {count: 2}\n", env=None):
        d = tmp_path / f"dcgm{len(made)}"
        d.mkdir()
        (d / "gpus.yaml").write_text(yaml_text)
        s = Server("dcgm", str(d), dict(MOCK_DCGM_FREEZE="100", **(env or {})))
        made.append(s)
        assert s.wait(), s.logtext()
        return s
    yield make
    for s in made:
        s.stop()


def hf_cli():
    for p in (os.path.join(MOCK, "..", "platform", ".venv", "bin", "hf"),
              os.path.join(MOCK, "..", ".build", "spike", "venv-core", "bin", "hf")):
        if os.path.exists(p):
            return os.path.abspath(p)
    return None
