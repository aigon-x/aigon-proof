#!/usr/bin/env bash
# GATE-D2: explicit JSON graph and complete execution trace validation.
# Usage: plan-parallelism.sh FILE [--validate-plan-only]
#        AIGON_QUALITY_PLAN_FILE=FILE plan-parallelism.sh
#        plan-parallelism.sh --selftest
# Exit 0 = checked trace PASS or explicitly scoped PLAN_VALID;
# exit 1 = FAIL; exit 2 = UNVERIFIED. MAX_VIOLATIONS is not supported.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/../.." && pwd)"
exec python3 -B "$project_root/tools/quality/plan_parallelism_gate.py" "$@"
