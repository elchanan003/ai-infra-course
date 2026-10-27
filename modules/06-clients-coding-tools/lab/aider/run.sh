#!/usr/bin/env bash
# Lab 06 task 6.2 (yours): run Aider headless on the scratch repo with one instruction:  ./run.sh "set the banner to HELLO123"
# Aider is /home/student/ai-infra-course/platform/.venv-aider/bin/aider. verify.sh calls this script itself.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDER="$HERE/../../../../platform/.venv-aider/bin/aider"
set -a; . "$HERE/aider.env"; set +a
OPENAI_API_KEY="${LAB_KEY_OVERRIDE:-${OPENAI_API_KEY:-}}"; export OPENAI_API_KEY   # keep this line: verify uses it for the bad-key control
cd "$HERE/repo" || exit 2
# Note: Aider can exit 0 even when its API call failed - decide what exit code your script should report.
# TODO: run "$AIDER" app.py --message "$1" ... (model name, edit format, non-interactive, no network chatter, no auto-commit)
echo "run.sh: not implemented" >&2; exit 2
