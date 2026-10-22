#!/usr/bin/env bash
# Wrapper dla hook-runner: tools/gates/<id>.sh → python consistency.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/tools/gates/capability-consistency.py" "$@"
