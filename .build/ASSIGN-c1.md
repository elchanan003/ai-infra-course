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

## 10:25Z note (coordinator, while c1 lead was rate-limited)
- A coordinator Sonnet agent is fixing/validating module 01 (edits only modules/01-*; appends verdict to reports/c1-01-02.md). c1: leave 01 alone until that line appears, then take everything back (01 gate if PASS, 02, 10, WP5).
- 10:48Z: coordinator agents now own 01, 02, 10 (one each; edit only their module dir; verdicts appended to reports/c1-01-02.md / c1-10-11.md as "coordinator-agent"). c1 at resume: do not edit these modules until the coordinator hands them back here.

## 11:50Z HANDBACK (coordinator): c1 owns module 10 and WP5 again; coordinator launches no agents.
- 01, 02 PASS + gated (commits 70eb796, 7e650b1). All of 00-09, 11 gated.
- 10 status (see reports/c1-10-11.md "coordinator-agent:" lines):
  - N=1 PASS (.build/evidence/10-1), N=2 PASS (.build/evidence/10-2) — do not redo.
  - N=3 FAIL (.build/evidence/10-3): prepare-lab.sh 3 dies "sick replica received no traffic" (~45x404/38x200 after sick node recreate); look at plant_3 in lib/inc3.sh.
  - N=4, N=5: apply-solution/checks/lab.md/hints realigned to HEAD inc4.sh/inc5.sh; starters 0/5 with cause FAILs; solutions NOT re-run.
  - Clean starters (answers, postmortem-1, incident-1/2 restored from a619bc6) committed in the WIP commit below — HEAD lab/ is now the starter.
- After 10 N=1..5 PASS: create gates/10.done, then WP5 (validate-all full, clean-machine setup.sh, offline-check, teardown, final commit).
