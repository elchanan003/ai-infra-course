#!/usr/bin/env python3
"""Structural + sanity check of a postmortem.  usage: pm_check.py FILE COMPONENT KEYWORD[,KEYWORD...]
Prints 'OK ...' or 'FAIL reason'. HTML comments and headings never count as content."""
import re, sys
path, comp, kws = sys.argv[1], sys.argv[2].lower(), [k for k in sys.argv[3].lower().split(",") if k]
try: text = open(path, encoding="utf-8").read()
except OSError: print("FAIL file missing"); sys.exit()
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
secs, cur = {}, None
for line in text.splitlines():
    m = re.match(r"^##\s+(.*\S)\s*$", line)
    if m: cur = m.group(1).strip().lower(); secs[cur] = []; continue
    if cur and not line.startswith("# "): secs[cur].append(line)
words = lambda ls: len(re.findall(r"[A-Za-z0-9]{2,}", "\n".join(ls)))
need = {"summary": 15, "impact": 10, "root cause": 25, "mitigation and fix": 15, "detection": 10}
for s, n in need.items():
    if s not in secs: print(f"FAIL section '## {s.title()}' is missing"); sys.exit()
    if words(secs[s]) < n: print(f"FAIL section '{s.title()}' needs at least {n} words of your own (has {words(secs[s])})"); sys.exit()
tl = [l for l in secs.get("timeline", []) if re.search(r"\b\d{1,2}:\d{2}\b", l) and words([l]) >= 4]
if len(tl) < 3: print(f"FAIL Timeline needs >= 3 UTC lines like '14:05 - what happened' (found {len(tl)})"); sys.exit()
rc = "\n".join(secs["root cause"]).lower()
if comp not in rc: print("FAIL Root cause does not name the component where the fault was"); sys.exit()
if kws and not any(re.search(k, rc) for k in kws): print("FAIL Root cause names the component but not the mechanism - say what was configured how, and why that hurt users"); sys.exit()
mf = "\n".join(secs["mitigation and fix"]).lower()
if not (re.search(r"mitigat", mf) and re.search(r"\bfix|durable|source of truth|permanent", mf)): print("FAIL 'Mitigation and fix' must separate what you did to stop the pain (mitigation) from the durable fix"); sys.exit()
acts = [l for l in secs.get("action items", []) if re.match(r"^\s*[-*]\s+(\[.\]\s*)?\S", l) and words([l]) >= 4]
if len(acts) < 3: print(f"FAIL Action items needs >= 3 bullets of >= 4 words (found {len(acts)})"); sys.exit()
joined = "\n".join(acts).lower()
if not re.search(r"alert|monitor|dashboard|slo|detect|probe|absent|page\b|notif", joined): print("FAIL no action item improves detection (alert/dashboard/monitor/SLO)"); sys.exit()
if not re.search(r"\bci\b|test|review|canary|rollout|limit|validat|lint|guard|policy|gate|admission|checklist|runbook|automat|template|diff|checksum", joined): print("FAIL no action item prevents recurrence (test/CI/review/limit/canary/policy)"); sys.exit()
if not any(re.search(r"\b(owner|owned by|team|oncall|on-call|sre|platform)\b", l.lower()) for l in acts): print("FAIL action items need an owner (a team or role), not just a task"); sys.exit()
blame = re.search(r"\b(careless|stupid|negligen\w*|should have known|forgot to|lazy|incompetent)\b", text.lower())
if blame: print(f"FAIL blameless tone: '{blame.group(1)}' describes a person, not a system gap"); sys.exit()
print(f"OK all sections filled, {len(tl)} timeline entries, {len(acts)} action items")
