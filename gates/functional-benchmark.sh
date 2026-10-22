#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# tools/gates/functional-benchmark.sh — gate functional-benchmark
# (hook-runner). Wrapper na scripts/functional-benchmark.sh (standard:
# F1 pytest 135, F2 TESTFORGE fast, F3 cerberus artefakt, F4 bash -n,
# F5 YAML SSOT, F6 sync dry-run stabilnosc, F7 coverage-matrix).
# Pełny przebieg L0-L6 (tools/test full) — na żądanie: --full.
# Kontrakt: exit 0 = PASS, 1 = FAIL, 2 = WARN.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out=$(bash "$ROOT/scripts/functional-benchmark.sh" "${1:-}" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
  echo "PASS functional-benchmark (7/7 suite'ow zielonych — pytest/TESTFORGE/cerberus/bash/yaml/sync/coverage; raport: reports/functional-benchmark/latest.summary)"
else
  echo "$out" | grep -E 'FAIL F|WARN F|═══' | head -8
  echo "FAIL functional-benchmark (rc=$rc — patrz reports/functional-benchmark/latest.summary)"
fi
exit "$rc"
