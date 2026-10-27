# 10 - Lab: five AI-platform incidents

Time: ~5 h (about 50 min per incident). Type: Investigate -> Fix -> Explain. Guidance: **independent**.
You get a page, not a hint. Use every signal: gateway metrics, engine metrics, DCGM, logs, files, Kubernetes state.

## Situation

You are on call for the internal AI platform: clients (chat users and coding agents) call the
**LiteLLM gateway** (port 18040, second replica 18041 in incident 1), which routes to **two serving replicas**
(`mock-vllm` A and B, simulated vLLM) on two simulated GPU nodes (`mock-dcgm`). Prometheus (18090) scrapes everything
every 5 s; Grafana is on 18030. Models arrive through an internal HF mirror; the serving network is air-gapped.
Incident 5 runs on a `kind` cluster with simulated GPU nodes.

For each incident you must: find the cause, fix it **in the source of truth** so it survives a restart,
prove it with data, name the root cause, and write the postmortem.

Honest scope (also see theory, honesty box): gateway, Postgres/Valkey, Prometheus, registry, tripwire, the Docker air-gap
network and the Kubernetes scheduler are **real**. The serving engines (`mock-vllm`), GPUs and DCGM signals (`mock-dcgm`),
the model weights of incident 4 (random bytes in real safetensors framing) and the Kubernetes GPU capacity plus the
device plugin (`gpu-plugin-sim.sh`) are **simulated**. Faults are real config/artifact/state problems or simulated hardware
signals. Latencies are in the engine's virtual seconds; production has real CUDA/NCCL/driver failures and real cold starts.

## Starting state

`./prepare-lab.sh N` (N = 1..5) converges what incident N needs, writes `lab/incident-N/`, runs a short healthy baseline
(your "before"), plants incident N and prints the page with the UTC **incident window** (use it for Prometheus queries).
Re-running it for the same N gives a fresh copy with a new hidden variant and saves your previous folder as `lab.bak-prepare-*`.
Incidents are independent; preparing one replaces the infrastructure of another. Wrap in `platform/lab-session.sh` if other course work may run.

| What | Where |
|---|---|
| Gateway (OpenAI-compatible) | http://127.0.0.1:18040 (master key in `platform/stack/README.md`); incident 1 adds a replica on :18041 |
| mock-vllm A / B | http://127.0.0.1:18021 / :18022 (`/metrics`, `/health`, `/admin/stats`) |
| mock-dcgm node A / B | http://127.0.0.1:18031 / :18032 (`/metrics`) |
| Prometheus / Grafana | http://127.0.0.1:18090 / http://127.0.0.1:18030 |
| Tripwire hits, HF mirror | `GET http://127.0.0.1:18072/hits`; hf-mirror `http://127.0.0.1:18071` (incident 4) |
| Cluster (incident 5) | `kubectl --context kind-aiinfra ...` |
| Source of truth | `lab/incident-N/` (what each incident re-applies on restart) |

Replace "127.0.0.1" with the Tailscale address for UIs when you are remote. Module-10 containers use ports 18140-18144 only if you start your own.

## Ownership

| Component | Status |
|---|---|
| files in `lab/incident-N/` that the page names as "yours" (configs, args, key policy, env files, manifests, the model cache of incident 4) | yours - fix them |
| `lab/answers/*`, `lab/postmortem-*.md` | yours - fill in |
| `lab/incident-N/restart.sh`, `apply-keys.sh`, `rollout.sh`, `MANIFEST.sha256`, `gpu.yaml`, `RELEASE-NOTES.md`, `PEAK.md`, `keys.env` | GIVEN - read them, do not edit (verify restores them) |
| live admin-API changes, `docker exec`, hand-patched nodes | allowed for investigation or mitigation, **never counted as a fix** |
| `platform/`, `mock/`, `lib/`, module scripts, the monitoring stack | given - do not modify |

## Rules of engagement

- Fix durably: `verify.sh` restarts the affected components with **your files** (and re-asserts simulated hardware
  faults where the fault is "hardware") before it probes. `/admin/fault`, editing a running container or patching a
  node by hand is a mitigation that a restart undoes; it does not count.
- Restart with the GIVEN helper of the incident (`lab/incident-N/restart.sh`). Do not run `platform/stack.sh up` without the
  lab environment: it would switch the config directory back to the default.
- You may mitigate first (capture your evidence before you do), but state in the postmortem which part was
  mitigation and which was the fix.
- Answer files are `KEY=value` lines (no spaces around `=`); `#` lines are ignored; `<...>` placeholders are rejected. Evidence
  values must come from the signals; `verify.sh` checks them against live data that depends on your hidden variant.
- Write the postmortem in your own words. Headings and template comments do not count as content. Blameless.
- Take notes with timestamps while you work; the timeline of your postmortem is built from them.

```bash
./prepare-lab.sh 1          # plant incident 1 (then 2, 3, 4, 5)
./verify.sh 1               # five graded checks for incident 1 (restarts components from your files, ~2-8 min)
./verify.sh --status        # your results so far
```

Valid root-cause enums (used in `N-rootcause.env`; discrimination rules in theory section 6):

| CAUSE | Meaning |
|---|---|
| `bad-release` | a deployed change in the component's own behaviour broke it |
| `misconfiguration` | a wrong value (URL, flag, env) with no more specific class |
| `rate-limit-misconfig` | limits/quotas absent, mis-scoped or not shared, so one client starves others |
| `kv-cache-exhaustion` | engine KV memory is the saturated resource |
| `capacity-overload` | demand exceeds capacity with everything configured correctly |
| `hardware-fault` | GPU/node fault (XID, ECC, thermal) |
| `artifact-integrity` | model artifact missing, partial or corrupt versus its manifest |
| `air-gap-leak` | something reaches outside the isolated network |
| `scheduling-config` | scheduler constraints or device-plugin config prevent placement |
| `dependency-outage` | a downstream system is down or unreachable |
| `runaway-client` | a client breaks a correct agreement |

`COMPONENT` is one of `gateway`, `router`, `serving`, `gpu`, `artifact`, `kubernetes`, `client`. `STATEMENT` is one sentence of at least
six words that names the mechanism (what was configured how, and why users were hurt).

## Graded checks (ids equal `verify.sh` output)

| Id | What is checked |
|---|---|
| N.1, N.2 | incident-specific, see the table below. Both restart or redeploy from **your** files first. N.2 is BLOCKED if N.1 fails |
| N.3 | `lab/answers/N-rootcause.env`: right `COMPONENT`, right `CAUSE` (a wrong value gets the discrimination rule that rejects it), a `STATEMENT` naming the mechanism |
| N.4 | `lab/answers/N-evidence.env`: values that must match the live data of your variant (numbers within tolerance, names exact) |
| N.5 | `lab/postmortem-N.md`: all sections filled, a UTC timeline of at least 3 entries, a root cause naming the component and the mechanism, mitigation separated from the fix, at least 3 action items with an owner, one that improves detection and one that prevents recurrence |

| Incident | N.1 | N.2 | N.4 fields |
|---|---|---|---|
| 1 gateway | a key with `rpm_limit: 3` yields exactly 3 x 200 across **both** replicas after a restart with your config and `keys.yaml` | an agent flood is rejected inside the team quota while the chat key keeps its reserve (8 of 8 x 200), no 5xx, engine TTFT p95 within the SLO | `HEAVY_KEY_ALIAS`, `TEAM_RPM_LIMIT`, `CHAT_429_COUNT`, `LIMIT_SCOPE` |
| 2 serving | engine A restarts healthy from your args and still serves the 4,096-token window | replay of the daily peak: all 200, 0 preemptions, KV peak under 95 %, TTFT p95 within the SLO, gateway path healthy | `KV_PEAK`, `PREEMPTIONS`, `PEAK_WAITING`, `PLANTED_MAX_NUM_SEQS` |
| 3 gpu + router | with the hardware fault re-asserted, the failing replica serves at most a few of 40 requests, and takes traffic again after a cooldown once healthy | 40 of 40 user requests answered, none waits as long as the sick replica stalls | `AFFECTED_NODE`, `XID_CODE`, `GPU_UUID`, `DRAIN_DECISION`, `TEMP_C` |
| 4 artifact | every snapshot file matches `MANIFEST.sha256` and `rollout.sh` serves a completion inside `aiinfra-airgap` | zero DNS lookups from the air-gapped network, and an incomplete artifact fails closed without touching the network | `MISSING_FILE`, `BAD_FILE`, `BAD_SHA`, `TRIPWIRE_HOST`, `TRIPWIRE_HITS` |
| 5 kubernetes | after a clean redeploy from your three files (no leftover objects, no hand-patched capacity) the model pod is Ready on the new pool | a second GPU pod runs, a pod asking for more GPUs than advertised stays Pending with `Insufficient nvidia.com/gpu` | `NODE_NAME`, `TAINT_KEY`, `WRONG_RESOURCE`, `FIRST_REASON`, `SECOND_REASON`, `GPU_CAPACITY_AFTER` |

Template files for all answers and postmortems are shipped in `lab/`; the field names are the table above.

---

## Incident 1 - "Chat users get 429s and slow answers while one team is working" (~50 min)

`./prepare-lab.sh 1`, then read the page. Your files: `lab/incident-1/litellm/config.yaml`, `keys.yaml` (applied by the GIVEN `apply-keys.sh`).

1. Quantify: which clients see errors (by key/team), which status codes, since when. Size the problem before you open any config.
2. Is the engine busy, or is the gateway rejecting? Which layer is the deepest one that shows the problem?
3. Find out what limits exist, for whom, and at which scope. Compare the two replicas (what does each one count?).
4. Fix it in the source of truth: the key policy must leave the chat key its reserve (the page states the policy), and the limit state must mean the same on both replicas. Restart with `restart.sh`, re-apply the keys.
5. Prove it with the same signals, then fill the answers and the postmortem.

Success: 1.1, 1.2 (fix), 1.3 (enum), 1.4 (evidence), 1.5 (postmortem).

## Incident 2 - "Latency spikes at peak since yesterday's release" (~50 min)

`./prepare-lab.sh 2`. Your file: `lab/incident-2/mock-vllm-a/args`. Off-peak looks fine; the peak was replayed once for you.

1. Read `RELEASE-NOTES.md` and `PEAK.md`: which of the changes can matter and which are decoys? Say why for each.
2. Read your "before" and incident windows: running, waiting, KV usage, preemptions, TTFT, generation tokens. Draw the chain in the order the signals appear.
3. Size it: how many sequences of the peak's length does this GPU's KV budget hold (module 01 maths, the engine prints the numbers at start)? Compute before you edit.
4. Fix `args` so the peak is served without preemption and with margin, without shrinking the context contract. Restart with `restart.sh` and replay the peak yourself.
5. Evidence, answers, postmortem.

Success: 2.1-2.5.

## Incident 3 - "One replica is slow and the gateway keeps sending it traffic" (~60 min)

`./prepare-lab.sh 3`. Your file: `lab/incident-3/litellm/config.yaml`. Give the incident a few minutes to develop before you conclude.

1. Work out which replica, why it is slow, and which hardware signal explains it (DCGM, `nvidia-smi` inside the exporter container).
2. Decide separately what you do about the node (drain? wait? by which signal?) and what you do about the routing. They are different fixes: the node stays sick during verification.
3. Protect users in the router: bounded wait, retry on the peer, ejection with a way back. Think about what each number costs (the page and `config.yaml` comments contain a tuning that "stops flapping").
4. Evidence, answers, postmortem. The postmortem needs both: the fault and the missing guard.

Success: 3.1-3.5.

## Incident 4 - "The new model rollout will not start" (~60 min)

`./prepare-lab.sh 4`. Files: `lab/incident-4/rollout.env`, `hf-cache/` (yours); `rollout.sh`, `MANIFEST.sha256` (given).

1. Run `lab/incident-4/rollout.sh` and read what it says. Check the tripwire counter before and after.
2. Check the artifact before you trust it: verify every file against the manifest from the connected side. Capture what you find **before** you replace anything (the corrupt file's checksum is evidence).
3. Ask whether the rollout stayed inside the air gap. Which setting turns a slow, networked failure into a fast, local one - and what does it not fix?
4. Fix everything that is wrong, not only the first thing: restore the artifact (the connected side's copy is served by the HF mirror) and the environment. Prove it twice: the engine serves, and an incomplete artifact still fails closed without a single lookup.
5. Evidence, answers, postmortem.

Success: 4.1-4.5.

## Incident 5 - "The model pod is Pending after the node-pool change" (~50 min)

`./prepare-lab.sh 5` (stops the compose stack, builds the `kind` cluster on first run - several minutes - then plants the incident). Files: `lab/incident-5/model.yaml`, `device-plugin.yaml`, `time-slicing.yaml`; apply them yourself with `kubectl --context kind-aiinfra apply -f` (verify applies all three too).

1. Read what the scheduler says (`describe pod`, events), then what the nodes offer (`describe node`: taints, labels, Capacity/Allocatable).
2. Fix, re-apply, read the event again: reasons stack, a fixed one reveals the next.
3. Be ready to explain why patching the node by hand would not have been a fix, and what time-slicing does and does not give you.
4. Evidence, answers, postmortem.

Success: 5.1-5.5.

---

## Done

- `./verify.sh --status` shows 5/5 for every incident.
- `./cleanup.sh && ./verify-clean.sh` (twice) when you finish the module; this removes the rollout containers, lab key/team, the compose stack and the `kind` cluster.

## Reflection (discuss with the tutor)

1. Which incident did you detect last, and what alert would have caught it first? Write the PromQL.
2. In which incident was a single dashboard misleading? What did the second layer add?
3. Which action items could be enforced in CI (config lint, checksum gate, key template) and which need a human decision?
4. What would you put in a runbook for incident 3 so a new on-call can resolve it in five minutes?
5. Which incident would behave differently on real GPUs, and how?
