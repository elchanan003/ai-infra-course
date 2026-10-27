#!/usr/bin/env bash
# Module 11 cleanup: removes runtime state only (.state, .last-verify). Never touches lab/. Idempotent.
set -uo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -rf "$MODULE_DIR/.state" "$MODULE_DIR/.last-verify"
echo "cleanup: runtime state removed (lab/ untouched)"
