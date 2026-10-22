#!/usr/bin/env bash
# M4 tests only: strict coverage accounting; UNKNOWN is never a detected mutation.
set -euo pipefail
unset PYTHONOPTIMIZE PYTHONPATH PYTHONHOME BASH_ENV ENV
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/tools/gates/tests/m4/negative_suite.py" "$@"
