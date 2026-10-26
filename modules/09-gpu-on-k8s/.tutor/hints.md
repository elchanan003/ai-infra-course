# 09 — Hint ladder (tutor only). H1 nudge, H2 concept, H3 partial, H4 full (only if asked or stuck after H3). Log per task.

## 9.1 Read the fake nvidia-smi
- H1: Which column compares GPUs by heat? Are all GPUs on a node the same model?
- H2: Index is an enumeration order, UUID is the identity. The table shows memory in MiB and power as draw/cap. Compare rows, do not assume GPU 0.
- H3: `bin/smi A --query-gpu=index,uuid,temperature.gpu,memory.total,power.limit --format=csv` gives one row per GPU. Take the row with the highest temperature; memory.total and power.limit are in that row.
- H4: Run the query above, pick the max-temperature row, write its index, uuid, memory.total (integer) and power.limit (integer watts) into `smi.env`.

## 9.2 Alert rules
- H1: Is each of the four metrics a gauge, a counter, or "last value"? Which PromQL function suits each?
- H2: XID holds the last code until reset: alert on state (`> 0`), short `for`. Temperature is noisy: `for: 2m`. ECC totals are counters: `increase()`. A leak is a trajectory: compare a prediction with the card total, not just a positive slope. Keep labels with `by (Hostname, gpu, UUID)` (or do not aggregate).
- H3: `max by (Hostname, gpu, UUID) (DCGM_FI_DEV_XID_ERRORS) > 0`; `... (DCGM_FI_DEV_GPU_TEMP) > 85` `for: 2m`; `increase(DCGM_FI_DEV_ECC_DBE_VOL_TOTAL[5m]) > 0`; leak: `predict_linear(DCGM_FI_DEV_FB_USED[10m], 7200) > DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE` with a `for`.
- H4: see `.tutor/solution/prometheus/rules/dcgm-alerts.yml`.
- Common stalls: `changes()` for XID (never fires for a stuck value); `deriv() > 0` for the leak (fires on slow drift); `sum by` or `without` dropping UUID; SBE metric instead of DBE; `for: 5m` on XID (too slow for a live check); forgetting `../../platform/stack.sh reload-prometheus`.

## 9.3 Drain or wait?
- H1: Which series is non-zero on only one GPU across both nodes? Read its labels.
- H2: Classify the code: application-class (13, 31, 43: restart workload, wait) vs hardware-class (48, 63, 64, 74, 79, 95: cordon, drain, ticket). Cheatsheet and theory 3.3.
- H3: `curl -s localhost:18031/metrics | grep XID_ERRORS` and the same on :18032; find the line with a value > 0. The `UUID` label is the answer for XID_GPU_UUID; the port tells the node (18031 = A, 18032 = B).
- H4: Read code, node and UUID as above; ACTION = `wait` for 13/31/43, `drain` otherwise; REASON: one sentence with the class and the pre-drain checks.

## 9.4 Nodes advertise GPUs
- H1: Where in the node object does allocatable capacity live, and can plain `kubectl patch` reach it?
- H2: Extended resources are written to `status`, which is a subresource: `kubectl patch node N --subresource=status --type=json`. In a JSON pointer `/` is `~1`. Labels and taints are normal spec/metadata calls and are idempotent with `--overwrite`.
- H3: loop over inventory lines with `while read -r node count product mem _`; skip comments/blank; patch `add /status/capacity/nvidia.com~1gpu` and `/status/allocatable/nvidia.com~1gpu`; then `label --overwrite` x3, `taint --overwrite`.
- H4: `.tutor/solution/k8s/node-gpu.sh`.
- Common stalls: patching `capacity` only and checking immediately (kubelet needs a sync); hard-coded counts; taint without `--overwrite` fails on the second run (idempotency); forgetting `INVENTORY` env override.

## 9.5 GPU pod
- H1: Read the Pending message: is it capacity, taint or selector? Which of the three have you not handled yet?
- H2: GPU request goes into `resources.limits` (integer); a toleration for key `nvidia.com/gpu` effect `NoSchedule`; nodeSelector on the exact label value from the node.
- H3: `nodeSelector: {nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB}`, `tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]`, `resources: {limits: {nvidia.com/gpu: 1}}`.
- H4: `.tutor/solution/k8s/gpu-pod.yaml`.
- Common stalls: requests only (API error); `nvidia.com/gpu: "1"` quoted fine; label value typed from memory (`A100` vs full string).

## 9.6 Time-slicing ConfigMap
- H1: What type must a ConfigMap `data` value be? So what does `any:` contain?
- H2: A string holding the device-plugin config YAML (`any: |-`). `renameByDefault` and `failRequestsGreaterThanOne` belong to `sharing.timeSlicing`; `replicas` and `name` to the entry in `resources`.
- H3: structure `version: v1` / `sharing:` / `timeSlicing:` / `renameByDefault: true` / `failRequestsGreaterThanOne: true` / `resources: [{name: nvidia.com/gpu, replicas: 4}]` (theory 4.1).
- H4: `.tutor/solution/k8s/timeslicing-cm.yaml`.
- Common stalls: nested mapping directly under `data` (kubeconform: got object, want string); `replicas: "4"`; namespace missing (dry-run rejected); config placed in a ClusterPolicy instead.

## 9.7 TP=2 Deployment
- H1: Which three things does a TP=2 server need from its pod spec that a TP=1 server does not? What does a rolling update need?
- H2: `limits: nvidia.com/gpu: 2` in ONE pod; Memory `emptyDir` on `/dev/shm`; `strategy: Recreate` (or `maxSurge: 0, maxUnavailable: 1`) because surge needs a second pair of GPUs.
- H3: add `strategy.type: Recreate`, nodeSelector + toleration as in 9.5, `volumes: [{name: shm, emptyDir: {medium: Memory}}]` mounted at `/dev/shm`, and `--tensor-parallel-size 2` in the echoed command.
- H4: `.tutor/solution/k8s/vllm-tp2.yaml`.
- Common stalls: `maxSurge: 0` with `maxUnavailable: 0` (invalid); limit 2 but flag 1 (inconsistent); sizeLimit missing is fine.

## T Troubleshooting
- H1: `k describe pod broken-gpu`. Read the whole FailedScheduling message, count the buckets.
- H2: The scheduler records one reason per node. Compare the resource name in the pod with the keys of a node's `allocatable`; then look at taints.
- H3: Two independent causes: the resource name has a plural `s`, and there is no toleration for the GPU taint. Fixing only one changes the message but not the outcome.
- H4: `nvidia.com/gpus` -> `nvidia.com/gpu`; add `tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]`. Reapply: delete and recreate the pod (resources are immutable).
