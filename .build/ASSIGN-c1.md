# Assignment for worker session c1 (second account, tmux `aiinfra-c1`, Sonnet 5.5)

You are a WORKER, not the coordinator. The coordinator (other session) is the only one who commits and edits BUILD-STATUS.md / decisions.md. English only; terse.
Coordination is ONLY through files under /home/student/ai-infra-course/.build/ and the shared lab lock.

## Read first
.build/author-brief.md (binding), .build/finish-prefix.md, CONVENTIONS.md, .build/decisions.md (binding; overrides PLAN), .build/PLAN.md §4-§5, .build/BUILD-STATUS.md (incl. "Phase-2 notes per author"), mock/README.md and platform/stack/README.md once they exist, platform/lib.sh header.

## Gates (wait for these marker files; coordinator creates them)
- `.build/gates/WP2.done` and `.build/gates/WP3.done` → platform + mocks validated. Before they exist you may only write content (lab/ starters, hints, solutions, script drafts, deepen theory); do NOT run containers or kind.
- `.build/gates/03.done`, `04.done`, `05.done`, `09.done` → prerequisites for WP4-E phase 2.
Poll cheaply (e.g. check every ~10 min); don't busy-loop.

## Your work packages
1. **WP4-D phase 2 — modules 07-agents-mcp-sandbox-rag, 09-gpu-on-k8s** (+ cheatsheets mcp-agents.md, gpu-k8s-dcgm.md, hf-airgap.md: review/fix only).
   Phase-1 files already exist: modules/07-*/{theory.md (419 lines), quiz.md, lab.md (DRAFT), .tutor/answers.md}, modules/09-*/{theory.md (335 lines → deepen to ≥400 real depth), quiz.md, lab.md (DRAFT), .tutor/answers.md}, the three cheatsheets.
   To do: resolve every "(TBC)" against the real READMEs; lab/ starters; .tutor/hints.md (H1-H4), .tutor/solution/, .tutor/apply-solution.sh; prepare-lab.sh (09: `A|B` parts), verify.sh, cleanup.sh, verify-clean.sh; fill lab-answers in answers.md. Ports: module 07 uses 18130-18134 only (decisions.md). kind topology for 09 via platform/k8s.sh gpu-patch (gpu-node-a 2 GPU, gpu-node-b 1 GPU) — if k8s.sh can't express it, ship a module-local topology YAML.
   Done = `.build/validate-module.sh 07` and `... 09` print `NN PASS` + each planted fault caught once.
2. **WP4-E phase 2 — modules 10-capstone, 11-onboarding-prep** (after the 4 gates above).
   Phase-1 files exist: modules/10-capstone/{theory.md, lab.md, quiz.md, .tutor/answers.md, .tutor/design.md (CONFIRM items to reconcile)}, modules/11-onboarding-prep/{theory.md, lab.md, quiz.md, .tutor/answers.md}.
   To do: everything else in the file contract; capstone `prepare-lab.sh N` / `verify.sh N` / `verify.sh --status`, pm_check approach from the sibling (/home/student/observability-course/modules/10-capstone). Capstone ports 18140-18144. Reuse modules' fault mechanics only via platform/mock contracts (don't edit other modules).
   Done = `validate-module.sh 10 N` PASS for N=1..5 and `validate-module.sh 11` PASS.
3. **WP5 sub-validations** — later, only when the coordinator adds a task to this file under "## Extra tasks".

## Rules
- Spawn your own subagents with model "sonnet" for authoring if useful; you are responsible for their output.
- Every container/kind sequence through `platform/lab-session.sh <cmd...>` (shared flock lock with the coordinator's agents). Leave stack down and no kind cluster when releasing.
- Edit ONLY modules/07-*, 09-*, 10-*, 11-* and the three cheatsheets above. platform/, mock/, other modules, core docs: never edit — if something blocks you, write the need in your report and continue with other work.
- Never touch non-course containers; never prune; do not git commit; do not push.
- Write files incrementally (you may hit rate limits; on restart, re-read this file and your report, continue).

## Reporting
Append terse English progress to `.build/reports/c1-<topic>.md` (topics: `07-09`, `10-11`, `wp5`): after each milestone one line `<UTC time> <module> <status> <evidence path or verdict line>`, and blockers/needs on separate lines prefixed `NEED:`. Final entry per topic: validate-module verdict lines + known limitations (≤ 15 lines).

## Extra tasks
Ownership rule: a module group is yours ONLY when BUILD-STATUS.md says "owned by c1" for it. Never edit modules owned by the coordinator's running agents (WP4-A 00-02, WP4-B 03/08 + cheatsheets vllm-flags-metrics.md/vram-kv-math.md, WP4-C 04-06 + cheatsheets/litellm.md).

1. **Takeover of interrupted coordinator agents (standing task).** If BUILD-STATUS.md marks WP4-A, WP4-B or WP4-C as "interrupted — owned by c1", finish that group: prompt = .build/finish-prefix.md + "YOUR ASSIGNMENT: modules <ids> (+ their cheatsheets)", check .build/evidence/NN/ and BUILD-STATUS phase notes first. Done = validate-module.sh NN PASS for each. Report .build/reports/c1-takeover-<ids>.md.
2. **WP5 tooling: .build/validate-all.sh** (you own this file). Runs `.build/validate-module.sh` sequentially for the module ids given (capstone as `10 N` for N=1..5), via the existing lock semantics (validate-module.sh already locks — do not double-lock), and writes `.build/evidence/SUMMARY.md` (table: module, verdict line, wall time, date). Done = run on at least one module that already has a gate marker in .build/gates/ (e.g. NN.done), output table produced.
3. **WP5 tooling: .build/offline-check.sh** (you own this file). Static + local checks, no network: every service in platform/stack/compose.yaml has `pull_policy: never`; no `:latest` or untagged images in versions.env, compose files or modules/*/ scripts; every image in versions.env present locally (`docker image inspect`); models in platform/models.txt present in ~/.cache/aiinfra-course; platform/.venv and .venv-aider importable (`hf`, `mcp`, `openai`, `aider --version`). Prints OK/FAIL lines + summary, exit 0 only if all OK. Done = runs, output saved to .build/evidence/offline-check.log; FAIL lines listed as NEED: in your report (do not fix files you don't own).
Report for 2-3: .build/reports/c1-wp5.md.
