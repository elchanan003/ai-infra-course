# Cheatsheet: GPUs on Kubernetes, DCGM, XID

(Pins: k8s 1.33, GPU Operator v26.7.2, device plugin 0.20.1, toolkit 1.20.1, dcgm-exporter 4.6.1-4.8.4. Lab: GPUs and DCGM data simulated; scheduler real.)

## Stack
pod `limits: nvidia.com/gpu` -> kubelet + device plugin `Allocate` -> containerd runtime `nvidia` -> Container Toolkit (CDI/hook: /dev/nvidia*, libcuda, nvidia-smi) -> driver -> GPU.
GPU Operator `ClusterPolicy` deploys: driver (optional), toolkit, device plugin, GFD, dcgm-exporter, MIG manager, validator (later stages wait in `Init` until earlier pass).
No GPUs on a node? `kubectl -n gpu-operator get pods -o wide`: logs of the earliest non-Running component. Air gap: mirror images, prebuild driver for the exact kernel or use host drivers (`driver.enabled=false`).

## Requesting GPUs
```yaml
spec:
  nodeSelector: {nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3}   # exact string, from GFD
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  containers:
  - name: vllm
    resources: {limits: {nvidia.com/gpu: 1}}   # limits only; integer; no overcommit
    volumeMounts: [{name: shm, mountPath: /dev/shm}]
  volumes: [{name: shm, emptyDir: {medium: Memory}}]
```
- TP=N -> `nvidia.com/gpu: N` in ONE pod on ONE node. Free GPUs spread over nodes do not help (fragmentation).
- Model fills the node: `strategy: Recreate` or `maxSurge: 0, maxUnavailable: 1`.
- Slow start: `startupProbe` generous, readiness on `/health`.
- Typo `nvidia.com/gpus` = unknown resource -> Pending `Insufficient nvidia.com/gpus`.

## Pending messages -> cause
| Message | Fix |
|---|---|
| `Insufficient nvidia.com/gpu` | no node with enough free GPUs (check allocatable vs allocated; node plugin down?) |
| `node(s) had untolerated taint {nvidia.com/gpu: ...}` | add toleration |
| `node(s) didn't match Pod's node affinity/selector` | label missing/mistyped (`gpu.product`), GFD absent |
| `Insufficient nvidia.com/<other name>` | resource name typo or MIG/rename name mismatch |
```bash
kubectl get nodes -o custom-columns=N:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
kubectl describe pod P | sed -n '/Events/,$p'
kubectl describe node N | sed -n '/Allocated resources/,/Events/p'
# lab: simulated device plugin
kubectl patch node N --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"},{"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"2"}]'
kubectl taint nodes N nvidia.com/gpu=present:NoSchedule
```

## nvidia-smi
`nvidia-smi -L` (UUIDs; UUID is the stable id, index can change), `nvidia-smi --query-gpu=index,uuid,temperature.gpu,memory.used,memory.total,power.draw --format=csv`, `nvidia-smi -q -d PERFORMANCE` (throttle reasons), `dmesg | grep -i xid`.
Table: Temp C, Pwr usage/cap W, Memory-Usage MiB, GPU-Util %, Volatile Uncorr. ECC (non-zero = serious).

## dcgm-exporter metrics (:9400)
| Metric | Notes |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | % time a kernel ran: NOT saturation |
| `DCGM_FI_DEV_FB_USED` / `FB_FREE` | MiB; vLLM preallocates so flat by design; steady growth under flat load = leak |
| `DCGM_FI_DEV_GPU_TEMP` | C; alert > 85 sustained |
| `DCGM_FI_DEV_POWER_USAGE` | W; at cap = power throttle |
| `DCGM_FI_DEV_XID_ERRORS` | last XID code; use `> 0` (state) or `changes()` (events), know the difference |
| `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL` / `ECC_DBE_VOL_TOTAL` | counters since driver load: `increase()`; DBE > 0 pages |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `PROF_SM_ACTIVE`, `PROF_DRAM_ACTIVE` | profiling: better saturation signals |
Labels: `Hostname, gpu, UUID, device, modelName` (+ `namespace, pod, container` with pod mapping). Keep `UUID` in alert results.

## XID cheat table
| XID | Meaning | Action |
|---|---|---|
| 13 | graphics engine exception | restart workload, investigate app |
| 31 | GPU memory page fault | restart workload (app), watch recurrence |
| 43 | GPU stopped processing | restart workload |
| 48 | double-bit ECC | drain, reset/RMA |
| 63 | row remap event | reset at next window |
| 64 | row remap failure | drain, RMA |
| 74 | NVLink error | drain (TP jobs), inspect link |
| 79 | fell off the bus | drain now, reboot, RMA if repeated |
| 94 | contained ECC | restart affected pod, watch |
| 95 | uncontained ECC | drain + GPU reset |
| 119/120 | GSP timeout/error | drain, reset, check driver notes |
Before drain: replicas elsewhere? PDB? spare GPU capacity for evicted pods? `kubectl cordon N; kubectl drain N --ignore-daemonsets --delete-emptydir-data`; fix; `kubectl uncordon N`.

## Sharing
| | Memory isolation | Fault isolation | Change cost | Use |
|---|---|---|---|---|
| dedicated | n/a | n/a | n/a | big models, TP |
| MIG | hardware | hardware | drain + reset | multi-tenant SLO |
| MPS | optional | none | daemon | trusted co-location |
| time-slicing | none | none | plugin restart | dev/CI/notebooks |
| DRA | driver | driver | new API (GA k8s 1.34; beta in 1.33) | future |
Time-slicing config (device plugin ConfigMap, data key = config name):
```yaml
version: v1
sharing:
  timeSlicing:
    renameByDefault: true            # resource becomes nvidia.com/gpu.shared
    failRequestsGreaterThanOne: true # reject "2 slices" requests
    resources: [{name: nvidia.com/gpu, replicas: 4}]
```
Activate: ClusterPolicy `spec.devicePlugin.config.{name,default}` or node label `nvidia.com/device-plugin.config=<key>`. Node then advertises replicas x GPUs.
MIG: label `nvidia.com/mig.config=all-1g.10gb`; strategies none/single/mixed (`nvidia.com/mig-3g.40gb`); 80 GB profiles 1g.10gb(7) 2g.20gb(3) 3g.40gb(2) 4g.40gb 7g.80gb; slice memory is the VRAM budget.
