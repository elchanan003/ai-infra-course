"""Builds the vLLM metric families from vllm_metrics_spec.json (generated from the golden /metrics capture)."""
import json, os
from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, Summary, generate_latest

SPEC = json.load(open(os.path.join(os.path.dirname(__file__), "vllm_metrics_spec.json")))


class VllmMetrics:
    def __init__(self, model_name, cap, args):
        self.reg = CollectorRegistry()
        self.model_name = model_name
        self.fam = {}
        for e in SPEC:
            n, t, h, ln = e["name"], e["type"], e["help"], e["labelnames"]
            if t == "counter":
                m = Counter(n, h, ln, registry=self.reg)
            elif t == "gauge":
                m = Gauge(n, h, ln, registry=self.reg)
            elif t == "histogram":
                m = Histogram(n, h, ln, buckets=e["buckets"] + [float("inf")], registry=self.reg)
            elif t == "summary":
                m = Summary(n, h, ln, registry=self.reg)
            else:
                raise ValueError(t)
            self.fam[n] = (m, e)
            for ch in e["children"]:
                if ln:
                    kv = dict(zip(ln, ch))
                    if "model_name" in kv:
                        kv["model_name"] = model_name
                    if n == "vllm:cache_config_info":
                        continue
                    m.labels(**kv)
                else:
                    pass
        self.set_cache_config(cap, args)

    def set_cache_config(self, cap, args):
        m, e = self.fam["vllm:cache_config_info"]
        kv = dict(zip(e["labelnames"], e["children"][0]))
        kv.update(block_size=cap["block_size"], effective_attention_block_size=cap["block_size"],
                  user_specified_block_size=args.get("block-size") if args.get("block-size") else "None",
                  cache_dtype=args["kv-cache-dtype"], enable_prefix_caching=str(bool(cap["prefix_caching"])),
                  gpu_memory_utilization=str(cap["gpu_memory_utilization"]),
                  kv_cache_max_concurrency=str(cap["max_concurrency"]), kv_cache_memory_bytes=str(cap["kv_cache_memory_bytes"]),
                  kv_cache_size_tokens=str(cap["kv_cache_size_tokens"]), num_gpu_blocks=str(cap["num_gpu_blocks"]),
                  engine="0")
        m.labels(**kv).set(1)

    def _lab(self, name, **extra):
        m, e = self.fam[name]
        kv = {"engine": "0", "model_name": self.model_name}
        kv.update(extra)
        return m.labels(**kv) if e["labelnames"] else m

    def inc(self, name, v=1.0, **extra):
        self._lab(name, **extra).inc(v)

    def set(self, name, v, **extra):
        self._lab(name, **extra).set(v)

    def obs(self, name, v, **extra):
        self._lab(name, **extra).observe(v)

    def render(self):
        return generate_latest(self.reg)
