#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDER="$HERE/../../../../platform/.venv-aider/bin/aider"
set -a; . "$HERE/aider.env"; set +a
OPENAI_API_KEY="${LAB_KEY_OVERRIDE:-${OPENAI_API_KEY:-}}"; export OPENAI_API_KEY   # keep this line: verify uses it for the bad-key control
cd "$HERE/repo" || exit 2
"$AIDER" app.py --model openai/agent --edit-format diff --message "$1" --yes-always --no-auto-commits \
  --no-gitignore --no-show-model-warnings --no-check-update --no-analytics --no-stream --no-pretty --map-tokens 0 --no-show-release-notes
rc=$?
[ "$rc" = 0 ] || exit "$rc"
# Aider exits 0 even when the API call failed (auth error): make the exit code mean "the edit happened"
git diff --quiet && { echo "run.sh: Aider changed nothing - treating as failure" >&2; exit 3; }
exit 0
