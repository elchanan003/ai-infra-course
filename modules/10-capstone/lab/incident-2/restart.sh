#!/usr/bin/env bash
# GIVEN (do not edit). Recreates mock-vllm A so it re-reads lab/incident-2/mock-vllm-a/args.
exec "$(cd "$(dirname "$0")/../.." && pwd)/lib/restart.sh" 2
