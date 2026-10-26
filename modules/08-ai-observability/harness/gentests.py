#!/usr/bin/env python3
"""Generate promtool test files (JSON-as-YAML) for module 08 into OUTDIR. Stdlib only.
   gentests.py OUTDIR REPO_REL   (REPO_REL = path from OUTDIR to modules/08-ai-observability, e.g. ../..)
Rule files under test are the LEARNER's: lab/prometheus/rules/ai-recording.yml and ai-alerts.yml."""
import json, os, sys

OUT = sys.argv[1]; REL = sys.argv[2]
REC = f"{REL}/lab/prometheus/rules/ai-recording.yml"
ALR = f"{REL}/lab/prometheus/rules/ai-alerts.yml"
STEP = 15  # seconds, test evaluation interval
BASE = dict(job="vllm", model_name="chat", engine="0")


def lab(**kw):
    d = dict(BASE); d.update(kw)
    return ",".join(f'{k}="{v}"' for k, v in d.items())


def ramp(rate_per_s, n=80, start=0.0):
    """counter samples every STEP s: start, start+r*STEP, ... (n+1 samples)"""
    return " ".join(f"{start + rate_per_s * STEP * i:g}" for i in range(n + 1))


def const(v, n=80):
    return " ".join(f"{v:g}" for _ in range(n + 1))


def hist_series(name, replica, cum_rates, n=80, extra=""):
    out = []
    for le, r in cum_rates.items():
        out.append({"series": f'{name}_bucket{{{lab(replica=replica, instance="mock-vllm-%s:8000" % replica)},le="{le}"}}',
                    "values": ramp(r, n)})
    return out


def quantile(cum, q):
    items = sorted(((float(k) if k != "+Inf" else float("inf"), v) for k, v in cum.items()))
    tot = items[-1][1]; rank = q * tot; pl, pc = 0.0, 0.0
    for le, c in items:
        if c >= rank:
            return pl + (le - pl) * (rank - pc) / (c - pc) if c > pc and le != float("inf") else pl
        pl, pc = le, c


def add(a, b):
    return {k: a.get(k, 0) + b.get(k, 0) for k in set(a) | set(b)}


def write(name, rule_files, tests):
    doc = {"rule_files": rule_files, "evaluation_interval": f"{STEP}s", "tests": tests}
    json.dump(doc, open(os.path.join(OUT, name), "w"), indent=1)


def exp(expr, t, samples):
    return {"expr": expr, "eval_time": t, "exp_samples": samples}


TTFT = "vllm:time_to_first_token_seconds"
ITL = "vllm:inter_token_latency_seconds"

# ---------------------------------------------------------------- 8.2 recording rules
A = {"0.1": 2, "0.25": 6, "0.5": 8, "1.0": 10, "2.5": 10, "+Inf": 10}   # replica a: 10 req/s, fast
B = {"0.1": 0, "0.25": 0, "0.5": 0, "1.0": 0.4, "2.5": 2, "+Inf": 2}    # replica b: 2 req/s, slow
tot = add(A, B)
p95 = quantile(tot, 0.95)
ia = {"0.01": 5, "0.025": 8, "0.05": 9.5, "0.1": 10, "+Inf": 10}
ib = {"0.01": 0, "0.025": 0, "0.05": 0.5, "0.1": 2, "+Inf": 2}
p95i = quantile(add(ia, ib), 0.95)
series = (hist_series(TTFT, "a", A) + hist_series(TTFT, "b", B) + hist_series(ITL, "a", ia) + hist_series(ITL, "b", ib) +
          [{"series": f'vllm:generation_tokens_total{{{lab(replica="a", instance="mock-vllm-a:8000")}}}', "values": ramp(100)},
           {"series": f'vllm:generation_tokens_total{{{lab(replica="b", instance="mock-vllm-b:8000")}}}', "values": ramp(40)}])


def close(expr, v, tol=0.10):  # 1 when |expr - v| <= tol*v for ANY series (max of bool)
    return f"max(abs(({expr}) - {v}) / {v} < bool {tol})"


write("rec.test.yml", [REC], [{"interval": f"{STEP}s", "input_series": series, "promql_expr_test": [
    exp(close("model:vllm_ttft_seconds:p95_5m", p95), "8m", [{"labels": "{}", "value": 1}]),
    exp(close("model:vllm_itl_seconds:p95_5m", p95i), "8m", [{"labels": "{}", "value": 1}]),
    exp(close("model:vllm_generation_tokens:rate1m", 140), "8m", [{"labels": "{}", "value": 1}]),
]}])
json.dump({"ttft_p95": p95, "itl_p95": p95i}, open(os.path.join(OUT, "rec.expected.json"), "w"))

# ---------------------------------------------------------------- 8.4 alerts
def gauge(name, replica, vals):
    return {"series": f'{name}{{{lab(replica=replica, instance="mock-vllm-%s:8000" % replica)}}}', "values": vals}


def firing(alert, extra=""):
    return f'count(ALERTS{{alertname="{alert}",alertstate="firing"{extra}}})'


def anyst(alert):
    return f'count(ALERTS{{alertname="{alert}"}})'


W = {"severity": "warning", "team": "llm-platform"}
wsel = ',severity="warning",team="llm-platform"'
zero = const(0); flat_pre = const(0)
tests_kv = [
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:kv_cache_usage_perc", "a", const(0.95)), gauge("vllm:num_requests_waiting", "a", const(4)),
                                                {"series": f'vllm:num_preemptions_total{{{lab(replica="a", instance="mock-vllm-a:8000")}}}', "values": flat_pre}],
     "promql_expr_test": [exp(firing("KVCacheNearFull"), "1m", []), exp(firing("KVCacheNearFull", wsel), "6m", [{"labels": "{}", "value": 1}])]},
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:kv_cache_usage_perc", "a", const(0.95)), gauge("vllm:num_requests_waiting", "a", zero),
                                                {"series": f'vllm:num_preemptions_total{{{lab(replica="a", instance="mock-vllm-a:8000")}}}', "values": flat_pre}],
     "promql_expr_test": [exp(anyst("KVCacheNearFull"), "6m", []), exp(anyst("KVCacheNearFull"), "15m", [])]},
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:kv_cache_usage_perc", "a", const(0.95)), gauge("vllm:num_requests_waiting", "a", zero),
                                                {"series": f'vllm:num_preemptions_total{{{lab(replica="a", instance="mock-vllm-a:8000")}}}', "values": ramp(0.05)}],
     "promql_expr_test": [exp(firing("KVCacheNearFull", wsel), "8m", [{"labels": "{}", "value": 1}])]},
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:kv_cache_usage_perc", "a", const(0.5)), gauge("vllm:num_requests_waiting", "a", const(9)),
                                                {"series": f'vllm:num_preemptions_total{{{lab(replica="a", instance="mock-vllm-a:8000")}}}', "values": ramp(0.05)}],
     "promql_expr_test": [exp(anyst("KVCacheNearFull"), "10m", [])]},
]
write("kv.test.yml", [REC, ALR], tests_kv)

SLOW = {"0.25": 1, "0.5": 2, "1.0": 4, "2.5": 10, "5.0": 10, "+Inf": 10}      # p95 about 2.1 s
FAST = {"0.1": 5, "0.25": 9, "0.5": 10, "1.0": 10, "+Inf": 10}               # p95 well below 1 s
write("ttft.test.yml", [REC, ALR], [
    {"interval": f"{STEP}s", "input_series": hist_series(TTFT, "a", SLOW),
     "promql_expr_test": [exp(firing("TTFTHigh"), "1m30s", []), exp(firing("TTFTHigh", ',severity="critical",team="llm-platform"'), "8m", [{"labels": "{}", "value": 1}])]},
    {"interval": f"{STEP}s", "input_series": hist_series(TTFT, "a", FAST),
     "promql_expr_test": [exp(anyst("TTFTHigh"), "10m", [])]},
])

q_vals_hi = const(8)
q_vals_lo = const(3)
spike = " ".join(["8"] * 5 + ["0"] * 76)  # 1 minute of 8 then quiet
write("queue.test.yml", [REC, ALR], [
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:num_requests_waiting", "a", q_vals_hi)],
     "promql_expr_test": [exp(firing("QueueGrowing"), "2m", []), exp(firing("QueueGrowing", wsel), "5m", [{"labels": "{}", "value": 1}])]},
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:num_requests_waiting", "a", q_vals_lo)],
     "promql_expr_test": [exp(anyst("QueueGrowing"), "10m", [])]},
    {"interval": f"{STEP}s", "input_series": [gauge("vllm:num_requests_waiting", "a", spike)],
     "promql_expr_test": [exp(anyst("QueueGrowing"), "10m", [])]},
])

# ---------------------------------------------------------------- 8.6 panel query (expr injected by verify via PANEL_EXPR env into panel.test.yml)
if os.environ.get("PANEL_EXPR"):
    pe = os.environ["PANEL_EXPR"]
    MIX = {"0.1": 5, "0.25": 8, "0.5": 9.6, "1.0": 10, "2.5": 10, "5.0": 10, "+Inf": 10}
    # step change at t=600s: before all fast; after 20% slow (in the 2.5-5 s bucket)
    def stepped(fast_rate, slow_share, replica, n=80):
        out = []
        t_change = 40  # samples (600 s / 15)
        for le in ["0.1", "0.25", "0.5", "1.0", "2.5", "5.0", "+Inf"]:
            pre = fast_rate * {"0.1": 0.5, "0.25": 0.9, "0.5": 1, "1.0": 1, "2.5": 1, "5.0": 1, "+Inf": 1}[le]
            post_fast = fast_rate * (1 - slow_share)
            post = post_fast * {"0.1": 0.5, "0.25": 0.9, "0.5": 1, "1.0": 1, "2.5": 1, "5.0": 1, "+Inf": 1}[le]
            if le in ("5.0", "+Inf"):
                post = fast_rate  # all requests, slow ones land in (2.5, 5]
            vals, c = [0.0], 0.0
            for i in range(n):
                c += (pre if i < t_change else post) * STEP
                vals.append(c)
            out.append({"series": f'{TTFT}_bucket{{{lab(replica=replica, instance="mock-vllm-%s:8000" % replica)},le="{le}"}}', "values": " ".join(f"{x:g}" for x in vals)})
        return out
    def steady(replica, rate):
        return hist_series(TTFT, replica, {k: v * rate / 10.0 for k, v in MIX.items()})
    ref = quantile(MIX, 0.95)
    tests_panel = [
        {"interval": f"{STEP}s", "input_series": steady("a", 10) + steady("b", 3) +
            [{"series": f'{TTFT}_sum{{{lab(replica=r, instance="mock-vllm-%s:8000" % r)}}}', "values": ramp(rate * 0.3)} for r, rate in (("a", 10), ("b", 3))] +
            [{"series": f'{TTFT}_count{{{lab(replica=r, instance="mock-vllm-%s:8000" % r)}}}', "values": ramp(rate)} for r, rate in (("a", 10), ("b", 3))],
         "promql_expr_test": [exp(close(pe, ref, 0.10), "10m", [{"labels": "{}", "value": 1}])]},
        {"interval": f"{STEP}s", "input_series": stepped(10, 0.2, "a") + stepped(4, 0.2, "b") +
            [{"series": f'{TTFT}_sum{{{lab(replica=r, instance="mock-vllm-%s:8000" % r)}}}', "values": ramp(rate * 0.3)} for r, rate in (("a", 10), ("b", 4))] +
            [{"series": f'{TTFT}_count{{{lab(replica=r, instance="mock-vllm-%s:8000" % r)}}}', "values": ramp(rate)} for r, rate in (("a", 10), ("b", 4))],
         "promql_expr_test": [exp(f"max(({pe}) < bool 0.6)", "8m", [{"labels": "{}", "value": 1}]),
                              exp(f"max(({pe}) > bool 2.0)", "14m", [{"labels": "{}", "value": 1}])]},
    ]
    write("panel.a.test.yml", [], tests_panel[:1])
    write("panel.b.test.yml", [], tests_panel[1:])
