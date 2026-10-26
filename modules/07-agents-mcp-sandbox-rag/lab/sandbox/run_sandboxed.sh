#!/usr/bin/env bash
# Task 7.3 - run an untrusted Python script in a container.
# Usage: run_sandboxed.sh SCRIPT.py [TIMEOUT_SECONDS]      (default 10, maximum 30)
# STARTER: runs the job with NO isolation, no timeout, no cleanup. Fix that.
set -uo pipefail
SCRIPT="${1:?usage: run_sandboxed.sh SCRIPT.py [TIMEOUT_SECONDS]}"
TIMEOUT="${2:-10}"
IMAGE="${SANDBOX_IMAGE:-python:3.12-slim}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

# TODO(7.3): unique name sbx-<random>, label course=aiinfra, hardening flags, two timeout layers, exit 124, cleanup
exec docker run --rm --pull never -v "$SCRIPT:/job/script.py:ro" "$IMAGE" python /job/script.py
