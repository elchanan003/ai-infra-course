#!/usr/bin/env bash
# Module 11 verify: structure, length and placeholder checks on the three planning files. No stack needed.
# It cannot judge quality; the tutor reviews content with you. Deterministic: same files -> same output.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
L="$MODULE_DIR/lab"

precond "prepare-lab.sh was run" test -f "$MODULE_DIR/.state/prepared" || {
  for id in 11.1 11.2 11.3 11.4 T.1; do blocked "$id" "environment not ready - run ./prepare-lab.sh"; done
  summary; exit $?; }

run() { python3 -I - "$1" "$2" "$MODULE_DIR/theory.md" <<'PY'
import re, sys
kind, path, theory = sys.argv[1:4]
PH = re.compile(r"<[^>]*>|_{2,}|\?\?|\b(todo|tbd|fixme|fill in|lorem|xxx|asdf|n/a)\b", re.I)
words = lambda s: re.findall(r"[A-Za-z0-9֐-׿][A-Za-z0-9֐-׿'_/.-]*", s)
norm = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
SKILLS = ["Explain the four-layer request path and TTFT vs ITL", "VRAM and KV-cache math, engine flags",
  "Operate a vLLM-style engine: queue, preemption, KV metrics", "GPU on Kubernetes: operator, device plugin, XID, taints",
  "Weights and image supply chain, manifests, mirrors", "Model intake: scanning, signing, approval, fail-closed offline",
  "Gateway keys, teams, budgets, rate limits", "Routing, fallbacks, cooldowns, retries",
  "Clients and coding tools behind the gateway", "Agents, tool calling, MCP", "Sandboxing untrusted code",
  "RAG with a vector store", "Metrics, dashboards, alert rules, tracing and cost", "Incident triage, runbooks, postmortems"]
try:
    raw = open(path, encoding="utf-8").read().splitlines()
except OSError:
    print("FAIL file missing - run ./prepare-lab.sh to restore it"); sys.exit()
def days():
    out = {}
    for l in raw:
        m = re.match(r"^\s*Day\s+([1-5])\s*:\s*(.*)$", l)
        if m and m.group(1) not in out: out[m.group(1)] = m.group(2)
    return out
def split(rest):
    m = re.match(r"^\s*focus:\s*(.*?)\s*\|\s*output:\s*(.*?)\s*$", rest, re.I)
    return (m.group(1), m.group(2)) if m else (None, None)
if kind == "self":
    got = {}
    for l in raw:
        m = re.match(r"^\s*-\s*rating:\s*(\S*)\s*\|\s*(.*?)\s*\|\s*next:\s*(.*)$", l)
        if m: got[m.group(2).strip()] = (m.group(1), m.group(3).strip())
    missing = [s for s in SKILLS if s not in got]
    if missing: print(f"FAIL {len(missing)} of 14 skill lines missing or renamed, e.g. '{missing[0]}' - keep the line format, rate in place"); sys.exit()
    bad = [s for s in SKILLS if not re.fullmatch(r"[1-5]", got[s][0])]
    if bad: print(f"FAIL {len(bad)} skills not rated 1-5 yet, e.g. '{bad[0]}'"); sys.exit()
    r = {s: int(got[s][0]) for s in SKILLS}
    if len(set(r.values())) < 2: print("FAIL every skill has the same rating - a self-assessment that differentiates is the point"); sys.exit()
    low = [s for s in SKILLS if r[s] <= 3]
    weak = [s for s in low if len(words(got[s][1])) < 4 or PH.search(got[s][1])]
    if weak: print(f"FAIL {len(weak)} skills rated 1-3 lack a concrete next step (>= 4 words, what and by when), e.g. '{weak[0]}'"); sys.exit()
    nx = [norm(got[s][1]) for s in low]
    if len(set(nx)) < len(nx): print("FAIL two skills share an identical next step - make each one specific to its skill"); sys.exit()
    print(f"OK 14 skills rated, {len(low)} with a next step")
elif kind == "questions":
    th = {norm(re.sub(r"[*_`]", "", l.strip()[2:])) for l in open(theory, encoding="utf-8") if l.strip().startswith("- ")}
    sec, qs, secs, bad, copied = None, [], set(), 0, 0
    for l in raw:
        if l.startswith("## "): sec = l[3:].strip(); continue
        m = re.match(r"^\s*-\s+(.*\S)\s*$", l)
        if not m: continue
        q = m.group(1)
        if PH.search(q): bad += 1; continue
        if not (q.endswith("?") and len(words(q)) >= 6): bad += 1; continue
        if norm(q) in th: copied += 1; continue
        qs.append(norm(q)); secs.add(sec)
    if copied: print(f"FAIL {copied} question(s) are copied verbatim from the theory - write them for your team's real components"); sys.exit()
    if len(set(qs)) < 10: print(f"FAIL {len(set(qs))} valid distinct questions (need >= 10 bullets of >= 6 words ending in '?'; {bad} bullet(s) rejected as placeholder/too short)"); sys.exit()
    if len(secs) < 4: print(f"FAIL questions cover {len(secs)} sections (need >= 4)"); sys.exit()
    print(f"OK {len(set(qs))} questions across {len(secs)} sections")
else:
    d = days()
    miss = [f"Day {i}" for i in "12345" if i not in d]
    if miss: print("FAIL missing lines: " + ", ".join(miss)); sys.exit()
    parts = {i: split(d[i]) for i in "12345"}
    badf = [f"Day {i}" for i in "12345" if parts[i][0] is None or PH.search(d[i]) or len(words(parts[i][0])) < 3 or len(words(parts[i][1])) < 3]
    if kind == "plan":
        if badf: print("FAIL not filled in as 'Day N: focus: ... | output: ...' (>= 3 words each, no placeholders): " + ", ".join(badf)); sys.exit()
        print("OK 5 days with focus and output"); sys.exit()
    if badf: print("BLOCKED plan structure incomplete: " + ", ".join(badf)); sys.exit()
    if kind == "outputs":
        weakv = {"learn", "understand", "study", "know", "read", "get", "become", "review", "familiarize", "familiarise"}
        soft = [f"Day {i}" for i in "12345" if words(parts[i][1])[0].lower() in weakv]
        if soft: print(f"FAIL {', '.join(soft)}: output is an activity, not an artefact (a document, list, table or PR you could show)"); sys.exit()
        outs = [norm(parts[i][1]) for i in "12345"]
        if len(set(outs)) < 5: print("FAIL two days have the same output"); sys.exit()
        print("OK outputs are distinct artefacts"); sys.exit()
    if kind == "prod":
        act = re.compile(r"\b(tun\w*|chang\w*|restart\w*|deploy\w*|edit\w*|test\w*|break\w*|patch\w*|upgrad\w*|scal\w*|modif\w*|reconfig\w*)\b", re.I)
        prod = re.compile(r"\bprod(uction)?\b", re.I)
        safe = re.compile(r"staging|read-only|no change|without chang|review", re.I)
        hit = [f"Day {i}" for i in "12345" if act.search(d[i]) and prod.search(d[i]) and not safe.search(d[i])]
        if hit: print(f"FAIL {', '.join(hit)} proposes changing or testing something in production in week 1 - read-only first, see theory 5.2"); sys.exit()
        print("OK no production changes planned")
PY
}
chk() { local id="$1" kind="$2" file="$3" label="$4" r; r=$(run "$kind" "$L/$file")
  case "$r" in OK*) pass "$id" "$label: ${r#OK }";; BLOCKED*) blocked "$id" "$label: ${r#BLOCKED }";; *) fail "$id" "$label: ${r#FAIL }";; esac; }
chk 11.1 self      self-assessment.md "self-assessment"
chk 11.2 questions team-questions.md  "team questions"
chk 11.3 plan      first-week-plan.md "first-week plan"
chk 11.4 outputs   first-week-plan.md "plan outputs"
chk T.1  prod      first-week-plan.md "week-1 safety"
summary
