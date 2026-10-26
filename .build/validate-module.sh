#!/usr/bin/env bash
# .build/validate-module.sh NN [args...]   (runs under platform/lab-session.sh; extra args go to every script)
#   prepare-lab.sh -> verify.sh (0 PASS expected) -> .tutor/apply-solution.sh -> verify.sh x3 (100%, identical)
#   -> cleanup.sh -> verify-clean.sh x2 (pass, identical) -> restore lab/ from git (checkout + clean, rm lab.bak-*)
# Logs: .build/evidence/NN/<step>.log. Last line: "NN PASS|FAIL starter=x/y solution=a/b,a/b,a/b identical=yes|no clean=yes|no"
# "Identical" compares outputs after removing: lines starting with [PRE] [WARN] [INFO] or ~ (volatile, marked by verify),
# ISO timestamps, and tokens nonce-<hex>. Env: MODULES_DIR (default <course>/modules), EVIDENCE_DIR, KEEP_LAB=1 (skip restore).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
if [ "${AIINFRA_LAB_LOCK_HELD:-}" != 1 ]; then exec "$ROOT/platform/lab-session.sh" "$0" "$@"; fi
NN="$1"; shift; ARGS=("$@")
MODULES_DIR="${MODULES_DIR:-$ROOT/modules}"
MOD=$(ls -d "$MODULES_DIR/$NN"-* 2>/dev/null | head -1)
[ -n "$MOD" ] || { echo "$NN FAIL no module dir $MODULES_DIR/$NN-*"; exit 1; }
EV="${EVIDENCE_DIR:-$ROOT/.build/evidence}/$NN"; rm -rf "$EV"; mkdir -p "$EV"

step() {  # name script [args] -> log, returns script status
  local name="$1" s="$2"; shift 2
  [ -x "$s" ] || [ -f "$s" ] || { echo "missing $s" > "$EV/$name.log"; return 127; }
  ( cd "$MOD" && bash "$s" "$@" ) > "$EV/$name.log" 2>&1
  local rc=$?; echo "exit=$rc" >> "$EV/$name.log"; return $rc
}
score() { grep -E '^SCORE: [0-9]+/[0-9]+' "$1" | tail -1 | sed 's/^SCORE: //'; }
norm() { grep -vE '^(\[PRE\]|\[WARN\]|\[INFO\]|~|exit=)' "$1" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z?//g; s/nonce-?[0-9a-f]+/NONCE/g'; }

restore() {
  [ "${KEEP_LAB:-0}" = 1 ] && return
  git -C "$MOD" checkout -q -- lab 2>/dev/null; git -C "$MOD" clean -fdq -- lab 2>/dev/null
  rm -rf "$MOD"/lab.bak-*
}
trap restore EXIT

ok=1
step prepare "$MOD/prepare-lab.sh" "${ARGS[@]}" || { ok=0; echo "prepare failed (see $EV/prepare.log)" >&2; }
step verify-starter "$MOD/verify.sh" "${ARGS[@]}"
S0=$(score "$EV/verify-starter.log"); S0="${S0:-none}"
npass=$(grep -c '^\[PASS\]' "$EV/verify-starter.log")
[ "$npass" = 0 ] && [ "$S0" != none ] || ok=0

step apply-solution "$MOD/.tutor/apply-solution.sh" || { ok=0; echo "apply-solution failed" >&2; }
sol=(); ident=yes
for i in 1 2 3; do
  step "verify-solution-$i" "$MOD/verify.sh" "${ARGS[@]}"; rc=$?
  sc=$(score "$EV/verify-solution-$i.log"); sc="${sc:-none}"; sol+=("$sc")
  a=${sc%/*}; b=${sc#*/}
  { [ "$sc" != none ] && [ "$a" = "$b" ] && [ "$rc" = 0 ]; } || ok=0
  norm "$EV/verify-solution-$i.log" > "$EV/.n$i"
done
cmp -s "$EV/.n1" "$EV/.n2" && cmp -s "$EV/.n2" "$EV/.n3" || { ident=no; ok=0; }
rm -f "$EV"/.n?

step cleanup "$MOD/cleanup.sh" "${ARGS[@]}" || ok=0
clean=yes
for i in 1 2; do
  step "verify-clean-$i" "$MOD/verify-clean.sh" "${ARGS[@]}" || clean=no
  norm "$EV/verify-clean-$i.log" > "$EV/.c$i"
done
cmp -s "$EV/.c1" "$EV/.c2" || clean=no
rm -f "$EV"/.c?
[ "$clean" = yes ] || ok=0

restore; trap - EXIT
v=FAIL; [ "$ok" = 1 ] && v=PASS
line="$NN $v starter=$S0 solution=$(IFS=,; echo "${sol[*]}") identical=$ident clean=$clean"
echo "$line" | tee "$EV/verdict.txt"
[ "$ok" = 1 ]
