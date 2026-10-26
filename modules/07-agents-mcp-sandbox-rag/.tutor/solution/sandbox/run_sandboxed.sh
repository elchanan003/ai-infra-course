#!/usr/bin/env bash
# Reference solution 7.3: hardened, two timeout layers, named + labelled, always cleaned up.
set -uo pipefail
SCRIPT="${1:?usage: run_sandboxed.sh SCRIPT.py [TIMEOUT_SECONDS]}"
T="${2:-10}"
[[ "$T" =~ ^[0-9]+$ ]] || { echo "timeout must be an integer" >&2; exit 64; }
(( T < 1 )) && T=1
(( T > 30 )) && T=30
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 64; }
IMAGE="${SANDBOX_IMAGE:-python:3.12-slim}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
NAME="sbx-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FLAG="$(mktemp)"
WD=""
cleanup() {
  if [ -n "$WD" ]; then pkill -P "$WD" 2>/dev/null; kill "$WD" 2>/dev/null; fi
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -f "$FLAG"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
start=$SECONDS
docker run --name "$NAME" --label course=aiinfra --label module=07 --pull never \
  --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m,mode=1777 \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 64 --memory 256m --memory-swap 256m --cpus 1 --ulimit nofile=256 \
  --user 65534:65534 -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$SCRIPT:/job/script.py:ro" "$IMAGE" timeout -k 1 "$T" python /job/script.py &
PID=$!
( sleep $((T + 3)); echo timeout > "$FLAG"; docker kill "$NAME" >/dev/null 2>&1 ) >/dev/null 2>&1 &
WD=$!
wait "$PID"; rc=$?
if [ -s "$FLAG" ]; then rc=124
elif [ "$rc" -eq 137 ] && (( SECONDS - start >= T )); then rc=124; fi
exit "$rc"
