#!/usr/bin/env bash
# Serialize whole lab cycles (prepare -> verify -> cleanup) on this shared host.
#   platform/lab-session.sh <command...>
# Takes `flock -w 1800 /tmp/aiinfra-course-lab.lock` (waits up to 30 min, exit 75 on timeout), writes
# /tmp/aiinfra-course-lab.owner (pid, user, start time, command) while held, runs the command, releases.
# Re-entrant: nested calls inside a held session (AIINFRA_LAB_LOCK_HELD=1) just run the command.
# Example: platform/lab-session.sh bash -c 'modules/01-x/prepare-lab.sh && modules/01-x/verify.sh'
set -uo pipefail
[ $# -ge 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
LOCK=/tmp/aiinfra-course-lab.lock; OWNER=/tmp/aiinfra-course-lab.owner
if [ "${AIINFRA_LAB_LOCK_HELD:-}" = 1 ]; then exec "$@"; fi
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "lab-session: lock held by: $(cat "$OWNER" 2>/dev/null || echo unknown); waiting up to 30 min" >&2
  flock -w 1800 9 || { echo "lab-session: could not get the lab lock within 30 min" >&2; exit 75; }
fi
echo "pid=$$ user=$(id -un) since=$(date -u +%Y-%m-%dT%H:%M:%SZ) cmd=$*" > "$OWNER"
trap 'grep -q "^pid=$$ " "$OWNER" 2>/dev/null && rm -f "$OWNER"' EXIT
export AIINFRA_LAB_LOCK_HELD=1
"$@"
