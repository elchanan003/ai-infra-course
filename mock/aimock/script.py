"""Scripted "mock-chat" mode: /config/script.yaml rules -> deterministic tool_calls / text / Aider edit blocks."""
import json, re
from .common import load_yaml, msg_text

TPL = re.compile(r"\$\{(\w+)\}|\{(nonce|tool_result|last_user|model|file)\}")


class Plan:
    def __init__(self, rule, kind, text=None, tool_calls=None, usage=None):
        self.rule, self.kind, self.text, self.tool_calls, self.usage = rule, kind, text, tool_calls or [], usage


def _render(v, vars_):
    if isinstance(v, str):
        return TPL.sub(lambda m: str(vars_.get(m.group(1) or m.group(2), m.group(0))), v)
    if isinstance(v, dict):
        return {k: _render(x, vars_) for k, x in v.items()}
    if isinstance(v, list):
        return [_render(x, vars_) for x in v]
    return v


def extract_nonce(text, rx=None):
    rx = rx or r"nonce[\"'\s:=_-]*([A-Za-z0-9_-]{6,})"
    m = re.search(rx, text or "", re.I)
    if not m:
        return (text or "").strip()
    return m.group(1) if m.groups() else m.group(0)


class Script:
    def __init__(self, path):
        d = load_yaml(path, {})
        self.rules = d.get("rules") or []
        self.enabled = bool(self.rules)
        for r in self.rules:  # validate early (fail at startup, not at request time)
            for k in ("user_regex", "any_regex"):
                if k in (r.get("match") or {}):
                    re.compile(r["match"][k])
            if not any(k in r for k in ("tool_calls", "content", "edit")):
                raise ValueError(f"script rule {r.get('name')!r}: needs one of tool_calls/content/edit")

    def match(self, ctx):
        """ctx: endpoint, model, headers, messages(list of dicts), tools(list names), prompt, suffix"""
        msgs = ctx.get("messages") or []
        last = msgs[-1] if msgs else {}
        last_role = last.get("role")
        last_user = ""
        for m in reversed(msgs):
            if m.get("role") == "user":
                last_user = msg_text(m.get("content"))
                break
        if ctx["endpoint"] == "completions":
            last_user = ctx.get("prompt") or ""
        tool_result = msg_text(last.get("content")) if last_role == "tool" else ""
        alltext = "\n".join(msg_text(m.get("content")) for m in msgs) or (ctx.get("prompt") or "")
        for r in self.rules:
            mt = r.get("match") or {}
            groups = {}
            if "endpoint" in mt and mt["endpoint"] != ctx["endpoint"]:
                continue
            if "model" in mt and mt["model"] != ctx["model"]:
                continue
            if "last_role" in mt and mt["last_role"] != last_role:
                continue
            if "has_tool" in mt and mt["has_tool"] not in ctx.get("tools", []):
                continue
            if "user_regex" in mt:
                m = re.search(mt["user_regex"], last_user, re.S)
                if not m:
                    continue
                groups = {str(i + 1): g for i, g in enumerate(m.groups())}
                groups.update({k: v for k, v in m.groupdict().items()})
            if "any_regex" in mt and not re.search(mt["any_regex"], alltext, re.S):
                continue
            ok = True
            for hk, hv in (mt.get("header") or {}).items():
                if not re.search(str(hv), ctx["headers"].get(hk.lower(), "")):
                    ok = False
            if not ok:
                continue
            vars_ = dict(groups, nonce=extract_nonce(tool_result, r.get("nonce_regex")), tool_result=tool_result,
                         last_user=last_user, model=ctx["model"])
            return self._plan(r, vars_)
        return None

    def _plan(self, r, vars_):
        name, usage = r.get("name", "unnamed"), r.get("usage")
        if "tool_calls" in r:
            tcs = []
            for tc in r["tool_calls"]:
                a = _render(tc.get("arguments", {}), vars_)
                tcs.append((tc["name"], a if isinstance(a, str) else json.dumps(a, separators=(", ", ": "))))
            return Plan(name, "tool_calls", tool_calls=tcs, usage=usage)
        if "edit" in r:
            e = _render(r["edit"], vars_)
            lang = e.get("lang", "python")
            blk = (f"{e.get('preface', 'Here is the change.')}\n\n{e['file']}\n```{lang}\n<<<<<<< SEARCH\n{e['search'].rstrip(chr(10))}\n"
                   f"=======\n{e['replace'].rstrip(chr(10))}\n>>>>>>> REPLACE\n```\n")
            return Plan(name, "text", text=blk, usage=usage)
        return Plan(name, "text", text=_render(r["content"], vars_), usage=usage)
