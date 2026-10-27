# Postmortem - incident 5

## Summary
After the node-pool change the model-serving pod stayed Pending. The new pool's node carried a taint the pod did not tolerate and the time-slicing config used the wrong resource name, so the node advertised no nvidia.com/gpu. Adding the toleration and fixing the resource name fixed it.

## Impact
The model was not serving from the new pool; the old pool kept its capacity, so users saw reduced capacity but no outage.

## Timeline
- 08:30 - node-pool change applied, new pool nodes joined with a taint
- 08:40 - model pod Pending; describe pod shows an untolerated taint
- 08:55 - toleration added; pod still Pending with Insufficient nvidia.com/gpu
- 09:10 - describe node shows the wrong extended resource name and zero nvidia.com/gpu
- 09:20 - fix: time-slicing resource name corrected, capacity republished, pod Ready on the new pool

## Root cause
Component kubernetes: two stacked scheduling problems. The pod had no toleration for the taint of the new pool, and the device-plugin DaemonSet did not tolerate it either, so no plugin pod ran on the node, and the time-slicing ConfigMap named the resource nvidia.com/gpus, which the plugin ignores, so the node had zero allocatable nvidia.com/gpu. The scheduler reasons appeared one after the other as each was fixed.

## Mitigation and fix
Mitigation: none was needed beyond keeping the old pool serving. Durable fix in the source of truth: model.yaml and device-plugin.yaml carry the toleration and time-slicing.yaml uses the exact resource name; all are applied by the pipeline and a clean redeploy from the files results in a Ready pod.

## Detection
The pod was Pending for hours without an alert. Pending pods and nodes with zero allocatable GPUs were not monitored.

## Action items
- [ ] Platform team: alert when a pod stays Pending longer than 10 minutes and when a GPU node reports zero allocatable GPUs
- [ ] Platform team: admission or CI check that every pod requesting GPUs tolerates the taints of its target pool
- [ ] SRE: node-pool change checklist with a canary pod before moving workloads, owner on-call
- [ ] Platform team: schema validation of the time-slicing config resource name in CI
