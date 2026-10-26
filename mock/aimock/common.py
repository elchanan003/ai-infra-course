import hashlib, json, math, os, sys, time, yaml


def log(level, msg, tag="APIServer pid=1"):
    ts = time.strftime("%m-%d %H:%M:%S")
    print(f"({tag}) {level} {ts} [aimock] {msg}", flush=True)


def load_yaml(path, default=None):
    try:
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return default if default is not None else {}


def est_tokens(text):
    """Mock tokenizer convention: ceil(utf8 bytes / 4), minimum 1 for non-empty text."""
    if not text:
        return 0
    return max(1, math.ceil(len(text.encode("utf-8")) / 4))


def sha(*parts, n=16):
    h = hashlib.sha256()
    for p in parts:
        h.update(str(p).encode())
        h.update(b"\0")
    return h.hexdigest()[:n]


def frac(*parts):
    """Deterministic float in [0,1) from arbitrary parts."""
    return int(sha(*parts, n=12), 16) / float(16 ** 12)


def msg_text(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for p in content:
            if isinstance(p, dict):
                out.append(p.get("text") or "")
            elif isinstance(p, str):
                out.append(p)
        return "".join(out)
    return json.dumps(content)
