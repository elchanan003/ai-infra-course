#!/bin/bash
# mock/tests/run_tests.sh [pytest args]   -- unit + integration tests for aiinfra-mock / aiinfra-tripwire
# Creates mock/.venv-test (uv) on first use. Docker tests are serialized through the course lab lock.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; MOCK="$(dirname "$HERE")"
VENV="$MOCK/.venv-test"
if [ ! -x "$VENV/bin/python" ]; then
  uv venv --python 3.12 -q "$VENV"
  uv pip install -q --python "$VENV/bin/python" -r "$MOCK/requirements.txt" pytest httpx
fi
cd "$HERE"
export PYTHONPATH="$MOCK"
if [ "${SKIP_DOCKER:-0}" = "1" ]; then
  exec "$VENV/bin/python" -m pytest -q -m "not docker" "$@"
fi
"$VENV/bin/python" -m pytest -q -m "not docker" "$@"
flock -w 1800 /tmp/aiinfra-course-lab.lock "$VENV/bin/python" -m pytest -q -m docker "$@"
