# Course build status (for the coordinating agent, not the tutor)

If the build session died, a new agent can continue from here.
Plan: .build/PLAN.md (approved 2026-10-26). Research: .build/research-notes.md.
Coordinator = Opus, coordinates only; all authoring/testing is delegated to Sonnet subagents (model "sonnet"), English, terse reports.
Lab tests must hold the lock: flock -w 1800 /tmp/aiinfra-course-lab.lock -c '...'

| WP | Part | Status |
|---|---|---|
| WP0 | feasibility spike → .build/wp0-report.md, versions.proposed.env | done: .build/wp0-report.md, versions.proposed.env; decisions in .build/decisions.md (binding) |
| WP1 | core docs (README, CLAUDE.md+symlinks, PROGRESS, SYLLABUS, CONVENTIONS) | done (placeholders filled by WP2); total 45 h |
| WP2 | platform (versions.env, setup, stack, lib, doctor, k8s, lab-session.sh, validate-module.sh) | done (gate .build/gates/WP2.done). Untested: gw2 replica (18041) → modules 04/05 validate it; k8s.sh fake-gpu (optional) |
| WP3 | mock (mock-vllm, mock-chat, mock-dcgm, nvidia-smi, hf-mirror, tripwire) | done (gate .build/gates/WP3.done); contract mock/README.md; tests mock/tests/run_tests.sh |
| WP4-A | 00, 01, 02 | **owned by c1** (agent A cut off by rate limit). 00 PASS (gate); 01, 02 FAIL → c1 finishes |
| WP4-B | 03, 08 + cheatsheets | **owned by c1** (agent B cut off). 03 PASS (gate); 08 FAIL + Langfuse gate → c1 |
| WP4-C | 04, 05, 06 | **owned by c1** (agent C cut off). 04 PASS (gate); 05 FAIL, 06 unvalidated → c1 |
| WP4-D | 07, 09 | **owned by c1**; 07, 09 PASS (gates) |
| WP4-E | 10, 11 | **owned by c1**; starts now that gates 03/04/09 exist + 05 |
| WP5 | final validation, offline pass, clean-machine, teardown, commit | **owned by c1**; coordinator final review |

Second worker session c1 (other account, tmux aiinfra-c1): owns WP4-D/E phase 2 + assigned WP5 sub-validations; coordination via .build/ASSIGN-c1.md, .build/reports/, gate markers .build/gates/<X>.done (created by coordinator only after verifying evidence). Coordinator = only committer.
After each usage-limit reset: re-read this file, relaunch interrupted own agents (SendMessage resume, else new agent with finish-prefix.md).
Phases: authors are launched in 2 phases; phase 2 is triggered by the coordinator via SendMessage (or a new agent with finish-prefix.md if the original is gone). E phase 2 only after 03/04/05/09 validated.
Shared author docs: .build/author-brief.md, .build/finish-prefix.md. Validator: .build/validate-module.sh (WP2).

## Phase-2 notes per author (coordinator)
- E (10, 11): phase 1 done. CONFIRM items in modules/10-capstone/.tutor/design.md must be reconciled with mock/README.md + platform/stack/README.md.
- B (03, 08): phase 1 done; theory only 244/263 lines → phase 2 must deepen to ≥400 each; reconcile service names, LiteLLM metric names (live), startup error texts (golden/spike only, no paraphrase).
- D (07, 09): phase 1 done (07 theory 419, 09 theory 335 → deepen to ≥400 in phase 2). Assumes kind workers gpu-node-a (2 GPU) / gpu-node-b (1 GPU) via k8s.sh gpu-patch topology; SANDBOX_IMAGE pin; mock-chat pattern lookup_ticket (module may ship its own script.yaml); resolve all "(TBC)" against real READMEs.
- C (04, 05, 06): phase 1 done (theory 267/203/220 → deepen each to ≥400 with production depth, not padding). Phase-2 needs from WP2/WP3: litellm restart verb, LITELLM_CONFIG_DIR → lab/, 2nd replica :18041, per-backend /admin/stats peak concurrency, mock-chat Aider+FIM patterns, max_input_tokens groups, agent/coder aliases; design 4.8 (client network isolation); measure cooldown/fallback live in 5.3.
- A (00, 01, 02): phase 1 done (theory 209/221/142 → deepen; 02 especially). Lab port ranges assigned in decisions.md. Needs: hf-mirror serving a synthetic sharded repo at a pinned commit, SHA256SUMS bundle, prepare-generated pickle files with canary.

## Platform facts for authors (WP2 report)
- `stack.sh up` exits 1 if a container exited non-zero → prepare scripts that plant a mock-vllm startup refusal set STACK_ALLOW_EXITED=1.
- Tripwire static IPs: 172.29.230.2 (aiinfra), 172.29.231.2 (aiinfra-airgap = TRIPWIRE_IP); /hits = flat {host: n}.
- HF cache: ~/.cache/aiinfra-course/hf/hub; hf-mirror mounts hf/ at /data ro.
- mock/tests/run_tests.sh takes its own flock → never run inside lab-session.sh.
- validate-module.sh strips [PRE]/[WARN]/[INFO]/`~` lines, ISO timestamps, nonce-<hex>; env MODULES_DIR, EVIDENCE_DIR, KEEP_LAB=1.

## Ownership (rebalancing 2026-10-26, until coordinator account reset ~01:30 UTC)
- (2026-10-27 01:31 UTC) Coordinator account reset: A/B/C resumed in coordinator session (still coordinator-owned). Earlier rule: coordinator launched no agents until reset. Running coordinator agents: WP4-A (00-02), WP4-B (03, 08), WP4-C (04-06) phase 2 — if one dies, coordinator marks its row "interrupted — owned by c1" and c1 takes it over (ASSIGN-c1 extra task 1).
- c1 owns: WP4-D phase 2 (07, 09), WP4-E phase 2 (10, 11; after gates 03/04/05/09), WP5 tooling (validate-all.sh, offline-check.sh).

## Final rebalancing (2026-10-27 06:40Z, supersedes above)
- ALL remaining work owned by c1 (see .build/ASSIGN-c1.md). c1 may create gates after validate PASS, update BUILD-STATUS rows, commit locally. Coordinator launches no agents; answers .build/reports/c1-questions.md; final review only.

## Ownership handover (2026-10-27 06:50 UTC) — c1 is autonomous lead for ALL remaining work
- Gates created by c1 from evidence: 00, 03, 04, 07, 09 (PASS). Local commit 49e2611.
- c1 agents running: 05+06 | 01+02 | 08 | 11 validation. Next: 10 (N=1..5) after gate 05; then cheatsheets review, WP5 (validate-all.sh, offline-check.sh, SYLLABUS/CONVENTIONS TBD placeholders, final teardown, commit).
- Reports: .build/reports/c1-*.md; questions: .build/reports/c1-questions.md
