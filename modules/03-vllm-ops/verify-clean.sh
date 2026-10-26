#!/usr/bin/env bash
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
[ -z "$(docker ps -aq --filter label=lab=03-vllm-ops)" ] && pass C.1 "no scratch containers left" || fail C.1 "scratch mock containers still exist"
[ -z "$(docker ps -aq --filter name=^aiinfra-mock-vllm- --filter label=course=aiinfra)" ] && pass C.2 "no mock-vllm stack containers" || fail C.2 "mock-vllm stack containers still exist"
[ ! -d "$MOD/.state/run" ] && pass C.3 "scratch run dirs removed" || fail C.3 ".state/run still present"
[ -d "$MOD/lab" ] && [ -f "$MOD/lab/slo/SLO.md" ] && pass C.4 "lab/ untouched" || fail C.4 "lab/ content missing"
summary
