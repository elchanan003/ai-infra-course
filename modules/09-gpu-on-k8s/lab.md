# 09 — Lab: reading GPU failures and writing GPU manifests

Time: ~2.5 h. Guidance level: guided. Work from `modules/09-gpu-on-k8s/`. You edit files only under `lab/`.

**What is real and what is simulated (say it out loud):**
- **Part A** (compose profiles `mock obs`): the GPUs are **simulated**: two mock-dcgm containers (nodes `gpu-node-a`, `gpu-node-b`) that serve DCGM-exporter-style metrics and a fake `nvidia-smi`. Prometheus, PromQL, alert rules and `promtool` are **real**.
- **Part B** (kind cluster `aiinfra`: `aiinfra-control-plane`, `aiinfra-worker`, `aiinfra-worker2`): the Kubernetes API and scheduler are **real**. There is no driver, no container toolkit, no device plugin and no GPU: you simulate the plugin by patching node status. Pods run `sleep`. Time-slicing is **validated, not exercised**.
- Nothing here proves that a real GPU, driver or MIG slice works. What transfers one-to-one: the scheduler's behaviour, Pending messages, manifests, PromQL and alert design, XID triage.

```bash
./prepare-lab.sh A      # part A: mock obs, per-learner variant seeded in .state/
./prepare-lab.sh B      # part B: kind cluster, no GPUs yet, empty namespace gpu-lab
./prepare-lab.sh        # both (what verify.sh with no argument expects)
./verify.sh A           # or B, or no argument for everything
```
Part A and B can run side by side (the RAM rule only forbids kind together with the `llm` profile; `prepare-lab.sh B` removes the stack first if `llm` is up).
`k` below means `kubectl --context kind-aiinfra`. First verify run is slower (pods start, a rollout is timed, a live fault is injected and cleared).

## Ownership

| Path | Status |
|---|---|
| `lab/answers/smi.env` | yours: task 9.1 (starter: empty values) |
| `lab/prometheus/rules/dcgm-alerts.yml` | yours: task 9.2 (starter: no rules) |
| `lab/prometheus/prometheus.yml` | given: scrapes the two mock-dcgm nodes every 5 s, loads `rules/*.yml` |
| `lab/answers/xid.env` | yours: task 9.3 (starter: empty values) |
| `lab/k8s/inventory.txt` | given: GPUs, product label and memory per node |
| `lab/k8s/node-gpu.sh` | yours: task 9.4 (starter: fails with "not implemented") |
| `lab/k8s/gpu-pod.yaml` | yours: task 9.5 (starter: skeleton with TODOs) |
| `lab/k8s/timeslicing-cm.yaml` | yours: task 9.6 (starter: empty) |
| `lab/k8s/vllm-tp2.yaml` | yours: task 9.7 (starter: skeleton with TODOs) |
| `lab/k8s/broken-gpu-pod.yaml` | given, **broken**: task T |
| `bin/smi`, `schemas/`, `platform/`, `mock/`, module scripts | given: do not modify |

---

## Part A — GPU telemetry (mock-dcgm + fake nvidia-smi)

Useful commands:
```bash
bin/smi A -L                                   # fake nvidia-smi on node A ("bin/smi B ..." for node B)
bin/smi A                                      # the table
bin/smi A --query-gpu=index,uuid,temperature.gpu,memory.total,power.limit --format=csv
curl -s localhost:18031/metrics | grep DCGM_FI_DEV_GPU_TEMP     # node A exporter (node B: :18032)
```
Prometheus UI: `http://100.127.87.65:18090`. Series and the fault API are documented in `mock/README.md` section 4 (the mock's load is smooth and not coupled to any workload).

### Task 9.1 — Read the fake nvidia-smi

**Goal:** answer four questions about node A. The hardware differs per learner (your variant).
Predict first: which column tells you which GPU is the hottest, and what unit is memory in?

Fill `lab/answers/smi.env` (put the value right after `=`; the trailing comment is optional):
```
HOT_GPU_INDEX=      # index of the hottest GPU right now
HOT_GPU_UUID=       # its UUID (GPU-...)
VRAM_TOTAL_MIB=     # framebuffer total of THAT GPU, MiB (integer)
POWER_CAP_W=        # power cap of THAT GPU, W (integer)
```
Hints: GPUs on one node can be different models. `-L` lists UUIDs; the table lists temperature, power draw/cap and memory. MiB are not GB; cap is not draw. The UUID is the identity (theory 3.1).

Success criteria:
- `9.1a` HOT_GPU_INDEX is the hottest GPU of node A (live) and HOT_GPU_UUID belongs to that same GPU
- `9.1b` VRAM_TOTAL_MIB and POWER_CAP_W match that GPU
- `9.1c` the answer file is complete and well-formed (integer index, full `GPU-<uuid>`, integers; no placeholders)

### Task 9.2 — Alert rules for GPU health

**Goal:** write `lab/prometheus/rules/dcgm-alerts.yml` with four alerts. Every alert is **per GPU** and keeps `Hostname`, `gpu` and `UUID` on the alert.

| Alert | Condition |
|---|---|
| `GpuXidError` | an XID error value is reported (non-zero) on a GPU. The metric holds the last XID code and stays non-zero until a reset, so "XID present" is a state. A hard fault must page within about a minute |
| `GpuTooHot` | core temperature above 85 C sustained for 2 minutes (a 30 s spike or a GPU sitting at 84 C is not an alert) |
| `GpuEccUncorrected` | uncorrected (double-bit) ECC errors increased within the last 5 minutes. Corrected (single-bit) errors are a different matter |
| `GpuMemoryLeak` | framebuffer used is on a trajectory to fill the card within 2 hours, judged over a 10-minute window. Design the expression so that a GPU that is 95 % full but flat, or one that drifts 10 MiB/min, stays quiet. Explain your threshold in a comment |

Predict: which of these four metrics are gauges and which are counters, and what does that mean for the function you wrap them in? What does `for:` buy you for XID 79 versus temperature?
Hints: `promtool check rules` (through `promtool_check` in `platform/lib.sh`) catches syntax, not meaning. After editing, reload with `../../platform/stack.sh reload-prometheus`. The metric names are in `curl -s localhost:18031/metrics`. `FB_USED + FB_FREE` is the card's total.

Success criteria:
- `9.2a` `promtool check rules` passes and all four alert names exist
- `9.2b` verify feeds your rules synthetic series through `promtool test rules`; each alert FIRES on its bad series and the alert still carries the `UUID` and `Hostname` labels (XID stuck at 79; 92 C sustained; DBE counter jump; framebuffer +1200 MiB/min)
- `9.2c` the same alerts stay QUIET on healthy series: normal GPU, 84 C all day, 30 s temperature spike, old ECC count with no new errors, rising single-bit ECC, flat 95 % VRAM, slow drift
- `9.2d` live: verify injects an XID fault on one simulated GPU of node A through the mock fault API; `GpuXidError` fires in Prometheus for exactly that UUID (and not for healthy GPUs, and none of the four alerts fires on a healthy GPU, including the hot-but-fine one), then it resolves after the fault is cleared

### Task 9.3 — Drain or wait?

**Goal:** the mock has an active XID fault on one GPU of one node (your variant). Find it and decide.

Fill `lab/answers/xid.env`:
```
XID_CODE=           # the XID currently reported
XID_NODE=           # A or B
XID_GPU_UUID=       # UUID of the affected GPU
ACTION=             # drain | wait
REASON=             # one line, in your words
```
Predict: how will the fault show up in the metrics, and how in `nvidia-smi`? Hints: which series has a non-zero value, and what does its `UUID` label say? Application-class or hardware-class (theory 3.3)? What would you check *before* draining a node in production (replicas, PDB, spare GPUs)? Mention the evidence or the class in REASON.

Success criteria:
- `9.3a` XID_CODE, XID_NODE and XID_GPU_UUID match the live fault (variant-bound evidence)
- `9.3b` ACTION is the correct class for that XID (credited only if 9.3a passes)
- `9.3c` REASON is a real sentence (5+ words) citing the code or its class (needs 9.3a)

---

## Part B — GPU scheduling on kind (simulated capacity)

```bash
./prepare-lab.sh B
k get nodes -L nvidia.com/gpu.product                         # no GPUs yet
k get nodes -o custom-columns='N:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```
The stand-in image `python:3.12-slim` is preloaded into the kind nodes (the course is offline); pods run `sleep 3600`. The starters carry `terminationGracePeriodSeconds: 1` because `sleep` as PID 1 ignores SIGTERM. `verify.sh` applies your manifests itself, adds its own control pods, and deletes everything in `gpu-lab` afterwards; you may apply yours to experiment, but delete them before you rely on verify.

### Task 9.4 — Make the nodes advertise GPUs

**Goal:** `lab/k8s/node-gpu.sh` reads an inventory (`$INVENTORY`, default `inventory.txt` next to the script) and, for every node in it, applies what the NVIDIA device plugin and GPU Feature Discovery would: `nvidia.com/gpu` in node **status** (capacity and allocatable), labels `nvidia.com/gpu.product`, `nvidia.com/gpu.count`, `nvidia.com/gpu.memory` (MiB), and the taint `nvidia.com/gpu=present:NoSchedule` (what a GPU node pool does). It must be idempotent and must not hard-code the shipped numbers (verify runs it against a different inventory first).

Predict: what does `kubectl patch node ... -p '{"status":...}'` do without the status subresource, and why will the scheduler happily place a pod on a node whose GPUs do not exist?
Hints: extended resources live in `status`; `kubectl patch --subresource=status --type=json`; JSON pointer escapes `/` as `~1`; the scheduler reads `allocatable` (the kubelet derives it from capacity on its next sync, but write both); `--overwrite` for labels and taints.

Success criteria:
- `9.4a` capacity AND allocatable of `aiinfra-worker` / `aiinfra-worker2` follow the inventory (shipped and a changed one)
- `9.4b` product/count/memory labels carry the exact inventory strings (shipped and a changed one)
- `9.4c` both GPU nodes carry the `nvidia.com/gpu` `NoSchedule` taint; the control-plane advertises no GPU
- `9.4d` running `node-gpu.sh` a second time exits 0 and changes nothing

(From here on verify sets the reference topology itself, so a failed 9.4 does not block 9.5-T.)

### Task 9.5 — A GPU pod, and the pods that must stay Pending

**Goal:** `lab/k8s/gpu-pod.yaml`: pod `gpu-ok` in `gpu-lab` that requests **one** GPU, tolerates the taint and selects the node by the `nvidia.com/gpu.product` label of the A100 node (`NVIDIA-A100-SXM4-80GB`; copy it from the node, strings are exact).

Predict: what exactly will `k describe pod` say for a pod that asks for 4 GPUs, and what for a pod that does not tolerate the taint?

Success criteria:
- `9.5a` `gpu-ok` reaches Running on `aiinfra-worker`
- `9.5b` live object: `limits` has `nvidia.com/gpu` = 1 (requests absent or 1)
- `9.5c` control (needs 9.5a): verify's pod asking for 4 GPUs stays Pending with `Insufficient nvidia.com/gpu` (capacity is enforced, not just labelled)
- `9.5d` control (needs 9.5a): verify's pod without your toleration stays Pending on the untolerated `nvidia.com/gpu` taint

### Task 9.6 — Time-slicing ConfigMap (validated, not exercised)

**Goal:** `lab/k8s/timeslicing-cm.yaml`: ConfigMap `time-slicing-config` in namespace `gpu-lab`, label `course: aiinfra`, with one config named `any` in `data`: device-plugin config `version: v1`, time-slicing of `nvidia.com/gpu` into 4 replicas, **renamed** (`renameByDefault: true`) and `failRequestsGreaterThanOne: true`. Add a comment in the file saying what time-slicing does **not** give you.

Predict: what does the node advertise after this config on a 2-GPU node with `renameByDefault: true`, and under which resource name must a sharing-friendly pod ask?
Hints: `data.<key>` is a *string* holding YAML (`|-`); theory 4.1 shows the structure; which keys belong to `timeSlicing` and which to a `resources` entry?

Success criteria:
- `9.6a` exactly one ConfigMap `time-slicing-config` in `gpu-lab`, and `kubeconform` (strict, local schema) accepts it
- `9.6b` server-side dry-run (`kubectl apply --dry-run=server`) is accepted; nothing is applied
- `9.6c` the embedded config parses as YAML with `version: v1`, `sharing.timeSlicing.renameByDefault: true`, `failRequestsGreaterThanOne: true` and one resource `nvidia.com/gpu` with `replicas: 4`

This config is **not applied**: kind has no device plugin, so nothing would read it. In the lab you prove the manifest is well-formed and accepted, nothing more.

### Task 9.7 — Tensor-parallel Deployment

**Goal:** `lab/k8s/vllm-tp2.yaml`: Deployment `vllm-tp2` (1 replica, label `app: vllm-tp2`) whose pod needs **2 GPUs in one pod**: GPU limit and the `--tensor-parallel-size` flag (echoed by the stand-in command line) agree; it selects and tolerates the A100 node; it mounts a Memory-medium `emptyDir` at `/dev/shm`; and its update strategy still works when the model fills the node.

Predict: with the default `RollingUpdate` and a node that has exactly 2 GPUs, what happens to the second revision?

Success criteria:
- `9.7a` the pod is Running on `aiinfra-worker` only (the 2-GPU node)
- `9.7b` `limits.nvidia.com/gpu` == 2 and `--tensor-parallel-size 2` in the container command/args (consistent)
- `9.7c` `/dev/shm` is a volumeMount backed by an `emptyDir` with `medium: Memory`
- `9.7d` (needs 9.7a) verify changes the pod template and the new revision rolls out to Running within 120 s with no second pair of GPUs free
- `9.7e` control (needs 9.7a): the same pod template forced onto the 1-GPU node stays Pending with `Insufficient nvidia.com/gpu`

### Task T — Troubleshooting: the pod that never starts

`lab/k8s/broken-gpu-pod.yaml` is a copy-paste from a team wiki. `k apply` succeeds and the pod stays Pending. You are not told why.

**Goal:** edit the file so pod `broken-gpu` (same name, same namespace) reaches Running, still holding one GPU. Do not pin it with `nodeName`, do not remove the taint from the nodes, do not drop the GPU request.

Predict first: what will the Events say? Then check. Hints: `k describe pod broken-gpu`; the scheduler counts every node in exactly one bucket, so the message is a histogram. Fix one cause, re-read the message, repeat; a pod can have more than one problem.

Success criteria:
- `T.1` `broken-gpu` is Running and its live object holds exactly one GPU (`limits`)
- `T.2` (needs T.1) fixed the right way: exact resource name `nvidia.com/gpu` only, a toleration for the GPU taint, no `nodeName` in the file, taints still on the nodes

---

When done: `./verify.sh`, then the quiz, then `./cleanup.sh` before the next module.
