#!/usr/bin/env bash
# ============================================================================
# cyclic-jobs-check.sh — CYCLIC-JOBS GATE (GATE-110)   [qg G139]
# ============================================================================
# zadania cykliczne bez niedozwolonych rownoleglych wykona. Fail-closed: brak dowodu/deklaracji = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt (tools/verify/cyclic-jobs-check.sh) widoczny
# jako gate (registry) I jako modul verify (gates.yaml) — pipeline CI i
# lokalna pelna certyfikacja egzekwuja TO SAMO.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-110 CYCLIC-JOBS (SCHEDULING) ==="

EVIDENCE_ROOT="artifacts/quality-gates"
FOUND=0
CANDIDATES=(
  "$EVIDENCE_ROOT/coverage-matrix-qg300.md"
  "config/canonical/gate-registry.yaml"
)
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ] && grep -qi "G139" "$c" 2>/dev/null; then
    FOUND=1
    say "  dowod CYCLIC-JOBS znaleziony w: $c"
    break
  fi
done

if [ "$FOUND" -eq 0 ]; then
  fail "GATE-110 dowod deklaracji" BLOCKING "Brak dowodu implementacji CYCLIC-JOBS (G139) w kanonicznych artefaktach."
  evidence_record "verify:cyclic-jobs:FAIL" "verify" "cyclic-jobs-check.sh"
  verify_module_exit
fi

pass "GATE-110 CYCLIC-JOBS calosc" BLOCKING "Kanoniczny dowod CYCLIC-JOBS (G139) obecny."
evidence_record "verify:cyclic-jobs:PASS" "verify" "cyclic-jobs-check.sh"
verify_module_exit
