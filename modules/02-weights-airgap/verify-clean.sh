#!/usr/bin/env bash
# Module 02 verify-clean: proves cleanup.sh removed runtime state and nothing else.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
n=$(docker ps -aq --filter label=course=aiinfra | wc -l)
[ "$n" = 0 ] && pass C.1 "no course containers left" || fail C.1 "$n course container(s) still present: $(docker ps -a --filter label=course=aiinfra --format '{{.Names}}' | tr '\n' ' ')"
nn=$(docker network ls -q --filter label=course=aiinfra | wc -l)
[ "$nn" = 0 ] && pass C.2 "no course networks left" || fail C.2 "$nn course network(s) still present"
vols=$(docker volume ls -q --filter label=course=aiinfra | grep -E 'seaweedfs-data|registry-data' | tr '\n' ' ')
[ -z "$vols" ] && pass C.3 "store data volumes removed (S3 objects, registry content)" || fail C.3 "store volumes still present: $vols"
refs=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost:18050/aiinfra/' | tr '\n' ' ')
[ -z "$refs" ] && pass C.4 "no local tags for the internal registry" || fail C.4 "local registry tags remain: $refs"
HUB="${AIINFRA_CACHE:-$HOME/.cache/aiinfra-course}/hf/hub"
ls -d "$HUB"/models--aiinfra-lab--tiny-* >/dev/null 2>&1 && fail C.5 "synthetic repo still in the mirror cache" || pass C.5 "synthetic repo removed from the mirror cache"
docker image inspect "$LLAMACPP_IMAGE" >/dev/null 2>&1 && pass C.6 "course images untouched ($LLAMACPP_IMAGE present)" || fail C.6 "the llama.cpp image is gone - cleanup removed too much"
lf=""; for f in REPOS.env pickle_scan.py s3-sync.py s3-serve.env airgap/run.sh airgap/offline.env registry/answers.env answers/header.json answers/incident.json; do [ -f "$MODULE_DIR/lab/$f" ] || lf="$lf $f"; done
[ -z "$lf" ] && [ -d "$MODULE_DIR/lab/pickles" ] && [ -d "$MODULE_DIR/lab/incoming" ] && pass C.7 "lab/ workspace intact" || fail C.7 "lab files missing:$lf"
[ -s "$MODULE_DIR/.state/variant.json" ] && pass C.8 "variant assignment kept" || fail C.8 "variant.json missing"
summary
