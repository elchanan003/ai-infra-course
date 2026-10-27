# Postmortem - incident 4

## Summary
The rollout of the new model to the air-gapped serving pool failed and the network team saw DNS lookups from the serving subnet. The snapshot lacked its tokenizer and one shard did not match the manifest, and the loader ran without offline mode. Restoring the artifact from the registry and setting offline mode fixed both.

## Impact
The new model version could not be rolled out; the serving network made outside lookups that raised a security question, but no data left the isolated network.

## Timeline
- 09:10 - rollout started and failed with a tokenizer error
- 09:25 - the network team reports DNS lookups from the serving subnet
- 09:40 - tripwire counter shows the lookups for the configured endpoint name
- 09:55 - sha256sum against the manifest shows the missing tokenizer and one corrupt shard
- 10:20 - fix: artifact restored from the registry, checksums match, HF_HUB_OFFLINE set, rollout healthy with zero lookups

## Root cause
Component artifact: the model snapshot was incomplete and corrupt compared with the manifest from the connected side: the tokenizer file was missing and one safetensors shard had a flipped byte, which a running engine would never reveal. As a contributing factor the rollout environment lacked HF_HUB_OFFLINE, so the loader tried to resolve its configured hub endpoint and generated the DNS lookups.

## Mitigation and fix
Mitigation: we stopped retrying the rollout so the lookups ended. Durable fix in the source of truth: the artifact was pulled again from the registry and every file now matches the manifest checksum, and rollout.env sets HF_HUB_OFFLINE=1 so an incomplete artifact fails closed locally without touching the network.

## Detection
The lookups were seen by the network team, not by us; the tripwire counter showed it afterwards. Nothing verified the artifact before the rollout.

## Action items
- [ ] Platform team: alert when the tripwire or DNS log counts any query from the serving subnet
- [ ] Platform team: rollout gate that runs sha256sum against the manifest and refuses a mismatch, as a CI step
- [ ] Release owner: require HF_HUB_OFFLINE=1 in the serving template, enforced by a policy check in review
- [ ] SRE: runbook step that compares the artifact checksum before any restart
