#!/usr/bin/env bash
# Module 01 cleanup: remove lab containers and stop the stack (volumes kept). Never touches lab/ or
# .state/variant.json. Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
docker ps -aq --filter name=aiinfra-lab01- --filter label=course=aiinfra | xargs -r docker rm -f >/dev/null 2>&1
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
rm -rf "$MODULE_DIR/.state/runtime"
echo "cleanup: lab containers removed, course stack down (lab/ untouched)"
