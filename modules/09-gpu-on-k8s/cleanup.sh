#!/usr/bin/env bash
# Module 09 cleanup: removes only runtime state this module created (kind cluster `aiinfra`, the compose stack, .state/ variant).
# Never touches lab/ (your files). Idempotent: the output is the same on every run.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/../../platform/lib.sh"
if kind get clusters 2>/dev/null | grep -qx aiinfra; then "$PLATFORM_DIR/k8s.sh" down >/dev/null 2>&1; fi
"$PLATFORM_DIR/stack.sh" down >/dev/null 2>&1
rm -rf "$MODULE_DIR/.state" "$MODULE_DIR/.last-verify"
echo "cleanup: kind cluster aiinfra removed, compose stack down, .state/ removed; lab/ untouched"
