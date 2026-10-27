# Postmortem - incident 2

## Summary
Time to first token at the daily peak was a multiple of the SLO after release 2026.10.26 although GPU utilisation looked fine. The release had raised max-num-seqs far above what the KV cache holds and disabled prefix caching. Sizing max-num-seqs to the KV budget fixed it.

## Impact
Chat requests during the 14:30 to 15:10 peak waited in the queue and were recomputed after preemption; p95 TTFT was about three times the SLO while off-peak traffic was unaffected.

## Timeline
- 14:30 - daily peak starts and queue depth rises on serving replica A
- 14:35 - kv cache usage reaches 100 percent and preemptions start
- 14:50 - on-call compares the release notes with the flags and finds max-num-seqs raised
- 15:05 - mitigation: lowered concurrency at the gateway
- 15:30 - fix: max-num-seqs sized below the KV budget, prefix caching enabled, engine restarted from the args file

## Root cause
Component serving: the release raised --max-num-seqs far beyond the number of sequences the KV cache budget of this GPU can hold and disabled prefix caching. At peak the running sequences exhausted KV blocks (kv cache usage 100 percent), the scheduler preempted and recomputed sequences, and requests queued; GPU utilisation stayed high because it was busy redoing prefill.

## Mitigation and fix
Mitigation: we limited concurrency in front of the engine to stop the queue growing. Durable fix in the source of truth: the args file now sets max-num-seqs to about 85 percent of what the KV budget supports for the mean sequence length and re-enables prefix caching; the engine was restarted from that file and the peak replay shows zero preemptions.

## Detection
The KV cache usage and preemption counters existed in Prometheus but nothing alerted on them; we noticed through the TTFT complaint.

## Action items
- [ ] Platform team: alert on kv cache usage above 90 percent for 5 minutes and on any increase of the preemption counter, with a promtool test
- [ ] Platform team: CI check that max-num-seqs times the mean sequence length stays under the KV budget of the target GPU
- [ ] SRE: peak-load canary before every serving flag change, owner on-call rotation
- [ ] Release owner: describe flag changes with their capacity effect in the release notes review
