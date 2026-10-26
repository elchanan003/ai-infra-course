# 10 — Lab: five AI-platform incidents

Time: ~5 h (about 50 min per incident). Type: Investigate -> Fix -> Explain. Guidance: **independent**.
You get a page, not a hint. Use every signal: gateway metrics, engine metrics, DCGM, logs, files, Kubernetes state.

## Situation

You are on call for the internal AI platform: clients (chat users and coding agents) call the
**LiteLLM gateway** (port 18040), which routes to **two serving replicas** (`mock-vllm` A and B, simulated
vLLM) on two simulated GPU nodes (`mock-dcgm`). Prometheus (18090) scrapes everything every 5 s; Grafana is on 18030.
Models arrive through an internal mirror and registry; the serving network is air-gapped. Incident 5 runs on a
`kind` cluster with simulated GPU nodes.

For each incident you must: find the cause, fix it **in the source of truth** so it survives a restart,
prove it with data, name the root cause, and write the postmortem.

Honest scope: gateway, Prometheus, Postgres/Valkey, registry, mirror and tripwire are real; the serving
engine, GPUs and the Kubernetes GPU capacity are simulated (see theory). Faults are real config/artifact/state
problems or simulated hardware signals.

## Starting state

`./prepare-lab.sh N` (N = 1..5) converges the stack profiles that incident needs, deploys a clean baseline from the
files in `lab/incident-N/`, waits for a few minutes of healthy traffic (your "before"), then plants incident N and prints
the page. Re-running it for the same N gives a fresh copy with a new hidden variant. Incidents are independent.

| What | Where |
|---|---|
| Gateway (OpenAI-compatible) | http://127.0.0.1:18040 (keys printed by `prepare-lab.sh`; master key from `platform/stack/README.md`) |
| mock-vllm A / B | http://127.0.0.1:18021 / :18022 (`/metrics`, `/health`, `/admin/stats`) |
| mock-dcgm node A / B | http://127.0.0.1:18031 / :18032 (`/metrics`) |
| Prometheus / Grafana | http://127.0.0.1:18090 / http://127.0.0.1:18030 |
| Tripwire hits, registry, hf-mirror | `platform/stack/README.md` (ports 18050, 18071; tripwire `GET /hits` as printed by `prepare-lab.sh 4`) |
| Cluster (incident 5) | `kubectl --context kind-aiinfra ...` |
| Source of truth | `lab/incident-N/` (what each incident re-applies on restart) |

Replace "127.0.0.1" with the Tailscale address for UIs when you are remote.

## Ownership

| Component | Status |
|---|---|
| files in `lab/incident-N/` that the page tells you are "yours" (configs, args, manifests, env files) | yours - fix them |
| `lab/answers/*`, `lab/postmortem-*.md` | yours - fill in |
| live admin-API changes, `docker exec`, hand-patched nodes | allowed for investigation or mitigation, **never counted as a fix** |
| `platform/`, `mock/`, module scripts, baseline files marked `GIVEN` in each incident folder, the monitoring stack | given - do not modify |

## Rules of engagement

- Fix durably: `verify.sh` restarts the affected components with **your files** (and re-asserts simulated hardware
  faults where the fault is "hardware") before it probes. `/admin/fault`, editing a running container or patching a
  node by hand is a mitigation that a restart undoes; it does not count.
- You may mitigate first (capture your evidence before you do), but state in the postmortem which part was
  mitigation and which was the fix.
- Answer files are `KEY=value` lines (no spaces around `=`); `#` lines are ignored. Evidence values must come from the
  signals; `verify.sh` checks them against live data that depends on your incident variant.
- Write the postmortem in your own words. Headings and template comments do not count as content.
- Take notes with timestamps while you work; the timeline of your postmortem is built from them.

```bash
./prepare-lab.sh 1          # plant incident 1 (then 2, 3, 4, 5)
./verify.sh 1               # five graded checks for incident 1
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

`COMPONENT` is one of `gateway`, `router`, `serving`, `gpu`, `artifact`, `kubernetes`, `client`.

Each incident has the same five graded checks (`N.1` .. `N.5`):

| Id | What is checked |
|---|---|
| N.1 | the fix is durable: after `verify.sh` restarts the affected components with your files (and re-asserts simulated hardware faults), the incident does not come back |
| N.2 | the platform is healthy right now: a live probe through the gateway or the affected path (no 5xx, deterministic latency under the SLO, plus incident-specific positive and negative checks) |
| N.3 | `lab/answers/N-rootcause.env`: right `COMPONENT`, right `CAUSE`, and a one-sentence `STATEMENT` |
| N.4 | `lab/answers/N-evidence.env`: values that must match the live data of your variant (numbers within tolerance, names exact) |
| N.5 | `lab/postmortem-N.md`: all sections filled, a UTC timeline of at least 3 entries, a root cause naming the component and the mechanism, at least 3 action items including one that improves detection and one that prevents recurrence |

The fields of `lab/answers/N-evidence.env` and `N-rootcause.env` for the incident are written by `./prepare-lab.sh N`
(until then those files are placeholders); fill every field from live signals. Templates with shipped values are rejected.

---

## Incident 1 - "Chat users get 429s and slow answers while one team is working" (~50 min)

`./prepare-lab.sh 1`, then read the page it prints. Start from who is sending what and which status codes
come back; size the problem before you open any config.

1. Quantify: which clients see errors (by key/team), which status codes, since when.
2. Is the engine busy, or is the gateway rejecting? Which layer is the deepest one that shows the problem?
3. Find out what limits exist, for whom, and at which scope. Compare the two gateway replicas.
4. Fix it in the source of truth, then prove it with the same signals.

## Incident 2 - "Latency spikes at peak since yesterday's release" (~50 min)

`./prepare-lab.sh 2`. Off-peak looks fine. Find what changed in the release, then what the engine does
differently under load. Peak load is replayed by the lab; read your "before" window and the incident window.

## Incident 3 - "One replica is slow and the gateway keeps sending it traffic" (~60 min)

`./prepare-lab.sh 3`. Work out which replica, why it is slow, and why the platform did not protect users.
Decide what to do about the node and what to do about the routing; they are different fixes. Give the incident a few
minutes to develop before you conclude.

## Incident 4 - "The new model rollout will not start" (~60 min)

`./prepare-lab.sh 4`. The rollout script is in `lab/incident-4/`. Read what it does and what it says; check
the artifact before you trust it, and ask whether the rollout stayed inside the air gap. Fix everything that is wrong,
not only the first thing you find.

## Incident 5 - "The model pod is Pending after the node-pool change" (~50 min)

`./prepare-lab.sh 5` (builds the `kind` cluster on first run, then plants the incident). Read what the scheduler says,
fix, and read it again.

---

## Done

- `./verify.sh --status` shows 5/5 for every incident.
- `./cleanup.sh && ./verify-clean.sh` (twice) when you finish the module; this stops the lab profiles and deletes the `kind` cluster.

## Reflection (discuss with the tutor)

1. Which incident did you detect last, and what alert would have caught it first? Write the PromQL.
2. In which incident was a single dashboard misleading? What did the second layer add?
3. Which action items could be enforced in CI (config lint, checksum gate, key template) and which need a human decision?
4. What would you put in a runbook for incident 3 so a new on-call can resolve it in five minutes?
5. Which incident would behave differently on real GPUs, and how?
