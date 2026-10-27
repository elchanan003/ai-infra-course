# 11 - Hint ladder (tutor only)

Log per task, e.g. `11.2 [x] H2`. H3/H4 -> add the concept to Weak areas.

## Task 11.1 self-assessment
- H1: open PROGRESS.md next to the file. Which skills had low verify or quiz scores?
- H2: the rating should match evidence, not mood. A skill you only read about is a 2, not a 4. The checker needs at least two different ratings and a distinct next step per low skill.
- H3: a next step has a verb, an object and a time: "shadow the next model import and write down each approval step by day 10".
- H4: `.tutor/solution/self-assessment.md` (shows the shape; the learner's ratings are personal).
- Common failure: 11.1 "renamed" - the skill text was edited; restore the original line (`./prepare-lab.sh` does not overwrite, copy from `.verify/templates/`).

## Task 11.2 questions
- H1: which five facts about the team would change what you do on day 2?
- H2: use theory 2.1-2.3: specific, names a component, one per bullet, ends with `?`, at least 6 words.
- H3: pick one question per section: owner/deploy path (stack), approval and rollback (models), limits location (access), alerts and rota (operations), air-gap audit (security); then add 5 more specific to the engine or gateway you expect.
- H4: `.tutor/solution/team-questions.md`.
- Common failure: copied theory bullets (rejected), bullets without `?`, fewer than 4 sections used.

## Task 11.3 / 11.4 plan
- H1: for each day, what could you hand to your mentor at the end of it?
- H2: an output is a noun: checklist, diagram, PR, table, list. Avoid starting with learn/read/understand/review.
- H3: day 1 access checklist + request-path drawing; day 2 repo map + tiny PR; day 3 incident notes; day 4 starter PR; day 5 capacity/limits table.
- H4: `.tutor/solution/first-week-plan.md`.
- Common failure: lost the `focus:` / `output:` labels or the `|`; two days with the same output.

## Task T planted day
- H1: reread the colleague's Day 2 line. Which system would it touch, and who would be paged?
- H2: theory 5.2 - read-only first, never "just test" in production, staging if it exists.
- H3: replace the day with reading the engine configuration in the repo (not on the running system) and a documentation PR.
- H4: Day 2 of `.tutor/solution/first-week-plan.md`.
- Common failure: only softening the wording ("carefully restart") - still a production change; or just deleting the line (then 11.3 fails).
