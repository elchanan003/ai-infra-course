import concurrent.futures as cf, hashlib, json, os, re, struct, time
import pytest
from conftest import GOLDEN, MODELS, Server, http, write_cfg, hf_cli

SMALL_GPU = "name: L4\nmemory_gib: 24\ncount: 1\n"


def families(text, prefix=("vllm:", "http_")):
    out = {}
    for l in text.splitlines():
        m = re.match(r"# TYPE (\S+) (\S+)", l)
        if m and m.group(1).startswith(prefix) and not m.group(1).endswith("_created"):
            out[m.group(1)] = m.group(2)
    return out


def buckets(text):
    out = {}
    for l in text.splitlines():
        m = re.match(r'(\S+)_bucket\{(.*)le="([^"]+)"', l)
        if m:
            out.setdefault(m.group(1), [])
            if m.group(3) not in out[m.group(1)]:
                out[m.group(1)].append(m.group(3))
    return out


def metrics_text(s):
    return s.get("/metrics", raw=True)[1].decode()


def stable(text):
    return "\n".join(l for l in text.splitlines() if not re.match(r"(# (HELP|TYPE) )?(\S*_created|python_|process_)", l) and "_created" not in l.split("{")[0])


def test_metric_names_types_buckets_equal_golden(vllm):
    s = vllm()
    s.chat("x", max_tokens=3)
    s.post("/v1/chat/completions", dict(model="chat", messages=[{"role": "user", "content": "x"}], max_tokens=2, stream=True), raw=True)
    mine = metrics_text(s)
    golden = open(GOLDEN).read().split("# ===== appended")[0]
    fg, fm = families(golden), families(mine)
    assert fg == fm, (set(fg) ^ set(fm), {k: (fg[k], fm.get(k)) for k in fg if fg[k] != fm.get(k)})
    assert buckets(golden) == {k: v for k, v in buckets(mine).items() if k in buckets(golden)} 
    # label sets
    lab = lambda t, n: sorted(re.findall(r'(\w+)="', re.search(rf"^{re.escape(n)}\{{(.*?)\}} ", t, re.M).group(1)))
    for n in ("vllm:kv_cache_usage_perc", "vllm:request_success_total", "vllm:cache_config_info", "vllm:prompt_tokens_by_source_total"):
        assert lab(golden, n) == lab(mine, n), n
    assert 'model_name="chat"' in mine and 'engine="0"' in mine


def test_unique_ids_and_usage(vllm):
    s = vllm()
    ids = set()
    for i in range(30):
        c, r = s.chat(f"hi {i}", max_tokens=4)
        assert c == 200
        ids.add(r["id"])
        assert r["usage"]["completion_tokens"] == 4 and r["usage"]["total_tokens"] == r["usage"]["prompt_tokens"] + 4
    for i in range(5):
        ids.add(s.post("/v1/completions", dict(model="chat", prompt="a", max_tokens=2))[1]["id"])
        ids.add(s.post("/v1/embeddings", dict(model="chat", input="a"))[1]["id"])
    assert len(ids) == 40


def test_unique_ids_across_restart(vllm):
    a = vllm().chat("x", max_tokens=2)[1]["id"]
    b = vllm().chat("x", max_tokens=2)[1]["id"]
    assert a != b


def test_models_and_health(vllm):
    s = vllm()
    c, r = s.get("/v1/models")
    assert c == 200 and r["data"][0]["id"] == "chat" and r["data"][0]["max_model_len"] == 8192
    assert s.get("/health", raw=True)[0] == 200
    assert s.chat(model="nope")[0] == 404


def test_streaming(vllm):
    s = vllm()
    c, b, h = s.post("/v1/chat/completions", dict(model="chat", messages=[{"role": "user", "content": "hi"}], max_tokens=5, stream=True,
                                                 stream_options={"include_usage": True}), raw=True)
    lines = [l for l in b.decode().split("\n\n") if l]
    assert lines[-1] == "data: [DONE]"
    chunks = [json.loads(l[6:]) for l in lines[:-1]]
    assert chunks[0]["choices"][0]["delta"]["role"] == "assistant"
    content = [x for x in chunks if x["choices"] and x["choices"][0]["delta"].get("content")]
    assert len(content) == 5
    assert chunks[-1]["usage"]["completion_tokens"] == 5 and chunks[-1]["choices"] == []
    assert chunks[-2]["choices"][0]["finish_reason"] == "length"
    assert len({x["id"] for x in chunks}) == 1


def test_context_length_error(vllm):
    s = vllm(args="--max-model-len 256")
    c, r = s.chat("x " * 10, max_tokens=1000)
    assert c == 400 and "maximum context length is 256 tokens" in r["error"]["message"]


def test_fim_completions_echo(vllm):
    s = vllm()
    c, r = s.post("/v1/completions", dict(model="chat", prompt="def add(a, b):\n    return ", suffix="\n\nprint(add(1,2))", max_tokens=16))
    assert c == 200
    t = r["choices"][0]["text"]
    assert "FIM_ECHO prefix_chars=26 suffix_chars=17" in t
    last = s.get("/admin/stats")[1]["last_requests"][-1]
    assert last["fim"] is True and last["suffix_chars"] == 17 and last["prefix_tail"].endswith("return ")
    c, r = s.post("/v1/completions", dict(model="chat", prompt="<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>", max_tokens=4))
    assert "sentinels=fim_middle,fim_prefix,fim_suffix" in r["choices"][0]["text"]


def test_embeddings_deterministic_and_semantic(vllm):
    s = vllm(env=dict(MOCK_EMBED_DIM="64"))
    c, r1 = s.post("/v1/embeddings", dict(model="chat", input=["the cat sat on the mat", "stock markets fell sharply"]))
    c, r2 = s.post("/v1/embeddings", dict(model="chat", input=["the cat sat on the mat"]))
    assert r1["data"][0]["embedding"] == r2["data"][0]["embedding"] and len(r1["data"][0]["embedding"]) == 64
    c, q = s.post("/v1/embeddings", dict(model="chat", input="a cat on a mat"))
    dot = lambda a, b: sum(x * y for x, y in zip(a, b))
    assert dot(q["data"][0]["embedding"], r1["data"][0]["embedding"]) > dot(q["data"][0]["embedding"], r1["data"][1]["embedding"])
    c, b64 = s.post("/v1/embeddings", dict(model="chat", input="the cat sat on the mat", encoding_format="base64"))
    assert list(struct.unpack("<64f", __import__("base64").b64decode(b64["data"][0]["embedding"])))[:3] == pytest.approx(r2["data"][0]["embedding"][:3], rel=1e-5)


def run_load(s, n_seq=6, n_burst=6):
    for i in range(n_seq):
        assert s.chat(f"seq request number {i} " * 5, max_tokens=7 + i)[0] == 200
    with cf.ThreadPoolExecutor(n_burst) as ex:
        list(ex.map(lambda i: s.chat(f"burst request {i} " * 20, max_tokens=12), range(n_burst)))


def test_determinism_two_runs_identical_metrics(vllm):
    outs = []
    for _ in range(2):
        s = vllm(args="--max-model-len 4096 --max-num-seqs 4", env=dict(MOCK_TIME_SCALE="0"))
        run_load(s)
        time.sleep(0.2)
        outs.append(stable(metrics_text(s)))
        s.stop()
    assert outs[0] == outs[1]
    assert 'vllm:request_success_total{engine="0",finished_reason="length",model_name="chat"} 12.0' in outs[0]


def test_queueing_and_preemption_under_kv_pressure(vllm):
    s = vllm(model="llama-2-7b-mha", args="--max-model-len 2048 --max-num-seqs 16", gpu=SMALL_GPU, env=dict(MOCK_TIME_SCALE="0"))
    st = s.get("/admin/stats")[1]
    assert st["capacity"]["kv_cache_size_tokens"] < 20000
    with cf.ThreadPoolExecutor(24) as ex:
        res = list(ex.map(lambda i: s.chat("hello " * 600 + str(i), max_tokens=400)[0], range(24)))
    assert set(res) == {200}
    t = metrics_text(s)
    pre = float(re.search(r"^vllm:num_preemptions_total\S* (\S+)", t, re.M).group(1))
    qsum = float(re.search(r"^vllm:request_queue_time_seconds_sum\S* (\S+)", t, re.M).group(1))
    st = s.get("/admin/stats")[1]["engine"]
    assert pre > 0 and qsum > 0 and st["kv_peak_usage"] > 0.95 and st["running"] == 0 and st["kv_cache_usage"] == 0


def test_kv_usage_gauge_and_kv_pressure_fault(vllm):
    s = vllm()
    g = lambda: float(re.search(r"^vllm:kv_cache_usage_perc\S* (\S+)", metrics_text(s), re.M).group(1))
    assert g() == 0.0
    assert s.post("/admin/fault", dict(kv_pressure=0.6))[1]["kv_pressure"] == 0.6
    assert g() == pytest.approx(0.6, abs=0.01)
    s.delete("/admin/fault")
    assert g() == 0.0


def test_prefix_caching_counters(vllm):
    s = vllm(args="--max-model-len 4096 --enable-prefix-caching")
    long = "You are a helpful assistant. " * 100
    for i in range(3):
        s.chat(long + f"question {i}", max_tokens=2)
    t = metrics_text(s)
    q = float(re.search(r"^vllm:prefix_cache_queries_total\S* (\S+)", t, re.M).group(1))
    h = float(re.search(r"^vllm:prefix_cache_hits_total\S* (\S+)", t, re.M).group(1))
    assert q > 0 and h > 0.5 * q * (2 / 3)
    s2 = vllm(args="--max-model-len 4096 --no-enable-prefix-caching")
    for i in range(3):
        s2.chat(long + f"question {i}", max_tokens=2)
    h2 = float(re.search(r"^vllm:prefix_cache_hits_total\S* (\S+)", metrics_text(s2), re.M).group(1))
    assert h2 == 0.0


def test_fault_api(vllm):
    s = vllm()
    assert s.get("/admin/fault")[1]["error_rate"] == 0
    assert s.post("/admin/fault", dict(error_rate=1.0))[0] == 200
    codes = [s.chat("x", max_tokens=1)[0] for _ in range(5)]
    assert codes == [500] * 5
    assert s.post("/admin/fault", dict(bogus=1))[0] == 400
    assert s.post("/admin/fault", dict(error_rate=2))[0] == 400
    s.delete("/admin/fault")
    assert s.chat("x", max_tokens=1)[0] == 200
    # latency_ms is virtual: shows up in TTFT
    s.post("/admin/fault", dict(latency_ms=1500))
    c, _ = s.chat("x", max_tokens=2)
    t = metrics_text(s)
    ttft = float(re.search(r"^vllm:time_to_first_token_seconds_sum\S* (\S+)", t, re.M).group(1))
    assert ttft > 1.5
    # partial error rate is deterministic
    s.delete("/admin/fault")
    s.post("/admin/fault", dict(error_rate=0.5))
    a = [s.chat(f"x{i}", max_tokens=1)[0] for i in range(20)]
    assert 4 < a.count(500) < 16
    st = s.get("/admin/stats")[1]
    assert st["errors_injected"] >= 5 + a.count(500)


def test_fault_crash_and_slow_load(vllm):
    s = vllm()
    s.post("/admin/fault", dict(crash=True))
    assert s.p.wait(10) == 1
    s = vllm(extra={"fault.yaml": "slow_load_s: 3\n"}, wait=False)
    t0 = time.time()
    time.sleep(1.5)
    assert s.get("/health", raw=True)[0] == 503
    assert s.wait(20) and time.time() - t0 >= 2.5


def test_other_gpu_mem_blocks_startup(vllm, tmp_path):
    s = vllm(gpu="memory_gib: 80\n", extra={"fault.yaml": "other_gpu_mem_gib: 30\n"}, wait=False)
    assert s.p.wait(30) == 1 and "Free memory on device" in s.logtext()


def test_admin_stats(vllm):
    s = vllm()
    s.post("/v1/chat/completions", dict(model="chat", messages=[{"role": "system", "content": "sys"}, {"role": "user", "content": "hello there"}],
                                      tools=[{"type": "function", "function": {"name": "f", "parameters": {}}}], max_tokens=3, user="u1"),
           headers={"x-custom": "abc", "authorization": "Bearer sk-1234"})
    st = s.get("/admin/stats")[1]
    assert st["requests"]["chat"]["chat"] == 1 and st["tokens"]["completion"] == 3
    last = st["last_requests"][-1]
    assert last["headers"]["x-custom"] == "abc" and last["headers"]["authorization"] == "Bearer sk-1234"
    assert last["roles"] == ["system", "user"] and last["tools"] == ["f"] and last["user"] == "u1" and last["last_user"] == "hello there"
    assert st["capacity"]["num_gpu_blocks"] > 0 and st["engine"]["completed"] == 1


SCRIPT = """
rules:
  - name: weather
    match: {user_regex: "weather in (?P<city>\\\\w+)", has_tool: get_weather, last_role: user}
    tool_calls:
      - {name: get_weather, arguments: {city: "${city}"}}
    usage: {prompt_tokens: 111, completion_tokens: 22}
  - name: tool-result
    match: {last_role: tool}
    content: "The tool returned {nonce}."
    usage: {prompt_tokens: 150, completion_tokens: 9}
  - name: edit
    match: {user_regex: "rename (\\\\w+) to (\\\\w+)"}
    edit: {file: "src/app.py", search: "def ${1}():", replace: "def ${2}():"}
"""


def test_script_mode(vllm):
    s = vllm(script=SCRIPT)
    tools = [{"type": "function", "function": {"name": "get_weather", "parameters": {}}}]
    c, r = s.post("/v1/chat/completions", dict(model="chat", tools=tools, messages=[{"role": "user", "content": "what is the weather in Paris?"}]))
    ch = r["choices"][0]
    assert ch["finish_reason"] == "tool_calls" and ch["message"]["content"] is None
    tc = ch["message"]["tool_calls"][0]
    assert tc["function"]["name"] == "get_weather" and json.loads(tc["function"]["arguments"]) == {"city": "Paris"} and tc["id"].startswith("call_")
    assert r["usage"] == dict(prompt_tokens=111, total_tokens=133, completion_tokens=22, prompt_tokens_details={"cached_tokens": 0})
    msgs = [{"role": "user", "content": "what is the weather in Paris?"}, ch["message"],
            {"role": "tool", "tool_call_id": tc["id"], "content": '{"temp": 21, "nonce": "ab12cd34ef56"}'}]
    c, r = s.post("/v1/chat/completions", dict(model="chat", tools=tools, messages=msgs))
    assert r["choices"][0]["message"]["content"] == "The tool returned ab12cd34ef56." and r["usage"]["prompt_tokens"] == 150 and r["usage"]["completion_tokens"] == 9
    c, r = s.chat("please rename foo to bar")
    txt = r["choices"][0]["message"]["content"]
    assert "src/app.py\n```python\n<<<<<<< SEARCH\ndef foo():\n=======\ndef bar():\n>>>>>>> REPLACE\n```" in txt
    # streaming tool call
    c, b, h = s.post("/v1/chat/completions", dict(model="chat", tools=tools, stream=True, messages=[{"role": "user", "content": "weather in Rome"}]), raw=True)
    assert b"get_weather" in b and b'"finish_reason": "tool_calls"' in b and b.rstrip().endswith(b"[DONE]")
    assert s.get("/admin/stats")[1]["last_requests"][-1]["rule"] == "weather"


def write_tiny_hub(root, repo="acme/tiny", tokenizer=True, corrupt=False, wrong_blob=False):
    """Create an HF cache layout with a real (tiny) safetensors file whose blob name is its sha256."""
    org, name = repo.split("/")
    base = os.path.join(root, f"models--{org}--{name}")
    sha = "a" * 40
    snap = os.path.join(base, "snapshots", sha)
    os.makedirs(snap)
    os.makedirs(os.path.join(base, "blobs"))
    os.makedirs(os.path.join(base, "refs"))
    open(os.path.join(base, "refs", "main"), "w").write(sha)
    hdr = {"w": {"dtype": "BF16", "shape": [64, 64], "data_offsets": [0, 8192]}, "b": {"dtype": "BF16", "shape": [64], "data_offsets": [8192, 8320]}}
    hj = json.dumps(hdr).encode()
    blob = struct.pack("<Q", len(hj)) + hj + bytes(8320)
    digest = hashlib.sha256(blob).hexdigest()
    if corrupt:
        blob = blob[:-1] + b"\x01"
    files = {"config.json": (json.dumps(json.load(open(os.path.join(MODELS, "qwen2.5-0.5b", "config.json")))).encode(), hashlib.sha1(b"c").hexdigest()),
             "model.safetensors": (blob, digest)}
    if tokenizer:
        files["tokenizer.json"] = (b"{}", hashlib.sha1(b"t").hexdigest())
        files["tokenizer_config.json"] = (b"{}", hashlib.sha1(b"tc").hexdigest())
    for fn, (data, bn) in files.items():
        open(os.path.join(base, "blobs", bn), "wb").write(data)
        os.symlink(os.path.join("..", "..", "blobs", bn), os.path.join(snap, fn))
    return base


def test_model_loading_local_dir_checks(vllm, tmp_path):
    d = tmp_path / "m"
    d.mkdir()
    (d / "config.json").write_text(open(os.path.join(MODELS, "qwen2.5-0.5b", "config.json")).read())
    hdr = json.dumps({"w": {"dtype": "BF16", "shape": [10, 10], "data_offsets": [0, 200]}}).encode()
    (d / "model.safetensors").write_bytes(struct.pack("<Q", len(hdr)) + hdr + bytes(200))
    s = vllm(model=str(d), wait=False)  # weights but no tokenizer -> real-looking failure naming the file
    assert s.p.wait(30) == 1 and "missing file: tokenizer.json" in s.logtext()
    (d / "tokenizer.json").write_text("{}")
    s = vllm(model=str(d), wait=False)
    assert s.p.wait(30) == 1 and "missing file: tokenizer_config.json" in s.logtext()
    (d / "tokenizer_config.json").write_text("{}")
    s = vllm(model=str(d))
    assert "1 tensors" in s.logtext() or "tensors" in s.logtext()
    assert s.get("/admin/stats")[1]["capacity"]["params"] == 100
    (d / "SHA256SUMS").write_text("0" * 64 + "  model.safetensors\n")
    s = vllm(model=str(d), wait=False)
    assert s.p.wait(30) == 1 and "model.safetensors" in s.logtext() and "sha256 mismatch" in s.logtext()


def test_model_loading_hf_repo_offline_cache(vllm, tmp_path):
    hub = str(tmp_path / "hub")
    write_tiny_hub(hub)
    env = dict(HF_HUB_CACHE=hub, HF_HUB_OFFLINE="1", HF_HOME=str(tmp_path / "home"))
    s = vllm(model="acme/tiny", args="--max-model-len 2048", env=env)
    st = s.get("/admin/stats")[1]
    assert st["capacity"]["params"] == 64 * 64 + 64 and st["capacity"]["dtype"] == "bfloat16"
    # missing from cache while offline
    s = vllm(model="acme/missing", env=env, wait=False)
    assert s.p.wait(30) == 1 and "couldn't connect to" in s.logtext() and "offline mode" in s.logtext()


def test_model_loading_blob_sha_mismatch_and_missing_tokenizer(vllm, tmp_path):
    hub = str(tmp_path / "hub")
    write_tiny_hub(hub, "acme/bad", corrupt=True)
    write_tiny_hub(hub, "acme/notok", tokenizer=False)
    env = dict(HF_HUB_CACHE=hub, HF_HUB_OFFLINE="1", HF_HOME=str(tmp_path / "home"))
    s = vllm(model="acme/bad", env=env, wait=False)
    assert s.p.wait(30) == 1 and "shard 'model.safetensors': sha256 mismatch" in s.logtext()
    s = vllm(model="acme/notok", env=env, wait=False)
    assert s.p.wait(30) == 1 and "tokenizer.json" in s.logtext() and "Can't load tokenizer" in s.logtext()


def test_model_loading_online_via_hf_mirror_and_unreachable(vllm, tmp_path):
    hub = str(tmp_path / "hub")
    write_tiny_hub(hub)
    mdir = tmp_path / "mirror"
    mdir.mkdir()
    m = Server("hf-mirror", str(mdir), dict(MOCK_DATA_DIR=hub))
    try:
        assert m.wait()
        env = dict(HF_ENDPOINT=m.url, HF_HOME=str(tmp_path / "home2"), HF_HUB_DISABLE_XET="1", HF_HUB_CACHE=str(tmp_path / "dl"))
        s = vllm(model="acme/tiny", args="--max-model-len 2048", env=env)
        reqs = m.get("/admin/requests")[1]
        assert any("/api/models/acme/tiny/revision/main" in r["path"] for r in reqs) and any("resolve" in r["path"] for r in reqs)
        s.stop()
        env["HF_ENDPOINT"] = "http://127.0.0.1:9"
        env["HF_HUB_CACHE"] = str(tmp_path / "dl-empty")
        s = vllm(model="acme/tiny", env=env, wait=False)
        assert s.p.wait(60) == 1 and "couldn't connect to 'http://127.0.0.1:9'" in s.logtext()
    finally:
        m.stop()
