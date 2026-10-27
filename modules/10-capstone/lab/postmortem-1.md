# Postmortem - incident 1

## Summary
Chat users of the internal assistant received HTTP 429 and slow answers while the agents team ran its nightly batch. The batch consumed the whole team quota. Capping the agent key and sharing limit state between the gateway replicas fixed it.

## Impact
Roughly every second chat request was rejected for the duration of the batch; the engines were idle, so the loss was purely a gateway decision.

## Timeline
- 14:02 - agents team starts the nightly batch on the shared team quota
- 14:04 - chat users report 429 and slow answers; page received
- 14:12 - gateway metrics show 429 only for the chat key while engine queues stay empty
- 14:20 - mitigation: paused the batch client; chat recovers
- 14:40 - fix applied in keys.yaml and the gateway config, replicas restarted and verified

## Root cause
Component gateway: the agent key had no rpm or max_parallel_requests limit, so it could use the whole team rpm quota, and the two gateway replicas kept limit counters in process memory (no shared Valkey cache), so limits were per replica and effectively doubled and unpredictable. The chat key shares the team quota, so the batch starved it and chat saw 429.

## Mitigation and fix
Mitigation: we paused the batch client to stop the pain. Durable fix in the source of truth: keys.yaml gives the agent key an rpm cap below the team quota minus the chat reserve plus a concurrency cap, and the gateway config enables the Valkey-backed cache with no response caching so both replicas count together; both replicas restarted from that config.

## Detection
We learned from users, not from an alert. The gateway exposes failed request metrics by key alias and status, but no alert watched the 429 ratio of the chat key.

## Action items
- [ ] Platform team: alert when the 429 ratio of any interactive key exceeds 2 percent for 5 minutes, tested with a promtool unit test
- [ ] Platform team: CI lint that rejects keys without an rpm cap and config without shared rate limit state, owner platform
- [ ] Agents team: set a per-key budget and concurrency cap in the key template before any batch rollout, reviewed by the platform on-call
- [ ] SRE: runbook entry that compares limits per replica when 429 appears while the engine is idle
