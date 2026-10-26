#!/usr/bin/env bash
# The platform team's runner for the "report-bot" agent (code review: approved, tests green).
# Usage: legacy_runner.sh SCRIPT.py [TIMEOUT_SECONDS]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$(dirname "${1:?usage: legacy_runner.sh SCRIPT.py [TIMEOUT]}")" && pwd)/$(basename "$1")"
T="${2:-20}"
IMAGE="${SANDBOX_IMAGE:-python:3.12-slim}"
JOBDIR="$(dirname "$SCRIPT")"
SOCK="$HERE/../../.state/run/dockerd.sock"   # lets report-bot "inspect its own container"

exec timeout -k 2 "$T" docker run --rm --pull never \
  --label course=aiinfra --label module=07 --label role=legacy \
  --network none --privileged \
  -v "$JOBDIR:/job:ro" \
  -v "$SOCK:/var/run/docker.sock" \
  -v /etc:/host/etc:ro \
  "$IMAGE" python "/job/$(basename "$SCRIPT")"
