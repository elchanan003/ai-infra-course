# 09 — Lab: reading GPU failures and writing GPU manifests

DRAFT (phase 1). Task ids are final; paths, node names and helper names marked (TBC) are confirmed in phase 2 against `platform/` and `mock/README.md`.

Time: ~2.5 h. Guidance level: guided. Work from `modules/09-gpu-on-k8s/`.
**Part A** (compose profiles `mock obs`): simulated GPUs: mock-dcgm A/B and a fake `nvidia-smi`; real Prometheus and promtool. **Part B** (kind cluster `aiinfra`, 3 nodes: control-plane + `gpu-node-a` + `gpu-node-b` (TBC)): the Kubernetes scheduler is real; GPU capacity is **simulated** by patching node status (no driver, no device plugin, no real GPU). Time-slicing is **validated, not exercised**. Say this out loud to yourself: nothing here proves a real GPU works.

```bash
./prepare-lab.sh A          # part A: mock obs, variant seeded in .state/
# ... do tasks 9.1-9.3, then:
./prepare-lab.sh B          # part B: stops mock/obs, creates the kind cluster
```

(RAM: kind and the mock stack do not run together; `prepare-lab.sh B` removes the compose containers first. Part A results stay on disk.)

## Ownership

| Path | Status |
|---|---|
| `lab/answers/smi.env` | yours: task 9.1 (starter: empty values) |
| `lab/prometheus/rules/dcgm-alerts.yml` | yours: task 9.2 (starter: empty) |
| `lab/answers/xid.env` | yours: task 9.3 (starter: empty values) |
| `lab/k8s/node-gpu.sh` | yours: task 9.4 (starter: TODO) |
| `lab/k8s/inventory.env` | given: GPUs and product string per node |
| `lab/k8s/gpu-pod.yaml` | yours: task 9.5 |
| `lab/k8s/timeslicing-cm.yaml` | yours: task 9.6 |
| `lab/k8s/vllm-tp2.yaml` | yours: task 9.7 |
| `lab/k8s/broken-gpu-pod.yaml` | given, broken: task T |
| `platform/`, `mock/`, module scripts | given: do not modify |

---

## Part A — GPU telemetry (mock-dcgm + fake nvidia-smi)

Useful: `platform/bin/nvidia-smi --node A` (TBC; fake CLI, output imitates the real tool), `curl -s localhost:18031/metrics | grep DCGM_` (node A), `curl -s localhost:18032/metrics` (node B). Prometheus: `http://100.127.87.65:18090`. The exact series and the fault API are in `mock/README.md`.

### Task 9.1 — Read the fake nvidia-smi

**Goal:** answer questions about node A from `nvidia-smi` output (the variant differs per learner).

Fill `lab/answers/smi.env`:
```
HOT_GPU_INDEX=      # index of the hottest GPU right now
HOT_GPU_UUID=       # its UUID (GPU-...)
VRAM_TOTAL_MIB=     # framebuffer total of that GPU, MiB (integer)
POWER_CAP_W=        # power cap of that GPU, W (integer)
```
Hints: `-L` vs the table; MiB are not GB; the UUID is the identity (theory 3.1).

Success criteria:
- `9.1a` values match the live variant (index and UUID of the same GPU; consistent with each other)
- `9.1b` VRAM_TOTAL_MIB and POWER_CAP_W match that GPU
- `9.1c` the answer file contains no template/placeholder values

### Task 9.2 — Alert rules for GPU health

**Goal:** write `lab/prometheus/rules/dcgm-alerts.yml` with four alerts, all per GPU and all keeping `Hostname`, `gpu` and `UUID` on the alert:

| Alert | Condition |
|---|---|
| `GpuXidError` | an XID error value is reported (non-zero) on any GPU |
| `GpuTooHot` | core temperature above 85 C for 2 minutes |
| `GpuEccUncorrected` | uncorrected (double-bit) ECC errors increased within 5 minutes |
| `GpuMemoryLeak` | framebuffer used grows steadily: positive trend over a 10-minute window that predicts exhaustion (design the expression; explain your threshold in a comment) |

Hints: which are gauges and which counters? What does `for:` buy you for XID 79 versus temperature? Validate with `promtool check rules` before the live check (`promtool` from `platform/setup.sh`, see `lib.sh` `promtool_test`).

Success criteria:
- `9.2a` `promtool check rules` passes and all four alert names exist
- `9.2b` `promtool test rules` with verify's synthetic series: each alert FIRES on its bad series with `UUID` and `Hostname` labels intact
- `9.2c` the same alerts stay QUIET on healthy series (including a hot-but-below-threshold GPU and a stable-but-high VRAM GPU)
- `9.2d` live: verify injects an XID fault on one simulated GPU via the mock fault API, `GpuXidError` fires for exactly that UUID and not for the others, and resolves after the fault is cleared

### Task 9.3 — Drain or wait?

**Goal:** the mock has an active XID fault on a node (variant). Identify it and decide the action.

Fill `lab/answers/xid.env`:
```
XID_CODE=           # the XID currently reported
XID_NODE=           # A or B
XID_GPU_UUID=       # UUID of the affected GPU
ACTION=             # drain | wait
REASON=             # one line, in your words
```
Hints: where do you read the code (metric vs `nvidia-smi`)? Application-class or hardware-class (theory 3.3)? What would you check before draining?

Success criteria:
- `9.3a` XID_CODE, XID_NODE and XID_GPU_UUID match the live fault (variant-bound evidence)
- `9.3b` ACTION is the correct class for that XID
- `9.3c` REASON is non-empty, not the template text, and mentions the evidence (code or hardware/application)

---

## Part B — GPU scheduling on kind (simulated capacity)

```bash
./prepare-lab.sh B
kubectl --context kind-aiinfra get nodes -L nvidia.com/gpu.product     # no GPUs yet
```
`k` in the helpers = `kubectl --context kind-aiinfra`.

### Task 9.4 — Make the nodes advertise GPUs

**Goal:** `lab/k8s/node-gpu.sh` applies, for each node in `lab/k8s/inventory.env`, the simulated device-plugin and GFD effects: `nvidia.com/gpu` in node status capacity **and** allocatable, plus labels `nvidia.com/gpu.product`, `nvidia.com/gpu.count`, `nvidia.com/gpu.memory` (MiB). The script is idempotent.

Hints: extended resources live in `status`, which `kubectl patch` can only reach with the `status` subresource; JSON-pointer escapes `/` as `~1`; why must allocatable be patched, not only capacity? Taint GPU nodes `nvidia.com/gpu=present:NoSchedule` (what a GPU node pool does).

Success criteria:
- `9.4a` `gpu-node-a` and `gpu-node-b` report capacity AND allocatable matching the inventory
- `9.4b` product/count/memory labels present with the exact inventory strings
- `9.4c` GPU nodes carry the `NoSchedule` taint, the control-plane/non-GPU node advertises no GPUs
- `9.4d` running `node-gpu.sh` a second time changes nothing

### Task 9.5 — A GPU pod, and the pod that must stay Pending

**Goal:** `lab/k8s/gpu-pod.yaml`: a pod `gpu-ok` (image `busybox`/the course image, command `sleep 3600`) that requests one GPU, tolerates the taint and selects the product label of `gpu-node-a`. Namespace `gpu-lab`, label `course: aiinfra`.

Success criteria:
- `9.5a` `gpu-ok` reaches Running on `gpu-node-a`
- `9.5b` the GPU is requested in `limits` (inspected on the live object), integer 1
- `9.5c` negative: verify applies its own pod asking for more GPUs than any node has: it stays Pending with `Insufficient nvidia.com/gpu` (proves capacity is enforced, not just labelled)
- `9.5d` negative: verify's pod without your toleration stays Pending with an untolerated-taint reason

### Task 9.6 — Time-slicing ConfigMap (validated, not exercised)

**Goal:** `lab/k8s/timeslicing-cm.yaml`: ConfigMap `time-slicing-config` in namespace `gpu-lab` with a config named `any`: device-plugin config `version: v1`, time-slicing of `nvidia.com/gpu` into 4 replicas, **renamed** (`renameByDefault: true`) and `failRequestsGreaterThanOne: true`.

Hints: `data.<key>` is a string holding YAML. What does `renameByDefault` do to the resource name your pods request? Write one comment in the file saying what this does NOT give you.

Success criteria:
- `9.6a` `kubeconform` passes on the file
- `9.6b` server-side dry-run (`kubectl apply --dry-run=server`) is accepted
- `9.6c` the embedded config parses as YAML and has `version: v1`, replicas 4, `renameByDefault: true`, `failRequestsGreaterThanOne: true` for resource `nvidia.com/gpu`
- (this config is NOT applied: kind has no device plugin; the lab verifies the manifest only)

### Task 9.7 — Tensor-parallel Deployment

**Goal:** `lab/k8s/vllm-tp2.yaml`: Deployment `vllm-tp2` (1 replica; image busybox stand-in with `sleep`, but write the args as if for vLLM: `--tensor-parallel-size 2`) that needs 2 GPUs in one pod, tolerates the taint, mounts a memory `emptyDir` at `/dev/shm` and uses an update strategy that works when it fills the node.

Success criteria:
- `9.7a` pod Running on the node with 2 GPUs (`gpu-node-a`) only
- `9.7b` `limits.nvidia.com/gpu` == 2 and `--tensor-parallel-size 2` in args (consistent)
- `9.7c` `/dev/shm` is a Memory-medium emptyDir
- `9.7d` strategy is `Recreate` or `maxSurge: 0` (a new revision rolls out to Running without a second GPU free: verify patches the image and waits)
- `9.7e` negative: the same Deployment forced onto the 1-GPU node (verify's variant) stays Pending with `Insufficient nvidia.com/gpu`

### Task T — Troubleshooting: the pod that never starts

`lab/k8s/broken-gpu-pod.yaml` is a copy-paste from a team wiki. `kubectl apply` succeeds and the pod stays Pending. You are not told why.

**Goal:** edit the file so the pod `broken-gpu` reaches Running (same name, same namespace, still requesting one GPU, not scheduled by removing the GPU request).

Hints: `kubectl describe pod` Events; the scheduler counts each node in one bucket, so the message is a histogram. Fix one cause, re-read the message, repeat.

Success criteria:
- `T.1` `broken-gpu` is Running and requests one GPU in limits on the live object
- `T.2` it uses the correct resource name and a toleration (not `nodeName` pinning, not removing the taint from the node)
