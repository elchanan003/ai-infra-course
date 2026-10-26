# Course build status (for the coordinating agent, not the tutor)

If the build session died, a new agent can continue from here.
Plan: .build/PLAN.md (approved 2026-10-26). Research: .build/research-notes.md.
Coordinator = Opus, coordinates only; all authoring/testing is delegated to Sonnet subagents (model "sonnet"), English, terse reports.
Lab tests must hold the lock: flock -w 1800 /tmp/aiinfra-course-lab.lock -c '...'

| WP | Part | Status |
|---|---|---|
| WP0 | feasibility spike → .build/wp0-report.md, versions.proposed.env | running (started 2026-10-26) |
| WP1 | core docs (README, CLAUDE.md+symlinks, PROGRESS, SYLLABUS, CONVENTIONS) | done (TBD-WP0 version placeholders + TBD-WP2 lib signatures to fill later); total 45 h |
| WP2 | platform (versions.env, setup, stack, lib, doctor, k8s) | todo (after WP0) |
| WP3 | mock (mock-vllm, mock-chat, mock-dcgm, nvidia-smi, hf-mirror, tripwire) | todo (after WP0) |
| WP4-A | 00, 01, 02 | todo |
| WP4-B | 03, 08 + cheatsheets | todo |
| WP4-C | 04, 05, 06 | todo |
| WP4-D | 07, 09 | todo |
| WP4-E | 10, 11 | todo |
| WP5 | final validation, offline pass, teardown, commit | todo |
