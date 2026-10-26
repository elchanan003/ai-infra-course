# 09 — Quiz

1. Draw the chain from a pod's `limits: nvidia.com/gpu: 1` down to the hardware. For each of driver, container toolkit, device plugin and GFD, name one failure and the visible symptom.
2. A manifest has `requests: {nvidia.com/gpu: 1}` only (no limits). What does the API server do? Why must requests equal limits for extended resources, and why can you not ask for `0.5`?
3. A pod is Pending: `0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 2 node(s) had untolerated taint {nvidia.com/gpu: present}`. Which node is the GPU node, what is the actual problem, and what minimal change fixes it? Which scheduler filter reports first when a node is both tainted and out of GPUs?
4. Three nodes: A has 2 free GPUs, B has 1 free, C has 1 free. A Deployment requests `nvidia.com/gpu: 2` with `--tensor-parallel-size 2`, replicas 2. How many pods run, where, and why? What does the second pod's Pending message look like?
5. You roll out a new version of a model Deployment that uses all 4 GPUs of a node, default `RollingUpdate` (maxSurge 25%). What happens, and what strategy settings fix it?
6. A vLLM TP=2 pod starts and then hangs/crashes with NCCL or "bus error" messages although both GPUs were allocated. What is the most likely manifest omission?
7. Given `nvidia-smi -L` output on node B in which GPU indexes 0 and 1 swapped after a reboot, why should alert annotations carry `UUID` rather than `gpu` index? Which identifier goes into the hardware ticket?
8. Write the PromQL (using dcgm-exporter names) for: (a) any GPU whose XID value is non-zero, keeping host/GPU/UUID; (b) a VRAM leak: framebuffer usage grew for 30 minutes at an almost constant request rate; (c) temperature above 85 C for 5 minutes. For (a), explain the behaviour difference between `> 0` and `changes(...[5m]) > 0`.
9. Classify XID 13, 31, 48, 63, 79, 94, 95 as "restart workload", "drain" or "reset at next window", and say what you check before draining a node.
10. Explain why GPU_UTIL = 100% does not mean the GPU is full. Give a case where it is 0% but the GPU is "busy" from the platform's point of view. Which engine-level metrics would you use for capacity?
11. Node config: time-slicing `replicas: 4`, `renameByDefault: false`, 8 physical GPUs. What does the node advertise? Why is a pod with `nvidia.com/gpu: 2` problematic, and what does `failRequestsGreaterThanOne: true` change? What is the main risk of running two LLM servers on one time-sliced GPU?
12. Compare MIG, time-slicing and MPS on memory isolation, fault isolation and operational cost of change. Which one for (a) a multi-tenant embedding service with latency SLOs, (b) developers' notebooks, (c) a 70B model?
13. Which MIG profile on an 80 GB H100 can hold a 7B bf16 model (about 15 GB weights) with a modest KV cache, and which MIG strategy lets one node expose both `1g.10gb` and `3g.40gb` devices under different resource names?
14. In this lab the kind node advertises GPUs by a status patch. List two ways in which this differs from a real device plugin, and one thing the scheduler cannot tell apart.
15. Why is the time-slicing ConfigMap in task 9.6 "validated, not exercised"? What would you check on a real cluster after applying it?
