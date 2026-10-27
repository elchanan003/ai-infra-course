#!/usr/bin/env bash
# .build/validate-all.sh [--dry-run] [ID ...]
#   ID = module number (e.g. 03) or module:arg (e.g. 10:1 -> validate-module.sh 10 1).
#   No IDs: 00..09 10:1..10:5 11. Runs validate-module.sh sequentially (it takes the lab lock itself; no lock here).
#   Continues after failures; exit 0 only if every module PASSes.
#   Output: .build/evidence/SUMMARY.md (module | verdict | wall time | date UTC),
#           .build/evidence/NN/validate-all-<ts>[-argN].log per module.
#   --dry-run: print commands, write a sample SUMMARY.md to SUMMARY.dry-run.md (runs nothing).
#   Env: EVIDENCE_DIR (default .build/evidence), VALIDATE_MODULE (default .build/validate-module.sh).
set -uo pipefail
B="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVD="${EVIDENCE_DIR:-$B/evidence}"
VM="${VALIDATE_MODULE:-$B/validate-module.sh}"
DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
[ "${1:-}" = "-h" ] && { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
IDS=("$@")
[ ${#IDS[@]} -gt 0 ] || IDS=(00 01 02 03 04 05 06 07 08 09 10:1 10:2 10:3 10:4 10:5 11)
OUT="$EVD/SUMMARY.md"; [ $DRY = 1 ] && OUT="$EVD/SUMMARY.dry-run.md"
mkdir -p "$EVD"
TS=$(date -u +%Y%m%dT%H%M%SZ)
rows=""; allok=1
for id in "${IDS[@]}"; do
  mod="${id%%:*}"; arg=""; [ "$id" != "$mod" ] && arg="${id#*:}"
  cmd=("$VM" "$mod"); [ -n "$arg" ] && cmd+=("$arg")
  suffix=""; [ -n "$arg" ] && suffix="-arg$arg"
  if [ $DRY = 1 ]; then
    echo "DRY: ${cmd[*]}  -> $EVD/$mod/validate-all-$TS$suffix.log"
    rows+="| $id | $mod PASS (dry-run sample) | 0s | $(date -u +%F\ %T) |"$'\n'; continue
  fi
  tmp=$(mktemp); t0=$SECONDS
  "${cmd[@]}" > "$tmp" 2>&1; rc=$?
  dt=$((SECONDS-t0))
  verdict=$(grep -E ' (PASS|FAIL)( |$)' "$tmp" | tail -1)
  [ -n "$verdict" ] || verdict="$mod FAIL no verdict (rc=$rc)"
  [ $rc = 0 ] && [[ "$verdict" == *" PASS"* ]] || allok=0
  mkdir -p "$EVD/$mod"; mv "$tmp" "$EVD/$mod/validate-all-$TS$suffix.log"
  echo "$id: $verdict (${dt}s)"
  rows+="| $id | $verdict | ${dt}s | $(date -u +%F\ %T) |"$'\n'
done
{ echo "# Validation summary"; echo; echo "| module | verdict | wall time | date UTC |"; echo "|---|---|---|---|"; printf '%s' "$rows"; } > "$OUT"
echo "wrote $OUT"
[ $DRY = 1 ] && exit 0
[ $allok = 1 ]
