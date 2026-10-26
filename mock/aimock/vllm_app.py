import asyncio, base64, json, os, re, struct, sys, time, uuid, hashlib
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from . import VERSION, capacity, model_loader
from .common import est_tokens, frac, load_yaml, log, msg_text, sha
from .script import Script
from .vllm_engine import Engine, Req
from .vllm_metrics import VllmMetrics

WORDS = ("the model server batches requests and schedules tokens across running sequences while the cache keeps keys and values "
         "for every attention head so latency stays low under load and memory stays bounded by blocks").split()
FIM_RE = re.compile(r"<\|?fim[_▁]?(prefix|suffix|middle)\|?>|<fim_(prefix|suffix|middle)>", re.I)
FAULT_DEFAULTS = dict(latency_ms=0, error_rate=0.0, kv_pressure=0.0, crash=False, slow_load_s=0.0, other_gpu_mem_gib=0.0)


def startup(config_dir):
    """Parse config, resolve model, compute capacity. Raises StartupError (real vLLM text)."""
    text = ""
    p = os.path.join(config_dir, "args")
    if os.path.isfile(p):
        text = open(p).read()
    a = capacity.parse_args(text)
    if os.environ.get("MOCK_VLLM_ARGS"):
        a = capacity.parse_args(os.environ["MOCK_VLLM_ARGS"])
    if not a.get("model"):
        raise capacity.StartupError("ValueError", "No model specified: provide --model <path-or-repo-id> in /config/args")
    log("INFO", f"vLLM API server version {VERSION} (aimock: simulated, no GPU)")
    log("INFO", f"non-default args: { {k: v for k, v in a.items() if k != '_unknown' and DEFAULT_OF(k) != v} }")
    path, from_hub = model_loader.resolve(a["model"], a.get("download-dir"), a.get("revision"))
    info = model_loader.inspect(path, a["model"], from_hub)
    m = capacity.load_model(path)
    if info.get("params"):
        m["params"] = info["params"]
    if info.get("dtype") in ("bfloat16", "float16", "float32"):
        m["torch_dtype"] = info["dtype"]
    gpu = capacity.load_gpu(os.path.join(config_dir, "gpu.yaml"))
    fault0 = load_yaml(os.path.join(config_dir, "fault.yaml"), {})
    extra = float(fault0.get("other_gpu_mem_gib", 0) or 0)
    cap = capacity.compute(a, m, gpu, extra, allow_long=os.environ.get("VLLM_ALLOW_LONG_MAX_MODEL_LEN") == "1")
    cap["gpu"] = gpu
    cap["tensors"] = info.get("tensors", 0)
    return a, cap, fault0


def DEFAULT_OF(k):
    return capacity.DEFAULTS.get(k, object())


def oai_error(status, msg, etype, code=None):
    return JSONResponse({"error": {"message": msg, "type": etype, "param": None, "code": code or status}}, status_code=status)


def create_app(args, cap, fault0, config_dir):
    names = str(args.get("served-model-name") or args["model"]).split()
    mname = names[0]
    seed = int(args.get("seed") or 0)
    scale = float(os.environ.get("MOCK_TIME_SCALE", args.get("mock-time-scale", 1.0)))
    default_out = int(os.environ.get("MOCK_DEFAULT_OUTPUT_TOKENS", args.get("mock-default-output-tokens", 64)))
    edim = int(os.environ.get("MOCK_EMBED_DIM", args.get("mock-embedding-dim", 384)))
    stats_n = int(os.environ.get("MOCK_STATS_N", 100))
    script = Script(os.path.join(config_dir, "script.yaml"))
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    faults = dict(FAULT_DEFAULTS)
    faults.update({k: v for k, v in (fault0 or {}).items() if k in FAULT_DEFAULTS})
    S = dict(boot=uuid.uuid4().hex[:8], seq=0, err_n=0, ready_at=time.monotonic() + float(faults["slow_load_s"] or 0),
             counters={}, last=[], tokens=dict(prompt=0, completion=0), errors_injected=0)
    metrics = VllmMetrics(mname, cap, args)
    engine = Engine(cap, metrics, scale, faults)

    @app.on_event("startup")
    async def _s():
        engine.start()
        log("INFO", f"GPU KV cache size: {cap['kv_cache_size_tokens']:,} tokens")
        log("INFO", f"Maximum concurrency for {cap['max_model_len']:,} tokens per request: {cap['max_concurrency']:.2f}x")
        log("INFO", f"Application startup complete. Serving {names} on port 8000")

    def new_id(prefix):
        S["seq"] += 1
        return f"{prefix}-{S['boot']}{S['seq']:08x}{uuid.uuid4().hex[:12]}"

    def loading():
        return time.monotonic() < S["ready_at"]

    def http_obs(handler, method, status, rbytes, sbytes, dur):
        cls = f"{status // 100}xx"
        metrics.fam["http_requests"][0].labels(handler=handler, method=method, status=cls).inc()
        metrics.fam["http_request_size_bytes"][0].labels(handler=handler).observe(rbytes)
        metrics.fam["http_response_size_bytes"][0].labels(handler=handler).observe(sbytes)
        metrics.fam["http_request_duration_highr_seconds"][0].observe(dur)
        metrics.fam["http_request_duration_seconds"][0].labels(handler=handler, method=method).observe(dur)

    def count(model, endpoint, status):
        c = S["counters"].setdefault(model, {})
        c[endpoint] = c.get(endpoint, 0) + 1
        c[f"status_{status}"] = c.get(f"status_{status}", 0) + 1

    def record(ctx, shape):
        e = dict(i=S["seq"], endpoint=ctx["endpoint"], model=ctx["model"], headers=ctx["headers"], **shape)
        S["last"].append(e)
        del S["last"][:-stats_n]
        return e

    def pre(request, headers):
        """returns an error response or None (loading, auth, injected faults, crash)."""
        if loading():
            return oai_error(503, "Service Unavailable: model is still loading", "ServiceUnavailable")
        if args.get("api-key") and headers.get("authorization") != f"Bearer {args['api-key']}":
            return oai_error(401, "Unauthorized", "Unauthorized")
        return None

    def injected():
        rate = float(faults.get("error_rate") or 0)
        S["err_n"] += 1
        if rate > 0 and frac(seed, "err", S["err_n"]) < rate:
            S["errors_injected"] += 1
            return oai_error(500, "Injected fault: internal server error (error_rate)", "InternalServerError")
        return None

    def check_crash():
        c = faults.get("crash")
        if c and c is not False:
            log("ERROR", "Injected fault: crash=true, exiting with code 1")
            asyncio.get_event_loop().call_later(0.05, lambda: os._exit(1))
            return oai_error(500, "EngineCore encountered an issue (injected crash)", "InternalServerError")
        return None

    def gen_pieces(key, n):
        out = []
        for i in range(n):
            w = WORDS[int(sha(seed, key, i, n=6), 16) % len(WORDS)]
            out.append(w if i == 0 else " " + w)
        return out

    def split_pieces(text):
        return re.findall(r"\s*\S+|\s+", text)

    def build_ctx(endpoint, body, headers, model):
        ctx = dict(endpoint=endpoint, model=model, headers=headers, messages=[], tools=[], prompt="", suffix=None)
        if endpoint == "chat":
            ctx["messages"] = body.get("messages") or []
            ctx["tools"] = [((t.get("function") or {}).get("name")) for t in (body.get("tools") or [])]
        else:
            pr = body.get("prompt", "")
            ctx["prompt"] = pr if isinstance(pr, str) else (" ".join(map(str, pr)) if isinstance(pr, list) else str(pr))
            ctx["suffix"] = body.get("suffix")
        return ctx

    def prompt_text(ctx, body):
        if ctx["endpoint"] == "chat":
            parts = []
            if body.get("tools"):
                parts.append("<tools>" + json.dumps(body["tools"], sort_keys=True) + "</tools>")
            for m in ctx["messages"]:
                parts.append(f"<|{m.get('role')}|>" + msg_text(m.get("content")) + json.dumps(m.get("tool_calls") or "") + "\n")
            return "".join(parts)
        return ctx["prompt"] + ("" if ctx["suffix"] is None else "<|fim_suffix|>" + str(ctx["suffix"]))

    def prompt_tokens_of(ctx, body, text):
        if ctx["endpoint"] == "chat":
            n = 3 + sum(4 + est_tokens(msg_text(m.get("content"))) + est_tokens(json.dumps(m.get("tool_calls")) if m.get("tool_calls") else "")
                        for m in ctx["messages"])
            if body.get("tools"):
                n += est_tokens(json.dumps(body["tools"]))
            return n
        pr = body.get("prompt", "")
        if isinstance(pr, list) and pr and all(isinstance(x, int) for x in pr):
            return len(pr)
        return est_tokens(text)

    async def generate(request, endpoint, body, model):
        headers = {k.lower(): v for k, v in request.headers.items()}
        ctx = build_ctx(endpoint, body, headers, model)
        text = prompt_text(ctx, body)
        ptoks = prompt_tokens_of(ctx, body, text)
        mt = body.get("max_completion_tokens") or body.get("max_tokens")
        hdr_out = headers.get("x-mock-output-tokens")
        plan = script.match(ctx) if script.enabled else None
        fim = endpoint == "completions" and (ctx["suffix"] is not None or bool(FIM_RE.search(ctx["prompt"])))
        pieces, tool_calls, usage_override, rule = None, [], None, None
        if plan:
            rule, usage_override = plan.rule, plan.usage
            if plan.kind == "tool_calls":
                tool_calls = plan.tool_calls
                n_nat = est_tokens(json.dumps(tool_calls)) + 2
                pieces = [""] * n_nat
            else:
                pieces = split_pieces(plan.text)
        elif fim:
            sents = sorted({(m.group(1) or m.group(2)).lower() for m in FIM_RE.finditer(ctx["prompt"])})
            pieces = split_pieces(f"FIM_ECHO prefix_chars={len(ctx['prompt'])} suffix_chars={len(str(ctx['suffix'] or ''))} "
                                  f"sentinels={','.join(sents) or 'none'} model={model}")
        shape = dict(stream=bool(body.get("stream")), max_tokens=mt, temperature=body.get("temperature"), user=body.get("user"),
                     rule=rule, prompt_tokens_est=ptoks, tool_choice=body.get("tool_choice"), n_tools=len(body.get("tools") or []),
                     tools=ctx["tools"])
        if endpoint == "chat":
            msgs = ctx["messages"]
            shape.update(n_messages=len(msgs), roles=[m.get("role") for m in msgs],
                         system_chars=sum(len(msg_text(m.get("content"))) for m in msgs if m.get("role") == "system"),
                         last_user=next((msg_text(m.get("content"))[:200] for m in reversed(msgs) if m.get("role") == "user"), None))
        else:
            shape.update(fim=fim, prompt_chars=len(ctx["prompt"]), suffix_chars=None if ctx["suffix"] is None else len(str(ctx["suffix"])),
                         prefix_tail=ctx["prompt"][-60:], suffix_head=None if ctx["suffix"] is None else str(ctx["suffix"])[:60])
        e = record(ctx, shape)
        # output length
        if usage_override and usage_override.get("completion_tokens") is not None:
            out_n = int(usage_override["completion_tokens"])
        elif pieces is not None:
            out_n = len(pieces)
        elif hdr_out:
            out_n = int(hdr_out)
        else:
            out_n = int(mt) if mt else default_out
        if mt and not (usage_override and "completion_tokens" in usage_override):
            out_n = min(out_n, int(mt))
        out_n = max(1, out_n)
        if usage_override and usage_override.get("prompt_tokens") is not None:
            ptoks_rep = int(usage_override["prompt_tokens"])
        else:
            ptoks_rep = ptoks
        total = ptoks + out_n
        if total > cap["max_model_len"]:
            msg = (f"This model's maximum context length is {cap['max_model_len']} tokens. However, you requested {total} tokens "
                   f"({ptoks} in the messages, {out_n} in the completion). Please reduce the length of the messages or completion.")
            if ptoks > cap["max_model_len"]:
                msg = (f"This model's maximum context length is {cap['max_model_len']} tokens. However, your request has {ptoks} input tokens. "
                       f"Please reduce the length of the input messages.")
            e["status"] = 400
            http_obs(request.url.path, "POST", 400, int(headers.get("content-length", 0) or 0), len(msg), 0.001)
            count(model, endpoint, 400)
            return oai_error(400, msg, "BadRequestError")
        if pieces is None:
            pieces = gen_pieces(sha(text), out_n)
            finish = "length" if mt else "stop"
        else:
            finish = "tool_calls" if tool_calls else "stop"
            if len(pieces) > out_n:
                pieces = pieces[:out_n - 1] + ["".join(pieces[out_n - 1:])]
            pieces = pieces + [""] * (out_n - len(pieces))
        eng_finish = "length" if (mt and out_n >= int(mt) and not plan) else "stop"
        req = Req(new_id("req"), ptoks, out_n, int(mt) if mt else default_out, text, eng_finish,
                  latency_s=float(faults.get("latency_ms") or 0) / 1000.0)
        engine.submit(req)
        S["tokens"]["prompt"] += ptoks_rep
        S["tokens"]["completion"] += out_n
        count(model, endpoint, 200)
        e["status"] = 200
        usage = dict(prompt_tokens=ptoks_rep, total_tokens=ptoks_rep + out_n, completion_tokens=out_n, prompt_tokens_details=None)
        rid = new_id("chatcmpl" if endpoint == "chat" else "cmpl")
        created = int(time.time())
        rbytes = int(headers.get("content-length", 0) or 0)

        def usage_now():
            u = dict(usage)
            if cap["prefix_caching"]:
                u["prompt_tokens_details"] = {"cached_tokens": req.cached}
            return u

        def chunk(delta=None, fr=None, text_=None, usage_=None):
            obj = dict(id=rid, created=created, model=model)
            if endpoint == "chat":
                obj["object"] = "chat.completion.chunk"
                obj["choices"] = [] if usage_ is not None else [dict(index=0, delta=delta or {}, logprobs=None, finish_reason=fr)]
            else:
                obj["object"] = "text_completion"
                obj["choices"] = [] if usage_ is not None else [dict(index=0, text=text_ or "", logprobs=None, finish_reason=fr)]
            if usage_ is not None:
                obj["usage"] = usage_
            return "data: " + json.dumps(obj) + "\n\n"

        def tool_calls_obj():
            return [dict(id="call_" + uuid.uuid4().hex[:24], type="function", function=dict(name=n, arguments=a)) for n, a in tool_calls]

        if body.get("stream"):
            include = bool((body.get("stream_options") or {}).get("include_usage"))

            async def gen():
                sent = 0
                try:
                    if endpoint == "chat":
                        yield chunk(delta=dict(role="assistant", content=""))
                    while True:
                        kind, val = await req.q.get()
                        if kind == "tok":
                            pc = pieces[val]
                            sent += 1
                            if endpoint == "chat":
                                if not tool_calls:
                                    yield chunk(delta=dict(content=pc))
                            else:
                                yield chunk(text_=pc)
                        else:
                            break
                    if tool_calls:
                        tcs = tool_calls_obj()
                        for i, t in enumerate(tcs):
                            yield chunk(delta=dict(tool_calls=[dict(index=i, id=t["id"], type="function", function=dict(name=t["function"]["name"], arguments=""))]))
                            yield chunk(delta=dict(tool_calls=[dict(index=i, function=dict(arguments=t["function"]["arguments"]))]))
                    yield chunk(delta={}, fr=finish, text_="")
                    if include:
                        yield chunk(usage_=usage_now())
                    yield "data: [DONE]\n\n"
                    http_obs(request.url.path, "POST", 200, rbytes, 0, req.e2e or 0.0)
                except asyncio.CancelledError:
                    engine.abort(req)
                    raise
                except GeneratorExit:
                    engine.abort(req)
                    raise
            return StreamingResponse(gen(), media_type="text/event-stream", headers={"cache-control": "no-cache"})
        try:
            await req.done.wait()
        except asyncio.CancelledError:
            engine.abort(req)
            raise
        text_out = "".join(pieces)
        if endpoint == "chat":
            msg = dict(role="assistant", content=None if tool_calls else text_out, refusal=None, annotations=None, audio=None,
                       function_call=None, tool_calls=tool_calls_obj() if tool_calls else [], reasoning_content=None)
            obj = dict(id=rid, object="chat.completion", created=created, model=model,
                       choices=[dict(index=0, message=msg, logprobs=None, finish_reason=finish, stop_reason=None, token_ids=None)],
                       service_tier=None, system_fingerprint=None, usage=usage_now(), prompt_logprobs=None, kv_transfer_params=None)
        else:
            if body.get("echo") and isinstance(body.get("prompt"), str):
                text_out = body["prompt"] + text_out
            obj = dict(id=rid, object="text_completion", created=created, model=model,
                       choices=[dict(index=0, text=text_out, logprobs=None, finish_reason=finish, stop_reason=None, token_ids=None, prompt_logprobs=None)],
                       service_tier=None, system_fingerprint=None, usage=usage_now(), kv_transfer_params=None)
        data = json.dumps(obj)
        http_obs(request.url.path, "POST", 200, rbytes, len(data), req.e2e or 0.0)
        return Response(data, media_type="application/json")

    async def handle(request, endpoint):
        headers = {k.lower(): v for k, v in request.headers.items()}
        er = pre(request, headers) or injected()
        if er is None:
            er = check_crash()
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise ValueError
        except Exception:
            return oai_error(400, "Invalid JSON body", "BadRequestError")
        model = body.get("model") or names[0]
        if er is not None:
            count(model, endpoint, er.status_code)
            record(dict(endpoint=endpoint, model=model, headers=headers), dict(status=er.status_code, injected=True))
            http_obs(request.url.path, "POST", er.status_code, int(headers.get("content-length", 0) or 0), 0, 0.001)
            return er
        if model not in names:
            count(model, endpoint, 404)
            return oai_error(404, f"The model `{model}` does not exist.", "NotFoundError")
        if endpoint == "embeddings":
            return embeddings(request, body, model, headers)
        if endpoint == "chat" and not isinstance(body.get("messages"), list):
            return oai_error(400, "messages: field required", "BadRequestError")
        return await generate(request, endpoint, body, model)

    def embed_vec(text):
        v = [0.0] * edim
        for tok in re.findall(r"\w+", text.lower()) or ["<empty>"]:
            h = hashlib.sha256(f"{seed}|{tok}".encode()).digest()
            for j in range(2):
                idx = int.from_bytes(h[j * 4:j * 4 + 4], "big") % edim
                v[idx] += 1.0 if h[8 + j] & 1 else -1.0
        n = sum(x * x for x in v) ** 0.5 or 1.0
        return [x / n for x in v]

    def embeddings(request, body, model, headers):
        inp = body.get("input", "")
        items = inp if isinstance(inp, list) and not (inp and isinstance(inp[0], int)) else [inp]
        items = [i if isinstance(i, str) else " ".join(map(str, i)) for i in items]
        fmt = body.get("encoding_format", "float")
        data = []
        for i, t in enumerate(items):
            v = embed_vec(t)
            data.append(dict(index=i, object="embedding", embedding=base64.b64encode(struct.pack(f"<{edim}f", *v)).decode() if fmt == "base64" else v))
        n = sum(est_tokens(t) for t in items)
        S["tokens"]["prompt"] += n
        count(model, "embeddings", 200)
        record(dict(endpoint="embeddings", model=model, headers=headers),
               dict(status=200, n_inputs=len(items), prompt_tokens_est=n, first_input=items[0][:200] if items else None, stream=False, user=body.get("user")))
        out = json.dumps(dict(id=new_id("embd"), object="list", created=int(time.time()), model=model, data=data,
                              usage=dict(prompt_tokens=n, total_tokens=n, completion_tokens=0, prompt_tokens_details=None)))
        http_obs(request.url.path, "POST", 200, int(headers.get("content-length", 0) or 0), len(out), 0.001)
        return Response(out, media_type="application/json")

    @app.post("/v1/chat/completions")
    async def chat(request: Request):
        return await handle(request, "chat")

    @app.post("/v1/completions")
    async def comp(request: Request):
        return await handle(request, "completions")

    @app.post("/v1/embeddings")
    async def emb(request: Request):
        return await handle(request, "embeddings")

    @app.get("/v1/models")
    async def models():
        if loading():
            return oai_error(503, "Service Unavailable: model is still loading", "ServiceUnavailable")
        return dict(object="list", data=[dict(id=n, object="model", created=int(time.time()), owned_by="vllm", root=args["model"], parent=None,
                                              max_model_len=cap["max_model_len"],
                                              permission=[dict(id="modelperm-" + sha(n, n=16), object="model_permission", created=int(time.time()),
                                                               allow_create_engine=False, allow_sampling=True, allow_logprobs=True, allow_search_indices=False,
                                                               allow_view=True, allow_fine_tuning=False, organization="*", group=None, is_blocking=False)])
                                        for n in names])

    @app.get("/health")
    async def health():
        if loading():
            return JSONResponse({"status": "loading"}, status_code=503)
        return Response(status_code=200)

    @app.get("/version")
    async def version():
        return {"version": VERSION}

    @app.get("/metrics")
    async def metrics_ep():
        engine.snapshot_gauges()
        from prometheus_client import REGISTRY
        return Response(metrics.render() + generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)

    # ---- admin
    @app.get("/admin/fault")
    async def fault_get():
        return dict(faults)

    @app.post("/admin/fault")
    async def fault_set(request: Request):
        try:
            b = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON"}, status_code=400)
        bad = [k for k in b if k not in FAULT_DEFAULTS]
        if bad:
            return JSONResponse({"error": f"unknown fault keys {bad}; allowed {sorted(FAULT_DEFAULTS)}"}, status_code=400)
        try:
            for k, v in b.items():
                faults[k] = bool(v) if k == "crash" else float(v) if k != "latency_ms" else float(v)
        except (TypeError, ValueError):
            return JSONResponse({"error": "values must be numbers (crash: bool)"}, status_code=400)
        if not 0 <= faults["error_rate"] <= 1 or not 0 <= faults["kv_pressure"] <= 1:
            return JSONResponse({"error": "error_rate and kv_pressure must be within 0..1"}, status_code=400)
        if "slow_load_s" in b:
            S["ready_at"] = time.monotonic() + faults["slow_load_s"]
        if faults["crash"]:
            check_crash()
        return dict(faults)

    @app.delete("/admin/fault")
    async def fault_del():
        faults.clear()
        faults.update(FAULT_DEFAULTS)
        S["ready_at"] = 0
        return dict(faults)

    @app.get("/admin/stats")
    async def stats():
        engine.snapshot_gauges()
        return dict(
            model=mname, served_model_names=names, boot_id=S["boot"], seed=seed, time_scale=scale,
            requests=S["counters"], tokens=dict(S["tokens"]), errors_injected=S["errors_injected"],
            engine=dict(virtual_time_s=round(engine.clock, 6), running=len(engine.running), waiting=len(engine.waiting) + len(engine.inbox),
                        kv_cache_usage=round(engine.kv_usage(), 6), kv_peak_usage=round(engine.peak_kv, 6), free_blocks=engine.free,
                        usable_blocks=engine.usable, preemptions=engine.preemptions, completed=engine.completed, steps=engine.steps,
                        prefix_cache_blocks=len(engine.prefix)),
            capacity={k: v for k, v in cap.items() if k != "gpu"}, gpu=cap["gpu"], faults=dict(faults),
            script=dict(enabled=script.enabled, rules=[r.get("name") for r in script.rules]),
            last_requests=S["last"])

    @app.delete("/admin/stats")
    async def stats_reset():
        S["counters"].clear()
        S["last"].clear()
        S["tokens"].update(prompt=0, completion=0)
        S["errors_injected"] = 0
        return {"status": "reset (Prometheus counters are NOT reset)"}

    return app
