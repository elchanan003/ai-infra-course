You are resuming interrupted work on the hands-on "AI Infrastructure & Platform (LLMOps)" course at /home/student/ai-infra-course. English only; terse.

A previous author agent was cut off (rate limit / crash). Its drafts are on disk. Your job: AUDIT the modules assigned below, FINISH anything missing or weak, and VALIDATE them for real.

First read .build/author-brief.md (binding: content, harness rules, lock rule, validation) and everything it lists. Check .build/BUILD-STATUS.md and .build/evidence/NN/ for what was already proven.

Audit per module: all contract files exist and are non-trivial; theory accurate for pinned versions, in scope, ends with Key takeaways + Check yourself; lab.md tasks match PLAN §4, troubleshooting task present, criteria ids == verify.sh ids; quiz 10-15 with answers; hints H1-H4 per task; lab/ is a clean starter (no solved answers, no lab.bak-*).
Then `.build/validate-module.sh NN` until it prints `NN PASS`; fix harness defects (measure behaviour, empty = 0, no flakiness). Leave stack down, no kind cluster. Do not git commit. Final report ≤ 15 lines with verdict lines.

YOUR ASSIGNMENT:
