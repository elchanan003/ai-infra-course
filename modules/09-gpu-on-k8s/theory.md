# 09 — GPUs on Kubernetes: driver to pod, DCGM, XID, sharing, manifests

Time: ~4 h (theory ~1.5 h, lab ~2.5 h). Prerequisites: 03 (vLLM ops), 08 (observability: PromQL, alert rules, promtool).
Pinned: Kubernetes 1.33 (kind node v1.33.1), NVIDIA GPU Operator v26.7.2 (container toolkit 1.20.1, device plugin 0.20.1, MIG manager 0.15.1, DCGM exporter 4.6.1-4.8.4), kubeconform and promtool from `platform/setup.sh`.

**This module has no GPU behind it. Be clear about what is simulated.**

| Element | In the lab | In production |
|---|---|---|
| GPUs, `nvidia-smi` output, DCGM metrics (temperature, power, XID, ECC, VRAM) | **simulated**: mock-dcgm (one container per simulated node) and a fake `nvidia-smi`; exact names/faults in `mock/README.md` | real driver + NVML + dcgm-exporter |
| Prometheus, PromQL, alert rules, `promtool test rules` | **real** | same |
| Kubernetes scheduler, resource accounting, taints/tolerations, nodeSelector, Pending reasons | **real** (kind, k8s 1.33) | same |
| `nvidia.com/gpu` capacity on a node | **simulated** by patching node status (what the device plugin would do) | advertised by the NVIDIA device plugin after real driver discovery |
| Time-slicing / MIG ConfigMaps | schema-validated and server-side dry-run only: **validated, not exercised** | applied by GPU Operator; changes real GPU behaviour |
| Driver container, container toolkit, runtime handler, MIG manager, DRA driver | **theory only** | real |

The scheduling half (requests, Pending, taints, affinity) behaves **exactly** like production because the scheduler only sees numbers in node status. The hardware half (what a GPU fault looks like, what the driver stack does) is taught from real formats and simulated data.

---

## 1. The stack from the metal to the pod

```
 Pod (vLLM)           limits: nvidia.com/gpu: 1          <- your manifest
   |  kubelet asks device plugin Allocate()
 Kubernetes           scheduler matches extended resource "nvidia.com/gpu" against node.allocatable
   |  kubelet -> containerd -> runtime handler "nvidia" (RuntimeClass)
 NVIDIA Container Toolkit   OCI hook / CDI: mounts /dev/nvidia*, driver libs (libcuda.so), nvidia-smi into the container
   |
 NVIDIA driver (kernel modules nvidia, nvidia_uvm, nvidia_modeset)   <- must match the CUDA version the image needs
   |
 GPU hardware (HBM, SMs, NVLink, ECC, thermal sensors)
```

Layer responsibilities and what breaks:

| Layer | Job | Typical failure | Symptom |
|---|---|---|---|
| Driver (kernel modules) | talks to the GPU | kernel upgrade without rebuilt module; Secure Boot unsigned module; version too old for the CUDA in the image | `nvidia-smi` fails: "couldn't communicate with the NVIDIA driver"; pods `CrashLoopBackOff` with "CUDA driver version is insufficient for CUDA runtime version" |
| Container Toolkit | injects device nodes and driver libs into containers | runtime not configured in containerd (`nvidia` handler missing) | pod starts but has no `/dev/nvidia*`; `nvidia-smi: command not found`; vLLM: "no CUDA GPUs available" |
| Device plugin (DaemonSet) | discovers GPUs, advertises `nvidia.com/gpu`, does `Allocate` | plugin pod crashing, wrong node selector, driver not ready | node `allocatable` has **no** `nvidia.com/gpu`: pods Pending `Insufficient nvidia.com/gpu` |
| GPU Feature Discovery (GFD) | labels nodes: `nvidia.com/gpu.product`, `.count`, `.memory`, `.family`, `nvidia.com/mig.capable`... | not deployed | nodeSelector on product label never matches: Pending with "didn't match Pod's node affinity/selector" |
| DCGM exporter | Prometheus metrics for GPU health/utilisation | no ServiceMonitor, wrong port | dashboards empty |
| Scheduler + kubelet | resource accounting | typos, missing tolerations | Pending forever |

### 1.1 NVIDIA GPU Operator (v26.7.2)

Installing the five components by hand, in the right order, on every node, is fragile. The **GPU Operator** is a Helm-installed controller driven by a single `ClusterPolicy` custom resource; it deploys, per GPU node (selected through Node Feature Discovery labels such as `feature.node.kubernetes.io/pci-10de.present=true`):

| Component | DaemonSet / pod | Notes |
|---|---|---|
| NVIDIA driver container | `nvidia-driver-daemonset` | optional (`driver.enabled=false` when drivers are baked into the OS image, the common on-prem choice for stability and air gaps) |
| Container Toolkit | `nvidia-container-toolkit-daemonset` | configures containerd/CRI-O (default runtime or `nvidia` RuntimeClass), CDI |
| Device plugin | `nvidia-device-plugin-daemonset` | advertises `nvidia.com/gpu` (or MIG resources) |
| GFD | `gpu-feature-discovery` | node labels |
| DCGM exporter | `nvidia-dcgm-exporter` | metrics on :9400 `/metrics`; the `dcgm` hostengine can be embedded or standalone |
| MIG manager | `nvidia-mig-manager` | applies the MIG layout named by node label `nvidia.com/mig.config` |
| Validator | `nvidia-operator-validator` | init-container chain that proves driver -> toolkit -> plugin -> a CUDA workload works; **pods stay Init until it passes** |
| Node Status Exporter, vGPU/KubeVirt managers, sandbox plugins | optional | |

Components start in a dependency order enforced by the validator: if one stage fails, later ones sit in `Init:0/N`. First debugging step on a node with no GPUs: `kubectl -n gpu-operator get pods -o wide`, then the logs of the **earliest** non-Running component.

**Air-gapped install** (theory, you do not run it): mirror the operator and component images to the internal registry (`validator.repository`, `driver.repository`, `toolkit.repository`... or global `--set operator.repository=registry.local/nvidia`), pre-build the driver image for your exact kernel (`nvcr.io/nvidia/driver:<ver>-<os>`; the driver container compiles or fetches kernel modules at start, which needs the OS package repos mirrored) **or** use pre-installed host drivers (`driver.enabled=false`) and preinstalled toolkit. Charts come from a local Helm repo or OCI registry. `imagePullSecrets` for the internal registry. This is typically the hardest part of an on-prem GPU rollout; the kernel/driver matrix is the thing to document.

**How the lab differs:** kind has no driver, toolkit or device plugin. We patch `status.capacity` and `status.allocatable` of the node with `nvidia.com/gpu` and add the GFD-style labels by hand (task 9.4). To the scheduler this is indistinguishable from a device plugin having reported GPUs. Two honest consequences: (1) the patch only survives because nothing reconciles it in kind (a real device plugin owns that field and would overwrite it); (2) containers get no `/dev/nvidia*` (the pods in the lab run `sleep`). An optional alternative, `run-ai/fake-gpu-operator` (chart 0.2.1), does the reconciling and works on arm64, but its exporter publishes only 3 DCGM series, which is why the course keeps mock-dcgm.

---

## 2. Requesting GPUs: resource model and scheduling

### 2.1 Extended resources

`nvidia.com/gpu` is an **extended resource**. Rules enforced by the API server and scheduler:

- Specified **only in `limits`** (or in both with equal values). If you write only `requests`, validation fails: for extended resources requests must equal limits and limits are required. Writing it in `limits` alone is the idiom: `resources: {limits: {nvidia.com/gpu: 1}}`.
- **Integers only** (no `0.5`). Fractions come from sharing mechanisms (section 4), which change what a "unit" is.
- No overcommit: the scheduler subtracts requests from `allocatable`. A pod asking for more than any node has stays `Pending` with `0/N nodes are available: N Insufficient nvidia.com/gpu.` This message is the first thing to read.
- A GPU is allocated to **one container** exclusively (unless shared); initContainers can request GPUs but that complicates accounting.
- Unlike CPU/memory there is no throttling or limit enforcement inside the GPU between pods: whoever owns the device owns all of its memory.
- Typos are not errors: `nvidia.com/gpus: 1` is simply another unknown extended resource name; the pod is Pending with `Insufficient nvidia.com/gpus`. That "plural s" is a classic incident and the planted fault in the lab.

### 2.2 Node selection: labels, taints, tolerations

GPU nodes are expensive, so clusters **taint** them so that non-GPU workloads stay away:

```bash
kubectl taint nodes gpu-node-a nvidia.com/gpu=present:NoSchedule
```

A GPU pod must tolerate that taint; many platforms inject the toleration automatically (admission controller / Kyverno / the `ExtendedResourceToleration` admission plugin: when a pod requests an extended resource, the API server adds a toleration for a taint with that resource name as key — worth knowing, since it explains why `tolerations` are sometimes missing from manifests yet work). Do not depend on it unless you know the cluster has it enabled; the lab cluster does not.

Pod spec pattern for "run on an H100 node":

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3    # from GFD; exact string matters
  tolerations:
    - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
  containers:
    - name: vllm
      resources:
        limits: {nvidia.com/gpu: 1}
```

`nodeSelector` string comparisons are exact: `NVIDIA-H100-80GB-HBM3` vs `NVIDIA-H100-80GB-HBM3e` do not match. Copy it from `kubectl get node -o jsonpath='{.metadata.labels}'`. Prefer `nodeAffinity` with `In` lists when several products are acceptable. Pending messages distinguish the cases: `node(s) didn't match Pod's node affinity/selector` (label), `node(s) had untolerated taint {...}` (toleration), `Insufficient nvidia.com/gpu` (capacity). Learn to map message -> fix; the scheduler counts every node in exactly one bucket, so the message is a histogram of reasons.

### 2.3 Multi-GPU pods and tensor parallelism

Tensor parallelism (module 01) splits each layer across GPUs; they exchange activations every layer, so they should share a fast interconnect. In k8s:

- `--tensor-parallel-size 2` requires `limits: nvidia.com/gpu: 2` **in one pod, on one node**. A pod can never span nodes; two pods each with 1 GPU on different nodes cannot do TP together (that needs pipeline/Ray or a multi-node framework such as LeaderWorkerSet).
- If no node has 2 free GPUs, the pod is Pending even when the cluster has 2 free GPUs spread over two nodes (**fragmentation**). Capacity planning is per node, and this is the main reason inference fleets keep uniform node shapes.
- Topology matters: 2 GPUs connected by NVLink (SXM/HGX boards, NVSwitch) vs through PCIe is a 5-10x bandwidth gap; the device plugin does not pick NVLink-adjacent pairs by default. Mitigation on real clusters: topology-aware device plugin settings, or dedicate nodes with full NVLink domains (8 GPUs, request all 8 or fixed halves).
- vLLM shared-memory trap: TP workers communicate through `/dev/shm`; the default 64 MiB in a pod is far too small. Mount `emptyDir: {medium: Memory}` at `/dev/shm` (or set `--ipc=host` in docker). Missing this gives bus errors / NCCL hangs at start.
- Use `Deployment` + `strategy: Recreate` (or `maxSurge: 0`) for a model that fills whole GPUs: a rolling update needs the old and the new pod simultaneously and so double the GPUs; with no spare capacity the new pod is Pending forever and the rollout stalls.
- Large images and model weights: startup takes minutes (pull image 5-10 GB + load weights). Use `startupProbe` with a generous `failureThreshold` and a `readinessProbe` on `/health` (vLLM returns 503 until loaded); a liveness probe too aggressive restarts the pod in a loop during a long load.

### 2.4 Reading a Pending GPU pod: the 30-second routine

```bash
kubectl describe pod P | sed -n '/Events/,$p'     # the FailedScheduling message
kubectl get nodes -o custom-columns=N:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,TAINT:.spec.taints[*].key
kubectl describe node N | sed -n '/Allocated resources/,/Events/p'   # what is already taken
```

Then in order: resource name spelled right? capacity exists on any node? taints tolerated? selector labels exist on a node **with** capacity? enough GPUs on a **single** node? Is something else (a stuck Terminating pod) holding the GPU?

---

## 3. DCGM and reading GPU health

### 3.1 nvidia-smi vs DCGM

`nvidia-smi` (NVML) is the interactive CLI: instantaneous, per host, human-readable, usually reachable via `kubectl exec` into a pod that has GPUs. **DCGM** (Data Center GPU Manager) is the fleet tool: a hostengine that samples fields at an interval, runs health checks and diagnostics (`dcgmi diag -r 1|2|3`), and feeds the **dcgm-exporter** which serves Prometheus metrics (`:9400/metrics`, default 30 s collection interval; configurable via `DCGM_EXPORTER_INTERVAL`, and the metric list via a CSV file mounted into the exporter).

What to read in `nvidia-smi` (real column names):

```
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|   0  NVIDIA H100 80GB HBM3         On   | 00000000:18:00.0   Off |                    0 |
| N/A   54C    P0            312W / 700W  |  61234MiB / 81559MiB   |     97%      Default |
```

Fields: `Temp` (GPU core C), `Pwr` (draw/cap), `Memory-Usage` (framebuffer used/total, MiB), `GPU-Util` (percent of time at least one kernel was running, section 3.4), `Volatile Uncorr. ECC` (uncorrected errors since driver load: non-zero is serious), `Persistence-M`, `Perf` (P0 = max, P8/P12 = idle; a loaded GPU stuck in P2+ with throttle reasons is a thermal/power problem). `nvidia-smi -q -d PERFORMANCE` shows throttle reasons (`HW Slowdown`, `SW Thermal Slowdown`, `SW Power Cap`). `nvidia-smi --query-gpu=index,uuid,temperature.gpu,memory.used --format=csv` is the scriptable form. `nvidia-smi -L` lists GPUs with UUIDs (`GPU-xxxxxxxx-xxxx-...`); **the UUID, not the index, is the stable identity** (index order can change across reboots/PCI enumeration; RMA tickets use serial/UUID).

In the lab the same fields come from the fake `nvidia-smi`; the format imitates the real tool.

### 3.2 Metrics you will alert on (dcgm-exporter names)

| Metric | Unit / type | Meaning | Alert idea |
|---|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | % gauge | time with a kernel running | **not** saturation (section 3.4) |
| `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_FB_FREE` | MiB gauge | framebuffer memory | used/(used+free) > 95%; **monotonic growth** under steady load = leak |
| `DCGM_FI_DEV_GPU_TEMP` | C gauge | core temperature | > 85 C sustained (datacenter GPUs throttle around 85-90 C; check the SKU's slowdown threshold) |
| `DCGM_FI_DEV_POWER_USAGE` | W gauge | board power | persistently at the cap = power-throttled |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | % | memory controller activity | memory-bound decode shows high here, moderate SM |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_DRAM_ACTIVE` | ratio 0-1 | profiling counters: how busy the engines really are | better saturation signals; available on datacenter GPUs, with some overhead; not available together with some profilers |
| `DCGM_FI_DEV_XID_ERRORS` | gauge, last XID code | the most recent XID error number (0 = none since boot of the exporter/driver) | any non-zero change |
| `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL`, `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` | counter since driver load | single-bit (corrected) / double-bit (uncorrected) ECC errors | DBE > 0 = page; SBE rate rising = watch |
| `DCGM_FI_DEV_RETIRED_PENDING`, `DCGM_FI_DEV_ROW_REMAP_FAILURE`, `DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS` | counts | memory row remapping state (Ampere+) | pending remap = reset needed; remap failure = RMA |
| `DCGM_FI_DEV_NVLINK_*` | counters | NVLink CRC/replay/recovery errors | rising errors = link degradation |
| `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS` | bitmask | why clocks are reduced | non-zero while loaded |

Labels attached by dcgm-exporter: `gpu` (index), `UUID`, `device` (`nvidia0`), `modelName`, `Hostname`, and (with pod mapping enabled) `namespace`, `pod`, `container`. The lab's mock-dcgm uses the same label scheme; the exact series/fault knobs are in `mock/README.md`. Pod-level attribution works through the kubelet pod-resources API: it lets you say "XID 79 hit the GPU used by pod `vllm-0`" and is how you tie a hardware event to a user-visible incident.

Practical alert-rule notes:

- Alert **per GPU** (`by (Hostname, gpu, UUID)`), and keep `UUID` on the result: the on-call needs it for the drain/RMA ticket.
- Gauges that hold the **last** XID value (`XID_ERRORS`) stay non-zero until reset. Use `changes(metric[5m]) > 0` or "non-zero for N minutes" depending on what you want, and understand both: a stuck non-zero value that never changes will not fire a `changes()` alert after the first window, while a plain `> 0` alert will fire until the node is reset.
- Counters (ECC totals) reset on driver reload: use `increase()`/`rate()`, not absolute values, and expect a reset to look like a drop.
- Leak detection: `deriv(DCGM_FI_DEV_FB_USED[30m]) > 0` over a window with a steady request rate, or `predict_linear(FB_USED[1h], 3600) > total`. A leak shows as steady slope while traffic is flat. Beware that vLLM **preallocates** its VRAM budget at start (module 03), so for a vLLM pod FB_USED is flat by design; growth beyond that budget means something else (a second process, a fragmentation/leak in a non-vLLM workload, a driver issue).
- Use `for:` long enough to ignore blips but short for hard faults (XID 79, DBE): these should page immediately.

### 3.3 XID errors: the GPU's kernel log

XIDs are driver-reported error events, visible in `dmesg` as `NVRM: Xid (PCI:0000:18:00): 79, pid=..., GPU has fallen off the bus.` and exported by DCGM. You do not memorise all of them; you learn the **families** and the **action**: is it the application, the memory, the link, or the board, and does it need a drain?

| XID | Meaning (short) | Usual cause | Typical action |
|---|---|---|---|
| 13 | Graphics engine exception | application bug (illegal instruction/address), occasionally HW | wait/restart the pod; investigate the workload; repeated on many apps -> suspect hardware |
| 31 | GPU memory page fault (MMU error) | application accessed invalid memory; sometimes a driver bug | restart the pod; treat as an app problem unless it recurs across workloads |
| 43 | GPU stopped processing | application hung/crashed the context | restart the pod; node usually stays |
| 45 | Preemptive cleanup after another error | a consequence (e.g. process killed) | read the earlier XID |
| 48 | Double-bit ECC error (uncorrectable) | HBM fault | **drain**, reset the GPU / reboot; recurring -> RMA |
| 63 | Row-remap event (ECC page retirement recorded) | HBM row remapped | **GPU reset needed** to apply: schedule at next window; repeated -> RMA |
| 64 | Row-remap failure | no spare rows left | **drain, RMA** |
| 74 | NVLink error | link degraded/failing | **drain** for multi-GPU TP jobs; inspect cabling/board |
| 79 | GPU has fallen off the bus | board/PCIe/power/thermal failure; driver can no longer talk to it | **drain immediately**, reboot, if recurring RMA; pods on it are dead |
| 94 | Contained ECC error | uncorrectable, but contained to the affected process | restart that pod; GPU may continue; track recurrence |
| 95 | Uncontained ECC error | error may have corrupted other processes' memory | **drain**, GPU reset required; all processes on that GPU are suspect |
| 119 / 120 | GSP (GPU System Processor) timeout / error | firmware/driver issue | drain, reset or reboot; check driver version known-issues |

Authoritative reference: the NVIDIA *XID Errors* documentation for your driver release; the table above is the operator's mental model, not a replacement. The rule teams encode: **application-class XIDs (13, 31, 43) -> alert + restart workload; hardware-class (48, 63, 64, 74, 79, 95, 119/120) -> cordon + drain + hardware ticket**. Drain means `kubectl cordon` (stop new pods), then `kubectl drain --ignore-daemonsets --delete-emptydir-data` (evict), then fix/reset, then `uncordon`. "Wait" means leave the node serving while the workload team investigates. Draining a node that hosts a model replica when it is the **only** replica is an outage: check the PodDisruptionBudget and replica count before draining, and remember GPU capacity is not elastic (the evicted model needs another node with free GPUs, or it goes Pending).

Automation worth knowing: **node problem detector / NVIDIA's "GPU health" checks / node-repair controllers** convert XID or DCGM health failures into a node condition and taint (`nvidia.com/gpu-unhealthy:NoSchedule`/`NoExecute`) so the scheduler stops using the node without a human. The router in the gateway (module 05) should also stop sending traffic to the replica via cooldowns; the dead GPU surfaces as upstream 5xx/timeouts first, then the alert.

### 3.4 "GPU utilisation" is not saturation

`DCGM_FI_DEV_GPU_UTIL` is the fraction of the sample period in which **at least one kernel was executing** on the GPU. A single tiny kernel running continuously reads 100% while using 1 of 132 SMs. A decode-heavy LLM server is memory-bandwidth-bound: it can show 95-100% GPU_UTIL with low `PROF_SM_ACTIVE`/tensor activity. The reverse also holds: a vLLM server waiting for requests shows ~0% but holds 90% of VRAM. For capacity decisions use **queue metrics and KV usage from the engine** (`vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`, module 03/08) and, if available, profiling fields. GPU_UTIL is a "is anything running" signal, good for finding idle (wasted) GPUs, bad for finding full ones.

---

## 4. Sharing GPUs: time-slicing, MIG, MPS, DRA

By default one GPU = one pod, which wastes expensive hardware when workloads are small (embedding models, 1-3B chat, notebooks, CI). Mechanisms, strongest isolation first:

| Mechanism | How it works | Memory isolation | Fault isolation | Perf isolation | Typical use |
|---|---|---|---|---|---|
| **Dedicated GPU** | whole device to one pod | n/a | n/a | n/a | big models, TP |
| **MIG** (Multi-Instance GPU; A100/A30/H100/H200/B200 class) | hardware partitions into up to 7 instances, each with its own SMs, L2 slice and memory slice | yes (hardware) | yes (hardware) | yes | multi-tenant inference of small/medium models |
| **MPS** (Multi-Process Service) | a daemon merges contexts so kernels from several processes run concurrently | optional limits | **no** (one fault can take down all clients) | partial (SM percentage limits) | co-located trusted jobs, throughput |
| **Time-slicing** | the driver context-switches between processes in turns; the device plugin advertises N "replicas" of one GPU | **no** (a process can take all VRAM; OOM hits neighbours) | **no** | **no** (latency jitter) | dev/test, CI, low-duty workloads |
| **vGPU** (licensed, hypervisor/virtualised) | virtual GPUs with fixed frame buffer | yes | yes | scheduling policies | VM-based platforms |
| **DRA** (Dynamic Resource Allocation) | k8s-native structured allocation of devices with attributes and claims | depends on driver | n/a | n/a | the future API; section 4.4 |

**Time-slicing is not isolation.** It multiplies the advertised resource count; nothing partitions memory. Two replicas of a 70 GB model on an 80 GB GPU: the second dies with CUDA OOM, or worse, makes the first one OOM at its next allocation. Capacity numbers on the node look larger and production incidents follow. This is the single most important caveat to remember; the platform team's rule is "time-slice only workloads whose VRAM sums fit and whose latency does not matter".

### 4.1 Time-slicing configuration (GPU Operator / device plugin 0.20)

A ConfigMap holds named plugin configs; the ClusterPolicy points to it and a node label selects which config a node uses.

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: time-slicing-config, namespace: gpu-operator}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

Activation: `kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'` (or the Helm value `devicePlugin.config.name`), optionally `kubectl label node N nvidia.com/device-plugin.config=any` to apply per node. The plugin restarts and the node then reports **`nvidia.com/gpu: 4` per physical GPU** (an 8-GPU node advertises 32). Key flags:

| Setting | Effect |
|---|---|
| `replicas: N` | one GPU appears as N allocatable units |
| `renameByDefault: true` | resource becomes `nvidia.com/gpu.shared` so that pods that want a *whole* GPU (`nvidia.com/gpu`) are never accidentally co-located; shared-friendly pods request `gpu.shared`. Strongly recommended in mixed clusters |
| `failRequestsGreaterThanOne: true` | a pod asking for 2 replicas gets an error instead of silently receiving "two slices", which is **not** twice the compute (it is two time slots, may even be the same GPU) |
| GFD label `nvidia.com/gpu.replicas` | exposes the replica count to schedulers; GFD also changes `gpu.product` to `<product>-SHARED` when renamed |

Behavioural facts: all processes on the GPU get **equal turns regardless of weight** (no priorities, no per-pod fractions; 4 replicas does not mean 25% each if two pods are idle, they just yield), context-switch overhead is real, and TP across time-sliced "GPUs" is meaningless.

In the lab (task 9.6) you write this ConfigMap and **validate it**: `kubeconform` against the schema and a server-side dry-run against the kind API. That proves the YAML is well-formed and accepted by Kubernetes; it proves nothing about the device plugin's behaviour, because kind has none. The lab says "validated, not exercised" on purpose. The plugin's own strictness (unknown keys, wrong types) is only checked when it loads the config; real clusters catch typos by watching the plugin pod logs after the change.

### 4.2 MIG

MIG slices an A100/H100-class GPU into **GPU instances** with fixed profiles named `<compute slices>g.<memory>gb`. Examples: A100-40GB: `1g.5gb` (7 per GPU), `2g.10gb` (3), `3g.20gb` (2), `4g.20gb` (1), `7g.40gb` (1); A100-80GB / H100-80GB: `1g.10gb` (7), `2g.20gb` (3), `3g.40gb` (2), `4g.40gb`, `7g.80gb`. Not every combination is legal (slice placement rules); the supported layouts are listed by `nvidia-smi mig -lgipp`.

Operator flow: label the node `nvidia.com/mig.config=all-1g.10gb` (or a custom layout from a `mig-parted` config); the **MIG manager** evicts GPU clients, enables MIG mode, creates the instances, restarts the plugin and sets `nvidia.com/mig.config.state=success`. **Enabling/changing MIG on a GPU requires no processes using it and often a GPU reset**: it is a disruptive maintenance operation, not an autoscaling knob.

Strategies (`mig.strategy`):

| Strategy | Resource names | Use |
|---|---|---|
| `none` | `nvidia.com/gpu` for whole GPUs, MIG ignored | default |
| `single` | every MIG device is called `nvidia.com/gpu` (all slices uniform) | simple fleets; manifests do not change |
| `mixed` | `nvidia.com/mig-1g.10gb`, `nvidia.com/mig-3g.40gb`... | different sizes on one node; manifests name the profile |

Sizing for LLMs: a MIG slice has a hard memory ceiling. A 7B bf16 model (about 14 GB weights + KV) needs `2g.20gb` or larger on an 80 GB card; `1g.10gb` cannot hold it. Use the same VRAM math as module 01 against the **slice** memory, not the card. MIG slices have no NVLink between them, so no TP across slices. Each slice is a separate device for the scheduler: `limits: nvidia.com/mig-3g.40gb: 1`.

MIG costs: fixed partitioning (idle slices cannot lend capacity), partial loss of memory/compute versus the whole (7 x 1g is not 7/7 of the SMs), some profilers/NVLink features unavailable. Benefit: real isolation, predictable latency. In the lab nothing in MIG is exercised.

### 4.3 MPS

An MPS control daemon runs on the node (GPU Operator can deploy it via the device plugin's `sharing.mps` section, in recent plugin releases). Clients attach to the daemon and share one CUDA context, enabling true concurrent kernel execution. `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` and pinned device memory limits provide soft partitioning. Fault isolation is weak: a fatal error in one client can take down all clients on that GPU. Use for co-located trusted services that want throughput.

### 4.4 Dynamic Resource Allocation (DRA)

The device-plugin model only knows an integer count per resource name; it cannot express "a GPU with at least 40 GB, NVLink-connected to the other one I got, MIG slice of this profile". **DRA** replaces it with API objects: `ResourceSlice` (driver publishes devices and attributes), `DeviceClass` (a category), `ResourceClaim` / `ResourceClaimTemplate` (pod's request, with CEL selectors on attributes) referenced from the pod spec `resourceClaims`. The scheduler allocates devices when scheduling; claims can be shared by pods or created per pod.

Status relevant to the pins: the structured-parameters DRA API went **beta in Kubernetes 1.32/1.33 and GA in 1.34** (`resource.k8s.io/v1`); on 1.33 clusters the API group and feature gate may not be enabled by default, so check before relying on it. NVIDIA provides the DRA driver (`k8s-dra-driver-gpu`) with GPU and ComputeDomain (multi-node NVLink) support, and GPU Operator can deploy it. Teams are migrating gradually; the device plugin remains the default for inference clusters in the pinned stack. Take-aways for the junior: know the objects exist, recognise `ResourceClaim` in a manifest, and know DRA will make "give me one MIG-capable GPU with 80 GB" a first-class request instead of node labels plus magic resource names. **Lab: theory only.**

### 4.5 Choosing

| Workload | Choose |
|---|---|
| 70B bf16 across 2-8 GPUs | dedicated GPUs, TP in one pod on one node |
| 7-13B chat, steady traffic | dedicated GPU (or MIG `3g`/`4g` if hardware supports it and tenancy matters) |
| embedding / reranker models, 1B-3B | MIG small slices or time-slicing with `renameByDefault` |
| notebooks, CI smoke tests, demos | time-slicing |
| multi-tenant with SLOs and hostile neighbours | MIG (or dedicated); never time-slicing |

---

## 5. Production GPU operations

- **Node pools**: separate GPU SKUs into pools with a uniform label/taint scheme (`nvidia.com/gpu.product`, a custom `pool=infer-h100`). Pending pods then say exactly which pool lacks capacity.
- **Capacity and fragmentation**: track free GPUs **per node**; alert when no node can place a TP=N pod even though N GPUs are free overall.
- **Autoscaling** GPU nodes (cluster-autoscaler / Karpenter) takes 5-15 minutes (VM + driver + image pull + weight load). Plan warm capacity; for on-prem it is "buy and rack", so queueing and priority (PriorityClass, Kueue) are the levers: Kueue/Volcano give queues, quotas and gang scheduling for batch jobs.
- **Preemption and priority**: `PriorityClass` lets inference evict batch/training; set it deliberately, preemption of a model server is an outage for its users.
- **Rolling updates**: model servers fill GPUs, so `maxSurge: 0, maxUnavailable: 1` or `Recreate`; or keep one spare GPU for surge.
- **Health pipeline**: dcgm-exporter -> Prometheus rules (section 3) -> Alertmanager -> page; plus node-level automation (taint on XID class) and `dcgmi diag -r 2` at node admission and after repairs. New or repaired nodes should pass burn-in before joining.
- **Driver upgrades** are rolling node operations: cordon, drain, upgrade, validate, uncordon (GPU Operator's `driver.upgradePolicy` automates this). Pin driver, toolkit and CUDA base image versions together; the compatibility matrix is the contract.
- **Model weights on nodes**: pull from the internal mirror/object store into a local cache volume (hostPath/PVC/ephemeral NVMe); a 140 GB model downloaded on every pod start is an outage waiting for a registry blip. Pre-warm with a DaemonSet or an image-volume.
- **Cost visibility**: GPU hours by team through pod attribution in DCGM (`namespace`/`pod` labels) and kube-state-metrics; idle-GPU report = GPUs allocated to pods with GPU_UTIL near 0 for hours.
- **Security**: do not give workloads `privileged` to "get GPU access"; the toolkit/CDI path provides devices without it. `NVIDIA_VISIBLE_DEVICES=all` in an image combined with the toolkit can hand a pod GPUs it never requested on some runtime configs: set `accept-nvidia-visible-devices-envvar-when-unprivileged = false` in toolkit config (operator default in recent versions) so that only the device plugin decides.

### 5.1 Debug flow when "the model pod has no GPU"

1. `kubectl describe pod`: Pending (scheduling reason) or Running-but-no-GPU?
2. Pending -> read section 2.4. Capacity missing on the node? `kubectl get node -o json | jq '.status.allocatable'`.
3. Running without GPU: does `nvidia-smi` work inside? Missing -> toolkit/runtime class; present but fails -> driver mismatch; works but framework says no CUDA -> image CUDA vs driver version, or `CUDA_VISIBLE_DEVICES` empty.
4. Node lacks capacity: `kubectl -n gpu-operator get pods -o wide`; earliest non-Running component's logs (validator init chain).
5. Hardware: dcgm-exporter / `dmesg | grep -i xid` / `nvidia-smi` on the host.

---

## Key takeaways

1. The stack is driver -> container toolkit -> device plugin (+GFD) -> kubelet -> scheduler; GPU Operator manages all of it from one `ClusterPolicy`, and the validator makes later stages wait for earlier ones. Debug from the earliest failing layer.
2. `nvidia.com/gpu` is an extended resource: integer, in `limits`, no overcommit. A typo is just another resource name and leaves the pod Pending with `Insufficient <name>`. Read the Pending message: capacity vs taint vs selector.
3. A TP=N model needs N GPUs in one pod on one node; fragmentation and rolling-update surge are the capacity traps. Mount `/dev/shm`.
4. Taint GPU nodes, tolerate in GPU pods, and select by exact GFD label strings.
5. GPU_UTIL means "a kernel was running", not "GPU is full". Use engine queue/KV metrics and profiling fields for saturation.
6. XIDs fall into application-class (13, 31, 43: restart workload) and hardware-class (48, 63, 64, 74, 79, 95, 119/120: cordon, drain, hardware ticket). Keep `UUID` in alerts; the UUID, not the index, identifies the GPU.
7. Time-slicing multiplies the advertised count and isolates nothing; MIG isolates in hardware but is rigid and disruptive to change; MPS shares without fault isolation; DRA is the future allocation API (GA in k8s 1.34).
8. In this lab GPUs and DCGM data are simulated and the time-slicing config is only validated; the scheduling behaviour is real. Production adds the driver/toolkit/operator layer and real hardware faults.

## Check yourself

1. A pod with `limits: {nvidia.com/gpus: 1}` is Pending with `Insufficient nvidia.com/gpus` while the node reports `nvidia.com/gpu: 2`. What is wrong and how do you confirm without reading the manifest?
2. Two nodes each have one free GPU. A Deployment with `--tensor-parallel-size 2` / `nvidia.com/gpu: 2` is Pending. Why, and what are the options?
3. dcgm-exporter shows XID 79 on GPU `GPU-3f...` of node B while XID 31 appears on node A. What do you do for each, and what do you check before draining B?
4. Why can `DCGM_FI_DEV_GPU_UTIL` be 100% while the vLLM server still accepts more load? Name two better signals.
5. Your team wants to put two vLLM replicas (70 GB each at `--gpu-memory-utilization 0.9`) on one 80 GB GPU using time-slicing with `replicas: 2`. What happens and what are your alternatives?
