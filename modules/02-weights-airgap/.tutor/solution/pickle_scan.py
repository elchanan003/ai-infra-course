#!/usr/bin/env python3
"""Static pickle scanner (task 2.2) - reference solution. Never unpickles."""
import io, json, pickletools, sys, zipfile

ALLOW = {("collections", "OrderedDict"), ("torch._utils", "_rebuild_tensor_v2"), ("torch._utils", "_rebuild_parameter"),
         ("torch", "FloatStorage"), ("torch", "BFloat16Storage"), ("torch", "HalfStorage"), ("torch", "LongStorage"),
         ("torch", "Size"), ("torch", "device"), ("numpy.core.multiarray", "_reconstruct"), ("numpy", "ndarray"), ("numpy", "dtype")}
STR_OPS = {"SHORT_BINUNICODE", "BINUNICODE", "BINUNICODE8", "UNICODE", "STRING", "BINSTRING", "SHORT_BINSTRING"}


def scan_pickle(data):
    findings, memo, recent = [], {}, []
    def check(op, mod, name):
        if (mod, name) not in ALLOW:
            findings.append({"opcode": op, "module": mod, "name": name})
    for op, arg, pos in pickletools.genops(data):
        n = op.name
        if n in STR_OPS:
            recent.append(arg)
        elif n in ("BINGET", "LONG_BINGET", "GET"):
            recent.append(memo.get(arg))
        elif n == "MEMOIZE":
            memo[len(memo)] = recent[-1] if recent else None
        elif n in ("BINPUT", "LONG_BINPUT", "PUT"):
            memo[arg] = recent[-1] if recent else None
        elif n == "GLOBAL":
            mod, name = arg.split(" ", 1); check("GLOBAL", mod, name)
        elif n == "STACK_GLOBAL":
            mod, name = (recent[-2], recent[-1]) if len(recent) >= 2 else (None, None); check("STACK_GLOBAL", mod, name)
        elif n in ("INST", "OBJ"):
            findings.append({"opcode": n, "module": None, "name": None}) if n == "INST" else None
        else:
            recent.append(None)
        recent[:] = recent[-4:]
    return findings


def scan(path):
    try:
        raw = open(path, "rb").read()
        findings = []
        if raw[:2] == b"PK":
            z = zipfile.ZipFile(io.BytesIO(raw))
            for n in z.namelist():
                if n.endswith(".pkl"):
                    findings += scan_pickle(z.read(n))
        else:
            findings = scan_pickle(raw)
    except Exception as e:
        return {"file": path, "verdict": "dangerous", "findings": [{"opcode": "PARSE_ERROR", "module": None, "name": str(e)[:80]}]}
    return {"file": path, "verdict": "dangerous" if findings else "safe", "findings": findings}


if __name__ == "__main__":
    results = [scan(p) for p in sys.argv[1:]]
    for r in results:
        print(json.dumps(r))
    sys.exit(1 if any(r["verdict"] == "dangerous" for r in results) else 0)
