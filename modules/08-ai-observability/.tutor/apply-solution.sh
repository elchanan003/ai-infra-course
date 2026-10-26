#!/usr/bin/env bash
# Validation helper: back up lab/, install the reference solution, reload Prometheus (solution-side apply step).
set -uo pipefail
MOD="$(cd "$(dirname "$0")/.." && pwd)"
ts=$(date +%Y%m%d-%H%M%S); cp -a "$MOD/lab" "$MOD/lab.bak-$ts"
cp -a "$MOD/.tutor/solution/lab/." "$MOD/lab/"
chmod -R a+rX "$MOD/lab"
curl -s -X POST http://127.0.0.1:18090/-/reload >/dev/null 2>&1 && echo "prometheus reloaded"
echo "solution applied (backup: lab.bak-$ts)"
