# Postmortem - incident 3

## Summary
The p95 latency of the chat alias doubled and some requests failed although load was normal. One GPU node had an XID error with thermal throttling, and the gateway router kept sending it half of the traffic. A router timeout and cooldown protect users; the node needs a drain and hardware ticket.

## Impact
About half of the requests went to the sick replica and were slow or failed with 5xx for the whole incident; the healthy replica was underused.

## Timeline
- 15:02 - p95 latency of the chat alias doubles
- 15:08 - per-backend request counters show one replica with slow and failed answers
- 15:15 - DCGM shows an XID error and a temperature at the throttle limit on one GPU
- 15:25 - mitigation: node cordoned and drained, traffic moves to the healthy replica
- 15:50 - fix: router timeout, retries, allowed fails and cooldown configured and verified under a still faulty node

## Root cause
Component gpu: a GPU on one node reported an XID error and thermal throttling, so its serving replica stalled and returned errors. The router made it worse because the config had no useful timeout, retries 0 and an allowed_fails of 1000 with a one second cooldown, so the failing deployment was never ejected and users waited for the full stall.

## Mitigation and fix
Mitigation: the node was drained and the replica taken out of rotation, which removes this one fault. Durable fix in the source of truth: the router config bounds the wait with a timeout, retries on the peer and ejects a failing deployment with allowed_fails and a cooldown, so the next sick node is contained without a human; the hardware goes to a replacement ticket.

## Detection
Nobody watched the DCGM XID counter or the per-backend error ratio; the first signal was the latency complaint.

## Action items
- [ ] Platform team: alert on DCGM XID errors not equal to zero and on temperature near the slowdown threshold, with a runbook link
- [ ] SRE: dashboard panel with per-backend error ratio and request share, reviewed weekly
- [ ] Platform team: CI test that fails a gateway config without timeout, retries and cooldown settings
- [ ] Hardware owner: replace the GPU and track the node until the ticket is closed
