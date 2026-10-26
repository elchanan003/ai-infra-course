#!/usr/bin/env bash
# Module 01 verify-clean: proves cleanup.sh removed runtime state and nothing else.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
n=$(docker ps -aq --filter label=course=aiinfra | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left (stack and aiinfra-lab01-* gone)" || fail C.1 "$n course container(s) still present: $(docker ps -a --filter label=course=aiinfra --format '{{.Names}}' | tr '\n' ' ')"
nn=$(docker network ls -q --filter label=course=aiinfra | wc -l)
[ "$nn" = 0 ] && pass C.2 "no course networks left" || fail C.2 "$nn course network(s) still present"
lf=""; for f in sizing.py llama.env bench.py prompt_template.py team_calc.py answers/quant.json answers/tp.json answers/vram.env variant/model.json; do [ -f "$MODULE_DIR/lab/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && pass C.3 "lab/ workspace files intact" || fail C.3 "lab files missing:$lf"
[ -s "$MODULE_DIR/.state/variant.json" ] && pass C.4 "variant assignment kept" || fail C.4 "variant.json missing"
summary
