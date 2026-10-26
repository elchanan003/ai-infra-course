#!/usr/bin/env bash
# Module 00 cleanup: stop the course stack (volumes kept) and drop runtime state. Never touches lab/
# or .state/variant.json. Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
rm -rf "$MODULE_DIR/.state/runtime" "$MODULE_DIR/.state/foreign.txt"
echo "cleanup: course stack down, runtime state removed (lab/ untouched)"
