# Course build status (for the coordinating agent, not the tutor)

If the build session died, a new agent can continue from here.
Plan: .build/PLAN.md (approved 2026-10-26). Research: .build/research-notes.md.
Coordinator = Opus, coordinates only; all authoring/testing is delegated to Sonnet subagents (model "sonnet"), English, terse reports.
Lab tests must hold the lock: flock -w 1800 /tmp/aiinfra-course-lab.lock -c '...'

| WP | Part | Status |
|---|---|---|
| WP0 | feasibility spike → .build/wp0-report.md, versions.proposed.env | done: .build/wp0-report.md, versions.proposed.env; decisions in .build/decisions.md (binding) |
| WP1 | core docs (README, CLAUDE.md+symlinks, PROGRESS, SYLLABUS, CONVENTIONS) | done (TBD-WP0 version placeholders + TBD-WP2 lib signatures to fill later); total 45 h |
| WP2 | platform (versions.env, setup, stack, lib, doctor, k8s, lab-session.sh) | running (Sonnet) |
| WP3 | mock (mock-vllm, mock-chat, mock-dcgm, nvidia-smi, hf-mirror, tripwire) | running (Sonnet, parallel to WP2; interface fixed in decisions.md) |
| WP4-A | 00, 01, 02 | phase 1 running (theory/quiz/answers/draft lab.md); phase 2 (harness+validation) after WP2+WP3 gates |
| WP4-B | 03, 08 + cheatsheets | phase 1 running (theory/quiz/answers/draft lab.md); phase 2 (harness+validation) after WP2+WP3 gates |
| WP4-C | 04, 05, 06 | phase 1 running (theory/quiz/answers/draft lab.md); phase 2 (harness+validation) after WP2+WP3 gates |
| WP4-D | 07, 09 | phase 1 running (theory/quiz/answers/draft lab.md); phase 2 (harness+validation) after WP2+WP3 gates |
| WP4-E | 10, 11 | phase 1 running (theory/quiz/answers/draft lab.md); phase 2 (harness+validation) after WP2+WP3 gates |
| WP5 | final validation, offline pass, teardown, commit | todo |

Phases: authors are launched in 2 phases; phase 2 is triggered by the coordinator via SendMessage (or a new agent with finish-prefix.md if the original is gone). E phase 2 only after 03/04/05/09 validated.
Shared author docs: .build/author-brief.md, .build/finish-prefix.md. Validator: .build/validate-module.sh (WP2).

## Phase-2 notes per author (coordinator)
- E (10, 11): phase 1 done. CONFIRM items in modules/10-capstone/.tutor/design.md must be reconciled with mock/README.md + platform/stack/README.md.
- B (03, 08): phase 1 done; theory only 244/263 lines → phase 2 must deepen to ≥400 each; reconcile service names, LiteLLM metric names (live), startup error texts (golden/spike only, no paraphrase).
- D (07, 09): phase 1 done (07 theory 419, 09 theory 335 → deepen to ≥400 in phase 2). Assumes kind workers gpu-node-a (2 GPU) / gpu-node-b (1 GPU) via k8s.sh gpu-patch topology; SANDBOX_IMAGE pin; mock-chat pattern lookup_ticket (module may ship its own script.yaml); resolve all "(TBC)" against real READMEs.
- C (04, 05, 06): phase 1 done (theory 267/203/220 → deepen each to ≥400 with production depth, not padding). Phase-2 needs from WP2/WP3: litellm restart verb, LITELLM_CONFIG_DIR → lab/, 2nd replica :18041, per-backend /admin/stats peak concurrency, mock-chat Aider+FIM patterns, max_input_tokens groups, agent/coder aliases; design 4.8 (client network isolation); measure cooldown/fallback live in 5.3.
- A (00, 01, 02): phase 1 done (theory 209/221/142 → deepen; 02 especially). Lab port ranges assigned in decisions.md. Needs: hf-mirror serving a synthetic sharded repo at a pinned commit, SHA256SUMS bundle, prepare-generated pickle files with canary.
