#!/usr/bin/env bash
# Remove runtime state of module 08: mock faults, scratch files. Never touches lab/.
set -uo pipefail
MOD="$(cd "$(dirname "$0")" && pwd)"
for u in http://127.0.0.1:18021 http://127.0.0.1:18022; do curl -s -m 3 -X DELETE "$u/admin/fault" >/dev/null 2>&1; done
rm -rf "$MOD/.state/run" "$MOD/.state/traffic-runs.jsonl" "$MOD/.last-verify"
echo "cleanup: module 08 runtime state removed (stack left as is; use platform/stack.sh down)"
