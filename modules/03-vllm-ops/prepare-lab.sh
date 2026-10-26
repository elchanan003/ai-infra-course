#!/usr/bin/env bash
# Module 03: bring up profile `mock` reading its flags from lab/vllm-a and lab/vllm-b, seed the per-learner variant,
# write starter/given files. Idempotent; never overwrites files you edited; never reveals answers.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
source "$MOD/../../platform/lib.sh"
PLATFORM="$MOD/../../platform"
python3 "$MOD/harness/gen.py" init || { echo "prepare: variant generation failed" >&2; exit 1; }
mkdir -p "$MOD/lab/tools" "$MOD/.state/run"
for f in apply.sh load.py snapshot.sh; do ln -sf "../../harness/$f" "$MOD/lab/tools/$f"; done
chmod -R a+rX "$MOD/lab"
for c in $(docker ps -aq --filter label=lab=03-vllm-ops); do docker rm -f "$c" >/dev/null 2>&1; done
export MOCK_VLLM_A_CONFIG_DIR="$MOD/lab/vllm-a" MOCK_VLLM_B_CONFIG_DIR="$MOD/lab/vllm-b"
# vllm-a starts broken on purpose (task 3.2): STACK_ALLOW_EXITED tolerates the exited container.
STACK_ALLOW_EXITED=1 "$PLATFORM/stack.sh" up mock || { echo "prepare: stack up mock failed" >&2; exit 1; }
for t in a b; do docker restart "aiinfra-mock-vllm-$t-1" >/dev/null 2>&1; done
sleep 2
precond "mock-vllm-b healthy (:18022)" wait_http "$MOCK_B_URL/health" 30
precond "mock-vllm-a up (task 3.2 starts it broken: exited is expected until you fix lab/vllm-a/args)" true
echo "Ready. Read modules/03-vllm-ops/lab.md. Edit only files under lab/ marked 'yours'."
