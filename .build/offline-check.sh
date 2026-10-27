#!/usr/bin/env bash
# Offline readiness check. Read-only, no network, no containers started.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; P="$ROOT/platform"
CACHE="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}"
NOK=0; NFAIL=0
ok(){ echo "OK   $*"; NOK=$((NOK+1)); }
bad(){ echo "FAIL $*"; NFAIL=$((NFAIL+1)); }
PY="$P/.venv/bin/python"; [ -x "$PY" ] || PY=python3
set -a; . "$P/versions.env"; set +a

echo "== 1. pull_policy: never on every compose service"
for f in $(find "$P" -path '*/.venv*' -prune -o \( -name 'compose*.y*ml' -o -name 'docker-compose*.y*ml' \) -print); do
  out=$("$PY" - "$f" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for n, s in (d.get("services") or {}).items():
    if (s or {}).get("pull_policy") != "never":
        print(n)
PYEOF
) || { bad "1 cannot parse $f"; continue; }
  if [ -z "$out" ]; then ok "1 all services pull_policy=never in ${f#$ROOT/}"
  else for s in $out; do bad "1 service '$s' lacks pull_policy: never (${f#$ROOT/})"; done; fi
done
# k8s manifests: imagePullPolicy
for f in $(grep -rlE '^\s*image:' "$P/k8s" 2>/dev/null); do
  grep -q 'imagePullPolicy: *\(Never\|IfNotPresent\)' "$f" && ok "1 k8s imagePullPolicy set in ${f#$ROOT/}" || bad "1 k8s manifest ${f#$ROOT/} has image: without imagePullPolicy"
done

echo "== 2. no :latest / untagged images"
v=$(grep -nE '^[A-Z_]+_IMAGE=' "$P/versions.env" | grep -E ':latest$|=[^:]*$' || true)
[ -z "$v" ] && ok "2 versions.env images all tagged" || bad "2 versions.env: $v"
hits=$(grep -rnE '[A-Za-z0-9._/-]+:latest\b' "$P" "$ROOT"/modules --include='*.sh' --include='*.yaml' --include='*.yml' --include='*.env' --include='Dockerfile*' --include='*.json' --include='*.py' --exclude-dir=.venv --exclude-dir=.venv-aider --exclude-dir=out --exclude-dir=node_modules 2>/dev/null | grep -vE '^[^:]+:[0-9]+:\s*#|\.tutor/' || true)
[ -z "$hits" ] && ok "2 no ':latest' refs in platform/ and modules/" || { while IFS= read -r l; do bad "2 :latest ref $l"; done <<<"$hits"; }
unt=$(grep -rnE '^\s*(image:|FROM)\s+[A-Za-z0-9._/-]+\s*$' "$P" "$ROOT"/modules --include='*.yaml' --include='*.yml' --include='Dockerfile*' --exclude-dir=.venv --exclude-dir=.venv-aider --exclude-dir=out 2>/dev/null | grep -vE 'FROM\s+(scratch|base|builder)\b' || true)
[ -z "$unt" ] && ok "2 no untagged image:/FROM refs" || { while IFS= read -r l; do bad "2 untagged image ref $l"; done <<<"$unt"; }
untr=$(grep -rnE 'docker run[^|]*' "$ROOT"/modules --include='*.sh' --exclude-dir=out 2>/dev/null | grep -E '"\$\{?[A-Z_]+_IMAGE\}?"' | grep -v ':' >/dev/null; echo)
# compose images must resolve to a tagged versions.env var
for img in $(grep -E '^\s*image:' "$P/stack/compose.yaml" | sed -E 's/.*image:\s*//'); do
  name=$(sed -E 's/^\$\{([A-Z_]+)\}.*/\1/' <<<"$img")
  [ -n "${!name:-}" ] || bad "2 compose image $img not defined in versions.env"
done

echo "== 3. images present locally"
for var in $(grep -oE '^[A-Z_]+_IMAGE=' "$P/versions.env" | tr -d =); do
  [ "$var" = VLLM_CPU_BROKEN_IMAGE ] && { echo "SKIP $var (documented, not pulled)"; continue; }
  img="${!var}"
  if docker image inspect "$img" >/dev/null 2>&1; then ok "3 $img"; else bad "3 image missing: $img ($var)"; fi
done

echo "== 4. models in cache ($CACHE)"
grep -vE '^\s*(#|$)' "$P/models.txt" | while IFS='|' read -r kind name repo file; do
  if [ "$kind" = gguf ]; then
    [ -s "$CACHE/models/$file" ] && echo "OK   4 $name" || echo "FAIL 4 model missing: $CACHE/models/$file"
  else
    d="$CACHE/hf/hub/models--${repo//\//--}/snapshots"
    if compgen -G "$d/*/*.safetensors" >/dev/null; then echo "OK   4 $name"; else echo "FAIL 4 model missing: $name ($repo) under $d"; fi
  fi
done > "${TMPDIR:-/tmp}/oc4.$$"
cat "${TMPDIR:-/tmp}/oc4.$$"; NOK=$((NOK+$(grep -c '^OK' "${TMPDIR:-/tmp}/oc4.$$"))); NFAIL=$((NFAIL+$(grep -c '^FAIL' "${TMPDIR:-/tmp}/oc4.$$"))); rm -f "${TMPDIR:-/tmp}/oc4.$$"

echo "== 5. venvs"
if [ -x "$P/.venv/bin/python" ]; then
  for m in huggingface_hub mcp openai; do
    "$P/.venv/bin/python" -I -c "import $m" 2>/dev/null && ok "5 .venv import $m" || bad "5 .venv cannot import $m"
  done
  [ -x "$P/.venv/bin/hf" ] && "$P/.venv/bin/hf" --help >/dev/null 2>&1 && ok "5 .venv hf CLI runs" || bad "5 .venv hf CLI missing/broken"
else bad "5 platform/.venv missing"; fi
if [ -x "$P/.venv-aider/bin/aider" ]; then
  "$P/.venv-aider/bin/aider" --version >/dev/null 2>&1 && ok "5 .venv-aider aider --version" || bad "5 .venv-aider aider --version fails"
else bad "5 platform/.venv-aider/bin/aider missing"; fi

echo "== SUMMARY: $NOK OK, $NFAIL FAIL"
[ "$NFAIL" -eq 0 ]
