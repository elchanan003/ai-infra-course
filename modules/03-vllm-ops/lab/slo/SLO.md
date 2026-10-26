# Given numbers for tasks 3.2, 3.3, 3.6, 3.8

## 3.2 (vllm-a, llama-3.1-8b on node-1: A10G 24 GiB, other process 0.5 GiB)
- Context floor required by the product: **57344** tokens (`--max-model-len` must be >= this).
- Utilization may not exceed 0.95 on this node.

## 3.3 (vllm-b)
- Load: 8 concurrent chat requests, each prompt ~2500 tokens, `max_tokens` 300
  (`python3 lab/tools/load.py --target b --preset task3`).
- Needed: all 8 run at the same time (peak `num_requests_running` >= 8), no preemption, all HTTP 200.

## 3.6 (slo/ — A100-80GB shared with another tenant: utilization fixed at 0.30, max length fixed at 4096)
Load family (verify uses the same family with another seed): one burst of 96 requests, prompt ~600 tokens, `max_tokens` ~300 (+-30%).

| SLO | Target |
|---|---|
| p95 inter-token latency | <= 0.1 s (at least 95% of inter-token gaps in the bucket `le="0.1"` or below) |
| Output throughput (generation tokens per **virtual** second of busy time) | >= 1450 tok/s |
| Preemptions | 0 |
TTFT is not graded here: in a single synchronized burst TTFT is just queue position; in production you gate TTFT on a realistic arrival process (module 08).

## 3.8 (vllm-t, node-2)
Same GPU type as node-1, but another process holds part of the GPU memory on node-2 (see `lab/vllm-t/gpu.node2.yaml`;
in production you would see it in `nvidia-smi`). Required headroom: configured utilization must be at least 0.02 below the free fraction.
