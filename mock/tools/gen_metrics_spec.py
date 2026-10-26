"""Regenerate aimock/vllm_metrics_spec.json from the golden vLLM /metrics capture."""
import json, re, sys, collections
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
help_, typ = {}, collections.OrderedDict()
for l in lines:
    m = re.match(r'# HELP (\S+) (.*)', l)
    if m: help_[m.group(1)] = m.group(2)
    m = re.match(r'# TYPE (\S+) (\S+)', l)
    if m: typ[m.group(1)] = m.group(2)
sample = re.compile(r'^([^\s{]+)(?:\{(.*)\})? (\S+)$')
def labels(s):
    return re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', s or '')
spec = []
for name, t in typ.items():
    if name.endswith('_created') and typ.get(name) == 'gauge': continue
    if name.startswith(('python_', 'process_')): continue
    base = name[:-6] if (t == 'counter' and name.endswith('_total')) else name
    e = dict(name=base, type=t, help=help_.get(name, ''), labelnames=[], buckets=[], children=[])
    seen = set()
    for l in lines:
        m = sample.match(l)
        if not m: continue
        sn, ls, val = m.groups()
        if t == 'histogram' and sn == name + '_bucket' or (t == 'summary' and sn == name + '_count') or \
           (t in ('counter', 'gauge') and sn == name):
            lab = labels(ls)
            if sn.endswith('_bucket'):
                le = [v for k, v in lab if k == 'le'][0]
                if le != '+Inf' and float(le) not in e['buckets']: e['buckets'].append(float(le))
                lab = [(k, v) for k, v in lab if k != 'le']
            names = [k for k, _ in lab]
            if not e['labelnames']: e['labelnames'] = names
            key = tuple(v for _, v in lab)
            if key not in seen:
                seen.add(key); e['children'].append(list(key))
    spec.append(e)
json.dump(spec, open(dst, 'w'), indent=1)
print(len(spec), 'families')
