#!/usr/bin/env bash
# Reference fix for task T: no privileged, no docker socket, no host /etc; only the job directory, read-only.
set -uo pipefail
SCRIPT="$(cd "$(dirname "${1:?usage: legacy_runner.sh SCRIPT.py [TIMEOUT_SECONDS]}")" && pwd)/$(basename "$1")"
T="${2:-20}"
IMAGE="${SANDBOX_IMAGE:-python:3.12-slim}"
JOBDIR="$(dirname "$SCRIPT")"

exec timeout -k 2 "$T" docker run --rm --pull never \
  --label course=aiinfra --label module=07 --label role=legacy \
  --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m,mode=1777 \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 --memory 256m --memory-swap 256m \
  --user 65534:65534 -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$JOBDIR:/job:ro" \
  "$IMAGE" python "/job/$(basename "$SCRIPT")"
