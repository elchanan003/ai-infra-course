# 11 - Lab: arrive with a plan

Time: ~25 min. Type: Reflect -> Plan. No services needed (no stack, no containers).

## Situation

Your onboarding starts soon. The team will assume you know the concepts; what they cannot give you is a clear
picture of your own gaps and a list of good questions. Turn the course into three short documents you will
actually use in week 1.

## Ownership

| File | Status |
|---|---|
| `lab/self-assessment.md`, `lab/team-questions.md`, `lab/first-week-plan.md` | yours - fill in (templates given) |
| `prepare-lab.sh`, `verify.sh`, `cleanup.sh`, `verify-clean.sh` | given - do not modify |
| `PROGRESS.md` (weak areas, open questions for the team) | the tutor's record; use it as input |

Commands (from `modules/11-onboarding-prep/`): `./prepare-lab.sh`, then `./verify.sh` as often as you like.
`verify.sh` checks structure, length and that no template text or placeholder is left; it cannot judge quality.
The tutor reviews the content with you. Identical files always give identical results.

## Task 1 - Self-assessment (8 min)

Rate every skill 1-5 honestly (compare with the weak areas in PROGRESS.md and your verify/quiz scores). The file
lists 14 skills across serving, GPUs, artifacts and air gap, gateway, agents, observability and incidents.
For each skill rated 1-3 write a concrete next step: what you will practise or ask, and by when.

Hints: do not rename or delete skill lines (the checker finds them by name). "Study more" is not a next step;
"read the router settings of the team and trace one fallback in staging by Thursday" is.

**Success criteria**
- 11.1 all 14 skills rated 1-5 (not all equal); every skill rated 1-3 has its own concrete next step of at least 4 words

## Task 2 - Questions for the team (7 min)

Using theory section 2 and the "Open questions for the team" in PROGRESS.md, write at least 10 questions you will
really ask, across at least 4 sections. Order them: the ones that change your first week first.

Hints: one bullet per question, ending with a question mark, at least 6 words; make them specific to a component
(see theory 2.3). Lines copied verbatim from the theory are rejected.

**Success criteria**
- 11.2 at least 10 distinct, non-placeholder questions in at least 4 sections

## Task 3 - First-week plan (5 min)

Adapt the template in theory section 5 to what you know about the team: for each day a focus and a concrete output.
Keep the exact line shape `Day N: focus: ... | output: ...`.

**Success criteria**
- 11.3 days 1-5 each have a focus and an output (at least 3 words each, no placeholders)
- 11.4 each output is an artefact you could show (document, list, table, PR) rather than an activity such as "learn" or "read", and no two outputs are the same

## Task T - Troubleshooting: the plan your colleague drafted (5 min)

The template arrives with one day already "planned" by a colleague. Read it before you fill in the rest and decide
whether it belongs in a first week, using theory 5.2. Replace it with something that does.

**Success criteria**
- T.1 no day of the plan proposes changing, tuning, restarting or testing something in production (staging, read-only work and reviewed PRs are fine)

## Done

`./verify.sh` prints `SCORE: 5/5`. Then go through the three files with the tutor, and copy them somewhere you
will have at work. Finally `./cleanup.sh` removes only the runtime state; your files in `lab/` stay.
