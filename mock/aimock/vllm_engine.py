"""Continuous-batching scheduler simulation on a virtual clock.

All metric values are derived from the virtual clock (never wall time), so identical load gives identical metrics.
Wall-clock pacing (sleeping virtual_dt / time_scale) only makes occupancy observable to real clients.
"""
import asyncio, math, time
from collections import OrderedDict, deque
from .common import sha

COLLECT_WINDOW_S = 0.02
IDLE_TICK = 0.005


class Req:
    def __init__(self, rid, prompt_len, out_total, max_tokens, prefix_text, finish_reason, latency_s=0.0, pieces=None):
        self.rid = rid
        self.prompt_len = prompt_len
        self.out_total = out_total
        self.max_tokens = max_tokens
        self.finish_reason = finish_reason
        self.prefix_text = prefix_text
        self.key = sha(prefix_text, n=10)
        self.latency_s = latency_s
        self.pieces = pieces
        self.q = asyncio.Queue()
        self.done = asyncio.Event()
        self.arrival = 0.0
        self.first_sched = None
        self.first_token_t = None
        self.last_tok_t = None
        self.finish_t = None
        self.generated = 0
        self.ctx = 0
        self.blocks = 0
        self.pf_rem = 0
        self.cached = 0
        self.preempts = 0
        self.stall_until = 0.0
        self.state = "new"
        self.reason = None
        self.ttft = None
        self.e2e = None
        self.queue_time = None


class Engine:
    def __init__(self, cap, metrics, time_scale=1.0, faults=None):
        self.cap, self.m = cap, metrics
        self.bs = cap["block_size"]
        self.usable = cap["usable_blocks"]
        self.free = self.usable
        self.faults = faults or {}
        self.clock = 0.0
        self.busy_v = 0.0
        self.inbox, self.waiting, self.running = [], deque(), []
        self.prefix = OrderedDict()
        self.time_scale = time_scale
        self.wake = asyncio.Event()
        self.preemptions = 0
        self.steps = 0
        self.peak_kv = 0.0
        self.completed = 0
        bw = cap["mem_bandwidth_gbs"] * 1e9 * 0.65
        self.dec_base = cap["weights_bytes_per_gpu"] / bw + 0.001
        self.dec_kv = cap["kv_bytes_per_token_per_gpu"] / bw
        self.dec_seq = 2e-5
        self.pf_tps = cap["tflops"] * 1e12 * 0.4 * cap["tp"] / (2.0 * cap["params"])
        self.flops_per_tok = 2.0 * cap["params"] / cap["tp"]
        self._task = None

    # ------------------------------------------------------------ state
    def pinned(self):
        return int(float(self.faults.get("kv_pressure") or 0.0) * self.usable)

    def avail(self):
        return self.free - self.pinned()

    def kv_usage(self):
        return min(1.0, ((self.usable - self.free) + max(0, self.pinned())) / self.usable) if self.usable else 0.0

    def blocks_for(self, tokens):
        return -(-tokens // self.bs)

    def snapshot_gauges(self):
        self.m.set("vllm:num_requests_running", len(self.running))
        w = len(self.waiting) + len(self.inbox)
        self.m.set("vllm:num_requests_waiting", w)
        self.m.set("vllm:num_requests_waiting_by_reason", w, reason="capacity")
        self.m.set("vllm:num_requests_waiting_by_reason", 0, reason="deferred")
        self.m.set("vllm:kv_cache_usage_perc", self.kv_usage())

    # ------------------------------------------------------------ API
    def submit(self, req):
        req.arrival = self.clock
        req.state = "waiting"
        self.inbox.append(req)
        self.wake.set()

    def abort(self, req):
        if req.state == "done":
            return
        for coll in (self.inbox, self.waiting, self.running):
            if req in coll:
                coll.remove(req)
        self.free += req.blocks
        req.blocks = 0
        req.state, req.reason = "done", "abort"
        self.m.inc("vllm:request_success", finished_reason="abort")
        req.q.put_nowait(("done", "abort"))
        req.done.set()

    def start(self):
        self._task = asyncio.get_event_loop().create_task(self.run())

    # ------------------------------------------------------------ prefix cache
    def _hashes(self, text):
        step = self.bs * 4
        h, out = "", []
        for i in range(0, len(text) - step + 1, step):
            h = sha(h, text[i:i + step], n=12)
            out.append(h)
        return out

    def _prefix_lookup(self, req):
        if not self.cap["prefix_caching"]:
            return 0
        hits = 0
        for h in self._hashes(req.prefix_text):
            if h in self.prefix:
                self.prefix.move_to_end(h)
                hits += 1
            else:
                break
        return min(hits * self.bs, max(0, req.prompt_len - 1))

    def _prefix_insert(self, req):
        if not self.cap["prefix_caching"]:
            return
        for h in self._hashes(req.prefix_text):
            self.prefix[h] = None
            self.prefix.move_to_end(h)
        while len(self.prefix) > self.usable:
            self.prefix.popitem(last=False)

    # ------------------------------------------------------------ scheduling
    def _preempt(self, r):
        self.running.remove(r)
        self.free += r.blocks
        r.blocks = 0
        r.preempts += 1
        r.pf_rem = r.ctx
        r.state = "waiting"
        self.waiting.appendleft(r)
        self.preemptions += 1
        self.m.inc("vllm:num_preemptions")

    def step(self):
        now = self.clock
        if self.inbox:
            self.inbox.sort(key=lambda r: (r.arrival, r.key))
            self.waiting.extend(self.inbox)
            self.inbox.clear()
        budget = self.cap["max_num_batched_tokens"]
        # 1) decoders (growth may preempt the newest running request)
        decoders = [r for r in self.running if r.pf_rem == 0 and r.stall_until <= now]
        for r in list(decoders):
            if r not in self.running:
                decoders.remove(r)
                continue
            need = self.blocks_for(r.ctx + 1) - r.blocks
            while need > 0 and self.avail() < need and self.running:
                victim = self.running[-1]
                self._preempt(victim)
                if victim in decoders:
                    decoders.remove(victim)
                if victim is r:
                    break
            if r in self.running and need > 0:
                self.free -= need
                r.blocks += need
        budget -= len(decoders)
        # 2) continue chunked prefill
        pf = 0
        pf_done = []
        for r in self.running:
            if r.pf_rem > 0 and r.stall_until <= now and budget > 0:
                n = min(r.pf_rem, budget)
                r.pf_rem -= n
                budget -= n
                pf += n
                if r.pf_rem == 0:
                    pf_done.append(r)
        # 3) admit
        while self.waiting and len(self.running) < self.cap["max_num_seqs"] and budget > 0:
            r = self.waiting[0]
            total_ctx = r.ctx if r.preempts and r.ctx else r.prompt_len
            need = self.blocks_for(total_ctx)
            if self.avail() < need:
                break
            self.waiting.popleft()
            self.running.append(r)
            self.free -= need
            r.blocks = need
            first = r.first_sched is None
            if first:
                r.first_sched = now
                r.queue_time = now - r.arrival
                r.cached = self._prefix_lookup(r)
                self.m.inc("vllm:prefix_cache_queries", r.prompt_len)
                self.m.inc("vllm:prefix_cache_hits", r.cached)
                self.m.inc("vllm:prompt_tokens_cached", r.cached)
                r.stall_until = now + r.latency_s
                r.pf_rem = r.prompt_len - r.cached
                r.ctx = r.prompt_len
            else:
                r.pf_rem = r.ctx
            r.state = "running"
            if r.stall_until <= now:
                n = min(r.pf_rem, budget)
                r.pf_rem -= n
                budget -= n
                pf += n
                if r.pf_rem == 0:
                    pf_done.append(r)
        # time
        dt = 0.0
        if decoders:
            dt += self.dec_base + self.dec_kv * sum(r.ctx for r in decoders) + self.dec_seq * len(decoders)
        if pf:
            dt += pf / self.pf_tps
            if not decoders:
                dt += 0.0005
        if dt == 0.0:
            stalls = [r.stall_until - now for r in self.running if r.stall_until > now]
            dt = min(stalls) if stalls else IDLE_TICK
        end = now + dt
        events = []
        toks = 0
        for r in decoders:
            if r.state != "running":
                continue
            self._emit(r, end, events)
            toks += 1
        for r in pf_done:
            if r.state != "running":
                continue
            if r.generated == 0:
                self.m.inc("vllm:prompt_tokens", r.prompt_len)
                self.m.inc("vllm:prompt_tokens_by_source", r.prompt_len - r.cached, source="local_compute")
                self.m.inc("vllm:prompt_tokens_by_source", r.cached, source="local_cache_hit")
                self._prefix_insert(r)
            need = self.blocks_for(r.ctx + 1) - r.blocks
            if need > 0 and self.avail() >= need:
                self.free -= need
                r.blocks += need
            self._emit(r, end, events)
            toks += 1
        tot = toks + pf
        if tot:
            self.m.obs("vllm:iteration_tokens_total", tot)
            self.m.inc("vllm:estimated_flops_per_gpu", self.flops_per_tok * tot)
            self.m.inc("vllm:estimated_read_bytes_per_gpu", self.cap["weights_bytes_per_gpu"] * (1 if tot else 0))
            self.m.inc("vllm:estimated_write_bytes_per_gpu", self.cap["kv_bytes_per_token_per_gpu"] * tot)
        self.clock = end
        self.peak_kv = max(self.peak_kv, self.kv_usage())
        self.steps += 1
        return dt, events

    def _emit(self, r, t, events):
        r.generated += 1
        r.ctx += 1
        self.m.inc("vllm:generation_tokens")
        if r.first_token_t is None:
            r.first_token_t = t
            r.ttft = t - r.arrival
            self.m.obs("vllm:time_to_first_token_seconds", r.ttft)
        else:
            self.m.obs("vllm:inter_token_latency_seconds", t - r.last_tok_t)
        r.last_tok_t = t
        events.append((r, "tok", r.generated - 1))
        if r.generated >= r.out_total:
            self._finish(r, t, events)

    def _finish(self, r, t, events):
        self.running.remove(r)
        self.free += r.blocks
        r.blocks = 0
        r.state, r.reason, r.finish_t = "done", r.finish_reason, t
        r.e2e = t - r.arrival
        m = self.m
        decode = t - r.first_token_t
        m.obs("vllm:e2e_request_latency_seconds", r.e2e)
        m.obs("vllm:request_queue_time_seconds", r.queue_time)
        m.obs("vllm:request_inference_time_seconds", t - r.first_sched)
        m.obs("vllm:request_prefill_time_seconds", r.first_token_t - r.first_sched)
        m.obs("vllm:request_decode_time_seconds", decode)
        if r.generated > 1:
            m.obs("vllm:request_time_per_output_token_seconds", decode / (r.generated - 1))
        m.obs("vllm:request_prompt_tokens", r.prompt_len)
        m.obs("vllm:request_generation_tokens", r.generated)
        m.obs("vllm:request_max_num_generation_tokens", r.max_tokens)
        m.obs("vllm:request_params_n", 1)
        m.obs("vllm:request_params_max_tokens", r.max_tokens)
        m.obs("vllm:request_num_preemptions", r.preempts)
        m.obs("vllm:request_prefill_kv_computed_tokens", r.prompt_len - r.cached)
        m.inc("vllm:request_success", finished_reason=r.finish_reason)
        self.completed += 1
        events.append((r, "done", r.finish_reason))

    # ------------------------------------------------------------ loop
    async def run(self):
        real0 = time.monotonic()
        busy0 = self.busy_v
        while True:
            if not (self.inbox or self.waiting or self.running):
                self.wake.clear()
                await self.wake.wait()
                await asyncio.sleep(COLLECT_WINDOW_S)
                real0, busy0 = time.monotonic(), self.busy_v
            try:
                dt, events = self.step()
            except Exception as e:  # keep the engine alive; surface in logs
                import traceback
                traceback.print_exc()
                await asyncio.sleep(0.1)
                continue
            self.busy_v += dt
            if self.time_scale > 0:
                delay = real0 + (self.busy_v - busy0) / self.time_scale - time.monotonic()
                await asyncio.sleep(delay if delay > 0.004 else 0)
            else:
                await asyncio.sleep(0)
            for r, kind, val in events:
                r.q.put_nowait((kind, val))
                if kind == "done":
                    r.done.set()
