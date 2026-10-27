# ASSIGN-c1 — c1 OWNS ALL REMAINING WORK (final rebalancing 2026-10-27 06:40Z, supersedes all earlier splits)

The Opus coordinator launches no more agents. c1 (tmux aiinfra-c1, Sonnet 5.5) runs autonomously until the course is done.
Coordinator is needed only for decisions written to .build/reports/c1-questions.md and for final review.

## Authority granted to c1
- c1 may create gate markers `.build/gates/<X>.done` itself, ONLY after `.build/validate-module.sh <X>` prints `<X> PASS` with logs in `.build/evidence/<X>/` (capstone: every N=1..5 PASS).
- c1 may update the BUILD-STATUS.md rows for its work and may make LOCAL git commits (never push) after each validated module/WP. Commit only course files + .build/; no secrets.
- Do not modify platform/lib.sh, platform/stack/*, mock/* unless unavoidable; then smallest fix, re-run mock/tests/run_tests.sh (outside lab-session.sh), note it in the report.

## Current state (coordinator, 06:40Z)
- Gates present: WP2, WP3, 00, 03, 04, 07, 09 (evidence PASS).
- 04: starter total 29 vs solution 31 — make check count constant across runs if cheap, then re-validate.
- FAIL (finish, author agents A/B/C were cut off; drafts on disk, use .build/finish-prefix.md as your brief):
  - 01 (solution 1/2, non-identical) — also theory depth ≥400 lines, lab tasks per PLAN §4 (it looks shrunk: only 2 checks).
  - 02 (11/14,10/14, clean=no).
  - 05 (starter 7/20 must be 0; solution non-identical).
  - 08 (15/18) + Langfuse gate `verify.sh langfuse` run alone with profile lf.
  - 06 never validated.
- Audit for all of 00-09: theory ≥400 lines real depth, quiz 10-15 + answers, hints H1-H4, lab criteria ids == verify ids.
- Cheatsheets: vllm-flags-metrics.md, vram-kv-math.md, litellm.md, hf-airgap.md, gpu-k8s-dcgm.md, mcp-agents.md — create/finish any missing.

## Order
1. 05 (blocks capstone), then 01, 02, 06, 08 (any order; can interleave content work while waiting for the lock).
2. 10 capstone (needs gates 03, 04, 05, 09) — validate N=1..5; 11.
3. WP5: .build/validate-all.sh over all modules → .build/evidence/SUMMARY.md; platform/setup.sh from an empty cache (clean-machine; images may be re-pulled, never prune anything); .build/offline-check.sh offline pass; doctor all OK; teardown: no course containers (`docker ps -a --filter label=course=aiinfra` empty), no kind cluster aiinfra; final commit.

## Rules (unchanged)
- Every prepare/verify/cleanup/test cycle via `platform/lab-session.sh <cmd...>` (shared lock /tmp/aiinfra-course-lab.lock); one cycle at a time; leave stack down, no kind cluster after each cycle.
- Never touch non-course containers (rakazo-*, cli-proxy-api, workout-mongo, kali-cli, obs course), the `kind` network, Docker daemon; never `docker system/volume prune`. Do not modify /home/student/observability-course. Ports 18000-18199; peak RAM < 8 GB.
- Subagents (if c1 uses them): model sonnet, English, terse.
- Reports: .build/reports/c1-<topic>.md (≤20 lines each). Questions: append to .build/reports/c1-questions.md with timestamp; if no answer in 30 min, choose the conservative default, note it, continue.
