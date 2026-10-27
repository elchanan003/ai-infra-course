#!/usr/bin/env bash
# GIVEN (do not edit). Recreates both gateway replicas so they re-read lab/incident-1/litellm/config.yaml.
exec "$(cd "$(dirname "$0")/../.." && pwd)/lib/restart.sh" 1
